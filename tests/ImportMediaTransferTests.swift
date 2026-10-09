import Foundation

@main
enum ImportMediaTransferTests {
    @MainActor
    static func main() async throws {
        let base = try ImportMediaProtocol.baseURL(host: "192.168.43.1")
        precondition(base.absoluteString == "http://192.168.43.1:8080")
        let encoded = try ImportMediaProtocol.endpoint(base: base, list: false, name: "part one.heic")
        precondition(encoded.absoluteString == "http://192.168.43.1:8080/v1/files/part%20one.heic")
        for bad in ["http://user:password@localhost", "https://localhost", "http://localhost:0", "http://localhost:65536", ""] {
            do { _ = try ImportMediaProtocol.baseURL(host: bad); fatalError("Unsafe base URL accepted") }
            catch ImportMediaError.unsafePath {}
        }
        for bad in ["../secret.heic", "%2e%2e.heic", "foo/bar.heic", "http://other/part.heic", "//other/part.heic", "part.heic?token=x", "part.heic#fragment", ""] {
            do { _ = try ImportMediaProtocol.endpoint(base: base, list: false, name: bad); fatalError("Unsafe remote path accepted") }
            catch ImportMediaError.unsafePath {}
        }
        let list = Data("""
        [{"fileName":"IMG_TEST","url":"filelists/LLHDR_TEST","mimeType":"image/folder","fileAdded":2},
        {"filename":"earlier.heic","fileAdded":1},{"filename":"earlier.heic","fileAdded":1}]
        """.utf8)
        let entries = try ImportMediaProtocol.decodeList(list)
        precondition(entries.count == 2 && entries[0].isBundle && entries[0].remoteName == "LLHDR_TEST")
        precondition(entries[1].isPhoto && !entries[1].isBundle)
        let empty = try ImportMediaProtocol.decodeList(Data("[]".utf8))
        let wrapped = try ImportMediaProtocol.decodeList(Data("{\"data\":{\"files\":[\"part.heic\"]}}".utf8))
        precondition(empty.isEmpty && wrapped.count == 1)
        for bad in ["null", "{}", "[{}]", "[{\"url\":\"../secret.heic\"}]", "{\"files\":42}"] {
            do { _ = try ImportMediaProtocol.decodeList(Data(bad.utf8)); fatalError("Invalid manifest accepted") }
            catch ImportMediaError.invalidList {}
        }
        do {
            _ = try ImportMediaProtocol.decodeList(Data(repeating: 32, count: 1_048_577))
            fatalError("Oversized manifest accepted")
        } catch ImportMediaError.invalidList {}

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = ImportMediaProbe(directory: folder)
        media.host = CommandLine.arguments[1]
        await media.refreshFileList()
        precondition(media.files.count == 2 && !media.isBusy, media.lastReport)
        await media.downloadPhoto(media.files[0])
        precondition(media.downloads.count == 1 && media.status.hasPrefix("Downloaded"), media.lastReport)
        let photoExtension = try ImportMediaProbe.validatedPhotoExtension(at: media.downloads[0])
        precondition(photoExtension == "png")
        let reloaded = ImportMediaProbe(directory: folder)
        precondition(reloaded.downloads == media.downloads)

        for name in ["missing.png", "fake.png", "truncated.png", "redirect.png"] {
            await media.downloadPhoto(ImportMediaEntry(name: name, remoteName: name, size: nil, added: 0, isBundle: false))
            precondition(media.status == "No photo downloaded" && media.downloads.count == 1, media.lastReport)
        }
        await media.downloadPhoto(ImportMediaEntry(name: "older.png", remoteName: "older.png", size: 1, added: 0, isBundle: false))
        precondition(media.downloads.count == 1 && media.lastReport.contains("does not match"))
        await media.downloadPhoto(ImportMediaEntry(name: "empty", remoteName: "LLHDR_EMPTY", size: nil, added: 0, isBundle: true))
        precondition(media.downloads.count == 1 && media.status == "Transfer failed")

        let download = Task { await media.downloadPhoto(ImportMediaEntry(
            name: "slow.png", remoteName: "slow.png", size: nil, added: 0, isBundle: false)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        download.cancel()
        await download.value
        precondition(media.status == "Cancelled" && !media.isBusy && media.downloads.count == 1)
        media.host = "192.168.43.1"
        precondition(media.files.isEmpty && media.downloads.count == 1)
        media.deleteDownload(folder.appendingPathComponent("not-listed.png"))
        precondition(media.downloads.count == 1)
        media.deleteDownload(media.downloads[0])
        precondition(media.downloads.isEmpty)
        print("Media import: JSON, safe paths, manifest, real image download, reload, HTTP errors, fake/truncated image, size mismatch, redirects and cancellation passed")
    }
}
