import Foundation
#if os(iOS)
import Photos
#endif

@MainActor
protocol ImportGalleryWriting {
    func save(_ url: URL, isVideo: Bool, date: Date?) async throws
}

enum ImportGalleryError: LocalizedError {
    case permissionDenied, saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Photos access denied; file kept in the app"
        case .saveFailed: return "Photos could not save the file; local copy kept"
        }
    }
}

#if os(iOS)
@MainActor
final class ImportGalleryWriter: ImportGalleryWriting {
    func save(_ url: URL, isVideo: Bool, date: Date?) async throws {
        var authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
            }
        }
        guard authorization == .authorized else { throw ImportGalleryError.permissionDenied }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = date
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: isVideo ? .video : .photo, fileURL: url, options: options)
            } completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? ImportGalleryError.saveFailed) }
            }
        }
    }
}
#endif
