import Foundation
import CoreBluetooth
import Combine

@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var devices: [BFA7Device] = []
    @Published private(set) var isScanning = false
    @Published private(set) var log: [String] = []
    let eventBus = BFA7EventBus()
    @Published private(set) var connectionState = "Не подключено"
    @Published private(set) var serviceCount = 0
    @Published private(set) var notificationCount = 0

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var subscribedCharacteristics: Set<String> = []

    private let miBeaconService = CBUUID(string: "FE95")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard state == .poweredOn else {
            appendLog("Bluetooth недоступен: \(stateDescription)")
            return
        }

        devices.removeAll()
        peripherals.removeAll()
        serviceCount = 0
        notificationCount = 0
        subscribedCharacteristics.removeAll()
        isScanning = true

        appendLog("Сканирование BFA7…", kind: .discovery)
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
        connectionState = "Подключение…"
        appendLog("Подключение к \(device.name)…", kind: .connection)
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
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
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ascii = data.map { byte -> String in
            let value = Int(byte)
            return (32...126).contains(value) ? String(UnicodeScalar(value)!) : "."
        }.joined()
        return "HEX=[\(hex)] ASCII=\"\(ascii)\""
    }

    private func subscribeIfSupported(_ characteristic: CBCharacteristic, peripheral: CBPeripheral) {
        let properties = characteristic.properties
        let key = "\(peripheral.identifier.uuidString)/\(characteristic.service?.uuid.uuidString ?? "?")/\(characteristic.uuid.uuidString)"

        if properties.contains(.notify) || properties.contains(.indicate), !subscribedCharacteristics.contains(key) {
            subscribedCharacteristics.insert(key)
            peripheral.setNotifyValue(true, for: characteristic)
            appendLog("Subscribe → \(characteristic.uuid.uuidString) [\(properties.description)]", kind: .notification)
        }

        if properties.contains(.read) {
            peripheral.readValue(for: characteristic)
            appendLog("Read → \(characteristic.uuid.uuidString)", kind: .value)
        }
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

struct BFA7Device: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let serviceData: String
}

extension BluetoothManager: CBCentralManagerDelegate {
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

        guard looksLikeBFA7 else { return }

        let hex = fe95Data?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "—"
        let device = BFA7Device(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            serviceData: hex
        )

        peripherals[peripheral.identifier] = peripheral

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
            appendLog("BFA7 найден: RSSI=\(RSSI.intValue) dBm, FE95=[\(hex)]", kind: .discovery)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        connectionState = "Подключено"
        appendLog("Подключено: \(peripheral.name ?? peripheral.identifier.uuidString)", kind: .connection)
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connectionState = "Ошибка подключения"
        appendLog("Ошибка подключения: \(error?.localizedDescription ?? "unknown")", kind: .error)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connectionState = "Отключено"
        notificationCount = 0
        subscribedCharacteristics.removeAll()
        appendLog("Отключено: \(error?.localizedDescription ?? "без ошибки")", kind: .connection)
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []

        Task { @MainActor in
            if let error {
                appendLog("GATT ошибка: \(error.localizedDescription)", kind: .error)
                return
            }

            serviceCount = services.count
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

            for characteristic in characteristics {
                let props = characteristic.properties.description
                appendLog("  \(characteristic.uuid.uuidString) [\(props)]", kind: .discovery)
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
                if characteristic.isNotifying {
                    notificationCount += 1
                }
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
                appendLog("Value ← \(characteristic.uuid.uuidString) \(logValue(data))", kind: .value)
            } else {
                appendLog("Value ← \(characteristic.uuid.uuidString) EMPTY", kind: .value)
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
