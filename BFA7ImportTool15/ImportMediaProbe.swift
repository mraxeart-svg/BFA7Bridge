import Foundation

@MainActor
final class ImportMediaProbe: ObservableObject {
    @Published var host = "192.168.43.1"
    @Published var status = "not probed"
    @Published var lastReport = ""
    private var isProbing = false

    func probe() {
        Task {
            await runProbe()
        }
    }

    private func runProbe() async {
        guard !isProbing else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              var base = URLComponents(string: trimmedHost.contains("://") ? trimmedHost : "http://\(trimmedHost)"),
              base.scheme == "http", let hostname = base.host, !hostname.isEmpty,
              base.user == nil, base.password == nil else {
            status = "invalid HTTP host"
            return
        }
        if base.port == nil { base.port = 8080 }
        base.query = nil
        base.fragment = nil
        isProbing = true
        defer { isProbing = false }

        status = "probing \(trimmedHost)"
        let paths = ["/v1/filelists"]
        var lines: [String] = []
        var receivedHTTPResponse = false
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        for path in paths {
            base.path = path
            guard let url = base.url else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                receivedHTTPResponse = http != nil
                let preview: String
                if let text = String(data: Data(data.prefix(160)), encoding: .utf8), !text.isEmpty {
                    preview = text.replacingOccurrences(of: "\n", with: " ")
                } else {
                    preview = Data(data.prefix(64)).importHexString
                }
                lines.append("GET \(url.absoluteString) -> \(code), \(data.count) B, \(preview)")
            } catch {
                lines.append("GET \(path) -> \(error.localizedDescription)")
            }
        }

        lastReport = lines.joined(separator: "\n")
        status = receivedHTTPResponse ? "probe finished; check HTTP status" : "no HTTP response"
    }
}
