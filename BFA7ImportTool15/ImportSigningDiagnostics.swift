import Foundation
import CoreFoundation

enum ImportHotspotCapability: String {
    case present, missing, unknown
}

enum ImportSigningDiagnostics {
    static let hotspotKey = "com.apple.developer.networking.HotspotConfiguration"

    static func current() -> ImportHotspotCapability {
        guard let url = Bundle.main.executableURL,
              let binary = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .unknown }
        return inspect(binary)
    }

    // Read only the current executable's bounded Mach-O signature and its plist.
    // This reports declared signed entitlements, not kernel validation or profile approval.
    static func inspect(_ binary: Data) -> ImportHotspotCapability {
        guard binary.count >= 32, binary.count <= 67_108_864,
              word(binary, 0, bigEndian: false) == 0xfeedfacf,
              let count = word(binary, 16, bigEndian: false), count <= 4096,
              let commandBytes = word(binary, 20, bigEndian: false),
              Int(commandBytes) <= binary.count - 32 else { return .unknown }
        let end = 32 + Int(commandBytes)
        var offset = 32
        for _ in 0..<count {
            guard offset <= end - 8,
                  let command = word(binary, offset, bigEndian: false),
                  let size = word(binary, offset + 4, bigEndian: false),
                  size >= 8, Int(size) <= end - offset else { return .unknown }
            if command == 0x1d { // LC_CODE_SIGNATURE / linkedit_data_command
                guard size >= 16,
                      let start = word(binary, offset + 8, bigEndian: false),
                      let length = word(binary, offset + 12, bigEndian: false),
                      length <= 1_048_576, Int(start) <= binary.count,
                      Int(length) <= binary.count - Int(start) else { return .unknown }
                return inspectSignature(Data(binary[Int(start)..<(Int(start) + Int(length))]))
            }
            offset += Int(size)
        }
        return .missing
    }

    static func inspectSignature(_ raw: Data) -> ImportHotspotCapability {
        guard raw.count >= 12, raw.count <= 1_048_576,
              word(raw, 0, bigEndian: true) == 0xfade0cc0,
              let length = word(raw, 4, bigEndian: true), length >= 12, Int(length) <= raw.count else { return .unknown }
        let data = Data(raw.prefix(Int(length)))
        guard
              let count = word(data, 8, bigEndian: true), count <= 128,
              12 + Int(count) * 8 <= data.count else { return .unknown }
        var xml: Data?
        var hasDER = false
        for index in 0..<Int(count) {
            let slot = 12 + index * 8
            guard let type = word(data, slot, bigEndian: true),
                  let position = word(data, slot + 4, bigEndian: true),
                  Int(position) >= 12 + Int(count) * 8, Int(position) <= data.count - 8,
                  let blobSize = word(data, Int(position) + 4, bigEndian: true),
                  blobSize >= 8, Int(blobSize) <= data.count - Int(position) else { return .unknown }
            if type == 7 { hasDER = true }
            if type == 5 {
                guard xml == nil, word(data, Int(position), bigEndian: true) == 0xfade7171 else { return .unknown }
                xml = Data(data[(Int(position) + 8)..<(Int(position) + Int(blobSize))])
            }
        }
        guard let xml else { return hasDER ? .unknown : .missing }
        guard let object = try? PropertyListSerialization.propertyList(from: xml, format: nil),
              let dictionary = object as? [String: Any] else { return .unknown }
        guard let value = dictionary[hotspotKey] else { return .missing }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else { return .unknown }
        return flag ? .present : .missing
    }

    private static func word(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let bytes = [UInt32(data[offset]), UInt32(data[offset + 1]), UInt32(data[offset + 2]), UInt32(data[offset + 3])]
        return bigEndian ? bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]
            : bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
    }
}
