import Foundation

struct ImportDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int

    var label: String {
        "\(name)  RSSI \(rssi)"
    }
}

struct MIWPairingRecord {
    let name: String
    let key: Data

    enum RecordError: LocalizedError {
        case invalid
        var errorDescription: String? {
            "Expected one O95 device record with a 16-byte detail.encrypt_key"
        }
    }

    private struct DeviceRecord: Decodable {
        let model: String
        let name: String?
        let detail: Detail?
        struct Detail: Decodable { let encrypt_key: String? }
    }

    private struct SourceList: Decodable { let list: [DeviceRecord] }
    private struct Response: Decodable { let code: Int; let data: SourceList }

    static func decode(_ data: Data) throws -> MIWPairingRecord {
        guard data.count <= 1_048_576 else { throw RecordError.invalid }
        let decoder = JSONDecoder()
        // Choose the top-level format explicitly; failed responses must not fall
        // through to a record parser and accidentally accept embedded credentials.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecordError.invalid
        }
        let records: [DeviceRecord]
        if object["code"] != nil {
            guard let response = try? decoder.decode(Response.self, from: data), response.code == 0 else {
                throw RecordError.invalid
            }
            records = response.data.list
        } else if object["list"] != nil {
            guard let list = try? decoder.decode(SourceList.self, from: data) else { throw RecordError.invalid }
            records = list.list
        } else {
            guard let record = try? decoder.decode(DeviceRecord.self, from: data) else { throw RecordError.invalid }
            records = [record]
        }
        let candidates = records.filter { $0.model == "miwear.phovideo.o95cn" }
        guard candidates.count == 1, let candidate = candidates.first,
              let hex = candidate.detail?.encrypt_key, hex.utf8.count == 32,
              let key = Data(importHexString: hex), key.count == 16 else { throw RecordError.invalid }
        return MIWPairingRecord(name: candidate.name ?? "Xiaomi AI Glasses", key: key)
    }
}

struct MIWBTCoreTokenCandidate {
    let key: Data

    enum CandidateError: LocalizedError {
        case invalid
        var errorDescription: String? {
            "Expected one unverified O95 refreshBTCoreToken candidate file"
        }
    }

    private struct Export: Decodable {
        let schema: String
        let source: String
        let validated: Bool
        let authentication_verified: Bool
        let candidates: [Candidate]
    }

    private struct Candidate: Decodable {
        let model: String
        let source: String
        let identity_source: String
        let refreshBTCoreToken: String
    }

    static func decode(_ data: Data) throws -> MIWBTCoreTokenCandidate {
        guard data.count <= 1_048_576,
              let export = try? JSONDecoder().decode(Export.self, from: data),
              export.schema == "bfa7-ios-btcore-token-candidates-v1",
              export.source == "HCWDeviceList.refreshBTCoreToken",
              !export.validated, !export.authentication_verified,
              export.candidates.count == 1, let candidate = export.candidates.first,
              candidate.model == "miwear.phovideo.o95cn" else { throw CandidateError.invalid }

        let prefix = "HCWDeviceList["
        let suffix = "].refreshBTCoreToken"
        guard candidate.source.hasPrefix(prefix), candidate.source.hasSuffix(suffix) else {
            throw CandidateError.invalid
        }
        let index = String(candidate.source.dropFirst(prefix.count).dropLast(suffix.count))
        guard !index.isEmpty, index.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(index), (0..<50_000).contains(number), String(number) == index,
              candidate.identity_source == "HCWDeviceList[\(index)].miwBTPeripheral",
              candidate.refreshBTCoreToken.utf8.count == 32,
              candidate.refreshBTCoreToken.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }),
              let key = Data(importHexString: candidate.refreshBTCoreToken), key.count == 16 else {
            throw CandidateError.invalid
        }
        return MIWBTCoreTokenCandidate(key: key)
    }
}

extension Data {
    init?(importHexString: String) {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard importHexString.unicodeScalars.allSatisfy({
            hexadecimal.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return nil }
        let scalars = importHexString.unicodeScalars.filter { scalar in
            hexadecimal.contains(scalar)
        }
        let compact = String(String.UnicodeScalarView(scalars))
        guard compact.count % 2 == 0 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var importHexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// BLE notifications are arbitrary fragments, including splits inside the magic/header.
struct MIWFrameStream {
    private var buffer: [UInt8] = []

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(contentsOf: data)
        var frames: [Data] = []
        while buffer.count >= 2 {
            guard buffer[0] == 0xA5 && buffer[1] == 0xA5 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= 8 else { break }
            let length = Int(buffer[4]) | Int(buffer[5]) << 8
            guard buffer.count >= 8 + length else { break }
            frames.append(Data(buffer.prefix(8 + length)))
            buffer.removeFirst(8 + length)
        }
        if buffer.count == 1 && buffer[0] != 0xA5 { buffer.removeAll() }
        return frames
    }
}
