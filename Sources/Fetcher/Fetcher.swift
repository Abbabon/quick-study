import Foundation
import Shared

@main
struct FetcherMain {
    static func main() async {
        let args = CommandLine.arguments
        let imagesOnly = args.contains("--images-only")
        let skipImages = args.contains("--no-images")

        let emitter = ProgressEmitter(logURL: Paths.fetcherLogURL)
        emitter.emit(phase: "start", message: "mtg-fetcher starting (imagesOnly=\(imagesOnly) skipImages=\(skipImages))")

        do {
            let store = try CardStore()
            let client = ScryfallClient()

            let bulkURL = Paths.supportDir.appendingPathComponent("bulk-oracle.json", isDirectory: false)

            // Images-only: reuse the bulk JSON already on disk (download it only if
            // missing) and download just the images not yet cached. No ingest.
            if imagesOnly {
                if !FileManager.default.fileExists(atPath: bulkURL.path) {
                    emitter.emit(phase: "json", message: "bulk JSON missing — downloading")
                    let info = try await client.bulkInfo(type: "oracle_cards")
                    try await client.downloadBulkJSON(from: info, to: bulkURL)
                }
                let refs = try client.extractImageRefs(at: bulkURL)
                emitter.emit(phase: "images", done: 0, total: refs.count)
                let downloader = ImageDownloader(concurrency: 8)
                await downloader.download(refs: refs, store: store) { done, total in
                    emitter.emit(phase: "images", done: done, total: total)
                }
                emitter.emit(phase: "done", message: "images complete")
                return
            }

            // 1. Fetch bulk-data index
            emitter.emit(phase: "json", message: "fetching bulk index")
            let info = try await client.bulkInfo(type: "oracle_cards")
            emitter.emit(phase: "json", message: "bulk size \(info.size) updated_at \(info.updated_at)")

            // 2. Download bulk JSON
            try await client.downloadBulkJSON(from: info, to: bulkURL)
            emitter.emit(phase: "json", message: "bulk JSON downloaded")

            // 3. Parse + ingest
            let cards = try client.parseBulk(at: bulkURL)
            let countBefore = try store.count()
            emitter.emit(phase: "ingest", done: 0, total: cards.count)
            // Upsert in batches so SQLite write-locks don't dominate.
            let batchSize = 1000
            var done = 0
            for batch in cards.chunked(into: batchSize) {
                try store.upsert(batch)
                done += batch.count
                emitter.emit(phase: "ingest", done: done, total: cards.count)
            }
            try store.setMeta("last_refresh", ISO8601DateFormatter().string(from: Date()))
            try store.setMeta("bulk_updated_at", info.updated_at)
            // The fetcher never deletes cards, so the row-count delta is the number
            // of brand-new cards this ingest added.
            let newCards = max(0, try store.count() - countBefore)

            // 4. Image download (unless --no-images)
            if skipImages {
                emitter.emit(phase: "done", message: "skipping images", newCards: newCards)
                return
            }
            let refs = try client.extractImageRefs(at: bulkURL)
            emitter.emit(phase: "images", done: 0, total: refs.count)
            let downloader = ImageDownloader(concurrency: 8)
            await downloader.download(refs: refs, store: store) { done, total in
                emitter.emit(phase: "images", done: done, total: total)
            }
            emitter.emit(phase: "done", message: "complete", newCards: newCards)
        } catch {
            emitter.emit(phase: "error", message: "\(error)")
            exit(1)
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
