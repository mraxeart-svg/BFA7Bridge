import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        TabView {
            DeviceView()
                .tabItem { Label("Device", systemImage: "eyeglasses") }
            CaptureView()
                .tabItem { Label("Capture", systemImage: "photo.on.rectangle") }
            AskView()
                .tabItem { Label("Ask", systemImage: "mic.badge.plus") }
            LabView()
                .tabItem { Label("Lab", systemImage: "waveform.path.ecg.rectangle") }
        }
    }
}

private struct DeviceView: View {
    @EnvironmentObject private var glasses: GlassesTransport
    @EnvironmentObject private var sessions: BFA7SessionStore
    @State private var scannerExpanded = true
    @State private var gattExpanded = false
    @State private var capabilitiesExpanded = false
    @State private var sessionStartedAt: Date?
    @State private var hexCommand = ""
    @State private var rawWriteEnabled = false

    var body: some View {
        NavigationStack {
            List {
                Section("Bluetooth") {
                    HStack {
                        Text("Состояние")
                        Spacer()
                        Text(bluetoothState).foregroundStyle(.secondary)
                    }

                    Button(glasses.isScanning ? "Остановить сканирование" : "Найти BFA7") {
                        if glasses.isScanning {
                            glasses.stopScan()
                        } else {
                            scannerExpanded = true
                            glasses.startScan()
                        }
                    }
                    .disabled(glasses.state != .poweredOn)

                    if !glasses.devices.isEmpty {
                        Button {
                            withAnimation { scannerExpanded.toggle() }
                        } label: {
                            Label(scannerExpanded ? "Свернуть сканер" : "Показать сканер",
                                  systemImage: scannerExpanded ? "chevron.up" : "chevron.down")
                        }
                    }
                }

                if scannerExpanded {
                    Section("BFA7") {
                        if glasses.devices.isEmpty {
                            Text("BFA7 пока не найден")
                                .foregroundStyle(.secondary)
                        }

                        ForEach(glasses.devices) { device in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(device.name).font(.headline)
                                    Spacer()
                                    Text("\(device.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                                Text(device.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                                Text("FE95: \(device.serviceData)").font(.caption2).foregroundStyle(.secondary)
                                Button("Подключиться и прочитать GATT") {
                                    glasses.connect(device)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Подключение") {
                    statusRow("Состояние", glasses.connectionState)
                    statusRow("GATT-сервисов", "\(glasses.serviceCount)")
                    statusRow("Notify/Indicate ON", "\(glasses.notificationCount)")
                    statusRow("Writable", "\(glasses.writableCharacteristics.count)")
                    statusRow("Последняя кнопка", glasses.lastButtonEvent)

                    DisclosureGroup("GATT Explorer", isExpanded: $gattExpanded) {
                        if glasses.gattServices.isEmpty {
                            Text("Подключись к BFA7")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(glasses.gattServices) { service in
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

                Section("Button Experiment") {
                    statusRow("Состояние", glasses.buttonExperimentState)
                    Button("Start baseline") {
                        glasses.startButtonExperiment()
                    }
                    Button("Mark physical button") {
                        glasses.markPhysicalButtonPress()
                    }
                    .disabled(glasses.buttonExperimentStartedAt == nil)
                    Button("Copy experiment report") {
                        UIPasteboard.general.string = glasses.finishButtonExperiment()
                    }
                    .disabled(glasses.buttonExperimentStartedAt == nil)
                }

                Section("Raw write") {
                    Toggle("Enable HEX write", isOn: $rawWriteEnabled)
                    TextField("HEX bytes", text: $hexCommand)
                        .textInputAutocapitalization(.characters)
                        .font(.body.monospaced())
                    Button("Write HEX") {
                        glasses.writeHexCommand(hexCommand)
                    }
                    .disabled(!rawWriteEnabled || hexCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Возможности") {
                    DisclosureGroup("BFA7 Bridge", isExpanded: $capabilitiesExpanded) {
                        ForEach(glasses.capabilities) { capability in
                            statusRow(capability.title, capability.status)
                        }
                    }
                }

                Section("Сессия исследования") {
                    if sessionStartedAt == nil {
                        Button {
                            sessionStartedAt = Date()
                            glasses.clearLog()
                        } label: {
                            Label("Начать новую сессию", systemImage: "record.circle")
                        }
                    } else {
                        Button {
                            let end = Date()
                            if let start = sessionStartedAt {
                                sessions.save(BFA7Session(id: UUID(), startedAt: start, endedAt: end, eventCount: glasses.log.count))
                            }
                            sessionStartedAt = nil
                        } label: {
                            Label("Завершить и сохранить", systemImage: "stop.circle")
                        }
                    }

                    Text("Сохранённых сессий: \(sessions.sessions.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(sessions.sessions.prefix(5)) { session in
                        VStack(alignment: .leading) {
                            Text(session.startedAt.formatted(date: .abbreviated, time: .standard))
                            Text("\(session.eventCount) событий")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                DiagnosticsSection()
            }
            .navigationTitle("BFA7 Bridge")
            .onChange(of: glasses.devices.count) { count in
                if count > 0 {
                    withAnimation { scannerExpanded = false }
                }
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private var bluetoothState: String {
        switch glasses.state {
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

private struct CaptureView: View {
    @EnvironmentObject private var media: MediaTransfer
    @EnvironmentObject private var systemCapture: SystemCaptureProbe

    var body: some View {
        NavigationStack {
            List {
                Section("System Capture") {
                    HStack {
                        Button("Refresh devices") {
                            systemCapture.refresh()
                        }
                        Spacer()
                        Button("Request access") {
                            Task { await systemCapture.requestPermissionsAndRefresh() }
                        }
                    }

                    Text(systemCapture.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    captureItems("Video", systemCapture.videoDevices)
                    captureItems("Audio input", systemCapture.audioInputs)
                    captureItems("Audio output", systemCapture.audioRouteOutputs)
                }

                Section("Wi-Fi transfer") {
                    TextField("Base URL", text: $media.baseURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button("Обновить список") {
                            Task { await media.refreshFileList() }
                        }
                        Spacer()
                        if media.isBusy { ProgressView() }
                    }

                    Button("Загрузить последний файл") {
                        Task { await media.downloadLatest() }
                    }
                    .disabled(media.isBusy)

                    Button("Ручной placeholder") {
                        media.useLocalPlaceholder()
                    }

                    Button("Probe latest file URLs") {
                        Task { await media.probeLatestFileURLs() }
                    }
                    .disabled(media.isBusy)

                    Button("Скопировать media report") {
                        UIPasteboard.general.string = media.lastTransferReport
                    }

                    Text(media.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Wi-Fi Probe") {
                    TextField("Probe paths", text: $media.probePathsText, axis: .vertical)
                        .lineLimit(4...10)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                    HStack {
                        Button("Run probe") {
                            Task { await media.runWiFiProbe() }
                        }
                        .disabled(media.isBusy)

                        Spacer()

                        Button("Copy probe report") {
                            UIPasteboard.general.string = media.lastProbeReport
                        }
                    }

                    TextField("Method probe paths", text: $media.methodProbePathsText, axis: .vertical)
                        .lineLimit(2...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                    Button("Run method probe") {
                        Task { await media.runMethodProbe() }
                    }
                    .disabled(media.isBusy)

                    TextField("Latest file template probe", text: $media.latestTemplateProbeText, axis: .vertical)
                        .lineLimit(4...12)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())

                    Button("Run latest template probe") {
                        Task { await media.runLatestTemplateProbe() }
                    }
                    .disabled(media.isBusy)

                    Text("Шаблоны: {remote}, {remoteRaw}, {remoteLeaf}, {remoteLeafRaw}, {identifier}, {identifierRaw}, {filename}, {filenameRaw}, {filenameBase}, {id}. Для POST: POST /path | {json}.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if media.probeResults.isEmpty {
                        Text("Probe ещё не запускался")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(media.probeResults) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.path)
                                .font(.caption.monospaced())
                            Text(result.summary)
                                .font(.caption2.monospaced())
                                .foregroundStyle(result.error == nil ? Color.secondary : Color.red)
                            if !result.preview.isEmpty {
                                Text(result.preview)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let latest = media.latestDownloaded {
                    Section("Latest") {
                        mediaRow(latest)
                        if let url = latest.localURL {
                            ShareLink(item: url) {
                                Label("Поделиться файлом", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                Section("Files") {
                    if media.files.isEmpty {
                        Text("Список пуст")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(media.files) { file in
                        Button {
                            Task { await media.download(file) }
                        } label: {
                            mediaRow(file)
                        }
                    }
                }
            }
            .navigationTitle("Capture")
            .onAppear {
                systemCapture.refresh()
            }
        }
    }

    @ViewBuilder
    private func captureItems(_ title: String, _ items: [BFA7SystemCaptureItem]) -> some View {
        if !items.isEmpty {
            DisclosureGroup(title) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.name)
                            Spacer()
                            if item.isBFA7Candidate {
                                Text("BFA7?")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(item.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func mediaRow(_ file: BFA7MediaFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.filename).font(.headline)
            HStack {
                Text(file.kind.rawValue)
                Text(file.displaySize)
                if file.localURL != nil { Text("downloaded") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct AskView: View {
    @EnvironmentObject private var media: MediaTransfer
    @EnvironmentObject private var voice: VoiceIO
    @EnvironmentObject private var speech: SpeechTranscriber
    @EnvironmentObject private var commands: CommandSession

    var body: some View {
        NavigationStack {
            List {
                Section("Command") {
                    TextField("Команда", text: $commands.commandText, axis: .vertical)
                        .lineLimit(2...4)
                    Button("Скачать с очков и подготовить") {
                        Task {
                            await media.downloadLatest()
                            commands.preparePayload(media: media.latestDownloaded)
                        }
                    }
                    .disabled(media.isBusy)

                    Button("Подготовить запрос") {
                        commands.preparePayload(media: media.latestDownloaded)
                    }
                    Button("Free ChatGPT handoff") {
                        Task { await commands.submitFree(media: media.latestDownloaded, voice: voice) }
                    }
                    Button("Скопировать prompt") {
                        commands.copyPrompt()
                    }
                    Button("Проверить, что API выключен") {
                        Task { await commands.provePaidAPIIsDisabled() }
                    }
                }

                Section("Voice") {
                    Text("BFA7 audio route build")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(voice.isRecording ? "Остановить запись" : "Push-to-talk") {
                            voice.isRecording ? voice.stopRecording() : voice.startRecording()
                        }
                        Spacer()
                        Button("Stop voice") { voice.stopSpeaking() }
                    }

                    HStack {
                        Button("Выбрать звук BFA7") {
                            voice.prepareAudioSession()
                            voice.preferBFA7InputIfAvailable()
                        }
                        Spacer()
                        Button("Проверить голос") { voice.speakRouteTest() }
                    }

                    Button("Распознать запись") {
                        Task {
                            if let transcript = await speech.transcribe(url: voice.lastRecordingURL) {
                                commands.commandText = transcript
                            }
                        }
                    }
                    .disabled(voice.isRecording || voice.lastRecordingURL == nil)

                    Button("Распознать и подготовить запрос") {
                        Task {
                            if let transcript = await speech.transcribe(url: voice.lastRecordingURL) {
                                commands.commandText = transcript
                                commands.preparePayload(media: media.latestDownloaded)
                            }
                        }
                    }
                    .disabled(voice.isRecording || voice.lastRecordingURL == nil)

                    Button("Скопировать аудио-отчёт") {
                        voice.refreshRouteStatus()
                        UIPasteboard.general.string = voice.audioRouteReport
                    }

                    Text(voice.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(speech.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !speech.lastTranscript.isEmpty {
                        Text(speech.lastTranscript)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(voice.routeStatus)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(voice.recordingStatus)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let url = voice.lastRecordingURL {
                        Text(url.lastPathComponent)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Latest media") {
                    if let latest = media.latestDownloaded {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(latest.filename).font(.headline)
                            Text("\(latest.kind.rawValue) • \(latest.displaySize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let url = latest.localURL {
                            ShareLink(item: url) {
                                Label("Поделиться файлом", systemImage: "square.and.arrow.up")
                            }
                        }
                    } else {
                        Text("Нет загруженного файла")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Free gate") {
                    Text(commands.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let payload = commands.lastPayload {
                        DisclosureGroup("Prompt") {
                            Text(payload.promptText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Ask")
        }
    }
}

private struct DiagnosticsSection: View {
    @EnvironmentObject private var glasses: GlassesTransport

    var body: some View {
        Section("Диагностика") {
            HStack {
                Label("События", systemImage: "waveform.path.ecg")
                Spacer()
                Text("\(glasses.log.count)").foregroundStyle(.secondary)
            }

            Button {
                UIPasteboard.general.string = glasses.diagnosticReport
                glasses.noteCopiedReport()
            } label: {
                Label("Скопировать всё в буфер", systemImage: "doc.on.clipboard")
            }

            Button {
                glasses.clearLog()
            } label: {
                Label("Очистить события", systemImage: "trash")
            }
            .disabled(glasses.log.isEmpty)

            if !glasses.log.isEmpty {
                DisclosureGroup("Журнал BLE") {
                    ForEach(Array(glasses.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}


private struct LabView: View {
    var body: some View {
        NavigationStack {
            List {
                ImportLabSection()
                ProtocolLabSection()
                WiFiImportChecklistSection()
            }
            .navigationTitle("Lab")
        }
    }
}


private struct ImportLabSection: View {
    @EnvironmentObject private var glasses: GlassesTransport
    @EnvironmentObject private var protocolLab: ProtocolLab
    @EnvironmentObject private var media: MediaTransfer
    @State private var importTriggerTarget = "FE95/005E"
    @State private var importTriggerHex = ""
    @State private var importTriggerEnabled = false
    @State private var createWifiAPSeq = "81"
    @State private var createWifiAPWifiType = 2

    var body: some View {
        Section("Import Lab") {
            Text("Цель: найти BLE/Wi-Fi момент, когда Xiaomi app включает Import mode.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Состояние")
                Spacer()
                Text(glasses.importExperimentState)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Button("Start import experiment") {
                glasses.startImportExperiment()
            }

            Button("Mark Xiaomi Import press") {
                glasses.markXiaomiImportPressed()
            }
            .disabled(glasses.importExperimentStartedAt == nil)

            Button("Copy import experiment report") {
                UIPasteboard.general.string = glasses.finishImportExperiment()
            }
            .disabled(glasses.importExperimentStartedAt == nil)

            HStack {
                Button("Copy import full HEX") {
                    UIPasteboard.general.string = protocolLab.importFullHexReport(around: glasses.importExperimentMarkedAt)
                }
                .disabled(protocolLab.packets.isEmpty)

                Spacer()

                Button("Copy replay candidates") {
                    UIPasteboard.general.string = protocolLab.importReplayCandidateReport(around: glasses.importExperimentMarkedAt)
                }
                .disabled(protocolLab.packets.isEmpty)
            }

            Button("Copy import JSON") {
                UIPasteboard.general.string = protocolLab.importJSONExport(around: glasses.importExperimentMarkedAt)
            }
            .disabled(protocolLab.packets.isEmpty)

            HStack {
                Button("Run Wi-Fi probe") {
                    Task { await media.runWiFiProbe() }
                }
                .disabled(media.isBusy)

                Spacer()

                Button("Copy probe") {
                    UIPasteboard.general.string = media.lastProbeReport
                }
            }

            Divider()

            Toggle("Enable import trigger writes", isOn: $importTriggerEnabled)

            TextField("Target characteristic", text: $importTriggerTarget)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())

            TextField("Import trigger HEX candidate", text: $importTriggerHex, axis: .vertical)
                .lineLimit(2...5)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())

            VStack(alignment: .leading, spacing: 8) {
                Text("APK CreateWifiAP candidate")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("seq")
                    TextField("81", text: $createWifiAPSeq)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .frame(maxWidth: 70)

                    Spacer()

                    Stepper("wifiType \(createWifiAPWifiType)", value: $createWifiAPWifiType, in: 0...4)
                        .labelsHidden()
                    Text("wifiType \(createWifiAPWifiType)")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Build CreateWifiAP") {
                        importTriggerHex = createWifiAPCandidateHex
                    }

                    Spacer()

                    Button("Build next seq") {
                        importTriggerHex = createWifiAPCandidateHex
                        createWifiAPSeq = nextHexByte(after: createWifiAPSeq)
                    }
                }
            }

            HStack {
                Button("Write trigger") {
                    _ = glasses.writeHexCommand(importTriggerHex, target: importTriggerTarget)
                }
                .disabled(!canWriteImportTrigger)

                Spacer()

                Button("Write + Wi-Fi probe") {
                    Task {
                        if glasses.writeHexCommand(importTriggerHex, target: importTriggerTarget) {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            await media.refreshFileList()
                        }
                    }
                }
                .disabled(!canWriteImportTrigger || media.isBusy)
            }

            HStack {
                Button("Write APK only") {
                    importTriggerHex = createWifiAPCandidateHex
                    if glasses.writeHexCommand(importTriggerHex, target: importTriggerTarget) {
                        createWifiAPSeq = nextHexByte(after: createWifiAPSeq)
                    }
                }
                .disabled(!importTriggerEnabled)

                Spacer()

                Button("Write APK + probe") {
                    Task {
                        importTriggerHex = createWifiAPCandidateHex
                        if glasses.writeHexCommand(importTriggerHex, target: importTriggerTarget) {
                            createWifiAPSeq = nextHexByte(after: createWifiAPSeq)
                            try? await Task.sleep(nanoseconds: 5_000_000_000)
                            await media.refreshFileList()
                        }
                    }
                }
                .disabled(!importTriggerEnabled || media.isBusy)
            }

            Text("Важно: это лаборатория для проверенных BLE-кандидатов. Наблюдаемые incoming A5-пакеты не считаются доказанными командами Xiaomi app.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("APK clue: CreateWifiAP uses command bytes 00 02 and content 01 wifiType 01; encrypted commands prepend seq. This section only builds that candidate, it does not prove the final trigger until the Wi-Fi probe succeeds.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Порядок: Start -> переключись в Xiaomi app -> нажми Import -> вернись сюда -> Mark -> согласись на Wi-Fi -> Run Wi-Fi probe -> Copy import report + Copy probe.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(protocolLab.activityReport(around: glasses.importExperimentMarkedAt, label: "Import"))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .textSelection(.enabled)
        }
    }

    private var canWriteImportTrigger: Bool {
        importTriggerEnabled &&
        !importTriggerTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !importTriggerHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var createWifiAPCandidateHex: String {
        let seq = normalizedHexByte(createWifiAPSeq) ?? "81"
        let wifiType = String(format: "%02X", createWifiAPWifiType & 0xff)
        return "\(seq) 00 02 01 \(wifiType) 01"
    }

    private func normalizedHexByte(_ value: String) -> String? {
        let filtered = value.filter { $0.isHexDigit }
        guard !filtered.isEmpty,
              let byte = UInt8(filtered.suffix(2), radix: 16) else { return nil }
        return String(format: "%02X", byte)
    }

    private func nextHexByte(after value: String) -> String {
        let current = UInt8(normalizedHexByte(value) ?? "80", radix: 16) ?? 0x80
        let next = current == 0x7f ? UInt8(0x80) : current &+ 1
        return String(format: "%02X", next)
    }
}

private struct ProtocolLabSection: View {
    @EnvironmentObject private var glasses: GlassesTransport
    @EnvironmentObject private var protocolLab: ProtocolLab

    var body: some View {
        Section("Protocol Lab") {
            HStack {
                Text("Packets")
                Spacer()
                Text("\(protocolLab.filteredPackets.count)/\(protocolLab.packets.count)")
                    .foregroundStyle(.secondary)
            }

            TextField("Characteristic filter", text: $protocolLab.characteristicFilter)
                .textInputAutocapitalization(.characters)
                .font(.body.monospaced())

            Toggle("Only A5 A5 frames", isOn: $protocolLab.showOnlyA5Frames)

            Text(protocolLab.packetStats)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Button("Copy JSON") {
                    UIPasteboard.general.string = protocolLab.jsonExport
                }
                Button("Copy CSV") {
                    UIPasteboard.general.string = protocolLab.csvExport
                }
                Button("Clear") {
                    protocolLab.clear()
                }
                .disabled(protocolLab.packets.isEmpty)
            }

            Button("Copy focused report") {
                UIPasteboard.general.string = protocolLab.focusedReport(around: glasses.buttonExperimentMarkedAt)
            }
            .disabled(protocolLab.filteredPackets.isEmpty)

            Button("Copy button candidates") {
                UIPasteboard.general.string = protocolLab.buttonCandidateReport(around: glasses.buttonExperimentMarkedAt)
            }
            .disabled(protocolLab.filteredPackets.isEmpty)

            Button("Copy capture burst report") {
                UIPasteboard.general.string = protocolLab.captureBurstReport(around: glasses.buttonExperimentMarkedAt)
            }
            .disabled(protocolLab.filteredPackets.isEmpty)
        }

        Section("Capture Bursts") {
            let bursts = protocolLab.burstSummaries(around: glasses.buttonExperimentMarkedAt)

            if bursts.isEmpty {
                Text("No capture-sized burst in the focused window.")
                    .foregroundStyle(.secondary)
            }

            ForEach(bursts) { burst in
                VStack(alignment: .leading, spacing: 3) {
                    Text(burst.relativeRangeLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("\(burst.byteCount) B / \(burst.packetCount) packets / seq \(burst.sequenceRange)")
                        .font(.caption.monospaced())
                    Text("starts \(burst.payloadStartCount), continuations \(burst.continuationCount), controls \(burst.shortControlCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }

        Section("Button Timeline") {
            if glasses.buttonExperimentMarkedAt == nil {
                Text("Mark physical button in Device -> Button Experiment to center this timeline.")
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(protocolLab.timeline(around: glasses.buttonExperimentMarkedAt).suffix(80))) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.relativeLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(entry.packet.byteCount) B").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(entry.packet.characteristicUUID)
                        .font(.caption2.monospaced())
                    Text(entry.packet.frame?.summary ?? (entry.packet.firstBytes + (entry.packet.looksLikeA5Frame ? "  A5" : "")))
                        .font(.caption2.monospaced())
                        .foregroundStyle(entry.packet.looksLikeA5Frame ? .primary : .secondary)
                    Text(entry.packet.firstBytes)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct WiFiImportChecklistSection: View {
    @EnvironmentObject private var wifiLab: WiFiImportLab

    var body: some View {
        Section("Wi-Fi Import Checklist") {
            TextField("SSID", text: binding(\.ssid))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("BFA7 IP", text: binding(\.glassesIP))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
            TextField("iPhone IP", text: binding(\.iphoneIP))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
            TextField("Gateway", text: binding(\.gateway))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
            TextField("DNS", text: binding(\.dns))
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
            TextField("Open ports", text: binding(\.openPorts), axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
            TextField("Protocol/endpoints", text: binding(\.protocolNotes), axis: .vertical)
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
            TextField("Capture notes", text: binding(\.captureNotes), axis: .vertical)
                .lineLimit(2...6)

            HStack {
                Button("Copy report") {
                    wifiLab.markUpdated()
                    UIPasteboard.general.string = wifiLab.checklist.markdownReport
                }
                Button("Reset") {
                    wifiLab.reset()
                }
            }
        }

        Section("Import Targets") {
            Text("Capture these during Xiaomi Glasses App Import: SSID, BFA7 IP, iPhone IP, gateway, DNS, open TCP/UDP ports, and endpoints. USB-C to PC is not enough to observe this traffic.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<WiFiImportChecklist, String>) -> Binding<String> {
        Binding(
            get: { wifiLab.checklist[keyPath: keyPath] },
            set: { newValue in
                var updated = wifiLab.checklist
                updated[keyPath: keyPath] = newValue
                updated.lastUpdated = Date()
                wifiLab.checklist = updated
            }
        )
    }
}
