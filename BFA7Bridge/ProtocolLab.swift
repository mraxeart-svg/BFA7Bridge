import Foundation
import Combine

enum BFA7PacketDirection: String, Codable, Hashable {
    case incoming = "in"
    case outgoing = "out"

    var marker: String {
        switch self {
        case .incoming:
            return "<-"
        case .outgoing:
            return "->"
        }
    }
}

struct BFA7ProtocolPacket: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let direction: BFA7PacketDirection
    let serviceUUID: String
    let characteristicUUID: String
    let byteCount: Int
    let hex: String
    let ascii: String
    let firstBytes: String
    let looksLikeA5Frame: Bool
    let frame: BFA7Frame?

    init(date: Date = Date(), direction: BFA7PacketDirection = .incoming, serviceUUID: String, characteristicUUID: String, data: Data) {
        self.id = UUID()
        self.date = date
        self.direction = direction
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.byteCount = data.count
        self.hex = data.bfa7HexString
        self.ascii = data.bfa7AsciiPreview
        self.firstBytes = Data(data.prefix(8)).bfa7HexString
        self.looksLikeA5Frame = data.count >= 2 && data[data.startIndex] == 0xA5 && data[data.index(after: data.startIndex)] == 0xA5
        self.frame = BFA7Frame(data: data)
    }

    var line: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let frameSummary = frame?.summary ?? "raw"
        return "\(formatter.string(from: date)) | \(direction.marker) \(characteristicUUID) | \(byteCount) B | \(firstBytes) | \(frameSummary)"
    }

    var csvLine: String {
        [
            date.ISO8601Format(),
            direction.rawValue,
            serviceUUID,
            characteristicUUID,
            "\(byteCount)",
            firstBytes,
            looksLikeA5Frame ? "true" : "false",
            frame?.kind.rawValue ?? "",
            frame?.sequenceText ?? "",
            frame?.declaredLengthText ?? "",
            hex,
            ascii
        ].map(Self.csvEscape).joined(separator: ",")
    }

    private static func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}


enum BFA7FrameKind: String, Codable, Hashable {
    case shortControl
    case payloadStart
    case payloadContinuation
    case unknown
}

struct BFA7Frame: Codable, Hashable {
    let kind: BFA7FrameKind
    let sequence: Int?
    let declaredLength: Int?
    let opCode: Int?
    let header: String

    init?(data: Data) {
        guard !data.isEmpty else { return nil }
        let bytes = Array(data)
        if bytes.count >= 2, bytes[0] == 0xA5, bytes[1] == 0xA5 {
            sequence = bytes.count > 3 ? Int(bytes[3]) : nil
            declaredLength = bytes.count > 5 ? Int(bytes[4]) | (Int(bytes[5]) << 8) : nil
            opCode = bytes.count > 2 ? Int(bytes[2]) : nil
            header = Data(bytes.prefix(min(bytes.count, 8))).bfa7HexString

            if bytes.count == 8, bytes.count > 2, bytes[2] == 0x01 {
                kind = .shortControl
            } else if bytes.count > 2, bytes[2] == 0x03 {
                kind = .payloadStart
            } else {
                kind = .unknown
            }
        } else {
            sequence = nil
            declaredLength = nil
            opCode = nil
            header = Data(bytes.prefix(min(bytes.count, 8))).bfa7HexString
            kind = .payloadContinuation
        }
    }

    var sequenceText: String {
        guard let sequence else { return "" }
        return String(format: "0x%02X", sequence)
    }

    var declaredLengthText: String {
        guard let declaredLength else { return "" }
        return "\(declaredLength)"
    }

    var summary: String {
        var parts = ["kind=\(kind.rawValue)"]
        if let opCode {
            parts.append(String(format: "op=0x%02X", opCode))
        }
        if let sequence {
            parts.append(String(format: "seq=0x%02X", sequence))
        }
        if let declaredLength {
            parts.append("len=\(declaredLength)")
        }
        return parts.joined(separator: " ")
    }
}

private struct BFA7PacketSizeCount {
    let size: Int
    let count: Int
}

private struct BFA7FrameKindCount {
    let kind: BFA7FrameKind
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

struct BFA7BurstSummary: Identifiable, Hashable {
    let id = UUID()
    let relativeStart: TimeInterval
    let relativeEnd: TimeInterval
    let packetCount: Int
    let byteCount: Int
    let payloadStartCount: Int
    let continuationCount: Int
    let shortControlCount: Int
    let sequenceRange: String
    let firstHeader: String
    let lastHeader: String

    var duration: TimeInterval {
        max(0, relativeEnd - relativeStart)
    }

    var relativeRangeLabel: String {
        "\(Self.timeLabel(relativeStart))...\(Self.timeLabel(relativeEnd))"
    }

    var line: String {
        "\(relativeRangeLabel) | duration=\(String(format: "%.3fs", duration)) | packets=\(packetCount) | bytes=\(byteCount) | starts=\(payloadStartCount) | continuations=\(continuationCount) | controls=\(shortControlCount) | seq=\(sequenceRange) | first=\(firstHeader) | last=\(lastHeader)"
    }

    private static func timeLabel(_ value: TimeInterval) -> String {
        String(format: "%+.3fs", value)
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

    func record(direction: BFA7PacketDirection = .incoming, serviceUUID: String, characteristicUUID: String, data: Data) {
        packets.append(BFA7ProtocolPacket(direction: direction, serviceUUID: serviceUUID, characteristicUUID: characteristicUUID, data: data))
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

    func burstSummaries(around date: Date?) -> [BFA7BurstSummary] {
        let candidates = timeline(around: date)
            .filter { entry in
                entry.packet.byteCount >= 64 || entry.packet.frame?.kind == .payloadStart || entry.packet.frame?.kind == .payloadContinuation
            }
            .sorted { $0.relativeSeconds < $1.relativeSeconds }

        var groups: [[BFA7TimelineEntry]] = []
        let maxGap: TimeInterval = 0.35

        for entry in candidates {
            if let lastGroup = groups.indices.last, let previous = groups[lastGroup].last, entry.relativeSeconds - previous.relativeSeconds <= maxGap {
                groups[lastGroup].append(entry)
            } else {
                groups.append([entry])
            }
        }

        return groups.compactMap { group in
            let byteCount = group.reduce(0) { $0 + $1.packet.byteCount }
            guard byteCount >= 4096 || group.count >= 8 else { return nil }

            let payloadStarts = group.filter { $0.packet.frame?.kind == .payloadStart }
            let continuations = group.filter { $0.packet.frame?.kind == .payloadContinuation }
            let controls = group.filter { $0.packet.frame?.kind == .shortControl }
            let sequences = payloadStarts.compactMap { $0.packet.frame?.sequence }
            let sequenceRange: String
            if let first = sequences.first, let last = sequences.last {
                sequenceRange = String(format: "0x%02X...0x%02X", first, last)
            } else {
                sequenceRange = "none"
            }

            return BFA7BurstSummary(
                relativeStart: group.first?.relativeSeconds ?? 0,
                relativeEnd: group.last?.relativeSeconds ?? 0,
                packetCount: group.count,
                byteCount: byteCount,
                payloadStartCount: payloadStarts.count,
                continuationCount: continuations.count,
                shortControlCount: controls.count,
                sequenceRange: sequenceRange,
                firstHeader: group.first?.packet.firstBytes ?? "",
                lastHeader: group.last?.packet.firstBytes ?? ""
            )
        }
    }

    var burstStats: String {
        let bursts = burstSummaries(around: nil)
        guard !bursts.isEmpty else { return "capture bursts=0" }
        let largest = bursts.max { $0.byteCount < $1.byteCount }
        return "capture bursts=\(bursts.count), largest=\(largest?.byteCount ?? 0)B"
    }

    var packetStats: String {
        let filtered = filteredPackets
        let a5 = filtered.filter { $0.looksLikeA5Frame }.count
        let incoming = filtered.filter { $0.direction == .incoming }.count
        let outgoing = filtered.filter { $0.direction == .outgoing }.count
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
        let groupedKinds = Dictionary(grouping: filtered.compactMap(\.frame)) { frame in
            frame.kind
        }
        let kindCounts = groupedKinds.map { key, value in
            BFA7FrameKindCount(kind: key, count: value.count)
        }
        let kindSummary = kindCounts.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.count > rhs.count
        }.map { item in
            "\(item.kind.rawValue) x\(item.count)"
        }.joined(separator: ", ")
        return "packets=\(filtered.count), in=\(incoming), out=\(outgoing), A5=\(a5), sizes=[\(sizeSummary)], frames=[\(kindSummary)]"
    }

    var jsonExport: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(filteredPackets)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    var csvExport: String {
        let header = "date,direction,service_uuid,characteristic_uuid,byte_count,first_bytes,looks_like_a5,frame_kind,sequence,declared_length,hex,ascii"
        return ([header] + filteredPackets.map(\.csvLine)).joined(separator: "\n")
    }

    func buttonCandidateReport(around date: Date?) -> String {
        let entries = timeline(around: date)
        let controlFrames = entries.filter { entry in
            entry.packet.frame?.kind == .shortControl
        }
        var lines: [String] = []
        lines.append("BFA7 Button Candidate Report")
        lines.append("Generated: \(Date().ISO8601Format())")
        lines.append("Mark: \(date?.ISO8601Format() ?? "not marked")")
        lines.append("Short control frames are common keep-alive/control counters until proven otherwise.")
        lines.append("")
        for entry in controlFrames {
            let frame = entry.packet.frame
            lines.append("\(entry.relativeLabel) | \(entry.packet.direction.marker) \(entry.packet.characteristicUUID) | \(entry.packet.firstBytes) | \(frame?.summary ?? "raw")")
        }
        return lines.joined(separator: "\n")
    }

    func captureBurstReport(around date: Date?) -> String {
        let bursts = burstSummaries(around: date)
        var lines: [String] = []
        lines.append("BFA7 Capture Burst Report")
        lines.append("Generated: \(Date().ISO8601Format())")
        lines.append("Mark: \(date?.ISO8601Format() ?? "not marked")")
        lines.append("Heuristic: grouped payload/large packets with <=350ms gaps; candidate if >=4096 bytes or >=8 packets.")
        lines.append("")

        if bursts.isEmpty {
            lines.append("No capture-sized burst found in the focused window.")
        } else {
            for burst in bursts {
                lines.append(burst.line)
            }
        }

        return lines.joined(separator: "\n")
    }



    func importWindowEntries(around date: Date?) -> [BFA7TimelineEntry] {
        guard let date else { return packets.suffix(120).map { BFA7TimelineEntry(relativeSeconds: 0, packet: $0) } }
        return packets.compactMap { packet in
            let relative = packet.date.timeIntervalSince(date)
            guard relative >= -timelineWindowBefore && relative <= timelineWindowAfter else { return nil }
            return BFA7TimelineEntry(relativeSeconds: relative, packet: packet)
        }
        .sorted { $0.relativeSeconds < $1.relativeSeconds }
    }

    func importJSONExport(around date: Date?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let packets = importWindowEntries(around: date).map(\.packet)
        let data = (try? encoder.encode(packets)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func importFullHexReport(around date: Date?) -> String {
        var lines: [String] = []
        lines.append("BFA7 Import Full HEX Report")
        lines.append("Generated: \(Date().ISO8601Format())")
        lines.append("Mark: \(date?.ISO8601Format() ?? "not marked")")
        lines.append("Note: incoming rows are BLE notifications/reads; outgoing rows are commands written by BFA7 Bridge.")
        lines.append("")
        for entry in importWindowEntries(around: date) {
            lines.append("\(entry.relativeLabel) | \(entry.packet.direction.marker) \(entry.packet.serviceUUID)/\(entry.packet.characteristicUUID) | \(entry.packet.byteCount) B | \(entry.packet.frame?.summary ?? "raw")")
            lines.append("HEX: \(entry.packet.hex)")
            lines.append("ASCII: \(entry.packet.ascii)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func importReplayCandidateReport(around date: Date?) -> String {
        let entries = importWindowEntries(around: date)
            .filter { entry in
                entry.packet.direction == .incoming
                    && entry.packet.characteristicUUID.localizedCaseInsensitiveContains("005E")
                    && entry.packet.byteCount <= 96
                    && entry.packet.looksLikeA5Frame
            }

        var lines: [String] = []
        lines.append("BFA7 Import Replay Candidate Report")
        lines.append("Generated: \(Date().ISO8601Format())")
        lines.append("Mark: \(date?.ISO8601Format() ?? "not marked")")
        lines.append("Important: candidates below are incoming packets observed from glasses, not confirmed write commands. Replay only after separate approval and preferably one-by-one.")
        lines.append("Target write characteristic if tested later: prefer FE95/005E, then FE95/005F.")
        lines.append("")

        if entries.isEmpty {
            lines.append("No <=96B A5 candidates in import window.")
        } else {
            for entry in entries {
                lines.append("\(entry.relativeLabel) | \(entry.packet.byteCount) B | \(entry.packet.frame?.summary ?? "raw")")
                lines.append(entry.packet.hex)
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    func activityReport(around date: Date?, label: String) -> String {
        let entries = timeline(around: date)
        var lines: [String] = []
        lines.append("BFA7 \(label) Activity Report")
        lines.append("Generated: \(Date().ISO8601Format())")
        lines.append("Mark: \(date?.ISO8601Format() ?? "not marked")")
        lines.append("Window: -\(String(format: "%.1f", timelineWindowBefore))s...+\(String(format: "%.1f", timelineWindowAfter))s")
        lines.append(packetStats)
        lines.append("")

        guard !entries.isEmpty else {
            lines.append("No packets in focused window.")
            return lines.joined(separator: "\n")
        }

        let byCharacteristic = Dictionary(grouping: entries) { "\($0.packet.direction.marker) \($0.packet.characteristicUUID)" }
        lines.append("By characteristic:")
        for key in byCharacteristic.keys.sorted() {
            let group = byCharacteristic[key] ?? []
            let byteCount = group.reduce(0) { $0 + $1.packet.byteCount }
            let sizes = Dictionary(grouping: group) { $0.packet.byteCount }
                .map { size, items in "\(size)B x\(items.count)" }
                .sorted()
                .joined(separator: ", ")
            let first = group.map(\.relativeSeconds).min() ?? 0
            let last = group.map(\.relativeSeconds).max() ?? 0
            let a5 = group.filter { $0.packet.looksLikeA5Frame }.count
            lines.append("- \(key): packets=\(group.count), bytes=\(byteCount), A5=\(a5), range=\(String(format: "%+.3fs", first))...\(String(format: "%+.3fs", last)), sizes=[\(sizes)]")
        }

        lines.append("")
        lines.append("Timeline:")
        for entry in entries {
            lines.append("\(entry.relativeLabel) | \(entry.packet.direction.marker) \(entry.packet.characteristicUUID) | \(entry.packet.byteCount) B | \(entry.packet.firstBytes) | \(entry.packet.frame?.summary ?? "raw")")
        }
        return lines.joined(separator: "\n")
    }

    func focusedReport(around date: Date?) -> String {
        var lines: [String] = []
        lines.append("BFA7 Protocol Lab focused report")
        lines.append("Generated: \(Date().ISO8601Format())")
        lines.append("Filter: \(characteristicFilter.isEmpty ? "all" : characteristicFilter)")
        lines.append(packetStats)
        lines.append(burstStats)
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
