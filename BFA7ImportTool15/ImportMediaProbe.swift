import Combine
import Foundation
import ImageIO
import AVFoundation
import CryptoKit

private struct ImportTransferRecord: Codable {
    let filename: String
    let date: Date?
    var gallerySaved: Bool
}

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
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    private var operation: Task<Void, Never>?
    private let directory: URL
    private let gallery: ImportGalleryWriting?
    private var records: [String: ImportTransferRecord] = [:]
    private var recordLoadError: Error?

    init(directory: URL? = nil, gallery: ImportGalleryWriting? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BFA7Imports", isDirectory: true)
        #if os(iOS)
        self.gallery = gallery ?? ImportGalleryWriter()
        #else
        self.gallery = gallery
        #endif
        let index = self.directory.appendingPathComponent(".import-index.json")
        if FileManager.default.fileExists(atPath: index.path) {
            do { records = try JSONDecoder().decode([String: ImportTransferRecord].self, from: Data(contentsOf: index)) }
            catch { recordLoadError = error }
        }
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

    func importAll() {
        guard operation == nil else { return }
        operation = Task {
            if await refreshFileList(), !Task.isCancelled { await downloadAll(files) }
            operation = nil
        }
    }

    func saveToGallery(_ url: URL) {
        guard operation == nil, downloads.contains(url) else { return }
        operation = Task {
            isBusy = true
            defer { isBusy = false; operation = nil }
            do {
                if let error = recordLoadError { throw error }
                let key = records.first(where: { $0.value.filename == url.lastPathComponent })?.key
                    ?? "local-\(url.lastPathComponent)"
                if records[key] == nil {
                    records[key] = ImportTransferRecord(filename: url.lastPathComponent, date: nil, gallerySaved: false)
                }
                try await exportToGallery(key: key)
                status = "Saved to Photos"
            } catch { report(error) }
        }
    }

    func isSavedToGallery(_ url: URL) -> Bool {
        records.values.contains { $0.filename == url.lastPathComponent && $0.gallerySaved }
    }

    func cancel() { operation?.cancel() }

    func deleteDownload(_ url: URL) {
        guard !isBusy, downloads.contains(url) else { return }
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

    @discardableResult
    func refreshFileList() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        completed = 0
        total = 0
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
            files = try ImportMediaProtocol.decodeList(data).filter { $0.isBundle || $0.isPhoto || $0.isVideo }
            let preview = String(data: Data(data.prefix(160)), encoding: .utf8) ?? ""
            lastReport = "GET \(url.absoluteString) -> 200, \(data.count) B\n\(preview)"
            status = "Found \(files.count) photos / videos"
            return true
        } catch {
            report(error)
            return false
        }
    }

    func downloadPhoto(_ entry: ImportMediaEntry) async {
        guard !isBusy else { return }
        isBusy = true
        completed = 0
        total = 0
        defer { isBusy = false }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            let base = try ImportMediaProtocol.baseURL(host: host)
            lastReport = ""
            let skipped = try await transfer(entry, base: base, session: session)
            status = skipped ? "Already imported" : (gallery == nil ? "Downloaded" : "Saved to Photos")
        } catch {
            if gallery == nil && !entry.isBundle && !(error is CancellationError) && !Task.isCancelled {
                status = "No photo downloaded"
                lastReport += "\n\(error.localizedDescription)"
            } else { report(error) }
        }
    }

    func downloadAll(_ entries: [ImportMediaEntry]) async {
        guard !isBusy else { return }
        isBusy = true
        completed = 0
        total = entries.count
        defer { isBusy = false }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        var failures: [String] = []
        var skipped = 0
        do {
            let base = try ImportMediaProtocol.baseURL(host: host)
            for entry in entries {
                try Task.checkCancellation()
                do {
                    if try await transfer(entry, base: base, session: session) { skipped += 1 }
                } catch {
                    try Task.checkCancellation()
                    failures.append("\(entry.name): \(error.localizedDescription)")
                }
                completed += 1
            }
            status = "Import finished: \(total - skipped - failures.count) saved, \(skipped) skipped, \(failures.count) failed"
            lastReport = failures.isEmpty ? "" : failures.joined(separator: "\n")
        } catch { report(error) }
    }

    private func transfer(_ entry: ImportMediaEntry, base: URL, session: URLSession) async throws -> Bool {
        if let error = recordLoadError { throw error }
        let identity = "\(base.host ?? "")\u{0}\(entry.remoteName)\u{0}\(entry.added)\u{0}\(entry.size ?? 0)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let record = records[key] {
            if record.gallerySaved { return true }
            let local = try localURL(record.filename)
            if FileManager.default.fileExists(atPath: local.path) {
                try await exportToGallery(key: key)
                return gallery == nil
            }
            records.removeValue(forKey: key)
        }
        var candidates = [entry]
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
        var lastError: Error = entry.isVideo ? ImportMediaError.invalidVideo : ImportMediaError.invalidImage
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
                guard let bytes = size?.intValue, bytes > 0,
                      bytes <= (candidate.isVideo ? 2_147_483_648 : 67_108_864) else {
                    throw candidate.isVideo ? ImportMediaError.invalidVideo : ImportMediaError.invalidImage
                }
                if let expected = candidate.size, expected != bytes { throw ImportMediaError.sizeMismatch }
                let ext: String
                if candidate.isVideo {
                    ext = try await Self.validatedVideoExtension(at: temporary, filename: candidate.remoteName)
                } else {
                    ext = try Self.validatedPhotoExtension(at: temporary)
                }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = URL(fileURLWithPath: candidate.remoteName).deletingPathExtension().lastPathComponent
                let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(name).\(ext)")
                try FileManager.default.moveItem(at: temporary, to: destination)
                let date = entry.added > 0 && entry.added.isFinite && entry.added < 4_102_444_800_000
                    ? Date(timeIntervalSince1970: entry.added / 1000) : nil
                records[key] = ImportTransferRecord(filename: destination.lastPathComponent, date: date, gallerySaved: false)
                reloadDownloads()
                try persistRecords()
                status = "Downloaded \(bytes) B"
                lastReport += "\nGET \(url.absoluteString) -> 200, \(bytes) B, decoded \(ext)"
            } catch {
                try Task.checkCancellation()
                if records[key] != nil { throw error }
                failures.append("\(candidate.remoteName): \(error.localizedDescription)")
                lastError = error
                continue
            }
            // Gallery failures must not cause another HDR component to be downloaded.
            try await exportToGallery(key: key)
            return false
        }
        lastReport += "\n" + failures.joined(separator: "\n")
        throw lastError
    }

    private func localURL(_ filename: String) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\") else { throw ImportMediaError.unsafePath }
        return directory.appendingPathComponent(filename)
    }

    private func persistRecords() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent(".import-index.json"), options: .atomic)
    }

    private func exportToGallery(key: String) async throws {
        guard let gallery, var record = records[key] else { return }
        guard !record.gallerySaved else { return }
        try Task.checkCancellation()
        let url = try localURL(record.filename)
        try await gallery.save(url, isVideo: ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()), date: record.date)
        record.gallerySaved = true
        records[key] = record
        try persistRecords()
        reloadDownloads()
    }

    static func validatedVideoExtension(at url: URL, filename: String) async throws -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw ImportMediaError.invalidVideo }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        let playable = try await asset.load(.isPlayable)
        guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else { throw ImportMediaError.invalidVideo }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 128, height: 128)
        // Decode one frame, not merely a container header or a spoofed MIME type.
        _ = try generator.copyCGImage(at: .zero, actualTime: nil)
        return ext
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
        config.timeoutIntervalForResource = 900
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
        )) ?? []).filter { ["heic", "heif", "jpg", "jpeg", "png", "mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
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
