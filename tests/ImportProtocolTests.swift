import Foundation

@main
enum ImportProtocolTests {
    static func hex(_ value: String) -> Data { Data(importHexString: value)! }
    static func field(_ tag: UInt8, _ bytes: Data) -> Data {
        precondition(bytes.count < 128)
        return Data([tag, UInt8(bytes.count)]) + bytes
    }

    static func main() throws {
        let record = """
        {"model":"miwear.phovideo.o95cn","name":"Test glasses","detail":{
        "encrypt_key":"000102030405060708090a0b0c0d0e0f","token":"ffffffffffffffffffffffffffffffff"}}
        """
        let selected = try MIWPairingRecord.decode(Data(record.utf8))
        precondition(selected.key == Data(0..<16))
        let wrapped = "{\"code\":0,\"data\":{\"list\":[\(record)]}}"
        let cloudKey = try MIWPairingRecord.decode(Data(wrapped.utf8)).key
        precondition(cloudKey == Data(0..<16))
        for invalid in [
            record.replacingOccurrences(of: "encrypt_key", with: "sessionKey"),
            record.replacingOccurrences(of: "o95cn", with: "band"),
            record.replacingOccurrences(of: "000102030405060708090a0b0c0d0e0f", with: "bad-key"),
            wrapped.replacingOccurrences(of: "\"code\":0", with: "\"code\":1"),
            "{\"list\":[\(record),\(record)]}", "null", "[]"
        ] {
            do {
                _ = try MIWPairingRecord.decode(Data(invalid.utf8))
                fatalError("Invalid or ambiguous device record accepted")
            } catch MIWPairingRecord.RecordError.invalid {}
        }
        let btcoreEntry = """
        {"model":"miwear.phovideo.o95cn","source":"HCWDeviceList[0].refreshBTCoreToken",
        "identity_source":"HCWDeviceList[0].miwBTPeripheral",
        "refreshBTCoreToken":"000102030405060708090a0b0c0d0e0f"}
        """
        let btcoreExport = """
        {"schema":"bfa7-ios-btcore-token-candidates-v1","validated":false,
        "authentication_verified":false,"source":"HCWDeviceList.refreshBTCoreToken",
        "candidates":[\(btcoreEntry)]}
        """
        let btcore = try MIWBTCoreTokenCandidate.decode(Data(btcoreExport.utf8))
        precondition(btcore.key == Data(0..<16))
        do {
            _ = try MIWPairingRecord.decode(Data(btcoreExport.utf8))
            fatalError("BTCore candidate accepted as legacy encrypt_key record")
        } catch MIWPairingRecord.RecordError.invalid {}
        for invalid in [
            record, btcoreEntry, "[]", "null",
            btcoreExport.replacingOccurrences(of: "\"validated\":false", with: "\"validated\":true"),
            btcoreExport.replacingOccurrences(of: "\"authentication_verified\":false", with: "\"authentication_verified\":true"),
            btcoreExport.replacingOccurrences(of: "bfa7-ios-btcore-token-candidates-v1", with: "unknown"),
            btcoreExport.replacingOccurrences(of: "o95cn", with: "band"),
            btcoreExport.replacingOccurrences(of: "[0].miwBTPeripheral", with: "[1].miwBTPeripheral"),
            btcoreExport.replacingOccurrences(of: "HCWDeviceList[0]", with: "HCWDeviceList[00]"),
            btcoreExport.replacingOccurrences(of: "HCWDeviceList[0]", with: "HCWDeviceList[-1]"),
            btcoreExport.replacingOccurrences(of: "refreshBTCoreToken\":", with: "tokenKey\":"),
            btcoreExport.replacingOccurrences(of: "000102030405060708090a0b0c0d0e0f", with: "000102030405060708090a0b0c0d0e0g"),
            btcoreExport.replacingOccurrences(of: "000102030405060708090a0b0c0d0e0f", with: "00 0102030405060708090a0b0c0d0e0f"),
            btcoreExport.replacingOccurrences(of: "[\(btcoreEntry)]", with: "[]"),
            btcoreExport.replacingOccurrences(of: "[\(btcoreEntry)]", with: "[\(btcoreEntry),\(btcoreEntry)]")
        ] {
            do {
                _ = try MIWBTCoreTokenCandidate.decode(Data(invalid.utf8))
                fatalError("Invalid or ambiguous BTCore token candidate accepted")
            } catch MIWBTCoreTokenCandidate.CandidateError.invalid {}
        }
        do {
            _ = try MIWBTCoreTokenCandidate.decode(Data(repeating: 32, count: 1_048_577))
            fatalError("Oversized BTCore export accepted")
        } catch MIWBTCoreTokenCandidate.CandidateError.invalid {}
        precondition(MIWProtocol.iOSWiFiAPRequest() == hex("08 02 10 58"))
        precondition(MIWProtocol.buildAppVerify(appRandom: Data(0..<16)) ==
                     hex("08 01 10 1A 1A 15 F2 01 12 0A 10") + Data(0..<16))
        do {
            _ = try MIWProtocol.parseDeviceVerify(hex("08 01 10 1A 1A 02 18 04"))
            fatalError("Unbound device accepted")
        } catch MIWProtocolError.accountError(let code) { precondition(code == 4) }
        precondition(Data(importHexString: "token=ab12") == nil)
        precondition(Data(importHexString: "AB 12\nCD") == hex("AB12CD"))

        // Same protobuf structure/lengths as the capture; no real credentials.
        let wifi = field(0x0a, Data("Xiaomi AI Glasses TEST1".utf8))
            + field(0x12, Data("testPASS1234".utf8))
            + field(0x1a, Data("192.168.43.1".utf8))
        let result = hex("08 00") + field(0x12, wifi)
        let system = hex("C2 03") + Data([UInt8(result.count)]) + result
        let packet = hex("08 02 10 58") + field(0x22, system)
        let credentials = MIWProtocol.parseWiFiCredentials(packet)
        precondition(credentials?.ssid == "Xiaomi AI Glasses TEST1")
        precondition(credentials?.password == "testPASS1234")
        precondition(credentials?.gateway == "192.168.43.1")
        let rotatedWiFi = field(0x0a, Data("Xiaomi AI Glasses TEST1".utf8))
            + field(0x12, Data("differentPASS5678".utf8))
            + field(0x1a, Data("192.168.43.1".utf8))
        let rotatedResult = hex("08 00") + field(0x12, rotatedWiFi)
        let rotatedSystem = hex("C2 03") + Data([UInt8(rotatedResult.count)]) + rotatedResult
        let rotatedPacket = hex("08 02 10 58") + field(0x22, rotatedSystem)
        precondition(MIWProtocol.parseWiFiCredentials(rotatedPacket)?.password == "differentPASS5678")
        precondition(MIWProtocol.parseWiFiCredentials(rotatedPacket)?.password != credentials?.password)
        var wrongID = packet
        wrongID[3] = 89
        precondition(MIWProtocol.parseWiFiCredentials(wrongID) == nil)
        for size in 0..<packet.count {
            precondition(MIWProtocol.parseWiFiCredentials(Data(packet.prefix(size))) == nil)
        }
        precondition(MIWProtocol.parseWiFiCredentials(packet + hex("00")) == nil)
        precondition(MIWProtocol.parseWiFiCredentials(packet + hex("80")) == nil)
        precondition(MIWProtocol.parseWiFiCredentials(packet + hex("F2 01 FF FF FF FF FF FF FF FF FF 7F")) == nil)
        precondition(MIWProtocol.parseWiFiCredentials(Data("Xiaomi AI Glasses TEST1 password".utf8)) == nil)

        let ack = hex("A5 A5 01 10 00 00 00 00")
        let frame = hex("A5 A5 03 11 06 00 00 00 01 02 11 22 33 44")
        for split in 0...frame.count {
            var stream = MIWFrameStream()
            let output = stream.append(Data(frame.prefix(split))) + stream.append(Data(frame.dropFirst(split)))
            precondition(output == [frame])
        }
        var stream = MIWFrameStream()
        precondition(stream.append(hex("00 44 A5")).isEmpty)
        precondition(stream.append(Data(ack.dropFirst()) + frame + ack) == [ack, frame, ack])
        var byteStream = MIWFrameStream()
        var received: [Data] = []
        for byte in frame + ack { received += byteStream.append(Data([byte])) }
        precondition(received == [frame, ack])

        // NIST SP 800-38A CTR vector, spanning a counter increment.
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let counter = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = hex("6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51")
        let expected = hex("874d6191b620e3261bef6864990db6ce 9806f66b7970fdff8617187bb9fffdff")
        let encrypted = try MIWBTAESCTR.encrypt(plain, key: key, initialCounter: counter)
        precondition(encrypted == expected)

        // Independent synthetic reference from Python cryptography HKDF/HMAC/AESCCM.
        // This checks the primitive implementation, NOT device auth compatibility.
        let keys = MIWProtocol.deriveKeys(token: Data(0..<16), appRandom: Data(16..<32), deviceRandom: Data(32..<48))
        precondition(keys.deviceKey == hex("d738074e6570abb50d001db70f497a37"))
        precondition(keys.appKey == hex("923e295e02aecb7619a8e1b9f574c988"))
        precondition(keys.deviceIV == hex("8676d225"))
        precondition(keys.appIV == hex("23869a15"))
        let signature = hex("17aa8eecac21d9d71cba6ea653d126d77abc2f4d0357f1cce01d433d40e42235")
        precondition(MIWProtocol.verifyDeviceSignature(signature, keys: keys, appRandom: Data(16..<32), deviceRandom: Data(32..<48)))
        precondition(!MIWProtocol.verifyDeviceSignature(Data(repeating: 0, count: 32), keys: keys, appRandom: Data(16..<32), deviceRandom: Data(32..<48)))
        let confirm = try MIWProtocol.buildAppConfirm(keys: keys, appRandom: Data(16..<32), deviceRandom: Data(32..<48), deviceName: "Test", systemVersion: 15.5, region: "RU")
        let appSign = hex("7e6e4d786282c1af4441b2ed315da93c8ae2c820a72df584d62315d73913a9dc")
        let companion = hex("806cad1c23f707c0417e2b53fb07a6c4e577f21dc9")
        let auth = field(0x0a, appSign) + field(0x12, companion)
        let account = hex("82 02") + Data([UInt8(auth.count)]) + auth
        precondition(confirm == hex("08 01 10 1b") + field(0x1a, account))
        print("Import protocol: command, credentials, malformed packets, framing, CTR, HKDF, HMAC and CCM passed")
    }
}
