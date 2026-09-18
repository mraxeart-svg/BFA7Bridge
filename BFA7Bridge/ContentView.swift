import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @EnvironmentObject private var sessions: BFA7SessionStore
    @State private var scannerExpanded = true
    @State private var gattExpanded = false
    @State private var capabilitiesExpanded = false
    @State private var sessionStartedAt: Date?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Состояние")
                        Spacer()
                        Text(bluetoothState).foregroundStyle(.secondary)
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
                            withAnimation { scannerExpanded.toggle() }
                        } label: {
                            Label(scannerExpanded ? "Свернуть сканер" : "Показать сканер",
                                  systemImage: scannerExpanded ? "chevron.up" : "chevron.down")
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
                                    Text(device.name).font(.headline)
                                    Spacer()
                                    Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                Text("FE95: \(device.serviceData)").font(.caption2).foregroundStyle(.secondary)
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
                        Text(bluetooth.connectionState).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("GATT-сервисов")
                        Spacer()
                        Text("\(bluetooth.serviceCount)").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Notify/Indicate ON")
                        Spacer()
                        Text("\(bluetooth.notificationCount)").foregroundStyle(.secondary)
                    }

                    DisclosureGroup("GATT Explorer", isExpanded: $gattExpanded) {
                        if bluetooth.gattServices.isEmpty {
                            Text("Подключись к BFA7 для заполнения.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(bluetooth.gattServices) { service in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(service.uuid).font(.caption).bold()
                                ForEach(service.characteristics) { characteristic in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(characteristic.uuid).font(.caption2.monospaced())
                                        Text(characteristic.properties + (characteristic.notifying ? " • ON" : ""))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.leading, 8)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section("Возможности") {
                    DisclosureGroup("Архитектура BFA7 Bridge", isExpanded: $capabilitiesExpanded) {
                        ForEach(bluetooth.capabilities) { capability in
                            HStack {
                                Text(capability.title)
                                Spacer()
                                Text(capability.status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Сессия исследования") {
                    if sessionStartedAt == nil {
                        Button {
                            sessionStartedAt = Date()
                            bluetooth.clearLog()
                        } label: {
                            Label("Начать новую сессию", systemImage: "record.circle")
                        }
                    } else {
                        Button {
                            let end = Date()
                            if let start = sessionStartedAt {
                                sessions.save(BFA7Session(id: UUID(), startedAt: start, endedAt: end, eventCount: bluetooth.log.count))
                            }
                            sessionStartedAt = nil
                        } label: {
                            Label("Завершить и сохранить", systemImage: "stop.circle")
                        }
                    }

                    Text("Сохранённых сессий: \(sessions.sessions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !sessions.sessions.isEmpty {
                        ForEach(sessions.sessions.prefix(5)) { session in
                            VStack(alignment: .leading) {
                                Text(session.startedAt.formatted(date: .abbreviated, time: .standard))
                                Text("\(session.eventCount) событий")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Диагностика") {
                    HStack {
                        Label("События", systemImage: "waveform.path.ecg")
                        Spacer()
                        Text("\(bluetooth.log.count)").foregroundStyle(.secondary)
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
            .onChange(of: bluetooth.devices.count) { count in
                if count > 0 {
                    withAnimation { scannerExpanded = false }
                }
            }
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
