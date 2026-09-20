import Foundation
import Combine

struct BFA7ProtocolPacket: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let serviceUUID: String
    let characteristicUUID: String
    let byteCount: Int
    let hex: String
    let ascii: String
    let firstBytes: String
    let looksLikeA5Frame: Bool

    init(date: Date = Date(), serviceUUID: String, characteristicUUID: String, data: Data) {
        self.id = UUID()
        self.date = date
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.byteCount = data.count
        self.hex = data.bfa7HexString
        self.ascii = data.bfa7AsciiPreview
        self.firstBytes = Data(data.prefix(8)).bfa7HexString
        self.looksLikeA5Frame = data.count >= 2 && data[data.startIndex] == 0xA5 && data[data.index(after: data.startIndex)] == 0xA5
    }

    var line: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(formatter.string(from: date)) | \(characteristicUUID) | \(byteCount) B | \(firstBytes) | A5=\(looksLikeA5Frame ? "yes" : "no")"
    }

    var csvLine: String {
        [
            date.ISO8601Format(),
            serviceUUID,
            characteristicUUID,
            "\(byteCount)",
            firstBytes,
            looksLikeA5Frame ? "true" : "false",
            hex,
            ascii
        ].map(Self.csvEscape).joined(separator: ",")
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

private struct BFA7PacketSizeCount {
    let size: Int
    let count: Int
}

struct BFA7TimelineEntry: Identifiable, Hashable {
    let id = UUID()
    let relativeSeconds: TimeInterval
    let packet: BFA7ProtocolPacket

    var relativeLabel: String {
        String(format: "%+.3fs", relativeSeconds)
    }
}

@MainActor
final class ProtocolLab: ObservableObject {
    @Published private(set) var packets: [BFA7ProtocolPacket] = []
    @Published var characteristicFilter = "005E"
    @Published var showOnlyA5Frames = false
    @Published var timelineWindowBefore: TimeInterval = 10
    @Published var timelineWindowAfter: TimeInterval = 15
    private let limit = 5000

    func record(serviceUUID: String, characteristicUUID: String, data: Data) {
        packets.append(BFA7ProtocolPacket(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID, data: data))
        if packets.count > limit {
            packets.removeFirst(packets.count - limit)
        }
    }

    func clear() {
        packets.removeAll()
    }

    var filteredPackets: [BFA7ProtocolPacket] {
        packets.filter { packet in
            let matchesCharacteristic = characteristicFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || packet.characteristicUUID.localizedCaseInsensitiveContains(characteristicFilter)
            let matchesFrame = !showOnlyA5Frames || packet.looksLikeA5Frame
            return matchesCharacteristic && matchesFrame
        }
    }

    func timeline(around date: Date?) -> [BFA7TimelineEntry] {
        guard let date else { return filteredPackets.suffix(80).map { BFA7TimelineEntry(relativeSeconds: 0, packet: $0) } }
        return filteredPackets.compactMap { packet in
            let relative = packet.date.timeIntervalSince(date)
            guard relative >= -timelineWindowBefore && relative <= timelineWindowAfter else { return nil }
            return BFA7TimelineEntry(relativeSeconds: relative, packet: packet)
        }
    }

    var packetStats: String {
        let filtered = filteredPackets
        let a5 = filtered.filter { $0.looksLikeA5Frame }.count
        let grouped = Dictionary(grouping: filtered) { packet in
            packet.byteCount
        }
        let sizeCounts = grouped.map { key, value in
            BFA7PacketSizeCount(size: key, count: value.count)
        }
        let sortedSizeCounts = sizeCounts.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.size < rhs.size
            }
            return lhs.count > rhs.count
        }
        let sizeSummary = sortedSizeCounts.prefix(8).map { item in
            "\(item.size)B x\(item.count)"
        }.joined(separator: ", ")
        return "packets=\(filtered.count), A5=\(a5), sizes=[\(sizeSummary)]"
    }

    var jsonExport: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(filteredPackets)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    var csvExport: String {
        let header = "date,service_uuid,characteristic_uuid,byte_count,first_bytes,looks_like_a5,hex,ascii"
        return ([header] + filteredPackets.map(\.csvLine)).joined(separator: "\n")
    }

    func focusedReport(around date: Date?) -> String {
        var lines: [String] = []
        lines.append("BFA7 Protocol Lab focused report")
        lines.append("Generated: \(Date().ISO8601Format())")
        lines.append("Filter: \(characteristicFilter.isEmpty ? "all" : characteristicFilter)")
        lines.append(packetStats)
        lines.append("")
        for entry in timeline(around: date) {
            lines.append("\(entry.relativeLabel) | \(entry.packet.line)")
        }
        return lines.joined(separator: "\n")
    }
}

extension Data {
    var bfa7HexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var bfa7AsciiPreview: String {
        map { byte -> String in
            let value = Int(byte)
            return (32...126).contains(value) ? String(UnicodeScalar(value)!) : "."
        }.joined()
    }
}
