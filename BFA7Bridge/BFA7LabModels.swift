import Foundation
import Combine

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

enum BFA7ExperimentKind: String, CaseIterable, Identifiable {
    case cameraButton = "Кнопка камеры"
    case touch = "Touch"

    var id: String { rawValue }
}

struct BFA7PacketEvent: Identifiable, Hashable {
    let id: UUID
    let date: Date
    let characteristicUUID: String
    let data: Data

    var hex: String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var byteCount: Int { data.count }

    var protocolPrefix: String {
        let bytes = Array(data.prefix(6))
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var signature: String {
        let head = Array(data.prefix(12))
        let tail = Array(data.suffix(4))
        let body = (head + (data.count > 16 ? tail : [])).map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(characteristicUUID)|\(data.count)|\(body)"
    }

    init(date: Date = Date(), characteristicUUID: String, data: Data) {
        self.id = UUID()
        self.date = date
        self.characteristicUUID = characteristicUUID
        self.data = data
    }
}

struct BFA7ExperimentResult: Identifiable {
    let id = UUID()
    let kind: BFA7ExperimentKind
    let startedAt: Date
    let triggerAt: Date
    let endedAt: Date
    let baselineCount: Int
    let actionCount: Int
    let candidatePackets: [BFA7PacketEvent]
    let changedPackets: [BFA7PacketEvent]

    var report: String {
        var lines: [String] = []
        lines.append("BFA7 Experiment: \(kind.rawValue)")
        lines.append("Start: \(startedAt.ISO8601Format())")
        lines.append("Trigger marker: \(triggerAt.ISO8601Format())")
        lines.append("End: \(endedAt.ISO8601Format())")
        lines.append("Baseline packets: \(baselineCount)")
        lines.append("Action-window packets: \(actionCount)")
        lines.append("Candidates: \(candidatePackets.count)")
        lines.append("Changed payloads: \(changedPackets.count)")
        lines.append("")
        lines.append("Candidates:")
        for packet in candidatePackets.prefix(30) {
            lines.append("  \(packet.date.ISO8601Format()) | \(packet.characteristicUUID) | \(packet.byteCount) B | \(packet.hex)")
        }
        if candidatePackets.count > 30 {
            lines.append("  … +\(candidatePackets.count - 30) more")
        }
        lines.append("")
        lines.append("Interpretation: candidates are correlations only; this experiment does not prove that a packet is a button/touch command.")
        return lines.joined(separator: "\n")
    }
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
