import CoreBluetooth
import Foundation
import NetworkExtension
import UIKit

@MainActor
final class ImportBLETransport: NSObject, ObservableObject {
    @Published var bluetoothState = "Bluetooth: starting"
    @Published var isScanning = false
    @Published var devices: [ImportDevice] = []
    @Published var connectedName = "not connected"
    @Published var writeTarget = "none"
    @Published var lastWrite = "none"
    @Published var lastNotify = "none"
    @Published var authStatus = "Connect the glasses"
    @Published var wifiSSID = ""
    @Published var wifiPassword = ""
    @Published var wifiGateway = "192.168.43.1"
    @Published var hasSavedToken = false
    @Published private(set) var notificationsReady = false
    @Published var log: [String] = []

    private enum AuthStage {
        case idle
        case waitingForStartResponse
        case waitingForDeviceVerify
        case waitingForDeviceConfirm
        case authenticated
        case waitingForWiFi
    }

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connected: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var receiveStream = MIWFrameStream()
    private var writeQueue: [Data] = []
    private var awaitingWriteResponse = false
    private var lastReceivedFrame: Data?
    private var txSequence: UInt8 = 0
    private var stage: AuthStage = .idle
    private var token: Data?
    private var appRandom: Data?
    private var sessionKeys: MIWSessionKeys?
    private var importRequestTask: Task<Void, Never>?
    private var sessionID = UUID()

    private let fe95Service = CBUUID(string: "FE95")
    private let writeUUID = CBUUID(string: "005F")
    private let notifyUUID = CBUUID(string: "005E")

    override init() {
        super.init()
        hasSavedToken = MIWTokenVault.load() != nil
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var canAuthenticate: Bool {
        connected?.state == .connected && writeCharacteristic != nil && notificationsReady
            && (stage == .idle || stage == .authenticated)
    }

    var canOpenWiFi: Bool {
        stage == .authenticated
    }

    func startScan() {
        guard central.state == .poweredOn else {
            appendLog("Scan skipped: Bluetooth is not powered on")
            return
        }
        devices.removeAll()
        peripherals.removeAll()
        isScanning = true
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        appendLog("Scan started; filtering bands and watches")
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        appendLog("Scan stopped")
    }

    func connect(_ device: ImportDevice) {
        guard let peripheral = peripherals[device.id] else { return }
        if connected === peripheral && peripheral.state != .disconnected { return }
        stopScan()
        if let previous = connected { central.cancelPeripheralConnection(previous) }
        resetSession(keepStatus: true)
        writeCharacteristic = nil
        notifyCharacteristic = nil
        notificationsReady = false
        writeTarget = "none"
        connectedName = "connecting \(device.name)"
        authStatus = "Connecting"
        connected = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        appendLog("Connecting to \(device.name)")
    }

    func disconnect() {
        resetSession(keepStatus: false)
        notificationsReady = false
        if let connected { central.cancelPeripheralConnection(connected) }
    }

    func authenticateAndOpenWiFi(tokenText: String) {
        guard canAuthenticate else {
            authStatus = "FE95/005E and 005F are not ready"
            appendLog(authStatus)
            return
        }

        let trimmed = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedToken: Data?
        if trimmed.isEmpty {
            selectedToken = MIWTokenVault.load()
        } else {
            selectedToken = Data(importHexString: trimmed)
        }
        guard let selectedToken, !selectedToken.isEmpty else {
            authStatus = "Enter the pairing token once"
            appendLog("No valid hexadecimal pairing token")
            return
        }

        resetSession(keepStatus: true)
        token = selectedToken
        do {
            appRandom = try MIWProtocol.secureRandom(count: 16)
        } catch {
            fail(error)
            return
        }

        stage = .waitingForStartResponse
        armTimeout("L1 START response")
        authStatus = "Starting MIWear transport"
        sendFrame(type: 2, sequence: 0, payload: MIWProtocol.l1StartPayload)
        appendLog("L1 START request sent")
    }

    func openImportWiFi() {
        guard canOpenWiFi else {
            appendLog("Authenticate before requesting Wi-Fi")
            return
        }
        requestCurrentWiFiAP()
    }

    func clearSavedToken() {
        MIWTokenVault.clear()
        hasSavedToken = false
        authStatus = "Saved token removed"
        appendLog("Pairing token removed from Keychain")
    }

    private func resetSession(keepStatus: Bool) {
        importRequestTask?.cancel()
        importRequestTask = nil
        sessionID = UUID()
        receiveStream = MIWFrameStream()
        writeQueue.removeAll()
        awaitingWriteResponse = false
        lastReceivedFrame = nil
        txSequence = 0
        stage = .idle
        token = nil
        appRandom = nil
        sessionKeys = nil
        wifiSSID = ""
        wifiPassword = ""
        if !keepStatus { authStatus = "Connect the glasses" }
    }

    private func sendAppVerify() {
        guard stage == .waitingForStartResponse, let appRandom else { return }
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
        let packet = MIWProtocol.buildAppVerify(appRandom: appRandom, appDeviceID: deviceID)
        stage = .waitingForDeviceVerify
        armTimeout("DeviceVerify")
        authStatus = "Verifying pairing token"
        sendL2(channel: 1, opcode: 1, payload: packet)
        appendLog("AppVerify sent: \(MIWProtocol.packetSummary(packet))")
    }

    private func handleAuthPacket(_ packet: Data) {
        do {
            switch stage {
            case .waitingForDeviceVerify:
                guard let token, let appRandom else {
                    throw MIWProtocolError.malformedPacket("authentication state was lost")
                }
                let verify = try MIWProtocol.parseDeviceVerify(packet)
                let keys = MIWProtocol.deriveKeys(
                    token: token,
                    appRandom: appRandom,
                    deviceRandom: verify.random
                )
                guard MIWProtocol.verifyDeviceSignature(
                    verify.signature,
                    keys: keys,
                    appRandom: appRandom,
                    deviceRandom: verify.random
                ) else {
                    throw MIWProtocolError.deviceSignatureMismatch
                }

                sessionKeys = keys
                let version = ProcessInfo.processInfo.operatingSystemVersion
                let systemVersion = Float("\(version.majorVersion).\(version.minorVersion)") ?? 15.0
                let packet = try MIWProtocol.buildAppConfirm(
                    keys: keys,
                    appRandom: appRandom,
                    deviceRandom: verify.random,
                    deviceName: UIDevice.current.name,
                    systemVersion: systemVersion,
                    region: Locale.current.regionCode ?? ""
                )
                stage = .waitingForDeviceConfirm
                armTimeout("DeviceConfirm")
                authStatus = "Confirming encrypted session"
                sendL2(channel: 1, opcode: 1, payload: packet)
                appendLog("Device signature valid; AppConfirm sent")

            case .waitingForDeviceConfirm:
                guard try MIWProtocol.parseDeviceConfirm(packet) else {
                    throw MIWProtocolError.deviceRejectedAuthentication
                }
                stage = .authenticated
                if let token {
                    MIWTokenVault.save(token)
                    hasSavedToken = MIWTokenVault.load() == token
                }
                authStatus = "Authenticated"
                appendLog("MIWear authentication complete; iOS AES-CTR session ready")
                requestCurrentWiFiAP()

            default:
                appendLog("Unexpected plaintext \(MIWProtocol.packetSummary(packet))")
            }
        } catch {
            fail(error)
        }
    }

    private func requestCurrentWiFiAP() {
        guard sessionKeys != nil else { return }
        sessionID = UUID()
        wifiSSID = ""
        wifiPassword = ""
        stage = .waitingForWiFi
        armTimeout("Wi-Fi AP result", seconds: 30)
        authStatus = "Requesting import Wi-Fi"
        do {
            try sendEncrypted(MIWProtocol.iOSWiFiAPRequest())
            appendLog("Sent SYSTEM / ENABLE_WIFI_AP (type=2 id=88)")
        } catch {
            fail(error)
        }
    }

    private func sendEncrypted(_ packet: Data) throws {
        guard let keys = sessionKeys else {
            throw MIWProtocolError.malformedPacket("session keys are unavailable")
        }
        let encrypted = try MIWProtocol.sealSessionPacket(packet, keys: keys)
        sendL2(channel: 1, opcode: 2, payload: encrypted)
        appendLog("CTR encrypted \(MIWProtocol.packetSummary(packet))")
    }

    private func handleL2(_ payload: Data) {
        guard payload.count >= 2 else {
            appendLog("Ignored short L2 packet")
            return
        }
        let channel = payload[0]
        let opcode = payload[1]
        let body = Data(payload.dropFirst(2))
        guard channel == 1 else {
            appendLog("Ignored L2 channel=\(channel), opcode=\(opcode), len=\(body.count)")
            return
        }

        if opcode == 1 {
            handleAuthPacket(body)
            return
        }
        guard opcode == 2, let keys = sessionKeys else {
            appendLog("Unexpected PB opcode=\(opcode), len=\(body.count)")
            return
        }

        do {
            let opened = try MIWProtocol.openSessionPacket(body, keys: keys)
            appendLog("CTR decrypted \(MIWProtocol.packetSummary(opened))")
            if let credentials = MIWProtocol.parseWiFiCredentials(opened) {
                acceptWiFiCredentials(credentials)
            }
        } catch {
            appendLog("Session decrypt failed: \(error.localizedDescription)")
        }
    }

    private func acceptWiFiCredentials(_ credentials: MIWWiFiCredentials) {
        guard stage == .waitingForWiFi else { return }
        importRequestTask?.cancel()
        stage = .authenticated
        wifiSSID = credentials.ssid
        wifiPassword = credentials.password
        wifiGateway = credentials.gateway.isEmpty ? "192.168.43.1" : credentials.gateway
        authStatus = "Wi-Fi credentials received"
        appendLog("AP credentials: SSID=\(credentials.ssid), gateway=\(wifiGateway)")
        joinWiFi(credentials)
    }

    private func joinWiFi(_ credentials: MIWWiFiCredentials) {
        let configuration: NEHotspotConfiguration
        if credentials.password.isEmpty {
            configuration = NEHotspotConfiguration(ssid: credentials.ssid)
        } else {
            configuration = NEHotspotConfiguration(
                ssid: credentials.ssid,
                passphrase: credentials.password,
                isWEP: false
            )
        }
        configuration.joinOnce = true
        let requestSession = sessionID
        authStatus = "Joining \(credentials.ssid)"
        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            Task { @MainActor in
                guard let self, self.sessionID == requestSession else { return }
                if let error = error as NSError?,
                   !(error.domain == NEHotspotConfigurationErrorDomain &&
                     error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue) {
                    self.authStatus = "Wi-Fi join failed: \(error.localizedDescription)"
                    self.appendLog(self.authStatus)
                } else {
                    self.authStatus = "Connected to import Wi-Fi"
                    self.appendLog("iOS accepted the hotspot configuration")
                }
            }
        }
    }

    private func processNotification(_ data: Data) {
        for frame in receiveStream.append(data) { handleFrame(frame) }
    }

    private func handleFrame(_ frame: Data) {
        let rawType = frame[2]
        let type = rawType & 0x0F
        let sequence = frame[3]
        let length = Int(frame[4]) | (Int(frame[5]) << 8)
        let expectedCRC = UInt16(frame[6]) | (UInt16(frame[7]) << 8)
        let payload = frame.subdata(in: 8..<(8 + length))
        guard crc16ARC(payload) == expectedCRC else {
            appendLog("Dropped L1 frame with bad CRC")
            return
        }

        switch type {
        case 1:
            appendLog("L1 ACK seq=\(sequence)")
        case 2:
            appendLog("L1 CMD seq=\(sequence) code=\(payload.first ?? 0)")
            if payload.first == 2 { sendAppVerify() }
        case 3:
            sendFrame(type: 1, sequence: sequence, payload: Data())
            guard frame != lastReceivedFrame else { return }
            lastReceivedFrame = frame
            handleL2(payload)
        default:
            appendLog("Ignored L1 type=\(type), seq=\(sequence)")
        }
    }

    private func sendL2(channel: UInt8, opcode: UInt8, payload: Data) {
        var l2 = Data([channel, opcode])
        l2.append(payload)
        let sequence = txSequence
        txSequence &+= 1
        sendFrame(type: 3, sequence: sequence, payload: l2)
    }

    private func sendFrame(type: UInt8, sequence: UInt8, payload: Data) {
        guard let peripheral = connected, let characteristic = writeCharacteristic else {
            appendLog("No FE95/005F write characteristic")
            return
        }
        var frame = Data([0xA5, 0xA5, type, sequence])
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(UInt8((payload.count >> 8) & 0xFF))
        let crc = crc16ARC(payload)
        frame.append(UInt8(crc & 0xFF))
        frame.append(UInt8((crc >> 8) & 0xFF))
        frame.append(payload)

        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        let maximum = peripheral.maximumWriteValueLength(for: writeType)
        guard maximum > 0, writeQueue.count < 512 else {
            fail(MIWProtocolError.malformedPacket("BLE write queue is unavailable"))
            return
        }
        for offset in stride(from: 0, to: frame.count, by: maximum) {
            writeQueue.append(frame.subdata(in: offset..<min(offset + maximum, frame.count)))
        }
        lastWrite = "\(frame.count) B \(Data(frame.prefix(40)).importHexString)"
        drainWrites()
    }

    private func drainWrites() {
        guard let peripheral = connected, peripheral.state == .connected,
              let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        while !writeQueue.isEmpty {
            if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse { return }
            if type == .withResponse && awaitingWriteResponse { return }
            let fragment = writeQueue.removeFirst()
            if type == .withResponse { awaitingWriteResponse = true }
            peripheral.writeValue(fragment, for: characteristic, type: type)
        }
    }

    private func armTimeout(_ response: String, seconds: UInt64 = 20) {
        importRequestTask?.cancel()
        importRequestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.fail(MIWProtocolError.malformedPacket("timed out waiting for \(response)"))
        }
    }

    private func crc16ARC(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    private func isBFA7Candidate(name: String, advertisementData: [String: Any]) -> Bool {
        let lower = name.lowercased()
        if lower.contains("band") || lower.contains("watch") { return false }
        if lower.contains("bfa7") || lower.contains("glass") { return true }
        if lower.contains("xiaomi") || lower.contains("mijia") { return true }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return services.contains(fe95Service) && !lower.contains("ble device")
    }

    private func fail(_ error: Error) {
        resetSession(keepStatus: true)
        authStatus = error.localizedDescription
        appendLog("ERROR: \(error.localizedDescription)")
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.insert("[\(formatter.string(from: Date()))] \(line)", at: 0)
        if log.count > 120 { log.removeLast(log.count - 120) }
    }

    private func shortUUID(_ uuid: CBUUID) -> String {
        uuid.uuidString.uppercased()
    }
}

extension ImportBLETransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: bluetoothState = "Bluetooth: powered on"
            case .poweredOff: bluetoothState = "Bluetooth: powered off"
            case .unauthorized: bluetoothState = "Bluetooth: unauthorized"
            case .unsupported: bluetoothState = "Bluetooth: unsupported"
            case .resetting: bluetoothState = "Bluetooth: resetting"
            case .unknown: bluetoothState = "Bluetooth: unknown"
            @unknown default: bluetoothState = "Bluetooth: unknown"
            }
            if central.state != .poweredOn {
                notificationsReady = false
                writeCharacteristic = nil
                notifyCharacteristic = nil
                connected = nil
                connectedName = "not connected"
                writeTarget = "none"
                isScanning = false
                resetSession(keepStatus: false)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            let name = peripheral.name
                ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? "BLE device"
            guard isBFA7Candidate(name: name, advertisementData: advertisementData) else { return }
            peripherals[peripheral.identifier] = peripheral
            let item = ImportDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
            if let index = devices.firstIndex(where: { $0.id == item.id }) {
                devices[index] = item
            } else {
                devices.append(item)
                devices.sort { $0.rssi > $1.rssi }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard connected === peripheral else { return }
            connectedName = peripheral.name ?? peripheral.identifier.uuidString
            authStatus = "Discovering FE95 service"
            appendLog("Connected: \(connectedName)")
            peripheral.discoverServices([fe95Service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard connected === peripheral else { return }
            connected = nil
            resetSession(keepStatus: true)
            connectedName = "connect failed"
            authStatus = "Connection failed"
            appendLog("Connect failed: \(error?.localizedDescription ?? "unknown")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard connected === peripheral else { return }
            connected = nil
            notificationsReady = false
            connectedName = "not connected"
            writeTarget = "none"
            writeCharacteristic = nil
            notifyCharacteristic = nil
            resetSession(keepStatus: false)
            appendLog("Disconnected: \(error?.localizedDescription ?? "normal")")
        }
    }
}

extension ImportBLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard connected === peripheral else { return }
            if let error { appendLog("Service discovery error: \(error.localizedDescription)") }
            guard let service = peripheral.services?.first(where: { $0.uuid == fe95Service }) else {
                authStatus = "FE95 service not found"
                return
            }
            peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard connected === peripheral else { return }
            if let error { appendLog("Characteristic discovery error: \(error.localizedDescription)") }
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == notifyUUID,
                   characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    notifyCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                    appendLog("Subscribed to FE95/005E")
                }
                let writable = characteristic.properties.contains(.write)
                    || characteristic.properties.contains(.writeWithoutResponse)
                if characteristic.uuid == writeUUID, writable {
                    writeCharacteristic = characteristic
                    writeTarget = "FE95/005F"
                    appendLog("Selected FE95/005F write target")
                }
            }
            if canAuthenticate {
                authStatus = hasSavedToken ? "Ready; saved token available" : "Ready; pairing token required once"
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard connected === peripheral, characteristic.uuid == notifyUUID else { return }
            notificationsReady = error == nil && characteristic.isNotifying
            if let error {
                fail(error)
            } else {
                appendLog("Notify \(shortUUID(characteristic.uuid)) enabled=\(characteristic.isNotifying)")
                if canAuthenticate { authStatus = "Ready for authentication" }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        Task { @MainActor in
            guard connected === peripheral else { return }
            if let error {
                appendLog("Notify error: \(error.localizedDescription)")
                return
            }
            guard characteristic.uuid == notifyUUID, let data = value else { return }
            lastNotify = "\(data.count) B \(Data(data.prefix(40)).importHexString)"
            processNotification(data)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard connected === peripheral, characteristic.uuid == writeUUID else { return }
            awaitingWriteResponse = false
            if let error { fail(error); return }
            drainWrites()
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            guard connected === peripheral else { return }
            drainWrites()
        }
    }
}
