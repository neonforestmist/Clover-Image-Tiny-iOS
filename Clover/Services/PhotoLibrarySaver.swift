import Photos
import UIKit

enum PhotoLibraryError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Allow Clover to add images in Settings, then try again."
    }
}

enum PhotoLibrarySaver {
    static func save(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.denied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}
