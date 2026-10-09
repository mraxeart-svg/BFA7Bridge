import Foundation

struct ImportMediaEntry: Identifiable, Equatable {
    let name: String
    let remoteName: String
    let size: Int?
    let added: Double
    let isBundle: Bool

    var id: String { remoteName }
    var isVideo: Bool { ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: remoteName).pathExtension.lowercased()) }
    var isPhoto: Bool {
        ["heic", "heif", "jpg", "jpeg", "png"].contains(
            URL(fileURLWithPath: remoteName).pathExtension.lowercased()
        )
    }
}

enum ImportMediaError: LocalizedError {
    case invalidList, unsafePath, invalidImage, invalidVideo, sizeMismatch, emptyBundle
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidList: return "Invalid or oversized file-list JSON"
        case .unsafePath: return "Invalid media path"
        case .invalidImage: return "Response is not a decodable HEIC, JPEG or PNG photo"
        case .invalidVideo: return "Response is not a playable MP4 or MOV video"
        case .sizeMismatch: return "Downloaded size does not match the manifest"
        case .emptyBundle: return "Bundle contains no supported photos"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

enum ImportMediaProtocol {
    static func decodeList(_ data: Data) throws -> [ImportMediaEntry] {
        guard data.count <= 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data),
              let rows = rows(in: object, depth: 0), rows.count <= 1_000 else {
            throw ImportMediaError.invalidList
        }
        var seen = Set<String>()
        let entries = rows.compactMap { row -> ImportMediaEntry? in
            let dictionary = row as? [String: Any] ?? [:]
            let name = string(dictionary, keys: ["fileName", "filename", "name"])
            let path = string(dictionary, keys: ["url", "path", "identifier"])
                ?? name ?? (row as? String)
            guard let path, let leaf = safeLeaf(path) else { return nil }
            let mime = dictionary["mimeType"] as? String
            let isBundle = mime == "image/folder" ||
                (leaf.hasPrefix("LLHDR_") && URL(fileURLWithPath: leaf).pathExtension.isEmpty)
            let number = dictionary["size"] as? NSNumber
            let size = number.flatMap { value -> Int? in
                let n = value.doubleValue
                return n > 0 && n <= 2_147_483_648 && n.rounded() == n ? Int(n) : nil
            }
            let added = (dictionary["fileAdded"] as? NSNumber)?.doubleValue ?? 0
            return ImportMediaEntry(name: name ?? leaf, remoteName: leaf,
                                    size: size, added: added, isBundle: isBundle)
        }.filter { seen.insert($0.id).inserted }
        guard rows.isEmpty || !entries.isEmpty else { throw ImportMediaError.invalidList }
        return entries.sorted { $0.added == $1.added ? $0.name > $1.name : $0.added > $1.added }
    }

    static func baseURL(host: String) throws -> URL {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: host.contains("://") ? host : "http://\(host)"),
              parts.scheme == "http", let name = parts.host, !name.isEmpty,
              parts.user == nil, parts.password == nil else { throw ImportMediaError.unsafePath }
        if parts.port == nil { parts.port = 8080 }
        guard let port = parts.port, (1...65535).contains(port) else { throw ImportMediaError.unsafePath }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { throw ImportMediaError.unsafePath }
        return url
    }

    static func endpoint(base: URL, list: Bool, name: String? = nil) throws -> URL {
        let root = base.appendingPathComponent(list ? "v1/filelists" : "v1/files")
        guard let name else { return root }
        guard safeLeaf(name) == name else { throw ImportMediaError.unsafePath }
        return root.appendingPathComponent(name)
    }

    private static func safeLeaf(_ path: String) -> String? {
        guard !path.isEmpty, path.utf8.count <= 1_024,
              !path.contains("%"), !path.contains("\\"),
              path.rangeOfCharacter(from: .controlCharacters) == nil,
              let parts = URLComponents(string: path), parts.scheme == nil, parts.host == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains("."), !segments.contains(".."),
              let last = segments.last, !last.isEmpty else { return nil }
        return String(last)
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        keys.compactMap { object[$0] as? String }.first(where: { !$0.isEmpty })
    }

    private static func rows(in object: Any, depth: Int) -> [Any]? {
        guard depth < 5 else { return nil }
        if let array = object as? [Any] { return array }
        guard let dictionary = object as? [String: Any] else { return nil }
        for key in ["files", "filelists", "items", "list", "data", "result"] {
            if let nested = dictionary[key] { return rows(in: nested, depth: depth + 1) }
        }
        return nil
    }
}
