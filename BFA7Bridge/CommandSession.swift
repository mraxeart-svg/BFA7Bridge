import Foundation
import Combine
import UIKit

@MainActor
final class CommandSession: ObservableObject {
    @Published var commandText = "Опиши что передо мной?"
    @Published private(set) var lastPayload: BFA7AskPayload?
    @Published private(set) var providerState: BFA7AIProviderState = .idle
    @Published private(set) var lastResponseText: String?
    @Published private(set) var status = "Ожидание"

    private let freeProvider = FreeChatGPTProvider()
    private let apiProvider = DisabledOpenAIAPIProvider()

    func preparePayload(media: BFA7MediaFile?) {
        let payload = BFA7AskPayload(command: normalizedCommand, media: media, createdAt: Date())
        lastPayload = payload
        providerState = .ready("Запрос подготовлен")
        status = media == nil ? "Запрос без медиа" : "Запрос с медиа: \(media!.filename)"
    }

    func submitFree(media: BFA7MediaFile?, voice: VoiceIO) async {
        let payload = BFA7AskPayload(command: normalizedCommand, media: media, createdAt: Date())
        lastPayload = payload
        providerState = .preparing
        status = "Free gate: подготовка"

        let result = await freeProvider.submit(payload: payload)
        providerState = result.state
        lastResponseText = result.responseText

        switch result.state {
        case .ready(let message):
            status = message
            if let response = result.responseText {
                voice.speak(response)
            }
        case .blocked(let reason):
            status = reason
            voice.speak("Запрос подготовлен. Бесплатный автоматический ответ пока заблокирован ограничениями iOS и ChatGPT.")
        case .failed(let error):
            status = error
        case .idle:
            status = "Ожидание"
        case .preparing:
            status = "Подготовка"
        }
    }

    func provePaidAPIIsDisabled() async {
        let payload = lastPayload ?? BFA7AskPayload(command: normalizedCommand, media: nil, createdAt: Date())
        let result = await apiProvider.submit(payload: payload)
        providerState = result.state
        status = statusText(for: result.state)
    }

    func copyPrompt() {
        let payload = lastPayload ?? BFA7AskPayload(command: normalizedCommand, media: nil, createdAt: Date())
        UIPasteboard.general.string = payload.promptText
        lastPayload = payload
        providerState = .ready("Prompt copied")
        status = "Prompt copied"
    }

    private var normalizedCommand: String {
        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Опиши что передо мной?" : trimmed
    }

    private func statusText(for state: BFA7AIProviderState) -> String {
        switch state {
        case .idle: return "Ожидание"
        case .preparing: return "Подготовка"
        case .ready(let value): return value
        case .blocked(let value): return value
        case .failed(let value): return value
        }
    }
}
