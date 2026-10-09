import Foundation
import NetworkExtension
import UIKit

@MainActor
final class ImportWiFiManager: ImportWiFiManaging {
    let capability = ImportSigningDiagnostics.current()
    var isForeground: Bool { UIApplication.shared.applicationState == .active }
    private var applying = false

    func apply(ssid: String, password: String, temporary: Bool) async throws {
        guard !applying else { throw ImportWiFiFailure.pending }
        guard isForeground else { throw ImportWiFiFailure.notForeground }
        applying = true
        defer { applying = false }
        let configuration = password.isEmpty ? NEHotspotConfiguration(ssid: ssid)
            : NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = temporary
        if !temporary { configuration.lifeTimeInDays = 1 }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                guard let error = error as NSError? else { continuation.resume(); return }
                guard error.domain == NEHotspotConfigurationErrorDomain else {
                    continuation.resume(throwing: ImportWiFiFailure.system(error.domain, error.code)); return
                }
                let failure: ImportWiFiFailure
                switch error.code {
                case NEHotspotConfigurationError.internal.rawValue: failure = .internalError
                case NEHotspotConfigurationError.alreadyAssociated.rawValue: failure = .alreadyAssociated
                case NEHotspotConfigurationError.userDenied.rawValue: failure = .userDenied
                case NEHotspotConfigurationError.pending.rawValue: failure = .pending
                case NEHotspotConfigurationError.applicationIsNotInForeground.rawValue: failure = .notForeground
                default: failure = .system(error.domain, error.code)
                }
                continuation.resume(throwing: failure)
            }
        }
    }

    func removeOwnConfiguration(ssid: String) async {
        let owned: [String] = await withCheckedContinuation { continuation in
            NEHotspotConfigurationManager.shared.getConfiguredSSIDs { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, owned.contains(ssid) else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    func importServiceAvailable(host: String) async -> Bool {
        guard !Task.isCancelled,
              let base = try? ImportMediaProtocol.baseURL(host: host),
              let url = try? ImportMediaProtocol.endpoint(base: base, list: true) else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ImportWiFiRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                  let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber,
                  size.intValue <= 1_048_576 else { return false }
            _ = try ImportMediaProtocol.decodeList(Data(contentsOf: temporary))
            return true
        } catch { return false }
    }
}

private final class ImportWiFiRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
