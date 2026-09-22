import Foundation
import Combine
import NetworkExtension

@MainActor
final class BFA7WiFiJoiner: ObservableObject {
    @Published var ssidText: String {
        didSet { UserDefaults.standard.set(ssidText, forKey: Self.ssidKey) }
    }
    @Published private(set) var status = "Wi-Fi join not tested"
    @Published private(set) var isJoining = false

    private static let ssidKey = "BFA7Bridge.wifi.ssid"
    private static let defaultSSID = "Xiaomi AI Glasses BFA7"

    init() {
        ssidText = UserDefaults.standard.string(forKey: Self.ssidKey) ?? Self.defaultSSID
    }

    func joinAndRefresh(media: MediaTransfer) async {
        let ssid = ssidText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty else {
            status = "Введите SSID очков"
            return
        }

        isJoining = true
        status = "Запрос подключения к \(ssid)"
        defer { isJoining = false }

        let configuration = NEHotspotConfiguration(ssid: ssid)
        configuration.joinOnce = false

        do {
            try await apply(configuration)
            status = "Wi-Fi prompt завершён; проверяю 192.168.43.1"
            let reachable = await media.quickRefreshFileList(timeout: 5)
            status = reachable ? "BFA7 Wi-Fi доступен" : "Подключение выполнено, но /v1/filelists не ответил"
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            status = "Уже подключено; проверяю 192.168.43.1"
            let reachable = await media.quickRefreshFileList(timeout: 5)
            status = reachable ? "BFA7 Wi-Fi доступен" : "Wi-Fi есть, но /v1/filelists не ответил"
        } catch {
            status = "Wi-Fi join ошибка; проверяю 192.168.43.1"
            let reachable = await media.quickRefreshFileList(timeout: 5)
            status = reachable ? "BFA7 Wi-Fi доступен после fallback" : "Wi-Fi join ошибка: \(error.localizedDescription)"
        }
    }

    private func apply(_ configuration: NEHotspotConfiguration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
