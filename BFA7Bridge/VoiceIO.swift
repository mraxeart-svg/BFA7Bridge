import Foundation
import AVFoundation
import Combine

@MainActor
final class VoiceIO: NSObject, ObservableObject {
    @Published private(set) var status = "Ожидание"
    @Published private(set) var routeStatus = "Audio route not checked"
    @Published private(set) var recordingStatus = "Recording not tested"
    @Published private(set) var isRecording = false
    @Published private(set) var lastRecordingURL: URL?

    private let synthesizer = AVSpeechSynthesizer()
    private var recorder: AVAudioRecorder?
    private var recordingStartedAt: Date?

    func prepareAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            preferBFA7InputIfAvailable()
            refreshRouteStatus()
            status = "Аудио готово"
        } catch {
            status = "Ошибка аудио: \(error.localizedDescription)"
            refreshRouteStatus()
        }
    }

    func refreshRouteStatus() {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let inputSummary = inputs.map { input in
            "\(input.portName) [\(input.portType.rawValue)]"
        }.joined(separator: ", ")
        let outputs = session.currentRoute.outputs.map { output in
            "\(output.portName) [\(output.portType.rawValue)]"
        }.joined(separator: ", ")
        let currentInputs = session.currentRoute.inputs.map { input in
            "\(input.portName) [\(input.portType.rawValue)]"
        }.joined(separator: ", ")

        routeStatus = "inputs: \(currentInputs.isEmpty ? "none" : currentInputs); outputs: \(outputs.isEmpty ? "none" : outputs); available: \(inputSummary.isEmpty ? "none" : inputSummary)"
    }

    func preferBFA7InputIfAvailable() {
        let session = AVAudioSession.sharedInstance()
        guard let input = session.availableInputs?.first(where: { port in
            let name = port.portName.lowercased()
            return name.contains("bfa7") || name.contains("xiaomi") || name.contains("ai glasses")
        }) else {
            refreshRouteStatus()
            return
        }

        do {
            try session.setPreferredInput(input)
            routeStatus = "Preferred input: \(input.portName) [\(input.portType.rawValue)]"
            refreshRouteStatus()
        } catch {
            status = "Не удалось выбрать BFA7 mic: \(error.localizedDescription)"
            refreshRouteStatus()
        }
    }

    func speakRouteTest() {
        speak("Проверка связи. Голосовой ответ идет через Xiaomi AI Glasses BFA7, если они выбраны как аудио маршрут.")
    }

    var audioRouteReport: String {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portName) | \($0.portType.rawValue) | \($0.uid)" }
        let outputs = session.currentRoute.outputs.map { "\($0.portName) | \($0.portType.rawValue) | \($0.uid)" }
        let available = (session.availableInputs ?? []).map { "\($0.portName) | \($0.portType.rawValue) | \($0.uid)" }
        return ([
            "BFA7 Audio Route Report",
            "Generated: \(Date().ISO8601Format())",
            "Status: \(status)",
            "Route: \(routeStatus)",
            "Recording: \(recordingStatus)",
            "",
            "Current inputs:",
            inputs.isEmpty ? "  none" : inputs.map { "  \($0)" }.joined(separator: "\n"),
            "",
            "Current outputs:",
            outputs.isEmpty ? "  none" : outputs.map { "  \($0)" }.joined(separator: "\n"),
            "",
            "Available inputs:",
            available.isEmpty ? "  none" : available.map { "  \($0)" }.joined(separator: "\n")
        ]).joined(separator: "\n")
    }

    func startRecording() {
        guard !isRecording else { return }
        prepareAudioSession()

        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                guard allowed else {
                    self.status = "Нет доступа к микрофону"
                    return
                }
                self.beginRecording()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        let recorder = recorder
        recorder?.updateMeters()
        let averagePower = recorder?.averagePower(forChannel: 0)
        let peakPower = recorder?.peakPower(forChannel: 0)
        let url = recorder?.url
        let startedAt = recordingStartedAt

        recorder?.stop()
        self.recorder = nil
        recordingStartedAt = nil
        isRecording = false

        updateRecordingStatus(
            url: url,
            startedAt: startedAt,
            averagePower: averagePower,
            peakPower: peakPower
        )
        status = "Запись сохранена"
        refreshRouteStatus()
    }

    func speak(_ text: String) {
        prepareAudioSession()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        status = "Голосовой ответ воспроизводится"
        refreshRouteStatus()
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        status = "Озвучивание остановлено"
    }

    private func beginRecording() {
        do {
            let directory = try recordingDirectory()
            let url = directory.appendingPathComponent("push-to-talk-\(Int(Date().timeIntervalSince1970)).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            recordingStartedAt = Date()
            lastRecordingURL = url
            recordingStatus = "Recording active on current route"
            isRecording = true
            status = "Идёт запись"
        } catch {
            status = "Ошибка записи: \(error.localizedDescription)"
        }
    }

    private func updateRecordingStatus(url: URL?, startedAt: Date?, averagePower: Float?, peakPower: Float?) {
        guard let url else {
            recordingStatus = "No recording URL"
            return
        }

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let average = averagePower.map { String(format: "%.1f dB", $0) } ?? "n/a"
        let peak = peakPower.map { String(format: "%.1f dB", $0) } ?? "n/a"
        recordingStatus = "file=\(url.lastPathComponent), duration=\(String(format: "%.2fs", duration)), size=\(size)B, avg=\(average), peak=\(peak)"
    }

    private func recordingDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("BFA7PushToTalk", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
