import CryptoKit
import Foundation
import Security

struct MIWSessionKeys {
    let deviceKey: Data
    let appKey: Data
    let deviceIV: Data
    let appIV: Data
}

struct MIWWiFiCredentials: Equatable {
    let ssid: String
    let password: String
    let gateway: String
}

enum MIWProtocolError: LocalizedError {
    case invalidToken
    case randomGenerationFailed
    case malformedPacket(String)
    case deviceSignatureMismatch
    case deviceRejectedAuthentication

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Token must be an even-length hexadecimal value"
        case .randomGenerationFailed:
            return "Could not generate a secure random value"
        case .malformedPacket(let detail):
            return "Malformed MIWear packet: \(detail)"
        case .deviceSignatureMismatch:
            return "The glasses rejected the saved token"
        case .deviceRejectedAuthentication:
            return "The glasses did not confirm authentication"
        }
    }
}

private struct MIWProtoField {
    let number: Int
    let wireType: Int
    let integer: UInt64?
    let bytes: Data?
    let fixed32: UInt32?
}

enum MIWProtocol {
    static let l1StartPayload = Data([
        0x01,
        0x01, 0x03, 0x00, 0x01, 0x00, 0x00,
        0x02, 0x02, 0x00, 0x00, 0xFC,
        0x03, 0x02, 0x00, 0x20, 0x00,
        0x04, 0x02, 0x00, 0x10, 0x27
    ])

    static func secureRandom(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw MIWProtocolError.randomGenerationFailed
        }
        return Data(bytes)
    }

    static func deriveKeys(token: Data, appRandom: Data, deviceRandom: Data) -> MIWSessionKeys {
        var salt = Data(appRandom)
        salt.append(deviceRandom)
        let material = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: token),
            salt: salt,
            info: Data("miwear-auth".utf8),
            outputByteCount: 64
        )
        let bytes = material.withUnsafeBytes { Data($0) }
        return MIWSessionKeys(
            deviceKey: bytes.subdata(in: 0..<16),
            appKey: bytes.subdata(in: 16..<32),
            deviceIV: bytes.subdata(in: 32..<36),
            appIV: bytes.subdata(in: 36..<40)
        )
    }

    static func buildAppVerify(appRandom: Data, appDeviceID: String) -> Data {
        var verify = bytesField(1, appRandom)
        if !appDeviceID.isEmpty {
            verify.append(stringField(2, appDeviceID))
        }
        let account = messageField(30, verify)
        return wearPacket(type: 1, id: 26, payloadField: 3, payload: account)
    }

    static func parseDeviceVerify(_ packet: Data) throws -> (random: Data, signature: Data) {
        guard let account = fields(in: packet).first(where: { $0.number == 3 })?.bytes else {
            throw MIWProtocolError.malformedPacket("missing account payload")
        }
        guard let verify = fields(in: account).first(where: { $0.number == 31 })?.bytes else {
            throw MIWProtocolError.malformedPacket("missing DeviceVerify")
        }
        let values = fields(in: verify)
        guard let random = values.first(where: { $0.number == 1 })?.bytes,
              let signature = values.first(where: { $0.number == 2 })?.bytes else {
            throw MIWProtocolError.malformedPacket("incomplete DeviceVerify")
        }
        return (random, signature)
    }

    static func verifyDeviceSignature(
        _ signature: Data,
        keys: MIWSessionKeys,
        appRandom: Data,
        deviceRandom: Data
    ) -> Bool {
        var signedData = Data(deviceRandom)
        signedData.append(appRandom)
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: signedData,
            using: SymmetricKey(data: keys.deviceKey)
        ))
        return constantTimeEqual(signature, expected)
    }

    static func buildAppConfirm(
        keys: MIWSessionKeys,
        appRandom: Data,
        deviceRandom: Data,
        deviceName: String,
        systemVersion: Float,
        region: String
    ) throws -> Data {
        var signInput = Data(appRandom)
        signInput.append(deviceRandom)
        let appSign = Data(HMAC<SHA256>.authenticationCode(
            for: signInput,
            using: SymmetricKey(data: keys.appKey)
        ))

        var companion = varintField(1, 1)
        companion.append(fixed32Field(2, systemVersion.bitPattern))
        if !deviceName.isEmpty { companion.append(stringField(3, deviceName)) }
        if !region.isEmpty { companion.append(stringField(5, region)) }

        let nonce = keys.appIV + Data(repeating: 0, count: 8)
        let encryptedCompanion = try MIWBTAESCCM.seal(
            companion,
            key: keys.appKey,
            nonce: nonce,
            tagLength: 4
        )
        var confirm = bytesField(1, appSign)
        confirm.append(bytesField(2, encryptedCompanion))
        let account = messageField(32, confirm)
        return wearPacket(type: 1, id: 27, payloadField: 3, payload: account)
    }

    static func parseDeviceConfirm(_ packet: Data) throws -> Bool {
        guard let account = fields(in: packet).first(where: { $0.number == 3 })?.bytes,
              let confirm = fields(in: account).first(where: { $0.number == 33 })?.bytes,
              let result = fields(in: confirm).first(where: { $0.number == 1 })?.integer else {
            throw MIWProtocolError.malformedPacket("missing DeviceConfirm")
        }
        return result != 0
    }

    static func iOSImportReadyPacket() -> Data {
        // Exact plaintext emitted immediately before wifiApRequest by Xiaomi Glasses 3.3.0.
        Data([0x08, 0x0D, 0x10, 0x06])
    }

    static func iOSWiFiAPRequest(frequency: UInt8 = 1) -> Data {
        // Exact MIWearPB schema shipped in Xiaomi Glasses 3.3.0 for iOS.
        var packet = Data([
            0x08, 0x0E, 0x10, 0x05, 0x82, 0x01, 0x0E, 0x2A, 0x0C, 0x08, 0x00,
            0x10, 0x00, 0x18, 0x00, 0x20, 0x00, 0x28, 0x00, 0x30, 0x00
        ])
        packet[packet.count - 1] = frequency
        return packet
    }

    static func sealSessionPacket(_ packet: Data, keys: MIWSessionKeys) throws -> Data {
        // MIWFlowEncrypt initializes CryptoSwift CTR with appKey as both the AES key
        // and the 16-byte initial counter block. The separate appIV is unused here.
        try MIWBTAESCTR.encrypt(packet, key: keys.appKey, initialCounter: keys.appKey)
    }

    static func openSessionPacket(_ payload: Data, keys: MIWSessionKeys) throws -> Data {
        guard !payload.isEmpty else {
            throw MIWProtocolError.malformedPacket("encrypted session payload is empty")
        }
        // Incoming packets use the matching device key as key and initial counter.
        return try MIWBTAESCTR.encrypt(payload, key: keys.deviceKey, initialCounter: keys.deviceKey)
    }

    static func parseWiFiCredentials(_ packet: Data) -> MIWWiFiCredentials? {
        // Current Android protobuf: WearPacket.system(4) -> wifiApResult(56)
        // -> Result.wifiAp(2) -> ssid/password/gateway(1/2/3).
        if let system = fieldBytes(4, in: packet),
           let result = fieldBytes(56, in: system),
           let wifi = fieldBytes(2, in: result),
           let ssid = fieldString(1, in: wifi), !ssid.isEmpty {
            return MIWWiFiCredentials(
                ssid: ssid,
                password: fieldString(2, in: wifi) ?? "",
                gateway: fieldString(3, in: wifi) ?? "192.168.43.1"
            )
        }

        var strings: [String] = []
        collectStrings(in: packet, depth: 0, output: &strings)
        let ssid = strings.first(where: {
            let value = $0.lowercased()
            return value.contains("xiaomi") || value.contains("glass") || value.contains("bfa7")
        })
        guard let ssid else { return nil }
        let gateway = strings.first(where: isIPv4) ?? "192.168.43.1"
        let password = strings.first(where: {
            $0 != ssid && $0 != gateway && $0.count >= 8 && $0.count <= 64
        }) ?? ""
        return MIWWiFiCredentials(ssid: ssid, password: password, gateway: gateway)
    }

    static func packetSummary(_ packet: Data) -> String {
        let parsed = fields(in: packet)
        let type = parsed.first(where: { $0.number == 1 })?.integer.map(String.init) ?? "?"
        let id = parsed.first(where: { $0.number == 2 })?.integer.map(String.init) ?? "?"
        return "WearPacket type=\(type) id=\(id) len=\(packet.count)"
    }

    private static func wearPacket(type: UInt64, id: UInt64, payloadField: Int, payload: Data) -> Data {
        var packet = varintField(1, type)
        packet.append(varintField(2, id))
        packet.append(messageField(payloadField, payload))
        return packet
    }

    private static func varintField(_ number: Int, _ value: UInt64) -> Data {
        var output = encodeVarint(UInt64((number << 3) | 0))
        output.append(encodeVarint(value))
        return output
    }

    private static func fixed32Field(_ number: Int, _ value: UInt32) -> Data {
        var output = encodeVarint(UInt64((number << 3) | 5))
        output.append(UInt8(value & 0xFF))
        output.append(UInt8((value >> 8) & 0xFF))
        output.append(UInt8((value >> 16) & 0xFF))
        output.append(UInt8((value >> 24) & 0xFF))
        return output
    }

    private static func bytesField(_ number: Int, _ bytes: Data) -> Data {
        var output = encodeVarint(UInt64((number << 3) | 2))
        output.append(encodeVarint(UInt64(bytes.count)))
        output.append(bytes)
        return output
    }

    private static func stringField(_ number: Int, _ value: String) -> Data {
        bytesField(number, Data(value.utf8))
    }

    private static func messageField(_ number: Int, _ message: Data) -> Data {
        bytesField(number, message)
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        var value = value
        var output = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            output.append(byte)
        } while value != 0
        return output
    }

    private static func fields(in data: Data) -> [MIWProtoField] {
        var offset = 0
        var output: [MIWProtoField] = []
        while offset < data.count, let key = readVarint(data, offset: &offset) {
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            guard number > 0 else { return output }
            switch wire {
            case 0:
                guard let value = readVarint(data, offset: &offset) else { return output }
                output.append(MIWProtoField(number: number, wireType: wire, integer: value, bytes: nil, fixed32: nil))
            case 1:
                guard offset + 8 <= data.count else { return output }
                offset += 8
            case 2:
                guard let length = readVarint(data, offset: &offset),
                      length <= UInt64(Int.max),
                      offset + Int(length) <= data.count else { return output }
                let bytes = data.subdata(in: offset..<(offset + Int(length)))
                offset += Int(length)
                output.append(MIWProtoField(number: number, wireType: wire, integer: nil, bytes: bytes, fixed32: nil))
            case 5:
                guard offset + 4 <= data.count else { return output }
                let value = UInt32(data[offset])
                    | (UInt32(data[offset + 1]) << 8)
                    | (UInt32(data[offset + 2]) << 16)
                    | (UInt32(data[offset + 3]) << 24)
                offset += 4
                output.append(MIWProtoField(number: number, wireType: wire, integer: nil, bytes: nil, fixed32: value))
            default:
                return output
            }
        }
        return output
    }

    private static func readVarint(_ data: Data, offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift < 64 {
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func fieldBytes(_ number: Int, in data: Data) -> Data? {
        fields(in: data).first(where: { $0.number == number && $0.wireType == 2 })?.bytes
    }

    private static func fieldString(_ number: Int, in data: Data) -> String? {
        guard let bytes = fieldBytes(number, in: data) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private static func collectStrings(in data: Data, depth: Int, output: inout [String]) {
        guard depth < 7 else { return }
        for field in fields(in: data) where field.wireType == 2 {
            guard let bytes = field.bytes, !bytes.isEmpty else { continue }
            if let value = String(data: bytes, encoding: .utf8), isPrintable(value) {
                if !output.contains(value) { output.append(value) }
            } else {
                collectStrings(in: bytes, depth: depth + 1, output: &output)
            }
        }
    }

    private static func isPrintable(_ value: String) -> Bool {
        guard (1...96).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0...255).contains(number)
        }
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<left.count { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

enum MIWTokenVault {
    private static let service = "com.mraxeart.BFA7ImportTool15"
    private static let account = "miwear-pairing-token"

    static func save(_ token: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = token
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
