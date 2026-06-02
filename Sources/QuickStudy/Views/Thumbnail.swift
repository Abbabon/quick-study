import SwiftUI
import AppKit
import Shared

/// Small card thumbnail loaded synchronously from the on-disk image cache,
/// with a placeholder when the image hasn't been downloaded. Shared by the
/// results list and the pinned row.
struct Thumbnail: View {
    let id: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 3).fill(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onAppear(perform: load)
    }

    private func load() {
        let url = Paths.imageURL(forCardID: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Cheap synchronous load — thumbnails are small JPEGs.
        if let img = NSImage(contentsOf: url) {
            self.image = img
        }
    }
}
