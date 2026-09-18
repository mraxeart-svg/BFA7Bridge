import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @State private var scannerExpanded = true

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                            scannerExpanded = true
                            bluetooth.startScan()
                        }
                    }
                    .disabled(bluetooth.state != .poweredOn)

                    if !bluetooth.devices.isEmpty {
                        Button {
                            withAnimation {
                                scannerExpanded.toggle()
                            }
                        } label: {
                            Label(
                                scannerExpanded ? "Свернуть сканер" : "Показать сканер",
                                systemImage: scannerExpanded ? "chevron.up" : "chevron.down"
                            )
                        }
                    }
                } header: {
                    Text("Bluetooth")
                }

                if scannerExpanded {
                    Section("BFA7") {
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
                }

                Section("Подключение") {
                    HStack {
                        Text("Состояние")
                        Spacer()
                        Text(bluetooth.connectionState)
                            .foregroundStyle(.secondary)
                    }

                    if bluetooth.serviceCount > 0 {
                        HStack {
                            Text("GATT-сервисы")
                            Spacer()
                            Text("\(bluetooth.serviceCount)")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Notify/Indicate")
                            Spacer()
                            Text("\(bluetooth.notificationCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Диагностика") {
                    HStack {
                        Label("События", systemImage: "waveform.path.ecg")
                        Spacer()
                        Text("\(bluetooth.log.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        UIPasteboard.general.string = bluetooth.diagnosticReport
                        bluetooth.noteCopiedReport()
                    } label: {
                        Label("Скопировать всё в буфер", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        bluetooth.clearLog()
                    } label: {
                        Label("Очистить события", systemImage: "trash")
                    }
                    .disabled(bluetooth.log.isEmpty)

                    if !bluetooth.log.isEmpty {
                        DisclosureGroup("Журнал BLE") {
                            ForEach(Array(bluetooth.log.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
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
