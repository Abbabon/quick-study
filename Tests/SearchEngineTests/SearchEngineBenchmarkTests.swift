import XCTest
@testable import QuickStudy
import Shared

/// Benchmarks `SearchEngine` on the real card corpus, and checks its byte fast path against the
/// original String scorer there. The corpus is loaded at test time from a copy of the local
/// QuickStudy DB (the live DB is never opened); the tests skip when no DB exists.
///
/// The latency assertions only apply to optimized builds — run them with
/// `swift test -c release -Xswiftc -enable-testing --filter SearchEngineBenchmarkTests`.
/// Debug builds just print the numbers.
final class SearchEngineBenchmarkTests: XCTestCase {
    /// Every prefix of these is searched, simulating keystroke-by-keystroke typing.
    private static let typed = [
        "lightning bolt", "jace, the mind sculptor", "sol ring", "modern horizons",
        "counterspell", "llanowar elves", "ljt", "zzzzqx",
    ]
    /// Whole queries hitting the set, filter and non-ASCII paths alongside a name.
    private static let whole = ["msc", "bolt r:common", "dragon mv>=5", "elf c:g", "æther", "jötun"]
    /// Filter-only full-text scans (no name): every card's type line / rules text is searched.
    private static let fullText = ["o:\"draw a card\"", "c:r t:creature", "o:flying", "t:legendary"]

    private static var engine: SearchEngine?

    override class func setUp() {
        engine = try? loadRealEngine()
    }

    private func realEngine() throws -> SearchEngine {
        guard let e = Self.engine else { throw XCTSkip("No usable local QuickStudy DB") }
        return e
    }

    func testSearchLatencyOnRealCorpus() throws {
        let engine = try realEngine()
        let queries = Self.typed.flatMap { q in (1...q.count).map { String(q.prefix($0)) } } + Self.whole
        let p99 = measure(engine, queries, label: "name typing")
        #if !DEBUG
        XCTAssertLessThan(p99, 1.0, "SearchEngine.search p99 must stay under 1 ms on the real corpus")
        #endif
    }

    func testFullTextFilterLatency() throws {
        let engine = try realEngine()
        let p99 = measure(engine, Self.fullText, label: "full-text filters")
        #if !DEBUG
        // A linear scan of ~6 MB of rules text; not covered by the 1 ms target, but must stay
        // well inside a 16 ms frame.
        XCTAssertLessThan(p99, 8.0)
        #endif
    }

    /// The byte fast path + prefilters must rank exactly like the original String scorer.
    func testFastPathMatchesReferenceScoring() throws {
        let engine = try realEngine()
        var queries = ["l", "bo", "lig bol", "æth", "dûl", "the", "of", "msc", "mh2", "zq", "a b"]
        for (k, m) in engine.minis.enumerated() where k % 2_000 == 0 {
            queries.append(String(m.nameLower.prefix(4)))
            queries.append(String(m.nameLower.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).prefix(3)))
        }
        func run(_ q: String) -> [String] {
            let r = engine.searchCounted(name: q, filters: [], limit: 20)
            return r.matches.map(\.id) + ["total=\(r.total)"]
        }
        let fast = queries.map(run)
        engine.referenceScoring = true
        defer { engine.referenceScoring = false }
        for (q, f) in zip(queries, fast) { XCTAssertEqual(f, run(q), "ranking differs for \"\(q)\"") }
    }

    /// Runs each query (after a warm-up pass) and returns the p99 in ms.
    private func measure(_ engine: SearchEngine, _ queries: [String], label: String) -> Double {
        for q in queries { _ = run(engine, q) }
        #if DEBUG
        let passes = 1
        #else
        let passes = 5
        #endif
        var samples: [Double] = []
        var slowest: [String: Double] = [:]
        for _ in 0..<passes {
            for q in queries {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = run(engine, q)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                samples.append(ms)
                slowest[q] = Swift.max(slowest[q] ?? 0, ms)
            }
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p99 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.99))]
        print(String(format: "SearchEngine bench [%@]: %d cards, %d searches  p50 %.3f ms  p99 %.3f ms  max %.3f ms",
                     label, engine.minis.count, samples.count, p50, p99, samples.last ?? 0))
        for (q, ms) in slowest.sorted(by: { $0.value > $1.value }).prefix(3) {
            print(String(format: "  slowest: %@ %.3f ms", "\"\(q)\"", ms))
        }
        return p99
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
        defer { try? FileManager.default.removeItem(at: dir) }
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
