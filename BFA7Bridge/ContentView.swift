import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager

    var body: some View {
        NavigationStack {
            List {
                Section("Bluetooth") {
                    HStack {
                        Text("Состояние")
                        Spacer()
                        Text(bluetoothState)
                            .foregroundStyle(.secondary)
                    }

                    Button(bluetooth.isScanning ? "Остановить сканирование" : "Найти BFA7") {
                        if bluetooth.isScanning {
                            bluetooth.stopScan()
                        } else {
                            bluetooth.startScan()
                        }
                    }
                    .disabled(bluetooth.state != .poweredOn)
                }

                Section("Устройства") {
                    if bluetooth.devices.isEmpty {
                        Text("BFA7 пока не найден. Нажми «Найти BFA7».")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(bluetooth.devices) { device in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(device.name)
                                    .font(.headline)
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(device.id.uuidString)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Text("FE95: \(device.serviceData)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Button("Подключиться и прочитать GATT") {
                                bluetooth.connect(device)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Лог") {
                    ForEach(Array(bluetooth.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("BFA7 Bridge")
        }
    }

    private var bluetoothState: String {
        switch bluetooth.state {
        case .poweredOn: return "Включен"
        case .poweredOff: return "Выключен"
        case .unauthorized: return "Нет разрешения"
        case .unsupported: return "Не поддерживается"
        case .resetting: return "Перезапуск"
        case .unknown: return "Неизвестно"
        @unknown default: return "Неизвестно"
        }
    }
}
