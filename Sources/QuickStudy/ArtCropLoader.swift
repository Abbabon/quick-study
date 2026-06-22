import AppKit
import Shared

/// Lazy `art_crop` loader for the game window: serves from the on-disk cache when
/// present, otherwise streams from Scryfall's CDN and writes into `Paths.artDir`.
/// This is the single sanctioned app-side writer of `art/` (the bulk "download all"
/// pass goes through the fetcher); it never touches `images/` or the DB.
@MainActor
final class ArtCropLoader {
    private let session: URLSession
    private let memory = NSCache<NSString, NSImage>()
    /// In-flight requests by illustration_id, so two rounds of the same art don't double-fetch.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
        memory.countLimit = 64
    }

    /// Returns the art image for an artwork, fetching + caching on first use. Returns nil
    /// only if both the disk cache miss and the network fetch fail.
    func image(for artwork: Artwork) async -> NSImage? {
        let key = artwork.illustrationID

        if let cached = memory.object(forKey: key as NSString) { return cached }

        let url = Paths.artURL(forIllustrationID: key)
        if FileManager.default.fileExists(atPath: url.path), let img = NSImage(contentsOf: url) {
            memory.setObject(img, forKey: key as NSString)
            return img
        }

        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> { [session] in
            guard let remote = URL(string: artwork.artCropURL) else { return nil }
            do {
                let (tmp, response) = try await session.download(from: remote)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    try? FileManager.default.removeItem(at: tmp)
                    return nil
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                try FileManager.default.moveItem(at: tmp, to: url)
                return NSImage(contentsOf: url)
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }
}
