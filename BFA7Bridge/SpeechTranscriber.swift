import Foundation
import Combine
import Speech

@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published private(set) var status = "Распознавание не запускалось"
    @Published private(set) var lastTranscript = ""

    private let locale = Locale(identifier: "ru-RU")

    func transcribe(url: URL?) async -> String? {
        guard let url else {
            status = "Нет записи для распознавания"
            return nil
        }

        guard await requestAuthorization() else {
            return nil
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            status = "Русское распознавание речи сейчас недоступно"
            return nil
        }

        status = "Распознаю \(url.lastPathComponent)"

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation

        return await withCheckedContinuation { continuation in
            var didResume = false
            var bestTranscript = ""
            recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result {
                    bestTranscript = result.bestTranscription.formattedString
                }

                let isFinished = result?.isFinal == true || error != nil
                guard isFinished, !didResume else { return }
                didResume = true

                Task { @MainActor in
                    if let error {
                        self?.status = "Ошибка распознавания: \(error.localizedDescription)"
                        continuation.resume(returning: nil)
                        return
                    }

                    let transcript = bestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if transcript.isEmpty {
                        self?.status = "Речь не распознана"
                        continuation.resume(returning: nil)
                    } else {
                        self?.lastTranscript = transcript
                        self?.status = "Команда распознана"
                        continuation.resume(returning: transcript)
                    }
                }
            }
        }
    }

    private func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let result = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                    continuation.resume(returning: authorizationStatus)
                }
            }
            if result == .authorized {
                return true
            }
            self.status = authorizationMessage(for: result)
            return false
        case .denied, .restricted:
            self.status = authorizationMessage(for: status)
            return false
        @unknown default:
            self.status = "Неизвестный статус Speech permission"
            return false
        }
    }

    private func authorizationMessage(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "Speech разрешён"
        case .denied:
            return "Нет доступа к распознаванию речи"
        case .restricted:
            return "Распознавание речи ограничено на устройстве"
        case .notDetermined:
            return "Speech permission ещё не запрошен"
        @unknown default:
            return "Неизвестный статус Speech permission"
        }
    }
}
