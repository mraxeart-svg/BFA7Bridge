import Foundation

@MainActor
private final class TestWiFiManager: ImportWiFiManaging {
    var capability: ImportHotspotCapability = .present
    var isForeground = true
    var responses: [Bool] = [false, true]
    var failures: [ImportWiFiFailure?] = []
    var calls: [(String, String, Bool)] = []
    var removed: [String] = []
    var suspendProbe = false
    var probeContinuation: CheckedContinuation<Bool, Never>?

    func apply(ssid: String, password: String, temporary: Bool) async throws {
        calls.append((ssid, password, temporary))
        if !failures.isEmpty, let error = failures.removeFirst() { throw error }
    }
    func removeOwnConfiguration(ssid: String) async { removed.append(ssid) }
    func importServiceAvailable(host: String) async -> Bool {
        if suspendProbe {
            suspendProbe = false
            return await withCheckedContinuation { probeContinuation = $0 }
        }
        return responses.isEmpty ? false : responses.removeFirst()
    }
}

@main
enum ImportWiFiTests {
    @MainActor
    static func main() async throws {
        try signingTests()
        let app = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(ImportSigningDiagnostics.inspect(app) == .present, "Packaged app lost Hotspot capability")

        let manager = TestWiFiManager()
        let connector = ImportWiFiConnector(manager: manager, delay: 0)
        connector.connect(ssid: "TEST", password: "fresh-one", host: "192.168.43.1")
        connector.connect(ssid: "TEST", password: "ignored-overlap", host: "192.168.43.1")
        await finish(connector)
        precondition(connector.isReady && manager.calls.count == 1 && manager.calls[0].1 == "fresh-one")
        connector.reset()
        manager.responses = [false, true]
        connector.connect(ssid: "TEST", password: "fresh-two", host: "192.168.43.1")
        await finish(connector)
        precondition(connector.isReady && manager.calls[1].1 == "fresh-two")

        let missing = TestWiFiManager()
        missing.capability = .missing
        missing.responses = [false]
        let noCapability = ImportWiFiConnector(manager: missing, delay: 0)
        noCapability.connect(ssid: "TEST", password: "secret", host: "192.168.43.1")
        await finish(noCapability)
        precondition(!noCapability.isReady && missing.calls.isEmpty && noCapability.status.contains("missing"))
        missing.responses = [true]
        noCapability.resume()
        await finish(noCapability)
        precondition(noCapability.isReady && missing.calls.isEmpty)

        let transient = TestWiFiManager()
        transient.failures = [.internalError, nil]
        let fallback = ImportWiFiConnector(manager: transient, delay: 0)
        fallback.connect(ssid: "TEST", password: "current-only", host: "192.168.43.1")
        await finish(fallback)
        precondition(fallback.isReady && transient.calls.count == 2 && transient.removed == ["TEST"])
        precondition(transient.calls[0].2 && !transient.calls[1].2 && transient.calls.allSatisfy { $0.1 == "current-only" })

        for failure in [ImportWiFiFailure.userDenied, .pending, .internalError] {
            let rejected = TestWiFiManager()
            rejected.capability = .unknown
            rejected.failures = [failure]
            let request = ImportWiFiConnector(manager: rejected, delay: 0)
            request.connect(ssid: "TEST", password: "secret", host: "192.168.43.1")
            await finish(request)
            rejected.responses = [false]
            request.resume()
            await finish(request)
            precondition(!request.isReady && rejected.calls.count == 1 && rejected.removed.isEmpty)
            precondition(!request.status.contains("secret"))
        }

        let noService = TestWiFiManager()
        noService.responses = []
        let configured = ImportWiFiConnector(manager: noService, delay: 0)
        configured.connect(ssid: "TEST", password: "secret", host: "192.168.43.1")
        await finish(configured)
        precondition(!configured.isReady && configured.status.contains("not reachable") && noService.calls.count == 1)

        let foreground = TestWiFiManager()
        foreground.isForeground = false
        let deferred = ImportWiFiConnector(manager: foreground, delay: 0)
        deferred.connect(ssid: "TEST", password: "fresh", host: "192.168.43.1")
        precondition(!deferred.isJoining && foreground.calls.isEmpty)
        foreground.isForeground = true
        deferred.resume()
        await finish(deferred)
        precondition(deferred.isReady && foreground.calls.count == 1)

        let stale = TestWiFiManager()
        stale.suspendProbe = true
        let changing = ImportWiFiConnector(manager: stale, delay: 0)
        changing.connect(ssid: "OLD", password: "old-pass", host: "192.168.43.1")
        for _ in 0..<100 where stale.probeContinuation == nil { await Task.yield() }
        precondition(stale.probeContinuation != nil)
        changing.reset()
        changing.connect(ssid: "NEW", password: "new-pass", host: "192.168.43.1")
        await finish(changing)
        stale.probeContinuation?.resume(returning: true)
        await Task.yield()
        precondition(changing.isReady && stale.calls.count == 1 && stale.calls[0].0 == "NEW")
        precondition(stale.calls[0].1 == "new-pass")
        let stalled = TestWiFiManager()
        stalled.suspendProbe = true
        let bounded = ImportWiFiConnector(manager: stalled, delay: 0, timeout: 10_000_000)
        bounded.connect(ssid: "TEST", password: "secret", host: "192.168.43.1")
        await finish(bounded)
        precondition(!bounded.isReady && bounded.status == "Wi-Fi connection timed out")
        stalled.probeContinuation?.resume(returning: true)
        await Task.yield()
        precondition(!bounded.isReady && stalled.calls.isEmpty)
        print("Wi-Fi: signing bounds, real app entitlement, password rotation, overlap, fallback, denial, service readiness, foreground and stale callbacks passed")
    }

    @MainActor
    private static func finish(_ connector: ImportWiFiConnector) async {
        for _ in 0..<2000 where connector.isJoining { try? await Task.sleep(nanoseconds: 1_000_000) }
        precondition(!connector.isJoining, "Wi-Fi operation did not finish")
    }

    private static func word(_ n: UInt32, bigEndian: Bool = true) -> Data {
        let bytes = [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                     UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
        return Data(bigEndian ? bytes : Array(bytes.reversed()))
    }

    private static func signature(_ dictionary: [String: Any]) throws -> Data {
        let xml = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        let blob = word(0xfade7171) + word(UInt32(xml.count + 8)) + xml
        return word(0xfade0cc0) + word(UInt32(20 + blob.count)) + word(1) + word(5) + word(20) + blob
    }

    private static func signingTests() throws {
        let key = ImportSigningDiagnostics.hotspotKey
        let good = try signature([key: true])
        precondition(ImportSigningDiagnostics.inspectSignature(good) == .present)
        precondition(ImportSigningDiagnostics.inspectSignature(good + Data(repeating: 0, count: 16)) == .present)
        let missingDictionaries: [[String: Any]] = [[:], [key: false]]
        for dictionary in missingDictionaries {
            let data = try signature(dictionary)
            precondition(ImportSigningDiagnostics.inspectSignature(data) == .missing)
        }
        let malformedDictionaries: [[String: Any]] = [[key: "true"], [key: 1]]
        for dictionary in malformedDictionaries {
            let data = try signature(dictionary)
            precondition(ImportSigningDiagnostics.inspectSignature(data) == .unknown)
        }
        for size in 0..<good.count {
            precondition(ImportSigningDiagnostics.inspectSignature(Data(good.prefix(size))) == .unknown)
        }
        var header = Data(repeating: 0, count: 32)
        header.replaceSubrange(0..<4, with: word(0xfeedfacf, bigEndian: false))
        header.replaceSubrange(16..<20, with: word(1, bigEndian: false))
        header.replaceSubrange(20..<24, with: word(16, bigEndian: false))
        let command = word(0x1d, bigEndian: false) + word(16, bigEndian: false)
            + word(48, bigEndian: false) + word(UInt32(good.count), bigEndian: false)
        let binary = header + command + good
        precondition(ImportSigningDiagnostics.inspect(binary) == .present)
        for size in 0..<binary.count { precondition(ImportSigningDiagnostics.inspect(Data(binary.prefix(size))) == .unknown) }
        var malformed = binary
        malformed.replaceSubrange(40..<44, with: word(UInt32.max, bigEndian: false))
        precondition(ImportSigningDiagnostics.inspect(malformed) == .unknown)
    }
}
