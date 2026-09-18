import Foundation

struct BFA7Capability: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
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
