import Foundation
import CryptoKit

enum BFA7SVProtocolError: LocalizedError {
    case invalidTokenKey
    case invalidLength(String)
    case cryptoFailed
    case invalidStartChannelResponse
    case deviceSignatureMismatch

    var errorDescription: String? {
        switch self {
        case .invalidTokenKey:
            return "Token key must be Xiaomi base64 data or hex bytes."
        case .invalidLength(let value):
            return "\(value) is too long for the one-byte Xiaomi SV length field."
        case .cryptoFailed:
            return "CryptoKit could not create the AES-GCM packet."
        case .invalidStartChannelResponse:
            return "StartChannel response must contain len(deviceRandom), deviceRandom, len(deviceSignature), deviceSignature."
        case .deviceSignatureMismatch:
            return "StartChannel device signature does not match HMAC-SHA256(sessionKey, random + deviceRandom)."
        }
    }
}

struct BFA7SVCommandBuild: Hashable {
    let title: String
    let hex: String
    let notes: [String]
}

struct BFA7SVWifiAPData: Hashable {
    let code: Int
    let ssid: String
    let passphrase: String
    let ip: String
}

struct BFA7SVStartChannelResponse: Hashable {
    let payloadOffset: Int
    let deviceRandom: Data
    let deviceSignature: Data
}

enum BFA7SVProtocol {
    static let defaultTarget = "AD3072F9-DCCB-4A10-989F-CA7EE37AB757/00001802-0000-1000-8000-00805F9B34FB"

    private static let hkdfSalt = Data([0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B])
    private static let hkdfInfo = Data("superhexa-bind".utf8)

    static func startChannel(random: String, seq: UInt8) throws -> BFA7SVCommandBuild {
        let randomBytes = Data(random.utf8)
        let content = try lengthPrefixed(randomBytes, label: "StartChannel random")
        let command = Data([seq, 0x05]) + content
        return BFA7SVCommandBuild(
            title: "StartChannel",
            hex: command.bfa7HexString,
            notes: [
                "APK: SendStartChannel via SVBaseCommandStrategy.getData(seq).",
                "Wire format: seq + commandType(0x05) + len(random) + UTF-8 random.",
                "Xiaomi reconnect uses a 10-char random string."
            ]
        )
    }

    static func sessionKey(tokenKeyText: String) throws -> Data {
        guard let tokenKey = tokenKeyData(from: tokenKeyText), !tokenKey.isEmpty else {
            throw BFA7SVProtocolError.invalidTokenKey
        }
        let inputKey = SymmetricKey(data: tokenKey)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: hkdfSalt,
            info: hkdfInfo,
            outputByteCount: 16
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func channelVerifyPayload(sessionKey: Data, startChannelResponse: Data, random: String, seq: UInt8) throws -> BFA7SVCommandBuild {
        let parsed = try parseStartChannelResponse(startChannelResponse)
        let signInput = Data(random.utf8) + parsed.deviceRandom
        let expectedSignature = HMAC<SHA256>.authenticationCode(for: signInput, using: SymmetricKey(data: sessionKey))
        guard Data(expectedSignature) == parsed.deviceSignature else {
            throw BFA7SVProtocolError.deviceSignatureMismatch
        }
        let encrypted = try aesGCMSeal(Data("device_info_data".utf8), keyData: sessionKey)
        let command = Data([seq, 0x06]) + (try lengthPrefixed(encrypted, label: "ChannelVerify encrypted data"))
        return BFA7SVCommandBuild(
            title: "ChannelVerify",
            hex: command.bfa7HexString,
            notes: [
                "APK: SendChannelVerify via SVBaseCommandStrategy.getData(seq).",
                "Parsed StartChannel response at payload offset \(parsed.payloadOffset).",
                "Device random: \(parsed.deviceRandom.bfa7HexString)",
                "Verified device signature: \(parsed.deviceSignature.bfa7HexString)",
                "Wire format: seq + commandType(0x06) + len(AES-GCM('device_info_data')) + encrypted bytes."
            ]
        )
    }

    static func parseStartChannelResponse(_ data: Data) throws -> BFA7SVStartChannelResponse {
        let bytes = Array(data)
        guard bytes.count >= 2 else { throw BFA7SVProtocolError.invalidStartChannelResponse }

        var candidateOffsets = Array(0...min(4, bytes.count - 1))
        if bytes.count > 8, bytes[0] == 0xA5, bytes[1] == 0xA5 {
            candidateOffsets.append(8)
        }
        for offset in candidateOffsets {
            guard let parsed = parseStartChannelResponse(bytes: bytes, offset: offset) else { continue }
            return parsed
        }
        throw BFA7SVProtocolError.invalidStartChannelResponse
    }

    static func encryptedCreateWifiAP(tokenKeyText: String, seq: UInt8, wifiType: UInt8) throws -> BFA7SVCommandBuild {
        let key = try sessionKey(tokenKeyText: tokenKeyText)
        return try encryptedCreateWifiAP(sessionKey: key, seq: seq, wifiType: wifiType)
    }

    static func encryptedCreateWifiAP(sessionKey: Data, seq: UInt8, wifiType: UInt8) throws -> BFA7SVCommandBuild {
        let inner = Data([0x00, 0x02, 0x01, wifiType, 0x01])
        let encrypted = try aesGCMSeal(inner, keyData: sessionKey)
        let command = Data([seq, 0x11]) + (try lengthPrefixed(encrypted, label: "BizData encrypted data"))
        return BFA7SVCommandBuild(
            title: "BizData(CreateWifiAP)",
            hex: command.bfa7HexString,
            notes: [
                "APK chain: SendCreateWifiAP -> SendBizData.",
                "Inner encrypted plaintext: 00 02 + 01 wifiType 01 = \(inner.bfa7HexString)",
                "Wire format: seq + commandType(0x11) + len(AES-GCM(inner)) + IV+ciphertext+tag.",
                "Session key: \(sessionKey.bfa7HexString)"
            ]
        )
    }

    static func parseWifiAPData(fromDecryptedBizResponse data: Data) -> BFA7SVWifiAPData? {
        let bytes = Array(data)
        let payload: ArraySlice<UInt8>
        if bytes.count >= 2, bytes[0] == 0x00, bytes[1] == 0x02 {
            payload = bytes.dropFirst(2)
        } else {
            payload = ArraySlice(bytes)
        }
        guard !payload.isEmpty else { return nil }

        var index = payload.startIndex
        let code = Int(Int8(bitPattern: payload[index]))
        index = payload.index(after: index)

        guard let ssid = readLengthString(payload, index: &index),
              let passphrase = readLengthString(payload, index: &index),
              let ipBytes = readLengthBytes(payload, index: &index),
              ipBytes.count == 4 else {
            return nil
        }

        let ip = ipBytes.map(String.init).joined(separator: ".")
        return BFA7SVWifiAPData(code: code, ssid: ssid, passphrase: passphrase, ip: ip)
    }

    static func tokenKeyData(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let base64 = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) {
            return base64
        }
        return Data(bfa7HexString: trimmed)
    }

    private static func aesGCMSeal(_ plaintext: Data, keyData: Data) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
            guard let combined = sealed.combined else { throw BFA7SVProtocolError.cryptoFailed }
            return combined
        } catch {
            throw BFA7SVProtocolError.cryptoFailed
        }
    }

    private static func lengthPrefixed(_ data: Data, label: String) throws -> Data {
        guard data.count <= 255 else { throw BFA7SVProtocolError.invalidLength(label) }
        return Data([UInt8(data.count)]) + data
    }

    private static func parseStartChannelResponse(bytes: [UInt8], offset: Int) -> BFA7SVStartChannelResponse? {
        guard offset < bytes.count else { return nil }
        let randomLength = Int(bytes[offset])
        let randomStart = offset + 1
        let randomEnd = randomStart + randomLength
        guard randomLength > 0, randomEnd < bytes.count else { return nil }

        let signatureLength = Int(bytes[randomEnd])
        let signatureStart = randomEnd + 1
        let signatureEnd = signatureStart + signatureLength
        guard signatureLength > 0, signatureEnd == bytes.count else { return nil }

        return BFA7SVStartChannelResponse(
            payloadOffset: offset,
            deviceRandom: Data(bytes[randomStart..<randomEnd]),
            deviceSignature: Data(bytes[signatureStart..<signatureEnd])
        )
    }

    private static func readLengthString(_ payload: ArraySlice<UInt8>, index: inout ArraySlice<UInt8>.Index) -> String? {
        guard let data = readLengthBytes(payload, index: &index) else { return nil }
        return String(data: Data(data), encoding: .utf8)
    }

    private static func readLengthBytes(_ payload: ArraySlice<UInt8>, index: inout ArraySlice<UInt8>.Index) -> [UInt8]? {
        guard index < payload.endIndex else { return nil }
        let count = Int(payload[index])
        index = payload.index(after: index)
        guard payload.distance(from: index, to: payload.endIndex) >= count else { return nil }
        let end = payload.index(index, offsetBy: count)
        let result = Array(payload[index..<end])
        index = end
        return result
    }
}

extension Data {
    init?(bfa7HexString: String) {
        let cleaned = bfa7HexString
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")

        let tokens: [Substring]
        if cleaned.count == 1, let only = cleaned.first, only.count > 2 {
            let value = String(only)
            guard value.count.isMultiple(of: 2) else { return nil }
            tokens = stride(from: 0, to: value.count, by: 2).map { offset in
                let start = value.index(value.startIndex, offsetBy: offset)
                let end = value.index(start, offsetBy: 2)
                return Substring(value[start..<end])
            }
        } else {
            tokens = cleaned
        }

        guard !tokens.isEmpty else { return nil }
        var bytes: [UInt8] = []
        for token in tokens {
            guard let byte = UInt8(token, radix: 16) else { return nil }
            bytes.append(byte)
        }
        self = Data(bytes)
    }
}
