import SwiftUI
import AppKit
import Shared

/// Small card thumbnail loaded synchronously from the on-disk image cache,
/// with a mana-tinted placeholder when the image hasn't been downloaded.
/// Shared by the results list and the pinned row.
struct Thumbnail: View {
    let id: String
    var identity: ColorIdentity = .colorless
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs))
                    .dsHairlineRing(cornerRadius: DS.Radius.xs)
            } else {
                IdentityPlaceholder(identity: identity, cornerRadius: DS.Radius.xs)
            }
        }
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
