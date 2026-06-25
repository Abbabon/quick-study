import Foundation
import Shared

@main
struct FetcherMain {
    static func main() async {
        let args = CommandLine.arguments
        let imagesOnly = args.contains("--images-only")
        let skipImages = args.contains("--no-images")
        let artwork = args.contains("--artwork")
        let downloadArt = args.contains("--download-art")
        let printings = args.contains("--printings")

        let emitter = ProgressEmitter(logURL: Paths.fetcherLogURL)
        emitter.emit(phase: "start", message: "mtg-fetcher starting (imagesOnly=\(imagesOnly) skipImages=\(skipImages) artwork=\(artwork) downloadArt=\(downloadArt) printings=\(printings))")

        do {
            let store = try CardStore()
            let client = ScryfallClient()

            // Artwork pipeline: ingest unique_artwork metadata, optionally download all art_crops.
            if artwork {
                let artBulkURL = Paths.supportDir.appendingPathComponent("bulk-unique-artwork.json", isDirectory: false)
                emitter.emit(phase: "json", message: "fetching unique_artwork bulk index")
                let info = try await client.bulkInfo(type: "unique_artwork")
                emitter.emit(phase: "json", message: "artwork bulk size \(info.size) updated_at \(info.updated_at)")
                try await client.downloadBulkJSON(from: info, to: artBulkURL)
                emitter.emit(phase: "json", message: "artwork bulk JSON downloaded")

                let artworks = try client.parseArtworks(at: artBulkURL)
                emitter.emit(phase: "artwork", done: 0, total: artworks.count)
                var done = 0
                for batch in artworks.chunked(into: 1000) {
                    try store.upsertArtworks(batch)
                    done += batch.count
                    emitter.emit(phase: "artwork", done: done, total: artworks.count)
                }
                try store.setMeta("artwork_updated_at", info.updated_at)

                if downloadArt {
                    let refs = try client.extractArtRefs(at: artBulkURL)
                    emitter.emit(phase: "images", done: 0, total: refs.count)
                    let downloader = ArtImageDownloader(concurrency: 8)
                    await downloader.download(refs: refs) { done, total in
                        emitter.emit(phase: "images", done: done, total: total)
                    }
                }
                emitter.emit(phase: "done", message: "artwork complete")
                return
            }

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
            // Row-count delta after upsert (before reconcile) is the number of brand-new
            // cards this ingest added — reconcile only removes rows that were already stale.
            let newCards = max(0, try store.count() - countBefore)

            // Reconcile: drop rows this complete ingest no longer produces (orphans from a
            // changed representative printing id; junk layouts an older fetcher ingested).
            // Safe only because we have the full, successfully-parsed id set in hand.
            let removed = try store.reconcileCards(keepingIDs: Set(cards.map(\.id)))
            if removed > 0 {
                emitter.emit(phase: "ingest", done: cards.count, total: cards.count,
                             message: "removed \(removed) stale cards")
            }

            // Sets catalog + per-card printings (manual refresh only; gated by --printings).
            if printings {
                emitter.emit(phase: "sets", message: "fetching set catalog")
                let sets = try await client.fetchSets()
                try store.upsertSets(sets)
                emitter.emit(phase: "sets", done: sets.count, total: sets.count)

                let defaultBulkURL = Paths.supportDir.appendingPathComponent("bulk-default.json", isDirectory: false)
                emitter.emit(phase: "printings", message: "fetching default_cards bulk index")
                let pInfo = try await client.bulkInfo(type: "default_cards")
                // Re-download only when the file is missing or Scryfall's stamp moved.
                let storedStamp = try store.meta("printings_updated_at")
                if !FileManager.default.fileExists(atPath: defaultBulkURL.path) || storedStamp != pInfo.updated_at {
                    try await client.downloadBulkJSON(from: pInfo, to: defaultBulkURL)
                }
                emitter.emit(phase: "printings", message: "parsing printings")
                let prints = try client.parsePrintings(at: defaultBulkURL)
                emitter.emit(phase: "printings", done: 0, total: prints.count)
                var pDone = 0
                for batch in prints.chunked(into: 1000) {
                    try store.upsertPrintings(batch)
                    pDone += batch.count
                    emitter.emit(phase: "printings", done: pDone, total: prints.count)
                }
                try store.setMeta("printings_updated_at", pInfo.updated_at)
            }

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
