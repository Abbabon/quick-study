import Foundation
import Shared

@main
struct FetcherMain {
    static func main() async {
        let args = CommandLine.arguments
        let skipImages = args.contains("--no-images")

        let emitter = ProgressEmitter(logURL: Paths.fetcherLogURL)
        emitter.emit(phase: "start", message: "mtg-fetcher starting (skipImages=\(skipImages))")

        do {
            let store = try CardStore()
            let client = ScryfallClient()

            // 1. Fetch bulk-data index
            emitter.emit(phase: "json", message: "fetching bulk index")
            let info = try await client.bulkInfo(type: "oracle_cards")
            emitter.emit(phase: "json", message: "bulk size \(info.size) updated_at \(info.updated_at)")

            // 2. Download bulk JSON
            let bulkURL = Paths.supportDir.appendingPathComponent("bulk-oracle.json", isDirectory: false)
            try await client.downloadBulkJSON(from: info, to: bulkURL)
            emitter.emit(phase: "json", message: "bulk JSON downloaded")

            // 3. Parse + ingest
            let cards = try client.parseBulk(at: bulkURL)
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

            // 4. Image download (unless --no-images)
            if skipImages {
                emitter.emit(phase: "done", message: "skipping images")
                return
            }
            let refs = try client.extractImageRefs(at: bulkURL)
            emitter.emit(phase: "images", done: 0, total: refs.count)
            let downloader = ImageDownloader(concurrency: 8)
            await downloader.download(refs: refs, store: store) { done, total in
                emitter.emit(phase: "images", done: done, total: total)
            }
            emitter.emit(phase: "done", message: "complete")
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
