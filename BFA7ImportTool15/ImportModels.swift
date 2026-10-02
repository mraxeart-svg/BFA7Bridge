import Foundation

struct ImportDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int

    var label: String {
        "\(name)  RSSI \(rssi)"
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
