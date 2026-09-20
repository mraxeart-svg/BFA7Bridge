import Foundation
import AVFoundation
import Combine

@MainActor
final class VoiceIO: NSObject, ObservableObject {
    @Published private(set) var status = "Ожидание"
    @Published private(set) var isRecording = false
    @Published private(set) var lastRecordingURL: URL?

    private let synthesizer = AVSpeechSynthesizer()
    private var recorder: AVAudioRecorder?

    func prepareAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            status = "Аудио готово"
        } catch {
            status = "Ошибка аудио: \(error.localizedDescription)"
        }
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
        recorder?.stop()
        recorder = nil
        isRecording = false
        status = "Запись сохранена"
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
            recorder.record()
            self.recorder = recorder
            lastRecordingURL = url
            isRecording = true
            status = "Идёт запись"
        } catch {
            status = "Ошибка записи: \(error.localizedDescription)"
        }
    }

    private func recordingDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("BFA7PushToTalk", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
