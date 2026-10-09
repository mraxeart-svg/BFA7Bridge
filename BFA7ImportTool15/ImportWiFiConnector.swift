import Combine
import Foundation

enum ImportWiFiFailure: Error {
    case internalError, alreadyAssociated, userDenied, pending, notForeground
    case system(String, Int)
}

@MainActor
protocol ImportWiFiManaging {
    var capability: ImportHotspotCapability { get }
    var isForeground: Bool { get }
    func apply(ssid: String, password: String, temporary: Bool) async throws
    func removeOwnConfiguration(ssid: String) async
    func importServiceAvailable(host: String) async -> Bool
}

@MainActor
final class ImportWiFiConnector: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var isJoining = false
    @Published private(set) var isReady = false
    var capability: ImportHotspotCapability { manager.capability }
    private let manager: ImportWiFiManaging
    private let delay: UInt64
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var target: (ssid: String, password: String, host: String)?
    private var deferred = false

    init(manager: ImportWiFiManaging, delay: UInt64 = 750_000_000) {
        self.manager = manager
        self.delay = delay
    }

    func connect(ssid: String, password: String, host: String) {
        guard !isJoining else { return }
        target = (ssid, password, host)
        isReady = false
        guard manager.isForeground else {
            deferred = true
            status = "Wi-Fi join waiting for foreground"
            return
        }
        deferred = false
        isJoining = true
        generation = UUID()
        let id = generation
        task = Task {
            await run(ssid: ssid, password: password, host: host, id: id)
            guard generation == id else { return }
            isJoining = false
            task = nil
        }
    }

    func resume() {
        guard deferred || isReady, let target else { return }
        connect(ssid: target.ssid, password: target.password, host: target.host)
    }

    func reset() {
        task?.cancel()
        task = nil
        generation = UUID()
        target = nil
        deferred = false
        status = ""
        isJoining = false
        isReady = false
    }

    private func current(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }

    private func run(ssid: String, password: String, host: String, id: UUID) async {
        status = "Checking current import network"
        // A manually joined network remains useful even if signing stripped the capability.
        if await manager.importServiceAvailable(host: host), current(id) {
            isReady = true
            status = "Import Wi-Fi service ready"
            return
        }
        guard current(id) else { return }
        guard capability != .missing else {
            status = "Auto-join unavailable: Hotspot permission missing in installed signature"
            return
        }
        do {
            status = "Waiting for glasses Wi-Fi"
            try await Task.sleep(nanoseconds: delay)
            guard current(id) else { return }
            guard manager.isForeground else {
                deferred = true
                status = "Wi-Fi join waiting for foreground"
                return
            }
            status = "Joining \(ssid)"
            do {
                try await manager.apply(ssid: ssid, password: password, temporary: true)
            } catch ImportWiFiFailure.alreadyAssociated {
                // Still verify TCP/IP and the import service; this is not proof of readiness.
            } catch ImportWiFiFailure.internalError {
                guard current(id), capability == .present else { throw ImportWiFiFailure.internalError }
                // One bounded fallback, with the same current password and app-owned config only.
                status = "Retrying glasses Wi-Fi"
                await manager.removeOwnConfiguration(ssid: ssid)
                try await Task.sleep(nanoseconds: delay)
                guard current(id) else { return }
                guard manager.isForeground else {
                    deferred = true
                    status = "Wi-Fi join waiting for foreground"
                    return
                }
                do { try await manager.apply(ssid: ssid, password: password, temporary: false) }
                catch ImportWiFiFailure.alreadyAssociated {}
            }
            guard current(id) else { return }
            status = "Checking import Wi-Fi service"
            for _ in 0..<6 {
                if await manager.importServiceAvailable(host: host), current(id) {
                    isReady = true
                    status = "Import Wi-Fi service ready"
                    return
                }
                guard current(id) else { return }
                try await Task.sleep(nanoseconds: delay)
            }
            status = "Wi-Fi configured; import service not reachable"
        } catch {
            guard current(id) else { return }
            switch error {
            case ImportWiFiFailure.userDenied: status = "Wi-Fi join declined"
            case ImportWiFiFailure.pending: status = "iOS Wi-Fi request still pending"
            case ImportWiFiFailure.notForeground:
                deferred = true
                status = "Wi-Fi join waiting for foreground"
            case ImportWiFiFailure.internalError: status = "iOS Wi-Fi internal error (code=8)"
            case ImportWiFiFailure.system(let domain, let code): status = "Wi-Fi join failed: \(domain), code=\(code)"
            default: status = "Wi-Fi join failed"
            }
        }
    }
}
