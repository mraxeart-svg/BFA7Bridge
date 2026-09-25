import CoreBluetooth
import Foundation

@MainActor
final class ImportBLETransport: NSObject, ObservableObject {
    @Published var bluetoothState = "Bluetooth: starting"
    @Published var isScanning = false
    @Published var devices: [ImportDevice] = []
    @Published var connectedName = "not connected"
    @Published var writeTarget = "none"
    @Published var lastWrite = "none"
    @Published var lastNotify = "none"
    @Published var log: [String] = []

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connected: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var sequence: UInt8 = 0x80

    private let fe95Service = CBUUID(string: "FE95")
    private let writeUUID = CBUUID(string: "005F")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    var canWrite: Bool {
        connected != nil && writeCharacteristic != nil
    }

    func startScan() {
        guard central.state == .poweredOn else {
            appendLog("Scan skipped: Bluetooth is not powered on")
            return
        }
        devices.removeAll()
        peripherals.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        appendLog("Scan started")
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        appendLog("Scan stopped")
    }

    func connect(_ device: ImportDevice) {
        guard let peripheral = peripherals[device.id] else { return }
        stopScan()
        connectedName = "connecting \(device.name)"
        writeTarget = "none"
        writeCharacteristic = nil
        connected = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        appendLog("Connecting to \(device.name)")
    }

    func disconnect() {
        if let connected = connected {
            central.cancelPeripheralConnection(connected)
        }
    }

    func writeAESCTRAPTrigger(appKeyText: String) {
        guard let appKey = Data(importHexString: appKeyText), appKey.count == 16 else {
            appendLog("Need 16-byte appKey hex")
            return
        }
        guard let peripheral = connected, let characteristic = writeCharacteristic else {
            appendLog("No FE95/005F write characteristic")
            return
        }

        do {
            let plaintext = Data([
                0x08, 0x0E, 0x10, 0x05, 0x82, 0x01, 0x0E, 0x2A, 0x0C, 0x08, 0x00,
                0x10, 0x00, 0x18, 0x00, 0x20, 0x00, 0x28, 0x00, 0x30, 0x01
            ])
            let cipher = try MIWBTAESCTR.encrypt(plaintext, key: appKey, initialCounter: appKey)
            var payload = Data([0x01, 0x02])
            payload.append(cipher)
            let frame = a5PayloadFrame(payload: payload, sequence: sequence)
            sequence = sequence == 0xFF ? 0x80 : sequence &+ 1

            let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            peripheral.writeValue(frame, for: characteristic, type: writeType)
            lastWrite = frame.importHexString
            appendLog("Wrote AP trigger to \(shortUUID(characteristic.uuid)), len=\(frame.count), type=\(writeType == .withoutResponse ? "withoutResponse" : "withResponse")")
        } catch {
            appendLog("AES-CTR build failed: \(error.localizedDescription)")
        }
    }

    private func a5PayloadFrame(payload: Data, sequence: UInt8) -> Data {
        var frame = Data([0xA5, 0xA5, 0x03, sequence])
        frame.append(UInt8(payload.count & 0xff))
        frame.append(UInt8((payload.count >> 8) & 0xff))
        let crc = crc16ARC(payload)
        frame.append(UInt8(crc & 0xff))
        frame.append(UInt8((crc >> 8) & 0xff))
        frame.append(payload)
        return frame
    }

    private func crc16ARC(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0x0000
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    private func isBFA7Candidate(name: String, advertisementData: [String: Any]) -> Bool {
        let lower = name.lowercased()
        if lower.contains("bfa7") || lower.contains("xiaomi") || lower.contains("glasses") {
            return true
        }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return services.contains(fe95Service)
    }

    private func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.insert("[\(formatter.string(from: Date()))] \(line)", at: 0)
        if log.count > 80 {
            log.removeLast(log.count - 80)
        }
    }

    private func shortUUID(_ uuid: CBUUID) -> String {
        uuid.uuidString.uppercased()
    }
}

extension ImportBLETransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothState = "Bluetooth: powered on"
            case .poweredOff:
                bluetoothState = "Bluetooth: powered off"
            case .unauthorized:
                bluetoothState = "Bluetooth: unauthorized"
            case .unsupported:
                bluetoothState = "Bluetooth: unsupported"
            case .resetting:
                bluetoothState = "Bluetooth: resetting"
            case .unknown:
                bluetoothState = "Bluetooth: unknown"
            @unknown default:
                bluetoothState = "Bluetooth: unknown"
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
            let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "BLE device"
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
            connectedName = peripheral.name ?? peripheral.identifier.uuidString
            appendLog("Connected: \(connectedName)")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectedName = "connect failed"
            appendLog("Connect failed: \(error?.localizedDescription ?? "unknown")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectedName = "not connected"
            writeTarget = "none"
            writeCharacteristic = nil
            appendLog("Disconnected")
        }
    }
}

extension ImportBLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error = error { appendLog("Service discovery error: \(error.localizedDescription)") }
            for service in peripheral.services ?? [] {
                appendLog("Service \(shortUUID(service.uuid))")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error = error { appendLog("Characteristic discovery error: \(error.localizedDescription)") }
            for characteristic in service.characteristics ?? [] {
                let serviceID = shortUUID(service.uuid)
                let charID = shortUUID(characteristic.uuid)
                appendLog("Characteristic \(serviceID)/\(charID) props=\(characteristic.properties.rawValue)")

                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }

                let canWrite = characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)
                if service.uuid == fe95Service && characteristic.uuid == writeUUID && canWrite {
                    writeCharacteristic = characteristic
                    writeTarget = "FE95/005F"
                    appendLog("Selected FE95/005F as write target")
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error = error {
                appendLog("Notify error: \(error.localizedDescription)")
                return
            }
            guard let data = characteristic.value else { return }
            let preview = Data(data.prefix(32)).importHexString
            lastNotify = "\(shortUUID(characteristic.uuid)) len=\(data.count) \(preview)"
            appendLog("Notify \(lastNotify)")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error = error {
                appendLog("Write ack error: \(error.localizedDescription)")
            } else {
                appendLog("Write ack \(shortUUID(characteristic.uuid))")
            }
        }
    }
}
