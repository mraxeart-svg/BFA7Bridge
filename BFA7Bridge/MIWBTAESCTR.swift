import CommonCrypto
import Foundation

enum MIWBTAESCTRError: Error {
    case invalidKeyLength
    case invalidCounterLength
    case createFailed(CCCryptorStatus)
    case updateFailed(CCCryptorStatus)
}

enum MIWBTAESCTR {
    static func encrypt(_ plaintext: Data, key: Data, initialCounter: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw MIWBTAESCTRError.invalidKeyLength }
        guard initialCounter.count == kCCBlockSizeAES128 else { throw MIWBTAESCTRError.invalidCounterLength }

        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            initialCounter.withUnsafeBytes { counterBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    counterBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw MIWBTAESCTRError.createFailed(createStatus)
        }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let updateStatus = plaintext.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    plaintext.count,
                    outputBytes.baseAddress,
                    output.count,
                    &moved
                )
            }
        }
        guard updateStatus == kCCSuccess else {
            throw MIWBTAESCTRError.updateFailed(updateStatus)
        }
        output.removeSubrange(moved..<output.count)
        return output
    }
}
