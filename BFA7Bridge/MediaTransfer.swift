import Foundation
import Combine

struct BFA7WiFiProbeResult: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let url: String
    let statusCode: Int?
    let mimeType: String?
    let suggestedFilename: String?
    let byteCount: Int
    let signature: String
    let preview: String
    let error: String?

    var summary: String {
        if let error { return "ERROR \(error)" }
        let status = statusCode.map { String($0) } ?? "n/a"
        return "HTTP \(status) • \(mimeType ?? "unknown") • \(byteCount) B • \(signature)"
    }
}

private struct BFA7ProbeRequest {
    let method: String
    let path: String
    let body: String?
    let label: String
}

@MainActor
final class MediaTransfer: ObservableObject {
    @Published var baseURLText: String {
        didSet { UserDefaults.standard.set(baseURLText, forKey: Self.baseURLKey) }
    }
    @Published var probePathsText: String {
        didSet { UserDefaults.standard.set(probePathsText, forKey: Self.probePathsKey) }
    }
    @Published var methodProbePathsText: String {
        didSet { UserDefaults.standard.set(methodProbePathsText, forKey: Self.methodProbePathsKey) }
    }
    @Published var latestTemplateProbeText: String {
        didSet { UserDefaults.standard.set(latestTemplateProbeText, forKey: Self.latestTemplateProbeKey) }
    }
    @Published private(set) var files: [BFA7MediaFile] = []
    @Published private(set) var latestDownloaded: BFA7MediaFile?
    @Published private(set) var status = "Ожидание"
    @Published private(set) var lastTransferReport = "Media transfer not tested"
    @Published private(set) var probeResults: [BFA7WiFiProbeResult] = []
    @Published private(set) var lastProbeReport = "Wi-Fi probe not run"
    @Published private(set) var isBusy = false

    private static let baseURLKey = "BFA7Bridge.media.baseURL"
    private static let probePathsKey = "BFA7Bridge.media.probePaths"
    private static let methodProbePathsKey = "BFA7Bridge.media.methodProbePaths"
    private static let latestTemplateProbeKey = "BFA7Bridge.media.latestTemplateProbePaths"
    private static let defaultBaseURL = "http://192.168.43.1:8080"
    private static let defaultProbePaths = [
        "/",
        "/v1/filelists",
        "/filelists",
        "/v1/files",
        "/v1/media",
        "/dcim",
        "/DCIM"
    ].joined(separator: "\n")
    private static let defaultMethodProbePaths = [
        "/v1/files",
        "/v1/media",
        "/v1/filelists"
    ].joined(separator: "\n")
    private static let defaultLatestTemplateProbePaths = [
        "/v1/files?url={remote}",
        "/v1/files?path={remote}",
        "/v1/files?name={filename}",
        "/v1/files?identifier={identifier}",
        "/v1/filelists/{remoteLeaf}",
        "/v1/filelists/{identifier}",
        "/v1/files/{remoteLeaf}",
        "/v1/files/{identifier}",
        "/file/{remoteLeaf}",
        "/files/{remoteLeaf}",
        "/download/{remoteLeaf}",
        "/download?url={remote}",
        "POST /v1/files | {\"url\":\"{remote}\"}",
        "POST /v1/files | {\"path\":\"{remote}\"}",
        "POST /v1/files | {\"filename\":\"{filename}\",\"identifier\":\"{identifier}\"}"
    ].joined(separator: "\n")

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        baseURLText = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        probePathsText = UserDefaults.standard.string(forKey: Self.probePathsKey) ?? Self.defaultProbePaths
        methodProbePathsText = UserDefaults.standard.string(forKey: Self.methodProbePathsKey) ?? Self.defaultMethodProbePaths
        latestTemplateProbeText = UserDefaults.standard.string(forKey: Self.latestTemplateProbeKey) ?? Self.defaultLatestTemplateProbePaths
    }

    func refreshFileList() async {
        guard let url = endpointURL(path: "/v1/filelists") else {
            status = "Неверный URL"
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let (data, response) = try await session.data(from: url)
            let object = try JSONSerialization.jsonObject(with: data)
            let parsed = Self.extractFiles(from: object)
            files = parsed.sorted { lhs, rhs in
                switch (lhs.createdAt, rhs.createdAt) {
                case let (left?, right?): return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.filename > rhs.filename
                }
            }
            status = "Найдено файлов: \(files.count)"
            lastTransferReport = Self.transferReport(
                title: "BFA7 File List",
                url: url,
                response: response,
                byteCount: data.count,
                files: files,
                error: nil
            )
        } catch {
            status = "Ошибка списка: \(error.localizedDescription)"
            lastTransferReport = Self.transferReport(title: "BFA7 File List", url: url, response: nil, byteCount: 0, files: [], error: error)
        }
    }


    func quickRefreshFileList(timeout: TimeInterval = 3) async -> Bool {
        guard let url = endpointURL(path: "/v1/filelists") else {
            status = "Неверный URL"
            return false
        }

        isBusy = true
        defer { isBusy = false }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                status = "Проверка списка: HTTP \(http.statusCode)"
                lastTransferReport = Self.transferReport(
                    title: "BFA7 File List Quick Check",
                    url: url,
                    response: response,
                    byteCount: data.count,
                    files: files,
                    error: nil
                )
                return false
            }

            let object = try JSONSerialization.jsonObject(with: data)
            let parsed = Self.extractFiles(from: object).sorted { lhs, rhs in
                switch (lhs.createdAt, rhs.createdAt) {
                case let (left?, right?): return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.filename > rhs.filename
                }
            }
            files = parsed
            status = "Найдено файлов: \(files.count)"
            lastTransferReport = Self.transferReport(
                title: "BFA7 File List Quick Check",
                url: url,
                response: response,
                byteCount: data.count,
                files: files,
                error: nil
            )
            return true
        } catch {
            status = "Проверка списка: \(error.localizedDescription)"
            lastTransferReport = Self.transferReport(title: "BFA7 File List Quick Check", url: url, response: nil, byteCount: 0, files: [], error: error)
            return false
        }
    }

    func downloadLatest() async {
        if files.isEmpty {
            await refreshFileList()
        }
        guard let latest = files.first else {
            status = "Нет файлов для загрузки"
            return
        }
        await download(latest)
    }

    func download(_ file: BFA7MediaFile) async {
        let candidates = downloadURLs(for: file)
        guard !candidates.isEmpty else {
            status = "Не удалось собрать URL файла"
            return
        }

        isBusy = true
        defer { isBusy = false }

        var failureLines: [String] = []
        var urlQueue = candidates
        var attempted = Set<String>()
        var index = 0

        while index < urlQueue.count {
            let url = urlQueue[index]
            index += 1
            guard attempted.insert(url.absoluteString).inserted else { continue }

            do {
                let (temporaryURL, response) = try await session.download(from: url)
                let responseData = (try? Data(contentsOf: temporaryURL, options: [.mappedIfSafe])) ?? Data()

                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    failureLines.append(Self.downloadFailureLine(url: url, response: response, data: responseData, error: nil))
                    continue
                }

                if responseData.isEmpty {
                    let error = NSError(
                        domain: "BFA7Bridge.MediaTransfer",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Empty 2xx response body"]
                    )
                    failureLines.append(Self.downloadFailureLine(url: url, response: response, data: responseData, error: error))
                    continue
                }

                if let bundleFiles = Self.extractBundleFiles(from: responseData), !bundleFiles.isEmpty {
                    let nestedURLs = bundleDownloadURLs(parent: file, manifestURL: url, bundleFiles: bundleFiles)
                    urlQueue.append(contentsOf: nestedURLs.filter { !attempted.contains($0.absoluteString) })
                    failureLines.append(Self.downloadFailureLine(
                        url: url,
                        response: response,
                        data: responseData,
                        error: NSError(
                            domain: "BFA7Bridge.MediaTransfer",
                            code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Bundle manifest; queued \(nestedURLs.count) nested media candidates"]
                        )
                    ))
                    continue
                }

                let directory = try mediaDirectory()
                let responseKind = BFA7MediaKind(mimeType: response.mimeType)
                let detected = Self.detectMedia(at: temporaryURL, fallback: responseKind == .unknown ? file.kind : responseKind)
                let savedName = Self.filenameForDownloadedFile(file, response: response, detected: detected)
                let destination = directory.appendingPathComponent(savedName)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)

                let finalKind = detected.kind
                let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
                let actualSize = (attributes?[.size] as? NSNumber)?.intValue ?? file.sizeBytes
                let saved = BFA7MediaFile(
                    id: file.id,
                    filename: destination.lastPathComponent,
                    kind: finalKind,
                    sizeBytes: actualSize,
                    createdAt: file.createdAt,
                    remotePath: file.remotePath,
                    localURL: destination
                )
                latestDownloaded = saved
                status = "Загружено: \(saved.filename)"
                lastTransferReport = Self.transferReport(
                    title: "BFA7 File Download",
                    url: url,
                    response: response,
                    byteCount: actualSize ?? 0,
                    files: [saved],
                    error: nil,
                    extraLines: [
                        "Candidate URL: \(url.absoluteString)",
                        "Detected signature: \(detected.signature)",
                        "Detected extension: \(detected.preferredExtension ?? "none")"
                    ]
                )
                return
            } catch {
                failureLines.append(Self.downloadFailureLine(url: url, response: nil, data: Data(), error: error))
            }
        }

        latestDownloaded = nil
        status = "Файл не скачан: все кандидаты вернули ошибку"
        let reportURL = candidates.first ?? URL(string: baseURLText)!
        lastTransferReport = Self.transferReport(
            title: "BFA7 File Download Failed",
            url: reportURL,
            response: nil,
            byteCount: 0,
            files: [file],
            error: nil,
            extraLines: ["Tried candidates:"] + failureLines
        )
    }

    func useLocalPlaceholder() {
        let media = BFA7MediaFile(
            id: UUID().uuidString,
            filename: "manual-capture-placeholder.jpg",
            kind: .photo,
            sizeBytes: nil,
            createdAt: Date(),
            remotePath: nil,
            localURL: nil
        )
        latestDownloaded = media
        status = "Подготовлен ручной placeholder"
    }

    func runWiFiProbe() async {
        let paths = probePathsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paths.isEmpty else {
            status = "Добавь хотя бы один probe path"
            return
        }

        isBusy = true
        status = "Wi-Fi probe: \(paths.count) paths"
        defer { isBusy = false }

        var results: [BFA7WiFiProbeResult] = []
        for path in paths {
            guard let url = endpointURL(path: path) else {
                results.append(BFA7WiFiProbeResult(
                    path: path,
                    url: path,
                    statusCode: nil,
                    mimeType: nil,
                    suggestedFilename: nil,
                    byteCount: 0,
                    signature: "invalid-url",
                    preview: "",
                    error: "Invalid URL"
                ))
                continue
            }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 6
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                results.append(BFA7WiFiProbeResult(
                    path: path,
                    url: url.absoluteString,
                    statusCode: http?.statusCode,
                    mimeType: response.mimeType,
                    suggestedFilename: response.suggestedFilename,
                    byteCount: data.count,
                    signature: Self.signature(for: data),
                    preview: Self.preview(for: data),
                    error: nil
                ))
            } catch {
                results.append(BFA7WiFiProbeResult(
                    path: path,
                    url: url.absoluteString,
                    statusCode: nil,
                    mimeType: nil,
                    suggestedFilename: nil,
                    byteCount: 0,
                    signature: "error",
                    preview: "",
                    error: error.localizedDescription
                ))
            }
        }

        probeResults = results
        lastProbeReport = Self.probeReport(title: "BFA7 Wi-Fi Probe Report", baseURL: baseURLText, results: results)
        let successCount = results.filter { $0.statusCode.map { 200..<400 ~= $0 } == true }.count
        status = "Wi-Fi probe: \(successCount)/\(results.count) ответили"
    }

    func probeLatestFileURLs() async {
        if files.isEmpty {
            await refreshFileList()
        }
        guard let latest = files.first else {
            status = "Нет fresh file для probe"
            return
        }

        let paths = probePaths(for: latest)
        await runProbe(paths: paths, title: "BFA7 Latest File Probe", statusPrefix: "Latest probe")
    }

    func runMethodProbe() async {
        let paths = methodProbePathsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paths.isEmpty else {
            status = "Добавь method probe paths"
            return
        }

        let methods = ["GET", "HEAD", "POST", "OPTIONS"]
        let expanded = paths.flatMap { path in methods.map { method in "\(method) \(path)" } }
        await runProbe(paths: expanded, title: "BFA7 Method Probe", statusPrefix: "Method probe")
    }

    func runLatestTemplateProbe() async {
        if files.isEmpty {
            await refreshFileList()
        }
        guard let latest = files.first else {
            status = "Нет fresh file для template probe"
            return
        }

        let paths = latestTemplateProbeText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { expandTemplate($0, for: latest) }

        guard !paths.isEmpty else {
            status = "Добавь latest template paths"
            return
        }

        await runProbe(paths: paths, title: "BFA7 Latest Template Probe", statusPrefix: "Template probe")
    }

    private func runProbe(paths: [String], title: String, statusPrefix: String) async {
        isBusy = true
        status = "\(statusPrefix): \(paths.count) requests"
        defer { isBusy = false }

        var results: [BFA7WiFiProbeResult] = []
        for rawPath in paths {
            let parsed = Self.parseProbePath(rawPath)
            guard let url = endpointURL(path: parsed.path) else {
                results.append(BFA7WiFiProbeResult(
                    path: rawPath,
                    url: parsed.path,
                    statusCode: nil,
                    mimeType: nil,
                    suggestedFilename: nil,
                    byteCount: 0,
                    signature: "invalid-url",
                    preview: "",
                    error: "Invalid URL"
                ))
                continue
            }

            do {
                var request = URLRequest(url: url)
                request.httpMethod = parsed.method
                request.timeoutInterval = 6
                request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
                if let body = parsed.body {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Data(body.utf8)
                } else if parsed.method == "POST" {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Data("{}".utf8)
                }
                let (data, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                results.append(BFA7WiFiProbeResult(
                    path: parsed.label,
                    url: url.absoluteString,
                    statusCode: http?.statusCode,
                    mimeType: response.mimeType,
                    suggestedFilename: response.suggestedFilename,
                    byteCount: data.count,
                    signature: Self.signature(for: data),
                    preview: Self.preview(for: data),
                    error: nil
                ))
            } catch {
                results.append(BFA7WiFiProbeResult(
                    path: parsed.label,
                    url: url.absoluteString,
                    statusCode: nil,
                    mimeType: nil,
                    suggestedFilename: nil,
                    byteCount: 0,
                    signature: "error",
                    preview: "",
                    error: error.localizedDescription
                ))
            }
        }

        probeResults = results
        lastProbeReport = Self.probeReport(title: title, baseURL: baseURLText, results: results)
        let successCount = results.filter { $0.statusCode.map { 200..<400 ~= $0 } == true }.count
        status = "\(statusPrefix): \(successCount)/\(results.count) ответили"
    }

    private static func parseProbePath(_ raw: String) -> BFA7ProbeRequest {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = trimmed.components(separatedBy: " | ")
        let requestPart = segments.first ?? trimmed
        let body = segments.dropFirst().joined(separator: " | ").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = requestPart.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, ["GET", "HEAD", "POST", "OPTIONS"].contains(parts[0].uppercased()) {
            let method = parts[0].uppercased()
            let label = body.isEmpty ? "\(method) \(parts[1])" : "\(method) \(parts[1]) | \(body)"
            return BFA7ProbeRequest(method: method, path: parts[1], body: body.isEmpty ? nil : body, label: label)
        }
        return BFA7ProbeRequest(method: "GET", path: requestPart, body: body.isEmpty ? nil : body, label: trimmed)
    }

    private func probePaths(for file: BFA7MediaFile) -> [String] {
        var paths: [String] = []
        if let remotePath = file.remotePath, !remotePath.isEmpty {
            paths.append(remotePath)
            if URL(fileURLWithPath: remotePath).pathExtension.isEmpty {
                paths.append(contentsOf: fallbackExtensions(for: file.kind).map { remotePath + "." + $0 })
            }
        }

        let base = file.remotePath?.split(separator: "/").last.map(String.init) ?? file.filename
        let noExtension = URL(fileURLWithPath: base).deletingPathExtension().lastPathComponent
        let thumbnailNames = [base, noExtension + ".jpg", file.filename + ".jpg"]
        paths.append(contentsOf: thumbnailNames.map { "thumbnail/" + $0 })

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func endpointURL(path: String) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath.lowercased().hasPrefix("http") {
            return URL(string: trimmedPath)
        }
        guard var components = URLComponents(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let split = trimmedPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let pathPart = split.first ?? trimmedPath
        components.path = pathPart.hasPrefix("/") ? pathPart : "/\(pathPart)"
        components.percentEncodedQuery = split.count > 1 ? split[1] : nil
        return components.url
    }

    private func expandTemplate(_ template: String, for file: BFA7MediaFile) -> String {
        let remote = file.remotePath ?? file.filename
        let remoteLeaf = remote.split(separator: "/").last.map(String.init) ?? remote
        let remoteBase = URL(fileURLWithPath: remoteLeaf).deletingPathExtension().lastPathComponent
        let filenameBase = URL(fileURLWithPath: file.filename).deletingPathExtension().lastPathComponent
        let identifier: String
        if URL(fileURLWithPath: remoteLeaf).pathExtension.isEmpty {
            identifier = remoteLeaf + "." + (Self.fallbackExtension(for: file.kind) ?? "jpg")
        } else {
            identifier = remoteLeaf
        }

        let values = [
            "{remote}": Self.percentEncode(remote),
            "{remoteRaw}": remote,
            "{remoteLeaf}": Self.percentEncode(remoteLeaf),
            "{remoteLeafRaw}": remoteLeaf,
            "{remoteBase}": Self.percentEncode(remoteBase),
            "{filename}": Self.percentEncode(file.filename),
            "{filenameRaw}": file.filename,
            "{filenameBase}": Self.percentEncode(filenameBase),
            "{identifier}": Self.percentEncode(identifier),
            "{identifierRaw}": identifier,
            "{id}": Self.percentEncode(file.id)
        ]

        return values.reduce(template) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }

    private func downloadURLs(for file: BFA7MediaFile) -> [URL] {
        let rawPath = file.remotePath?.isEmpty == false ? file.remotePath! : "/v1/filelists/\(file.filename)"
        let rawLeaf = rawPath.split(separator: "/").last.map(String.init) ?? rawPath
        let identifier: String
        if URL(fileURLWithPath: rawLeaf).pathExtension.isEmpty {
            identifier = rawLeaf + "." + (Self.fallbackExtension(for: file.kind) ?? "jpg")
        } else {
            identifier = rawLeaf
        }

        var rawCandidates = [
            "/v1/files/\(rawLeaf)",
            "/v1/files/\(identifier)",
            "/v1/filelists/\(rawLeaf)",
            "/v1/filelists/\(identifier)",
            rawPath
        ]

        if URL(fileURLWithPath: rawPath).pathExtension.isEmpty {
            for ext in fallbackExtensions(for: file.kind) {
                rawCandidates.append(rawPath + "." + ext)
            }
        }

        var seen = Set<String>()
        return rawCandidates.compactMap { raw in
            let url: URL?
            if raw.lowercased().hasPrefix("http") {
                url = URL(string: raw)
            } else {
                url = endpointURL(path: raw)
            }
            guard let url else { return nil }
            guard seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    private func bundleDownloadURLs(parent: BFA7MediaFile, manifestURL: URL, bundleFiles: [BFA7MediaFile]) -> [URL] {
        let rawPath = parent.remotePath?.isEmpty == false ? parent.remotePath! : manifestURL.lastPathComponent
        let folderLeaf = rawPath.split(separator: "/").last.map(String.init) ?? manifestURL.lastPathComponent
        let sorted = bundleFiles.sorted { lhs, rhs in
            let lhsMedia = lhs.kind != .unknown
            let rhsMedia = rhs.kind != .unknown
            if lhsMedia != rhsMedia { return lhsMedia && !rhsMedia }
            return (lhs.sizeBytes ?? 0) > (rhs.sizeBytes ?? 0)
        }

        var rawCandidates: [String] = []
        for child in sorted {
            let childPath = child.remotePath ?? child.filename
            rawCandidates.append("/v1/files/\(folderLeaf)/\(childPath)")
            rawCandidates.append("/v1/filelists/\(folderLeaf)/\(childPath)")
            rawCandidates.append("/v1/files/\(childPath)")
            rawCandidates.append("/v1/filelists/\(childPath)")
            rawCandidates.append("filelists/\(folderLeaf)/\(childPath)")
        }

        var seen = Set<String>()
        return rawCandidates.compactMap { raw in
            guard let url = endpointURL(path: raw) else { return nil }
            guard seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    private func fallbackExtensions(for kind: BFA7MediaKind) -> [String] {
        switch kind {
        case .photo: return ["jpg", "heic", "jpeg"]
        case .video: return ["mp4", "mov"]
        case .audio: return ["m4a", "aac", "wav"]
        case .unknown: return ["jpg", "mp4"]
        }
    }

    private struct MediaDetection {
        let kind: BFA7MediaKind
        let preferredExtension: String?
        let signature: String
    }

    private static func filenameForDownloadedFile(_ file: BFA7MediaFile, response: URLResponse, detected: MediaDetection) -> String {
        let rawName = response.suggestedFilename?.isEmpty == false ? response.suggestedFilename! : file.filename
        let name = URL(fileURLWithPath: rawName).lastPathComponent
        guard URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = detected.preferredExtension else {
            return name
        }
        return name + "." + ext
    }

    private static func detectMedia(at url: URL, fallback: BFA7MediaKind) -> MediaDetection {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return MediaDetection(kind: fallback, preferredExtension: fallbackExtension(for: fallback), signature: "unreadable")
        }

        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return MediaDetection(kind: .photo, preferredExtension: "jpg", signature: "jpeg")
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return MediaDetection(kind: .photo, preferredExtension: "png", signature: "png")
        }
        if data.count >= 12, let brand = String(data: data[4..<12], encoding: .ascii), brand.contains("ftyp") {
            let ext = (brand.contains("heic") || brand.contains("heif") || brand.contains("mif1")) ? "heic" : "mp4"
            let kind: BFA7MediaKind = ext == "heic" ? .photo : .video
            return MediaDetection(kind: kind, preferredExtension: ext, signature: brand.trimmingCharacters(in: .controlCharacters))
        }

        return MediaDetection(kind: fallback, preferredExtension: fallbackExtension(for: fallback), signature: firstBytesHex(data))
    }

    private static func fallbackExtension(for kind: BFA7MediaKind) -> String? {
        switch kind {
        case .photo: return "jpg"
        case .video: return "mp4"
        case .audio: return "m4a"
        case .unknown: return nil
        }
    }

    private static func firstBytesHex(_ data: Data) -> String {
        data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func downloadFailureLine(url: URL, response: URLResponse?, data: Data, error: Error?) -> String {
        var parts = [url.absoluteString]
        if let http = response as? HTTPURLResponse {
            parts.append("HTTP \(http.statusCode)")
        }
        if let mime = response?.mimeType {
            parts.append("MIME \(mime)")
        }
        if !data.isEmpty {
            parts.append("bytes \(data.count)")
            parts.append("signature \(signature(for: data))")
            let bodyPreview = preview(for: data).replacingOccurrences(of: "\n", with: " ")
            if !bodyPreview.isEmpty { parts.append("preview \(bodyPreview)") }
        }
        if let error {
            parts.append("error \(error.localizedDescription)")
        }
        return "- " + parts.joined(separator: " | ")
    }

    private static func signature(for data: Data) -> String {
        if data.isEmpty { return "empty" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.count >= 12, let brand = String(data: data[4..<12], encoding: .ascii), brand.contains("ftyp") {
            return brand.trimmingCharacters(in: .controlCharacters)
        }
        return firstBytesHex(data)
    }

    private static func preview(for data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let prefix = data.prefix(700)
        if let text = String(data: prefix, encoding: .utf8) ?? String(data: prefix, encoding: .ascii) {
            return text
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: .newlines)
                .prefix(12)
                .joined(separator: "\n")
        }
        return firstBytesHex(data)
    }

    private static func probeReport(title: String, baseURL: String, results: [BFA7WiFiProbeResult]) -> String {
        var lines = [
            title,
            "Generated: \(Date().ISO8601Format())",
            "Base URL: \(baseURL)",
            "Results: \(results.count)",
            ""
        ]
        for result in results {
            lines.append("## \(result.path)")
            lines.append("URL: \(result.url)")
            if let statusCode = result.statusCode { lines.append("HTTP: \(statusCode)") }
            if let mimeType = result.mimeType { lines.append("MIME: \(mimeType)") }
            if let suggestedFilename = result.suggestedFilename { lines.append("Suggested filename: \(suggestedFilename)") }
            lines.append("Bytes: \(result.byteCount)")
            lines.append("Signature: \(result.signature)")
            if let error = result.error { lines.append("Error: \(error)") }
            if !result.preview.isEmpty {
                lines.append("Preview:")
                lines.append(result.preview)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func transferReport(title: String, url: URL, response: URLResponse?, byteCount: Int, files: [BFA7MediaFile], error: Error?, extraLines: [String] = []) -> String {
        var lines = [
            title,
            "Generated: \(Date().ISO8601Format())",
            "URL: \(url.absoluteString)"
        ]
        if let http = response as? HTTPURLResponse {
            lines.append("HTTP: \(http.statusCode)")
        }
        if let response {
            lines.append("MIME: \(response.mimeType ?? "unknown")")
            lines.append("Suggested filename: \(response.suggestedFilename ?? "none")")
        }
        lines.append("Bytes: \(byteCount)")
        lines.append(contentsOf: extraLines)
        if let error {
            lines.append("Error: \(error.localizedDescription)")
        }
        if files.isEmpty {
            lines.append("Files: none")
        } else {
            lines.append("Files:")
            for file in files {
                lines.append("- \(file.filename) | kind=\(file.kind.rawValue) | size=\(file.displaySize) | remote=\(file.remotePath ?? "none") | local=\(file.localURL?.lastPathComponent ?? "none")")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func mediaDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("BFA7BridgeMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func extractBundleFiles(from data: Data) -> [BFA7MediaFile]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let files = extractFiles(from: object)
        guard !files.isEmpty else { return nil }
        let mediaFiles = files.filter { file in
            file.kind != .unknown || file.filename.lowercased().hasSuffix(".heic") || file.filename.lowercased().hasSuffix(".heif")
        }
        return mediaFiles.isEmpty ? files : mediaFiles
    }

    private static func extractFiles(from object: Any) -> [BFA7MediaFile] {
        if let array = object as? [Any] {
            return array.compactMap(parseFile)
        }
        guard let dictionary = object as? [String: Any] else { return [] }

        for key in ["files", "filelists", "items", "list", "data", "result"] {
            if let nested = dictionary[key] {
                let files = extractFiles(from: nested)
                if !files.isEmpty { return files }
            }
        }

        if let file = parseFile(dictionary) {
            return [file]
        }
        return []
    }

    private static func parseFile(_ object: Any) -> BFA7MediaFile? {
        if let filename = object as? String {
            return BFA7MediaFile(
                id: filename,
                filename: URL(fileURLWithPath: filename).lastPathComponent,
                kind: BFA7MediaKind(filename: filename),
                sizeBytes: nil,
                createdAt: nil,
                remotePath: filename,
                localURL: nil
            )
        }

        guard let dictionary = object as? [String: Any] else { return nil }
        let rawName = stringValue(dictionary, keys: ["filename", "fileName", "name", "path", "url"])
        guard let rawName, !rawName.isEmpty else { return nil }
        let filename = URL(fileURLWithPath: rawName).lastPathComponent
        let remotePath = stringValue(dictionary, keys: ["path", "url", "download", "downloadUrl"]) ?? rawName
        let size = intValue(dictionary, keys: ["size", "sizeBytes", "length", "bytes"])
        let createdAt = dateValue(dictionary, keys: ["createdAt", "created", "time", "timestamp", "mtime"])

        return BFA7MediaFile(
            id: remotePath,
            filename: filename,
            kind: BFA7MediaKind(filename: filename),
            sizeBytes: size,
            createdAt: createdAt,
            remotePath: remotePath,
            localURL: nil
        )
    }

    private static func stringValue(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
            if let value = dictionary[key] { return String(describing: value) }
        }
        return nil
    }

    private static func intValue(_ dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key] as? Int { return value }
            if let value = dictionary[key] as? Double { return Int(value) }
            if let value = dictionary[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func dateValue(_ dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = dictionary[key] as? TimeInterval {
                return Date(timeIntervalSince1970: value > 4_000_000_000 ? value / 1000 : value)
            }
            if let value = dictionary[key] as? String {
                if let date = ISO8601DateFormatter().date(from: value) { return date }
                if let number = TimeInterval(value) {
                    return Date(timeIntervalSince1970: number > 4_000_000_000 ? number / 1000 : number)
                }
            }
        }
        return nil
    }
}
