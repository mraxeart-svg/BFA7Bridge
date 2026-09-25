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
        let scalars = importHexString.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
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
