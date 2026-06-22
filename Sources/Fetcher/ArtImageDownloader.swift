import Foundation
import Shared

/// Concurrent, resumable downloader for the optional offline `art_crop` set.
/// Mirrors `ImageDownloader` but keyed on `illustration_id`, writing to `Paths.artDir`.
/// Writes no DB rows — art presence on disk is the only state.
public actor ArtImageDownloader {
    private let session: URLSession
    private let concurrency: Int

    public init(concurrency: Int = 8) {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = concurrency
        cfg.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: cfg)
        self.concurrency = concurrency
    }

    /// Downloads art for the given refs, calling `progress(done, total)` after each
    /// completion (success or skip). Files already on disk are skipped.
    public func download(
        refs: [ArtImageRef],
        progress: @Sendable @escaping (Int, Int) -> Void
    ) async {
        // Dedup by illustration_id (DFCs can repeat across card objects) and drop existing.
        var seen = Set<String>()
        let unique = refs.filter { seen.insert($0.illustrationID).inserted }
        let total = unique.count
        let pending = unique.filter {
            !FileManager.default.fileExists(atPath: Paths.artURL(forIllustrationID: $0.illustrationID).path)
        }
        var completed = total - pending.count
        progress(completed, total)

        await withTaskGroup(of: Void.self) { group in
            var iter = pending.makeIterator()
            for _ in 0..<concurrency {
                guard let ref = iter.next() else { break }
                group.addTask { await self.downloadOne(ref: ref) }
            }
            while await group.next() != nil {
                completed += 1
                progress(completed, total)
                if let ref = iter.next() {
                    group.addTask { await self.downloadOne(ref: ref) }
                }
            }
        }
    }

    private func downloadOne(ref: ArtImageRef) async {
        let dest = Paths.artURL(forIllustrationID: ref.illustrationID)
        guard let url = URL(string: ref.imageURL) else { return }
        do {
            let (tmp, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            // Silently skip — a later run retries.
        }
    }
}
