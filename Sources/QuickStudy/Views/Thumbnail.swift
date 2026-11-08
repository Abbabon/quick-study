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
    /// The decoded image and the card it belongs to. A row can be reused for another card (the
    /// results list keys rows by position), so an image only shows while its id still matches.
    @State private var loaded: (id: String, image: NSImage)?

    var body: some View {
        Group {
            // Cache hit: shown synchronously so a revisited card appears instantly, no flash.
            if let image = loaded?.id == id ? loaded?.image : ThumbnailCache.cached(id) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs))
                    .dsHairlineRing(cornerRadius: DS.Radius.xs)
            } else {
                IdentityPlaceholder(identity: identity, cornerRadius: DS.Radius.xs)
            }
        }
        .task(id: id) { await load() }
    }

    /// Miss: decode off the main thread. `.task(id:)` cancels this when the row moves on to
    /// another card, so a slow decode can't land on the wrong row.
    private func load() async {
        let cardID = id
        guard ThumbnailCache.cached(cardID) == nil else { return }
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let url = Paths.imageURL(forCardID: cardID)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Perf.measure("thumb.decode") { NSImage(contentsOf: url) }
        }.value
        guard let img else { return }
        ThumbnailCache.store(img, for: cardID)
        if !Task.isCancelled { loaded = (cardID, img) }
    }
}
