import Foundation
import UIKit

struct BFA7AIResult {
    let state: BFA7AIProviderState
    let responseText: String?
    let handoffURL: URL?
}

@MainActor
protocol BFA7AIProviding {
    var name: String { get }
    func submit(payload: BFA7AskPayload) async -> BFA7AIResult
}

@MainActor
struct FreeChatGPTProvider: BFA7AIProviding {
    let name = "Free ChatGPT handoff"

    func submit(payload: BFA7AskPayload) async -> BFA7AIResult {
        UIPasteboard.general.string = payload.promptText

        let chatGPTURL = URL(string: "chatgpt://")
        if let chatGPTURL, UIApplication.shared.canOpenURL(chatGPTURL) {
            await UIApplication.shared.openAsync(chatGPTURL)
            return BFA7AIResult(
                state: .blocked("Prompt copied and ChatGPT opened. iOS 17 does not expose a public free ChatGPT API that returns the answer to BFA7 Bridge automatically."),
                responseText: nil,
                handoffURL: chatGPTURL
            )
        }

        return BFA7AIResult(
            state: .blocked("Prompt copied. Install/sign in to the ChatGPT app or choose a local/free model path; no paid OpenAI API call was made."),
            responseText: nil,
            handoffURL: nil
        )
    }
}

struct DisabledOpenAIAPIProvider: BFA7AIProviding {
    let name = "OpenAI API disabled"

    func submit(payload: BFA7AskPayload) async -> BFA7AIResult {
        BFA7AIResult(
            state: .blocked("OpenAI API is intentionally disabled for this free-first build. It must not be enabled without explicit approval because it bills per API usage."),
            responseText: nil,
            handoffURL: nil
        )
    }
}

private extension UIApplication {
    @MainActor
    func openAsync(_ url: URL) async {
        await withCheckedContinuation { continuation in
            open(url, options: [:]) { _ in
                continuation.resume()
            }
        }
    }
}
