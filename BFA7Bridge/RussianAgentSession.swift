import Foundation
import Combine
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class RussianAgentSession: ObservableObject {
    @Published var endpointText: String {
        didSet { UserDefaults.standard.set(endpointText, forKey: Self.endpointKey) }
    }
    @Published var modelText: String {
        didSet { UserDefaults.standard.set(modelText, forKey: Self.modelKey) }
    }
    @Published var apiKeyText: String {
        didSet { UserDefaults.standard.set(apiKeyText, forKey: Self.apiKeyKey) }
    }
    @Published var attachLatestPhoto: Bool {
        didSet { UserDefaults.standard.set(attachLatestPhoto, forKey: Self.attachLatestPhotoKey) }
    }
    @Published var userText = "Что я вижу?"
    @Published private(set) var status = "Русский агент готов"
    @Published private(set) var lastResponse = ""
    @Published private(set) var lastPrompt = ""
    @Published private(set) var isBusy = false

    private static let endpointKey = "BFA7Bridge.russianAgent.endpoint.v1"
    private static let modelKey = "BFA7Bridge.russianAgent.model.v1"
    private static let apiKeyKey = "BFA7Bridge.russianAgent.apiKey.v1"
    private static let attachLatestPhotoKey = "BFA7Bridge.russianAgent.attachLatestPhoto.v1"

    init() {
        endpointText = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        modelText = UserDefaults.standard.string(forKey: Self.modelKey) ?? "local-model"
        apiKeyText = UserDefaults.standard.string(forKey: Self.apiKeyKey) ?? ""
        attachLatestPhoto = UserDefaults.standard.bool(forKey: Self.attachLatestPhotoKey)
    }

    func useTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userText = trimmed
        status = "Команда перенесена в русского агента"
    }

    func ask(media: BFA7MediaFile?, voice: VoiceIO) async {
        let command = normalizedUserText
        guard !command.isEmpty else {
            status = "Скажи или введи команду"
            return
        }

        isBusy = true
        status = "Русский агент думает"
        lastPrompt = prompt(command: command, media: media)

        do {
            let response: String
            if let endpoint = normalizedEndpoint {
                response = try await submitOpenAICompatible(
                    endpoint: endpoint,
                    model: normalizedModel,
                    prompt: lastPrompt,
                    media: media
                )
            } else {
                response = localResponse(command: command, media: media)
            }

            lastResponse = response
            status = normalizedEndpoint == nil ? "Локальный тестовый ответ готов" : "Ответ агента готов"
            voice.speak(response)
        } catch {
            status = "Ошибка агента: \(error.localizedDescription)"
        }

        isBusy = false
    }

    func speakLastResponse(voice: VoiceIO) {
        let text = lastResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "Нет ответа для озвучки"
            return
        }
        voice.speak(text)
    }

    private var normalizedUserText: String {
        userText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedModel: String {
        let trimmed = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "local-model" : trimmed
    }

    private var normalizedEndpoint: URL? {
        let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
            return nil
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/v1/chat/completions"
        } else if path == "v1" {
            components.path = "/v1/chat/completions"
        } else if !path.hasSuffix("chat/completions") {
            components.path = "/" + path + "/v1/chat/completions"
        }
        return components.url
    }

    private func prompt(command: String, media: BFA7MediaFile?) -> String {
        var lines = [
            "Ты русский голосовой агент для Xiaomi AI Glasses BFA7.",
            "Отвечай только на русском языке, коротко и практически.",
            "Команда пользователя: \(command)"
        ]

        if let media {
            lines.append("Последний файл с очков: \(media.filename), тип: \(media.kind.rawValue), размер: \(media.displaySize).")
            lines.append("Если тебе нужен реальный анализ изображения, скажи, что в этой версии изображение ещё не прикреплено к модели.")
        } else {
            lines.append("Изображение или видео сейчас не прикреплено.")
        }

        return lines.joined(separator: "\n")
    }

    private func localResponse(command: String, media: BFA7MediaFile?) -> String {
        let lowercased = command.lowercased()
        if lowercased.contains("виж") || lowercased.contains("опиши") || lowercased.contains("передо мной") {
            if let media {
                return "Я получил команду на русском и вижу последний файл с очков: \(media.filename). Реальный анализ изображения следующим шагом подключим через модель с vision."
            }
            return "Я понял команду на русском. Сейчас у меня нет изображения с очков, поэтому описать сцену честно не могу. Зато голосовой русский контур уже работает."
        }

        if lowercased.contains("переведи") {
            return "Я понял команду перевода. Для полноценного перевода подключи локальную модель через OpenAI-compatible endpoint."
        }

        return "Я русский агент BFA7 Bridge. Я услышал: \(command). Подключи локальную модель, и я буду отвечать как полноценный ИИ прямо голосом в очки."
    }

    private func submitOpenAICompatible(endpoint: URL, model: String, prompt: String, media: BFA7MediaFile?) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let apiKey = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var userContent = ChatRequestContent.text(prompt)
        if let imagePart = try latestPhotoPart(media: media) {
            userContent = .parts([
                .text(prompt),
                imagePart
            ])
        }

        let payload = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: .text("Ты полезный русский ассистент в умных очках. Отвечай кратко, ясно и только на русском языке.")),
                .init(role: "user", content: userContent)
            ],
            temperature: 0.4
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "empty response"
            throw RussianAgentError.httpStatus(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let answer = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty else {
            throw RussianAgentError.emptyAnswer
        }
        return answer
    }

    private func latestPhotoPart(media: BFA7MediaFile?) throws -> ChatContentPart? {
        guard attachLatestPhoto, let media, media.kind == .photo, let url = media.localURL else {
            return nil
        }

        let data = try Data(contentsOf: url)
        guard data.count <= 8_000_000 else {
            throw RussianAgentError.imageTooLarge(data.count)
        }

        return .image(url: "data:\(mimeType(for: url));base64,\(data.base64EncodedString())")
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "heic", "heif":
            return "image/heic"
        default:
            return "image/jpeg"
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatRequestMessage]
    let temperature: Double
}

private struct ChatRequestMessage: Encodable {
    let role: String
    let content: ChatRequestContent
}

private enum ChatRequestContent: Encodable {
    case text(String)
    case parts([ChatContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private struct ChatContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: ChatImageURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    static func text(_ text: String) -> ChatContentPart {
        ChatContentPart(type: "text", text: text, imageURL: nil)
    }

    static func image(url: String) -> ChatContentPart {
        ChatContentPart(type: "image_url", text: nil, imageURL: ChatImageURL(url: url))
    }
}

private struct ChatImageURL: Encodable {
    let url: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

private enum RussianAgentError: LocalizedError {
    case httpStatus(Int, String)
    case emptyAnswer
    case imageTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let body):
            return "HTTP \(status): \(body)"
        case .emptyAnswer:
            return "модель вернула пустой ответ"
        case .imageTooLarge(let size):
            return "фото слишком большое для запроса: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        }
    }
}
