import Foundation
import Shared

/// Concurrent, resumable image downloader. Skips files already on disk.
public actor ImageDownloader {
    private let session: URLSession
    private let concurrency: Int

    public init(concurrency: Int = 8) {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = concurrency
        cfg.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: cfg)
        self.concurrency = concurrency
    }

    /// Downloads images for the given refs. Calls `progress` after each completion
    /// (success or skip) with (done, total).
    public func download(
        refs: [CardImageRef],
        store: CardStore,
        progress: @Sendable @escaping (Int, Int) -> Void
    ) async {
        let total = refs.count
        // Filter out already-downloaded.
        let pending = refs.filter { !FileManager.default.fileExists(atPath: Paths.imageURL(forCardID: $0.id).path) }
        let alreadyDone = total - pending.count
        progress(alreadyDone, total)

        // Backfill image_path for any files that already exist on disk but aren't recorded.
        for ref in refs where !pending.contains(where: { $0.id == ref.id }) {
            let path = "images/\(ref.id).jpg"
            try? store.setImagePath(path, forID: ref.id)
        }

        // Concurrent queue with bounded parallelism.
        var completed = alreadyDone
        await withTaskGroup(of: Void.self) { group in
            var iter = pending.makeIterator()
            // Prime up to `concurrency` tasks.
            for _ in 0..<concurrency {
                guard let ref = iter.next() else { break }
                group.addTask { await self.downloadOne(ref: ref, store: store) }
            }
            // As each finishes, kick off the next.
            while await group.next() != nil {
                completed += 1
                progress(completed, total)
                if let ref = iter.next() {
                    group.addTask { await self.downloadOne(ref: ref, store: store) }
                }
            }
        }
    }

    private func downloadOne(ref: CardImageRef, store: CardStore) async {
        let dest = Paths.imageURL(forCardID: ref.id)
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
            try store.setImagePath("images/\(ref.id).jpg", forID: ref.id)
        } catch {
            // Silently skip — next refresh will retry. Errors get a log line via fetcher main.
        }
    }
}
