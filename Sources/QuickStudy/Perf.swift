import AppKit
import os

/// Lightweight perf instrumentation, left on in shipping builds (signposts and one log line per
/// measured interaction are cheap). Intervals show up in Instruments under Points of Interest;
/// the summary lines can be read back with:
///
///     log show --last 5m --style compact --predicate 'subsystem == "com.abbabon.quickstudy" AND category == "perf"'
///
/// Line format: `perf <name> <ms> ms [detail]`, so the numbers are easy to grep and aggregate.
@MainActor
enum Perf {
    nonisolated static let signposter = OSSignposter(subsystem: "com.abbabon.quickstudy", category: .pointsOfInterest)
    nonisolated static let log = Logger(subsystem: "com.abbabon.quickstudy", category: "perf")

    nonisolated static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Times `body` as a signpost interval and logs its duration.
    nonisolated static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let t0 = now()
        defer {
            signposter.endInterval(name, state)
            log.notice("perf \(name, privacy: .public) \(String(format: "%.2f", (now() - t0) * 1000), privacy: .public) ms")
        }
        return try body()
    }

    /// Start time for a user interaction: the timestamp of the event being handled (so time the
    /// event spent queued behind a busy main thread counts), or now if there is none.
    static func interactionStart() -> TimeInterval {
        let t = now()
        if let ts = NSApp.currentEvent?.timestamp, ts <= t, t - ts < 1 { return ts }
        return t
    }

    // MARK: - Interaction → main thread idle

    private static var pending: (name: StaticString, start: TimeInterval, detail: String, state: OSSignpostIntervalState)?
    private static var lastBeforeWaiting: TimeInterval = 0
    private static var observer: CFRunLoopObserver?

    /// Measures from `start` until the main run loop next goes idle (sleeps ≥ 8 ms) — i.e. the
    /// event, the model update, SwiftUI's re-render and the Core Animation commit have all run.
    /// This is what the user feels: the next keystroke can't be handled before that point.
    static func untilIdle(_ name: StaticString, since start: TimeInterval, detail: String = "") {
        finish()   // a new interaction ends the previous one at its last pre-sleep point
        pending = (name, start, detail, signposter.beginInterval(name))
        lastBeforeWaiting = now()
        installObserver()
    }

    private static func finish() {
        guard let p = pending else { return }
        pending = nil
        signposter.endInterval(p.name, p.state)
        let ms = (lastBeforeWaiting - p.start) * 1000
        log.notice("perf \(p.name, privacy: .public) \(String(format: "%.2f", ms), privacy: .public) ms \(p.detail, privacy: .public)")
    }

    private static func installObserver() {
        guard observer == nil else { return }
        var sleptAt: TimeInterval = 0
        // Order after Core Animation's commit observer (2_000_000) so "before waiting" means the
        // frame has been committed.
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue
                                                     | CFRunLoopActivity.afterWaiting.rawValue,
                                                     true, 2_000_001) { _, activity in
            MainActor.assumeIsolated {
                let t = now()
                if activity == .beforeWaiting {
                    lastBeforeWaiting = t
                    sleptAt = t
                } else if pending != nil, t - sleptAt >= 0.008 || t - pending!.start > 2 {
                    finish()
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs
    }
}
