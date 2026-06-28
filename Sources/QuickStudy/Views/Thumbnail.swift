import SwiftUI
import AppKit
import Shared

/// Process-wide cache of decoded card thumbnails, keyed by card id. Decoding a
/// JPEG is not free, and the results list re-creates `Thumbnail` views on every
/// keystroke/scroll, so without this each reappearance would re-decode the same
/// file on the main thread. Backed by `NSCache` so it self-evicts under memory
/// pressure.
enum ThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512
        return c
    }()

    static func cached(_ id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    static func store(_ image: NSImage, for id: String) {
        cache.setObject(image, forKey: id as NSString)
    }
}

/// Small card thumbnail served from an in-memory cache, decoded off the main
/// thread on a miss, with a mana-tinted placeholder while it loads or when the
/// image hasn't been downloaded. Shared by the results list and the pinned row.
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
        // Cache hit: assign synchronously so a revisited card shows instantly, no flash.
        if let cached = ThumbnailCache.cached(id) {
            image = cached
            return
        }
        // Miss: decode off the main thread, then hand the image back. The row may be
        // reused for another card before the decode finishes, so re-check `id`.
        let cardID = id
        Task.detached(priority: .userInitiated) {
            let url = Paths.imageURL(forCardID: cardID)
            guard FileManager.default.fileExists(atPath: url.path),
                  let img = NSImage(contentsOf: url) else { return }
            ThumbnailCache.store(img, for: cardID)
            await MainActor.run {
                if self.id == cardID { self.image = img }
            }
        }
    }
}
