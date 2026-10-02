import Foundation

@main
enum ImportProtocolTests {
    static func hex(_ value: String) -> Data { Data(importHexString: value)! }
    static func field(_ tag: UInt8, _ bytes: Data) -> Data {
        precondition(bytes.count < 128)
        return Data([tag, UInt8(bytes.count)]) + bytes
    }

    static func main() throws {
        precondition(MIWProtocol.iOSWiFiAPRequest() == hex("08 02 10 58"))
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
        print("Import protocol: command, credentials, malformed packets, framing and CTR passed")
    }
}
