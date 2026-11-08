import XCTest
@testable import QuickStudy
import Shared

/// Benchmarks `SearchEngine` on the real card corpus. The corpus is loaded at test time from a
/// copy of the local QuickStudy DB (the live DB is never opened); the test skips when no DB
/// exists (fresh clone / no refresh yet).
///
/// The p99 < 1 ms assertion only applies to optimized builds — run it with
/// `swift test -c release -Xswiftc -enable-testing --filter SearchEngineBenchmarkTests`.
/// Debug builds just print the numbers.
final class SearchEngineBenchmarkTests: XCTestCase {
    /// Every prefix of these is searched, simulating keystroke-by-keystroke typing, plus a
    /// few whole queries that hit the set, subsequence, no-match and filter paths.
    private static let typed = [
        "lightning bolt", "jace, the mind sculptor", "sol ring", "modern horizons",
        "counterspell", "llanowar elves", "ljt", "zzzzqx",
    ]
    private static let whole = ["msc", "bolt r:common", "c:r t:creature", "dragon mv>=5", "o:\"draw a card\""]

    func testSearchLatencyOnRealCorpus() throws {
        let engine = try Self.loadRealEngine()
        let queries = Self.typed.flatMap { q in (1...q.count).map { String(q.prefix($0)) } } + Self.whole

        // Warm up (first-call allocations, page faults).
        for q in queries { _ = run(engine, q) }

        var samples: [Double] = []
        #if DEBUG
        let passes = 1
        #else
        let passes = 5
        #endif
        for _ in 0..<passes {
            for q in queries {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = run(engine, q)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p99 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.99))]
        let max = samples.last ?? 0
        print(String(format: "SearchEngine bench: %d cards, %d searches  p50 %.3f ms  p99 %.3f ms  max %.3f ms",
                     engine.minis.count, samples.count, p50, p99, max))
        #if !DEBUG
        XCTAssertLessThan(p99, 1.0, "SearchEngine.search p99 must stay under 1 ms on the real corpus")
        #endif
    }

    private func run(_ engine: SearchEngine, _ q: String) -> Int {
        let parsed = QueryParser.parse(q)
        return engine.searchCounted(name: parsed.name, filters: parsed.filters).total
    }

    /// Copies the local DB (+WAL) to a temp dir and loads the engine the same way the app does.
    static func loadRealEngine() throws -> SearchEngine {
        let src = Paths.databaseURL
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw XCTSkip("No local QuickStudy DB at \(src.path)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("cards.sqlite")
        for suffix in ["", "-wal"] {
            let s = URL(fileURLWithPath: src.path + suffix)
            if FileManager.default.fileExists(atPath: s.path) {
                try FileManager.default.copyItem(at: s, to: URL(fileURLWithPath: dst.path + suffix))
            }
        }
        let store = try CardStore(url: dst)
        let engine = SearchEngine(minis: try store.loadMinis(), sets: try store.loadSetIndex(),
                                  filterFields: try store.loadFilterFields())
        guard engine.minis.count > 1000 else { throw XCTSkip("Local DB has too few cards to benchmark") }
        return engine
    }
}
