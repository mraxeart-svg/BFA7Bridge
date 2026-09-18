import Foundation
import Combine

enum BFA7EventKind: String, Codable {
    case connection
    case discovery
    case notification
    case value
    case button
    case touch
    case camera
    case microphone
    case audio
    case wifi
    case file
    case diagnostic
    case error
}

struct BFA7Event: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let kind: BFA7EventKind
    let title: String
    let detail: String

    init(kind: BFA7EventKind, title: String, detail: String = "") {
        self.id = UUID()
        self.date = Date()
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    var line: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let suffix = detail.isEmpty ? "" : " | \(detail)"
        return "\(formatter.string(from: date)) | \(kind.rawValue.uppercased()) | \(title)\(suffix)"
    }
}

@MainActor
final class BFA7EventBus: ObservableObject {
    @Published private(set) var events: [BFA7Event] = []
    private let limit = 2000

    func publish(_ event: BFA7Event) {
        events.append(event)
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
    }

    func publish(kind: BFA7EventKind, title: String, detail: String = "") {
        publish(BFA7Event(kind: kind, title: title, detail: detail))
    }

    func clear() {
        events.removeAll()
    }

    var report: String {
        events.map(\.line).joined(separator: "\n")
    }
}
