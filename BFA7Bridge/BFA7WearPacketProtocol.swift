import Foundation

struct BFA7WearPacketBuild: Hashable {
    let title: String
    let hex: String
    let packet: Data
    let notes: [String]
}

enum BFA7WearPacketProtocol {
    static let defaultTarget = "FE95/005F"

    static func wifiApRequestCandidate(
        packetSystemField: UInt32,
        systemWifiApRequestField: UInt32,
        requestFrequencyField: UInt32,
        frequency: UInt64,
        packetType: UInt64?,
        packetID: UInt64?
    ) -> BFA7WearPacketBuild {
        let request = varintField(requestFrequencyField, frequency)
        let system = lengthDelimitedField(systemWifiApRequestField, request)

        var packet = Data()
        if let packetType = packetType {
            packet.append(varintField(1, packetType))
        }
        if let packetID = packetID {
            packet.append(varintField(2, packetID))
        }
        packet.append(lengthDelimitedField(packetSystemField, system))

        var notes = [
            "iOS IPA symbols: MIWearPB.WearSystem.wifiApRequest, MIWearPB.WearWiFiAP.Request.frequency.",
            "iOS IPA symbols: MIWBTCore.MIWBTReq(timeOut:channel:package:) accepts MIWearPB.WearPacket.",
            "Hypothesis: WearPacket.system field=\(packetSystemField), WearSystem.wifiApRequest field=\(systemWifiApRequestField), Request.frequency field=\(requestFrequencyField).",
            "Target default is FE95/005F because observed incoming notifications arrive on FE95/005E while FE95/005F is writable+notify."
        ]
        if let packetType = packetType {
            notes.append("WearPacket.type field 1 = \(packetType).")
        } else {
            notes.append("WearPacket.type omitted.")
        }
        if let packetID = packetID {
            notes.append("WearPacket.id field 2 = \(packetID).")
        } else {
            notes.append("WearPacket.id omitted.")
        }

        return BFA7WearPacketBuild(
            title: "WearPacket(WearSystem.wifiApRequest)",
            hex: packet.bfa7HexString,
            packet: packet,
            notes: notes
        )
    }

    static func wifiApRequestRawPacket(
        packetSystemField: UInt32,
        systemWifiApRequestField: UInt32,
        requestFrequencyField: UInt32,
        frequency: UInt64,
        packetType: UInt64?,
        packetID: UInt64?
    ) -> Data {
        let request = varintField(requestFrequencyField, frequency)
        let system = lengthDelimitedField(systemWifiApRequestField, request)

        var packet = Data()
        if let packetType = packetType {
            packet.append(varintField(1, packetType))
        }
        if let packetID = packetID {
            packet.append(varintField(2, packetID))
        }
        packet.append(lengthDelimitedField(packetSystemField, system))
        return packet
    }

    static func miwChannelCandidate(
        packetSystemField: UInt32,
        systemWifiApRequestField: UInt32,
        requestFrequencyField: UInt32,
        frequency: UInt64,
        packetType: UInt64?,
        packetID: UInt64?,
        channel: UInt8,
        opCode: UInt8,
        ident: UInt8,
        sequence: UInt8,
        includeLength: Bool,
        includeIdent: Bool,
        includeA5Frame: Bool
    ) -> BFA7WearPacketBuild {
        let packet = wifiApRequestRawPacket(
            packetSystemField: packetSystemField,
            systemWifiApRequestField: systemWifiApRequestField,
            requestFrequencyField: requestFrequencyField,
            frequency: frequency,
            packetType: packetType,
            packetID: packetID
        )

        var channelPayload = Data([channel, opCode])
        if includeIdent {
            channelPayload.append(ident)
        }
        if includeLength {
            channelPayload.append(UInt8(packet.count & 0xff))
            channelPayload.append(UInt8((packet.count >> 8) & 0xff))
        }
        channelPayload.append(packet)

        let command = includeA5Frame ? a5PayloadFrame(payload: channelPayload, sequence: sequence) : channelPayload
        var notes = [
            "iOS IPA confirms MIWBTCore.MIWBTChannel(channel:opType:), MIWChannelPayload(channel, opCode, payload, ident), payloadData(), and transmissionData(data:).",
            "This build wraps the same WearPacket into a MIW channel candidate instead of writing raw protobuf only.",
            "Channel/op/ident are still hypotheses because FairPlay encryption hides the exact callsite.",
            "channel=0x\(hexByte(channel)), op=0x\(hexByte(opCode)), ident=0x\(hexByte(ident)), seq=0x\(hexByte(sequence)).",
            includeLength ? "Channel payload includes little-endian protobuf length before packet." : "Channel payload omits explicit protobuf length.",
            includeIdent ? "Channel payload includes ident byte." : "Channel payload omits ident byte.",
            includeA5Frame ? "Command is wrapped as A5 A5 03 seq len crc16(payload) payload." : "Command is channel payload only, without A5 transport wrapper."
        ]
        if let packetType = packetType {
            notes.append("WearPacket.type field 1 = \(packetType).")
        } else {
            notes.append("WearPacket.type omitted.")
        }
        if let packetID = packetID {
            notes.append("WearPacket.id field 2 = \(packetID).")
        } else {
            notes.append("WearPacket.id omitted.")
        }

        return BFA7WearPacketBuild(
            title: includeA5Frame ? "A5(MIWChannel(WearPacket.wifiApRequest))" : "MIWChannel(WearPacket.wifiApRequest)",
            hex: command.bfa7HexString,
            packet: command,
            notes: notes
        )
    }

    private static func varintField(_ number: UInt32, _ value: UInt64) -> Data {
        var result = fieldKey(number, wireType: 0)
        result.append(varint(value))
        return result
    }

    private static func lengthDelimitedField(_ number: UInt32, _ value: Data) -> Data {
        var result = fieldKey(number, wireType: 2)
        result.append(varint(UInt64(value.count)))
        result.append(value)
        return result
    }

    private static func fieldKey(_ number: UInt32, wireType: UInt32) -> Data {
        varint(UInt64((number << 3) | wireType))
    }

    private static func varint(_ value: UInt64) -> Data {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining != 0
        return Data(bytes)
    }

    private static func a5PayloadFrame(payload: Data, sequence: UInt8) -> Data {
        var frame = Data([0xA5, 0xA5, 0x03, sequence])
        frame.append(UInt8(payload.count & 0xff))
        frame.append(UInt8((payload.count >> 8) & 0xff))
        let crc = crc16X25(payload)
        frame.append(UInt8(crc & 0xff))
        frame.append(UInt8((crc >> 8) & 0xff))
        frame.append(payload)
        return frame
    }

    private static func crc16X25(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ 0x8408
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
    }

    private static func hexByte(_ byte: UInt8) -> String {
        String(format: "%02X", byte)
    }
}
