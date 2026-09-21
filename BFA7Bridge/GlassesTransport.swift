import Foundation
import CoreBluetooth
import Combine

@MainActor
final class GlassesTransport: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var devices: [BFA7Device] = []
    @Published private(set) var isScanning = false
    @Published private(set) var log: [String] = []
    @Published private(set) var connectionState = "Не подключено"
    @Published private(set) var serviceCount = 0
    @Published private(set) var notificationCount = 0
    @Published private(set) var gattServices: [BFA7GATTService] = []
    @Published private(set) var writableCharacteristics: [String] = []
    @Published private(set) var lastButtonEvent: String = "—"
    @Published private(set) var buttonExperimentState = "Ожидание"
    @Published private(set) var buttonExperimentStartedAt: Date?
    @Published private(set) var buttonExperimentMarkedAt: Date?
    @Published private(set) var importExperimentState = "Ожидание"
    @Published private(set) var importExperimentStartedAt: Date?
    @Published private(set) var importExperimentMarkedAt: Date?
    @Published private(set) var capabilities: [BFA7Capability] = [
        .init(id: "ble", title: "Bluetooth LE", status: "Готов"),
        .init(id: "gatt", title: "GATT Explorer", status: "Готов"),
        .init(id: "command", title: "Command writes", status: "Лаборатория"),
        .init(id: "button", title: "Button / touch events", status: "Исследование"),
        .init(id: "wifi", title: "Wi-Fi media transfer", status: "Через Capture"),
        .init(id: "camera", title: "Camera media", status: "Через Capture"),
        .init(id: "microphone", title: "Microphone", status: "Через Ask"),
        .init(id: "audio", title: "Voice answer", status: "Через Ask")
    ]

    let eventBus = BFA7EventBus()
    let protocolLab = ProtocolLab()

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var currentPeripheral: CBPeripheral?
    private var subscribedCharacteristics: Set<String> = []
    private var writableCharacteristicKeys: Set<String> = []
    private var writableCharacteristicRefs: [CBCharacteristic] = []
    private let miBeaconService = CBUUID(string: "FE95")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard state == .poweredOn else {
            appendLog("Bluetooth недоступен: \(stateDescription)", kind: .error)
            return
        }

        devices.removeAll()
        peripherals.removeAll()
        currentPeripheral = nil
        serviceCount = 0
        notificationCount = 0
        writableCharacteristics.removeAll()
        writableCharacteristicRefs.removeAll()
        writableCharacteristicKeys.removeAll()
        subscribedCharacteristics.removeAll()
        gattServices.removeAll()
        isScanning = true

        appendLog("Сканирование BFA7", kind: .discovery)
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        appendLog("Сканирование остановлено", kind: .discovery)
    }

    func connect(_ device: BFA7Device) {
        guard let peripheral = peripherals[device.id] else {
            appendLog("BFA7: периферия не найдена в кеше", kind: .error)
            return
        }

        stopScan()
        connectionState = "Подключение..."
        appendLog("Подключение к \(device.name)", kind: .connection)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let currentPeripheral else { return }
        central.cancelPeripheralConnection(currentPeripheral)
    }

    func startButtonExperiment() {
        clearLog()
        let now = Date()
        buttonExperimentStartedAt = now
        buttonExperimentMarkedAt = nil
        buttonExperimentState = "Baseline: подожди 10 секунд"
        appendLog("BUTTON EXPERIMENT START", kind: .button, detail: "Idle baseline before physical camera button")
    }

    func markPhysicalButtonPress() {
        let now = Date()
        buttonExperimentMarkedAt = now
        buttonExperimentState = "Кнопка отмечена: жди 15 секунд"
        appendLog("BUTTON PRESS MARK", kind: .button, detail: "Physical camera button pressed by tester")
    }

    func finishButtonExperiment() -> String {
        buttonExperimentState = "Отчёт готов"
        let report = buttonExperimentReport
        appendLog("BUTTON EXPERIMENT REPORT GENERATED", kind: .button)
        return report
    }

    var buttonExperimentReport: String {
        var lines: [String] = []
        lines.append("BFA7 Button Experiment")
        lines.append("Generated: \(Self.timestamp())")
        lines.append("Target characteristic: prefer 005E if present")
        lines.append("Start: \(buttonExperimentStartedAt?.ISO8601Format() ?? "not marked")")
        lines.append("Button mark: \(buttonExperimentMarkedAt?.ISO8601Format() ?? "not marked")")
        lines.append("")

        let scopedEvents = eventBus.events.filter { event in
            guard let start = buttonExperimentStartedAt else { return true }
            if let mark = buttonExperimentMarkedAt {
                return event.date >= mark.addingTimeInterval(-10) && event.date <= mark.addingTimeInterval(15)
            }
            return event.date >= start
        }

        for event in scopedEvents {
            let relative: String
            if let mark = buttonExperimentMarkedAt {
                relative = String(format: "%+.3fs", event.date.timeIntervalSince(mark))
            } else if let start = buttonExperimentStartedAt {
                relative = String(format: "%+.3fs", event.date.timeIntervalSince(start))
            } else {
                relative = "+0.000s"
            }
            let detail = event.detail.isEmpty ? "" : " | \(event.detail)"
            lines.append("\(relative) | \(event.kind.rawValue.uppercased()) | \(event.title)\(detail)")
        }

        return lines.joined(separator: "\n")
    }

    func startImportExperiment() {
        clearLog()
        protocolLab.clear()
        let now = Date()
        importExperimentStartedAt = now
        importExperimentMarkedAt = nil
        importExperimentState = "Baseline: открой Xiaomi app и готовь Import"
        appendLog("IMPORT EXPERIMENT START", kind: .wifi, detail: "Idle baseline before Xiaomi Glasses Import action")
    }

    func markXiaomiImportPressed() {
        let now = Date()
        importExperimentMarkedAt = now
        importExperimentState = "Import отмечен: жди Wi-Fi prompt/server"
        appendLog("IMPORT PRESS MARK", kind: .wifi, detail: "Tester pressed Import in Xiaomi Glasses app")
    }

    func finishImportExperiment() -> String {
        importExperimentState = "Отчёт готов"
        let report = importExperimentReport
        appendLog("IMPORT EXPERIMENT REPORT GENERATED", kind: .wifi)
        return report
    }

    var importExperimentReport: String {
        var lines: [String] = []
        lines.append("BFA7 Import Experiment")
        lines.append("Generated: \(Self.timestamp())")
        lines.append("Goal: find BLE activity around Xiaomi Glasses Import mode start")
        lines.append("Start: \(importExperimentStartedAt?.ISO8601Format() ?? "not marked")")
        lines.append("Import mark: \(importExperimentMarkedAt?.ISO8601Format() ?? "not marked")")
        lines.append("Connection: \(connectionState)")
        lines.append("Writable characteristics: \(writableCharacteristics.joined(separator: ", "))")
        lines.append("")
        lines.append("Protocol summary:")
        lines.append(protocolLab.activityReport(around: importExperimentMarkedAt, label: "Import"))
        lines.append("")
        lines.append("Capture burst summary:")
        lines.append(protocolLab.captureBurstReport(around: importExperimentMarkedAt))
        lines.append("")
        lines.append("Scoped events:")

        let scopedEvents = eventBus.events.filter { event in
            guard let start = importExperimentStartedAt else { return true }
            if let mark = importExperimentMarkedAt {
                return event.date >= mark.addingTimeInterval(-15) && event.date <= mark.addingTimeInterval(30)
            }
            return event.date >= start
        }

        for event in scopedEvents {
            let relative: String
            if let mark = importExperimentMarkedAt {
                relative = String(format: "%+.3fs", event.date.timeIntervalSince(mark))
            } else if let start = importExperimentStartedAt {
                relative = String(format: "%+.3fs", event.date.timeIntervalSince(start))
            } else {
                relative = "+0.000s"
            }
            let detail = event.detail.isEmpty ? "" : " | \(event.detail)"
            lines.append("\(relative) | \(event.kind.rawValue.uppercased()) | \(event.title)\(detail)")
        }
        return lines.joined(separator: "\n")
    }

    func writeHexCommand(_ hexString: String) {
        guard let peripheral = currentPeripheral else {
            appendLog("Нет активного BLE-подключения", kind: .error)
            return
        }
        guard let characteristic = writableCharacteristicRefs.first else {
            appendLog("Нет writable GATT-характеристики", kind: .error)
            return
        }
        guard let data = Data(hexString: hexString) else {
            appendLog("HEX-команда не распознана", kind: .error, detail: hexString)
            return
        }

        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
        appendLog("Write -> \(characteristic.uuid.uuidString) \(logValue(data))", kind: .value)
    }

    func clearLog() {
        eventBus.clear()
        log.removeAll()
    }

    func noteCopiedReport() {
        appendLog("Диагностический отчёт скопирован в буфер обмена", kind: .diagnostic)
    }

    var diagnosticReport: String {
        var lines: [String] = []
        lines.append("BFA7 Bridge diagnostic report")
        lines.append("Generated: \(Self.timestamp())")
        lines.append("Bluetooth: \(stateDescription)")
        lines.append("Connection: \(connectionState)")
        lines.append("Services: \(serviceCount)")
        lines.append("Notify/Indicate enabled: \(notificationCount)")
        lines.append("Writable characteristics: \(writableCharacteristics.joined(separator: ", "))")
        lines.append("Devices:")
        for device in devices {
            lines.append("  \(device.name) | UUID=\(device.id.uuidString) | RSSI=\(device.rssi) dBm | FE95=\(device.serviceData)")
        }
        lines.append("")
        lines.append("Events:")
        lines.append(eventBus.report)
        return lines.joined(separator: "\n")
    }

    private func appendLog(_ value: String, kind: BFA7EventKind = .diagnostic, detail: String = "") {
        eventBus.publish(kind: kind, title: value, detail: detail)
        log = eventBus.events.reversed().map(\.line)
    }

    private func logValue(_ data: Data) -> String {
        let previewLimit = 32
        let preview = Data(data.prefix(previewLimit))
        let hex = preview.map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = data.count > previewLimit ? " ... +\(data.count - previewLimit) B" : ""
        let ascii = preview.map { byte -> String in
            let value = Int(byte)
            return (32...126).contains(value) ? String(UnicodeScalar(value)!) : "."
        }.joined()
        return "\(data.count)B HEX=[\(hex)\(suffix)] ASCII=\"\(ascii)\""
    }

    private func subscribeIfSupported(_ characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        let properties = characteristic.properties
        let key = characteristicKey(peripheral: peripheral, characteristic: characteristic)

        if properties.contains(.notify) || properties.contains(.indicate), !subscribedCharacteristics.contains(key) {
            subscribedCharacteristics.insert(key)
            peripheral.setNotifyValue(true, for: characteristic)
            appendLog("Subscribe -> \(characteristic.uuid.uuidString) [\(properties.description)]", kind: .notification)
        }

        if properties.contains(.read) {
            peripheral.readValue(for: characteristic)
            appendLog("Read -> \(characteristic.uuid.uuidString)", kind: .value)
        }

        if properties.contains(.write) || properties.contains(.writeWithoutResponse) {
            let writableKey = "\(characteristic.service?.uuid.uuidString ?? "?")/\(characteristic.uuid.uuidString)"
            if !writableCharacteristicKeys.contains(writableKey) {
                writableCharacteristicKeys.insert(writableKey)
                writableCharacteristicRefs.append(characteristic)
                writableCharacteristics = writableCharacteristicRefs.map { "\($0.service?.uuid.uuidString ?? "?")/\($0.uuid.uuidString)" }
            }
        }
    }

    private func characteristicKey(peripheral: CBPeripheral, characteristic: CBCharacteristic) -> String {
        "\(peripheral.identifier.uuidString)/\(characteristic.service?.uuid.uuidString ?? "?")/\(characteristic.uuid.uuidString)"
    }

    private func updateNotificationState(for characteristic: CBCharacteristic) {
        guard let serviceUUID = characteristic.service?.uuid.uuidString else { return }
        guard let serviceIndex = gattServices.firstIndex(where: { $0.uuid == serviceUUID }) else { return }
        let service = gattServices[serviceIndex]
        let updated = service.characteristics.map { item in
            item.uuid == characteristic.uuid.uuidString
                ? BFA7GATTCharacteristic(id: item.id, serviceUUID: item.serviceUUID, uuid: item.uuid, properties: item.properties, notifying: characteristic.isNotifying)
                : item
        }
        gattServices[serviceIndex] = BFA7GATTService(id: service.id, uuid: service.uuid, characteristics: updated)
        notificationCount = gattServices.flatMap(\.characteristics).filter(\.notifying).count
    }

    private func recordPossibleButtonEvent(characteristic: CBCharacteristic, data: Data) {
        guard data.count <= 16 else { return }
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let title = "\(characteristic.uuid.uuidString): \(hex)"

        if let frame = BFA7Frame(data: data), frame.kind == .shortControl {
            lastButtonEvent = "Control counter: \(title)"
            return
        }

        lastButtonEvent = title
        appendLog("Small packet candidate", kind: .button, detail: title)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private var stateDescription: String {
        switch state {
        case .poweredOn: return "включен"
        case .poweredOff: return "выключен"
        case .unauthorized: return "нет разрешения"
        case .unsupported: return "не поддерживается"
        case .resetting: return "перезапускается"
        case .unknown: return "неизвестно"
        @unknown default: return "неизвестно"
        }
    }
}

extension GlassesTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        appendLog("Bluetooth: \(stateDescription)", kind: .connection)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? "BFA7 / неизвестное имя"

        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let hasFE95 = serviceUUIDs.contains { $0 == miBeaconService }
        let fe95Data = serviceData.first(where: { $0.key == miBeaconService })?.value

        let looksLikeBFA7 = hasFE95
            || name.localizedCaseInsensitiveContains("BFA7")
            || name.localizedCaseInsensitiveContains("Xiaomi AI Glasses")
            || name.localizedCaseInsensitiveContains("AI Glasses")

        guard looksLikeBFA7 else { return }

        let hex = fe95Data?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "—"
        let device = BFA7Device(id: peripheral.identifier, name: name, rssi: RSSI.intValue, serviceData: hex)
        peripherals[peripheral.identifier] = peripheral

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
            appendLog("BFA7 найден: RSSI=\(RSSI.intValue) dBm, FE95=[\(hex)]", kind: .discovery)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            currentPeripheral = peripheral
            connectionState = "Подключено"
            appendLog("Подключено: \(peripheral.name ?? peripheral.identifier.uuidString)", kind: .connection)
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "unknown"
        Task { @MainActor in
            connectionState = "Ошибка подключения"
            appendLog("Ошибка подключения: \(message)", kind: .error)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peripheralID = peripheral.identifier
        let message = error?.localizedDescription ?? "без ошибки"
        Task { @MainActor in
            if currentPeripheral?.identifier == peripheralID {
                currentPeripheral = nil
            }
            connectionState = "Отключено"
            notificationCount = 0
            writableCharacteristics.removeAll()
            writableCharacteristicRefs.removeAll()
            writableCharacteristicKeys.removeAll()
            subscribedCharacteristics.removeAll()
            appendLog("Отключено: \(message)", kind: .connection)
        }
    }
}

extension GlassesTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []

        Task { @MainActor in
            if let error {
                appendLog("GATT ошибка: \(error.localizedDescription)", kind: .error)
                return
            }

            serviceCount = services.count
            gattServices = services.map { BFA7GATTService(id: $0.uuid.uuidString, uuid: $0.uuid.uuidString, characteristics: []) }
            appendLog("GATT: найдено сервисов \(services.count)", kind: .discovery)

            for service in services {
                appendLog("Service: \(service.uuid.uuidString)", kind: .discovery)
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didDiscoverCharacteristicsFor service: CBService,
                                 error: Error?) {
        let characteristics = service.characteristics ?? []

        Task { @MainActor in
            if let error {
                appendLog("Characteristics ошибка: \(error.localizedDescription)", kind: .error)
                return
            }

            appendLog("Service \(service.uuid.uuidString): характеристик \(characteristics.count)", kind: .discovery)
            let discovered = characteristics.map { characteristic in
                BFA7GATTCharacteristic(
                    id: characteristic.uuid.uuidString,
                    serviceUUID: service.uuid.uuidString,
                    uuid: characteristic.uuid.uuidString,
                    properties: characteristic.properties.description,
                    notifying: characteristic.isNotifying
                )
            }
            if let index = gattServices.firstIndex(where: { $0.uuid == service.uuid.uuidString }) {
                gattServices[index] = BFA7GATTService(id: service.uuid.uuidString, uuid: service.uuid.uuidString, characteristics: discovered)
            }

            for characteristic in characteristics {
                appendLog("  \(characteristic.uuid.uuidString) [\(characteristic.properties.description)]", kind: .discovery)
                subscribeIfSupported(characteristic, peripheral: peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                 error: Error?) {
        Task { @MainActor in
            if let error {
                appendLog("Notify ERROR \(characteristic.uuid.uuidString): \(error.localizedDescription)", kind: .error)
            } else {
                updateNotificationState(for: characteristic)
                appendLog("Notify state \(characteristic.uuid.uuidString): \(characteristic.isNotifying ? "ON" : "OFF")", kind: .notification)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didUpdateValueFor characteristic: CBCharacteristic,
                                 error: Error?) {
        let data = characteristic.value

        Task { @MainActor in
            if let error {
                appendLog("Value ERROR \(characteristic.uuid.uuidString): \(error.localizedDescription)", kind: .error)
            } else if let data {
                protocolLab.record(
                    serviceUUID: characteristic.service?.uuid.uuidString ?? "?",
                    characteristicUUID: characteristic.uuid.uuidString,
                    data: data
                )
                appendLog("Value <- \(characteristic.uuid.uuidString) \(logValue(data))", kind: .value)
                recordPossibleButtonEvent(characteristic: characteristic, data: data)
            } else {
                appendLog("Value <- \(characteristic.uuid.uuidString) EMPTY", kind: .value)
            }
        }
    }
}

private extension CBCharacteristicProperties {
    var description: String {
        var values: [String] = []
        if contains(.read) { values.append("read") }
        if contains(.write) { values.append("write") }
        if contains(.writeWithoutResponse) { values.append("writeNR") }
        if contains(.notify) { values.append("notify") }
        if contains(.indicate) { values.append("indicate") }
        return values.joined(separator: ",")
    }
}

private extension Data {
    init?(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
        guard !cleaned.isEmpty else { return nil }

        var bytes: [UInt8] = []
        for token in cleaned {
            guard let byte = UInt8(token, radix: 16) else { return nil }
            bytes.append(byte)
        }
        self = Data(bytes)
    }
}
