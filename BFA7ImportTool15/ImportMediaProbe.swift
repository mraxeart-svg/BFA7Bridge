import Foundation

@MainActor
final class ImportMediaProbe: ObservableObject {
    @Published var host = "192.168.43.1"
    @Published var status = "not probed"
    @Published var lastReport = ""

    func probe() {
        Task {
            await runProbe()
        }
    }

    private func runProbe() async {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            status = "empty host"
            return
        }

        status = "probing \(trimmedHost)"
        let paths = ["/", "/v1/files", "/v1/files/", "/v1/file/list", "/v1/media/list", "/api/files"]
        var lines: [String] = []
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config)

        for path in paths {
            guard let url = URL(string: "http://\(trimmedHost)\(path)") else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                let preview: String
                if let text = String(data: Data(data.prefix(160)), encoding: .utf8), !text.isEmpty {
                    preview = text.replacingOccurrences(of: "\n", with: " ")
                } else {
                    preview = Data(data.prefix(64)).importHexString
                }
                lines.append("GET \(path) -> \(code), \(data.count) B, \(preview)")
            } catch {
                lines.append("GET \(path) -> \(error.localizedDescription)")
            }
        }

        lastReport = lines.joined(separator: "\n")
        status = lines.contains(where: { !$0.contains("-> The request timed out") && !$0.contains("-> Could not connect") && !$0.contains("-> A server with the specified hostname") }) ? "probe finished" : "no response"
    }
}
