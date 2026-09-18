import Foundation
import CoreBluetooth

@MainActor
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var devices: [BFA7Device] = []
    @Published private(set) var isScanning = false
    @Published private(set) var log: [String] = []

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]

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
        isScanning = true
        appendLog("Сканирование BFA7…")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        appendLog("Сканирование остановлено")
    }

    func connect(_ device: BFA7Device) {
        guard let peripheral = peripherals[device.id] else { return }
        stopScan()
        appendLog("Подключение к \(device.name)…")
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    private func appendLog(_ value: String) {
        log.insert(value, at: 0)
        if log.count > 100 { log.removeLast() }
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
        appendLog("Bluetooth: \(stateDescription)")
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

        // BFA7 currently advertises Xiaomi's FE95 service data. We also accept
        // Xiaomi-looking names, but do not write anything to the device yet.
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
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        appendLog("Подключено: \(peripheral.name ?? peripheral.identifier.uuidString)")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        appendLog("Ошибка подключения: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        appendLog("Отключено: \(error?.localizedDescription ?? "без ошибки")")
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        Task { @MainActor in
            if let error {
                appendLog("GATT ошибка: \(error.localizedDescription)")
            } else {
                appendLog("GATT: найдено сервисов \(services.count)")
                for service in services {
                    appendLog("Service: \(service.uuid.uuidString)")
                    peripheral.discoverCharacteristics(nil, for: service)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                 didDiscoverCharacteristicsFor service: CBService,
                                 error: Error?) {
        let characteristics = service.characteristics ?? []
        Task { @MainActor in
            if let error {
                appendLog("Characteristics ошибка: \(error.localizedDescription)")
            } else {
                appendLog("Service \(service.uuid.uuidString): характеристик \(characteristics.count)")
                for characteristic in characteristics {
                    let props = characteristic.properties.description
                    appendLog("  \(characteristic.uuid.uuidString) [\(props)]")
                }
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
