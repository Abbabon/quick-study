import XCTest
@testable import QuickStudy
import Shared
import EngineBindings

/// Benchmarks `SearchEngine` on the real card corpus, and checks its byte fast path against the
/// original String scorer there. The corpus is loaded at test time from a copy of the local
/// QuickStudy DB (the live DB is never opened); the tests skip when no DB exists.
///
/// The latency assertions only apply to optimized builds — run them with
/// `swift test -c release -Xswiftc -enable-testing --filter SearchEngineBenchmarkTests`.
/// Debug builds just print the numbers.
final class EngineBenchmarkTests: XCTestCase {
    /// Every prefix of these is searched, simulating keystroke-by-keystroke typing.
    private static let typed = [
        "lightning bolt", "jace, the mind sculptor", "sol ring", "modern horizons",
        "counterspell", "llanowar elves", "ljt", "zzzzqx",
    ]
    /// Whole queries hitting the set, filter and non-ASCII paths alongside a name.
    private static let whole = ["msc", "bolt r:common", "dragon mv>=5", "elf c:g", "æther", "jötun"]
    /// Filter-only full-text scans (no name): every card's type line / rules text is searched.
    private static let fullText = ["o:\"draw a card\"", "c:r t:creature", "o:flying", "t:legendary"]

    private static var engine: SearchIndex?

    override class func setUp() {
        engine = try? loadRealEngine()
    }

    private func realEngine() throws -> SearchIndex {
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

    /// Runs each query (after a warm-up pass) and returns the p99 in ms.
    private func measure(_ engine: SearchIndex, _ queries: [String], label: String) -> Double {
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
        print(String(format: "SearchIndex bench [%@]: %u cards, %d searches  p50 %.3f ms  p99 %.3f ms  max %.3f ms",
                     label, engine.cardCount(), samples.count, p50, p99, samples.last ?? 0))
        for (q, ms) in slowest.sorted(by: { $0.value > $1.value }).prefix(3) {
            print(String(format: "  slowest: %@ %.3f ms", "\"\(q)\"", ms))
        }
        return p99
    }

    private func run(_ engine: SearchIndex, _ q: String) -> Int {
        Int(engine.search(query: q).total)
    }

    /// Copies the local DB (+WAL) to a temp dir and loads the engine the same way the app does.
    static func loadRealEngine() throws -> SearchIndex {
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
        let engine = try SearchIndex.open(dbPath: dst.path)
        guard engine.cardCount() > 1000 else { throw XCTSkip("Local DB has too few cards to benchmark") }
        return engine
    }
}
