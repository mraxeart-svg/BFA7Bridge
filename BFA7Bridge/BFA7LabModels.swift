import Foundation
import Combine

struct BFA7Capability: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
}

struct BFA7Device: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let serviceData: String
    let profileHint: String
    let advertisedServices: String
}

struct BFA7GATTCharacteristic: Identifiable, Hashable {
    let id: String
    let serviceUUID: String
    let uuid: String
    let properties: String
    let notifying: Bool
}

struct BFA7GATTService: Identifiable, Hashable {
    let id: String
    let uuid: String
    let characteristics: [BFA7GATTCharacteristic]
}

struct BFA7Session: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let eventCount: Int
}

struct BFA7MediaFile: Identifiable, Hashable, Codable {
    let id: String
    let filename: String
    let kind: BFA7MediaKind
    let sizeBytes: Int?
    let createdAt: Date?
    let remotePath: String?
    var localURL: URL?

    var displaySize: String {
        guard let sizeBytes else { return "size unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(sizeBytes))
    }
}

enum BFA7MediaKind: String, Codable {
    case photo
    case video
    case audio
    case unknown

    init(filename: String) {
        let lowercased = filename.lowercased()
        if lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") || lowercased.hasSuffix(".png") || lowercased.hasSuffix(".heic") || lowercased.hasSuffix(".heif") || lowercased.hasPrefix("img_") || lowercased.hasPrefix("pic_") {
            self = .photo
        } else if lowercased.hasSuffix(".mp4") || lowercased.hasSuffix(".mov") || lowercased.hasPrefix("vid_") {
            self = .video
        } else if lowercased.hasSuffix(".m4a") || lowercased.hasSuffix(".wav") || lowercased.hasSuffix(".aac") || lowercased.hasPrefix("aud_") {
            self = .audio
        } else {
            self = .unknown
        }
    }

    init(mimeType: String?) {
        let lowercased = mimeType?.lowercased() ?? ""
        if lowercased.hasPrefix("image/") {
            self = .photo
        } else if lowercased.hasPrefix("video/") {
            self = .video
        } else if lowercased.hasPrefix("audio/") {
            self = .audio
        } else {
            self = .unknown
        }
    }
}

struct BFA7AskPayload: Identifiable, Hashable {
    let id = UUID()
    let command: String
    let media: BFA7MediaFile?
    let createdAt: Date

    var promptText: String {
        var lines = [
            "BFA7 Bridge request",
            "Command: \(command)"
        ]
        if let media {
            lines.append("Media: \(media.filename)")
            lines.append("Media kind: \(media.kind.rawValue)")
            lines.append("Media size: \(media.displaySize)")
            if let localURL = media.localURL {
                lines.append("Local file: \(localURL.lastPathComponent)")
            }
        } else {
            lines.append("Media: none")
        }
        lines.append("Answer briefly in Russian and describe what is visible if an image/video frame is attached.")
        return lines.joined(separator: "\n")
    }
}

enum BFA7AIProviderState: Equatable {
    case idle
    case preparing
    case ready(String)
    case blocked(String)
    case failed(String)
}

@MainActor
final class BFA7SessionStore: ObservableObject {
    @Published private(set) var sessions: [BFA7Session] = []
    private let key = "BFA7Bridge.sessions.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([BFA7Session].self, from: data) {
            sessions = decoded
        }
    }

    func save(_ session: BFA7Session) {
        sessions.insert(session, at: 0)
        sessions = Array(sessions.prefix(20))
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clear() {
        sessions.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }
}
