import Foundation
import AVFoundation
import CoreVideo

@MainActor
private final class TestGallery: ImportGalleryWriting {
    var denied = false
    var calls = 0
    var videos = 0
    func save(_ url: URL, isVideo: Bool, date: Date?) async throws {
        calls += 1
        if denied { throw ImportGalleryError.permissionDenied }
        precondition(FileManager.default.fileExists(atPath: url.path))
        if isVideo { videos += 1 }
    }
}

@main
enum ImportMediaTransferTests {
    @MainActor
    static func main() async throws {
        try await makeVideo(at: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("clip.mp4"))
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
        precondition(media.files.count == 3 && media.files[2].isVideo && !media.isBusy, media.lastReport)
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

        let galleryFolder = folder.appendingPathComponent("gallery")
        let gallery = TestGallery()
        let importer = ImportMediaProbe(directory: galleryFolder, gallery: gallery)
        importer.host = CommandLine.arguments[1]
        await importer.refreshFileList()
        gallery.denied = true
        await importer.downloadPhoto(importer.files[0])
        precondition(importer.status == "Transfer failed" && importer.downloads.count == 1 && gallery.calls == 1)
        precondition(!importer.isSavedToGallery(importer.downloads[0]))
        gallery.denied = false
        await importer.downloadPhoto(importer.files[0])
        precondition(importer.status == "Saved to Photos" && importer.downloads.count == 1 && gallery.calls == 2)
        precondition(importer.isSavedToGallery(importer.downloads[0]))
        let resumed = ImportMediaProbe(directory: galleryFolder, gallery: gallery)
        resumed.host = CommandLine.arguments[1]
        await resumed.downloadPhoto(importer.files[0])
        precondition(resumed.status == "Already imported" && gallery.calls == 2)
        await resumed.downloadAll(importer.files)
        precondition(resumed.completed == 3 && resumed.total == 3 && resumed.downloads.count == 3)
        precondition(gallery.calls == 4 && gallery.videos == 1 && resumed.status.contains("2 saved, 1 skipped, 0 failed"))
        for url in resumed.downloads { precondition(resumed.isSavedToGallery(url)) }
        await resumed.downloadAll(importer.files)
        precondition(gallery.calls == 4 && resumed.status.contains("0 saved, 3 skipped, 0 failed"))
        for name in ["fake.mp4", "truncated.mp4"] {
            await resumed.downloadPhoto(ImportMediaEntry(name: name, remoteName: name, size: nil, added: 0, isBundle: false))
            precondition(resumed.status == "Transfer failed" && resumed.downloads.count == 3 && gallery.calls == 4)
        }
        let missing = ImportMediaEntry(name: "missing.png", remoteName: "missing.png", size: nil, added: 0, isBundle: false)
        await resumed.downloadAll([missing] + importer.files)
        precondition(resumed.completed == 4 && resumed.status.contains("0 saved, 3 skipped, 1 failed"))
        precondition(gallery.calls == 4)
        let cancelled = Task { await resumed.downloadAll([
            ImportMediaEntry(name: "slow.png", remoteName: "slow.png", size: nil, added: 0, isBundle: false)
        ] + importer.files) }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancelled.cancel()
        await cancelled.value
        precondition(resumed.status == "Cancelled" && resumed.completed == 0 && gallery.calls == 4)
        print("Media import: image/video HTTP transfer, validation, gallery failure/retry, persistent deduplication, batch errors and cancellation passed")
    }

    static func makeVideo(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<2 {
            var pixel: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB,
                                             nil, &pixel) == kCVReturnSuccess)
            let buffer = pixel!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        precondition(writer.status == .completed, writer.error?.localizedDescription ?? "Video generation failed")
    }
}
