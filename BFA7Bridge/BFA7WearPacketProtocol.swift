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
}
