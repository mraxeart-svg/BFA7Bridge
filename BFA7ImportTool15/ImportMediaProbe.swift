import Combine
import Foundation
import ImageIO

private final class ImportRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class ImportMediaProbe: ObservableObject {
    @Published var host = "192.168.43.1" {
        didSet { if host != oldValue { clearRemoteFiles() } }
    }
    @Published var status = "not probed"
    @Published var lastReport = ""
    @Published private(set) var files: [ImportMediaEntry] = []
    @Published private(set) var downloads: [URL] = []
    @Published private(set) var isBusy = false
    private var operation: Task<Void, Never>?
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BFA7Imports", isDirectory: true)
        reloadDownloads()
    }

    func probe() {
        guard operation == nil else { return }
        operation = Task {
            await refreshFileList()
            operation = nil
        }
    }

    func download(_ entry: ImportMediaEntry) {
        guard operation == nil else { return }
        operation = Task {
            await downloadPhoto(entry)
            operation = nil
        }
    }

    func cancel() { operation?.cancel() }

    func deleteDownload(_ url: URL) {
        guard downloads.contains(url) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            reloadDownloads()
        } catch { report(error) }
    }

    func clearRemoteFiles() {
        cancel()
        files = []
        lastReport = ""
        status = "not probed"
    }

    func refreshFileList() async {
        guard !isBusy else { return }
        isBusy = true
        files = []
        defer { isBusy = false }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            let base = try ImportMediaProtocol.baseURL(host: host)
            let url = try ImportMediaProtocol.endpoint(base: base, list: true)
            status = "Fetching file list"
            let data = try await fetchList(url, session: session)
            try Task.checkCancellation()
            files = try ImportMediaProtocol.decodeList(data).filter { $0.isBundle || $0.isPhoto }
            let preview = String(data: Data(data.prefix(160)), encoding: .utf8) ?? ""
            lastReport = "GET \(url.absoluteString) -> 200, \(data.count) B\n\(preview)"
            status = "Found \(files.count) photos / bundles"
        } catch {
            report(error)
        }
    }

    func downloadPhoto(_ entry: ImportMediaEntry) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            let base = try ImportMediaProtocol.baseURL(host: host)
            var candidates = [entry]
            lastReport = ""
            if entry.isBundle {
                status = "Reading bundle \(entry.name)"
                let manifest = try ImportMediaProtocol.endpoint(base: base, list: true, name: entry.remoteName)
                let data = try await fetchList(manifest, session: session)
                candidates = try ImportMediaProtocol.decodeList(data).filter { $0.isPhoto && !$0.isBundle }
                    .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
                lastReport = "Manifest HTTP 200: \(candidates.count) photo parts"
                guard !candidates.isEmpty else { throw ImportMediaError.emptyBundle }
            }
            var failures: [String] = []
            for candidate in candidates {
                try Task.checkCancellation()
                let url = try ImportMediaProtocol.endpoint(base: base, list: false, name: candidate.remoteName)
                status = "Downloading \(candidate.remoteName)"
                do {
                    let (temporary, response) = try await session.download(from: url)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw ImportMediaError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
                    }
                    let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
                    guard let bytes = size?.intValue, bytes > 0, bytes <= 67_108_864 else {
                        throw ImportMediaError.invalidImage
                    }
                    if let expected = candidate.size, expected != bytes { throw ImportMediaError.sizeMismatch }
                    let ext = try Self.validatedPhotoExtension(at: temporary)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let name = URL(fileURLWithPath: candidate.remoteName).deletingPathExtension().lastPathComponent
                    let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(name).\(ext)")
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    reloadDownloads()
                    status = "Downloaded \(bytes) B"
                    lastReport += "\nGET \(url.absoluteString) -> 200, \(bytes) B, decoded \(ext)"
                    return
                } catch {
                    try Task.checkCancellation()
                    failures.append("\(candidate.remoteName): \(error.localizedDescription)")
                }
            }
            status = "No photo downloaded"
            lastReport += "\n" + failures.joined(separator: "\n")
        } catch {
            report(error)
        }
    }

    private func fetchList(_ url: URL, session: URLSession) async throws -> Data {
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ImportMediaError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 1_048_576 else {
            throw ImportMediaError.invalidList
        }
        return try Data(contentsOf: temporary)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.allowsCellularAccess = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: ImportRedirectGuard(), delegateQueue: nil)
    }

    static func validatedPhotoExtension(at url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              let ext = ["public.heic": "heic", "public.heif": "heif",
                         "public.jpeg": "jpg", "public.png": "png"][type],
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) != nil else { throw ImportMediaError.invalidImage }
        return ext
    }

    private func reloadDownloads() {
        downloads = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { ["heic", "heif", "jpg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left > right
            }
    }

    private func report(_ error: Error) {
        if Task.isCancelled { status = "Cancelled"; return }
        let error = error as NSError
        status = "Transfer failed"
        lastReport += "\n\(error.domain), code=\(error.code): \(error.localizedDescription)"
    }
}
