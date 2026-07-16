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

    /// One file to fetch. `recordID` is the card whose `image_path` row is updated
    /// after a successful download — set for front faces only; back faces are never
    /// recorded in the DB (presence on disk is their only state).
    struct DownloadItem: Sendable {
        let url: String
        let dest: URL
        let recordID: String?
    }

    /// Expands card refs into per-file download items (front always, back when present).
    static func downloadItems(for refs: [CardImageRef]) -> [DownloadItem] {
        var items: [DownloadItem] = []
        items.reserveCapacity(refs.count)
        for ref in refs {
            items.append(DownloadItem(url: ref.imageURL,
                                      dest: Paths.imageURL(forCardID: ref.id),
                                      recordID: ref.id))
            if let back = ref.backImageURL {
                items.append(DownloadItem(url: back,
                                          dest: Paths.backImageURL(forCardID: ref.id),
                                          recordID: nil))
            }
        }
        return items
    }

    /// Downloads images for the given refs (front + back faces). Calls `progress`
    /// after each completion (success or skip) with (done, total) counted in files.
    public func download(
        refs: [CardImageRef],
        store: CardStore,
        progress: @Sendable @escaping (Int, Int) -> Void
    ) async {
        let items = Self.downloadItems(for: refs)
        let total = items.count
        // Filter out already-downloaded.
        let pending = items.filter { !FileManager.default.fileExists(atPath: $0.dest.path) }
        let pendingDests = Set(pending.map { $0.dest.path })
        let alreadyDone = total - pending.count
        progress(alreadyDone, total)

        // Backfill image_path for any fronts that already exist on disk but aren't recorded.
        for item in items {
            if let id = item.recordID, !pendingDests.contains(item.dest.path) {
                try? store.setImagePath("images/\(id).jpg", forID: id)
            }
        }

        // Concurrent queue with bounded parallelism.
        var completed = alreadyDone
        await withTaskGroup(of: Void.self) { group in
            var iter = pending.makeIterator()
            // Prime up to `concurrency` tasks.
            for _ in 0..<concurrency {
                guard let item = iter.next() else { break }
                group.addTask { await self.downloadOne(item: item, store: store) }
            }
            // As each finishes, kick off the next.
            while await group.next() != nil {
                completed += 1
                progress(completed, total)
                if let item = iter.next() {
                    group.addTask { await self.downloadOne(item: item, store: store) }
                }
            }
        }
    }

    private func downloadOne(item: DownloadItem, store: CardStore) async {
        guard let url = URL(string: item.url) else { return }
        do {
            let (tmp, response) = try await session.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: tmp)
                return
            }
            if FileManager.default.fileExists(atPath: item.dest.path) {
                try FileManager.default.removeItem(at: item.dest)
            }
            try FileManager.default.moveItem(at: tmp, to: item.dest)
            if let id = item.recordID {
                try store.setImagePath("images/\(id).jpg", forID: id)
            }
        } catch {
            // Silently skip — next refresh will retry. Errors get a log line via fetcher main.
        }
    }
}
