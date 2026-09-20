import Foundation
import Combine

@MainActor
final class MediaTransfer: ObservableObject {
    @Published var baseURLText = "http://192.168.43.1:8080"
    @Published private(set) var files: [BFA7MediaFile] = []
    @Published private(set) var latestDownloaded: BFA7MediaFile?
    @Published private(set) var status = "Ожидание"
    @Published private(set) var isBusy = false

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refreshFileList() async {
        guard let url = endpointURL(path: "/v1/filelists") else {
            status = "Неверный URL"
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let (data, _) = try await session.data(from: url)
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
        } catch {
            status = "Ошибка списка: \(error.localizedDescription)"
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
        guard let url = downloadURL(for: file) else {
            status = "Не удалось собрать URL файла"
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            let (temporaryURL, _) = try await session.download(from: url)
            let directory = try mediaDirectory()
            let destination = directory.appendingPathComponent(file.filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            var saved = file
            saved.localURL = destination
            latestDownloaded = saved
            status = "Загружено: \(file.filename)"
        } catch {
            status = "Ошибка загрузки: \(error.localizedDescription)"
        }
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

    private func endpointURL(path: String) -> URL? {
        guard var components = URLComponents(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        components.path = path
        return components.url
    }

    private func downloadURL(for file: BFA7MediaFile) -> URL? {
        if let remotePath = file.remotePath, remotePath.lowercased().hasPrefix("http") {
            return URL(string: remotePath)
        }

        let path = file.remotePath?.isEmpty == false ? file.remotePath! : "/v1/filelists/\(file.filename)"
        guard var components = URLComponents(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }

    private func mediaDirectory() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("BFA7BridgeMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
