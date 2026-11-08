import AppKit
import notify
import os

/// Lightweight perf instrumentation, left on in shipping builds (signposts and one log line per
/// measured interaction are cheap). Intervals show up in Instruments under Points of Interest;
/// the summary lines can be read back with:
///
///     log show --last 5m --style compact --predicate 'subsystem == "com.abbabon.quickstudy" AND category == "perf"'
///
/// Line format: `perf <name> <ms> ms [first=<ms>ms cpu=<ms>ms] [detail]`, so the numbers are easy
/// to grep and aggregate. For interactions, `<ms>` runs until the main thread is idle again,
/// `first` until the first frame was committed, and `cpu` is the main thread's CPU time over
/// the interaction (excludes time spent waiting for a core on a loaded machine).
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

    /// Timestamp of the latest key-down not yet attributed to a search (set by a local monitor).
    private static var unconsumedKeyDown: TimeInterval?
    private static var keyMonitor: Any?

    static func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            unconsumedKeyDown = e.timestamp
            return e
        }
    }

    /// Start time for a keystroke-driven search: the timestamp of the key-down that caused it (so
    /// time the event spent queued behind a busy main thread counts), or now if there is none.
    /// Each key-down is used at most once. (Reading `NSApp.currentEvent` instead backdated
    /// programmatic searches and panel opens to whatever event happened to be processed last —
    /// that is what made "warm open after Esc" look like ~425 ms under the replay hook.)
    static func keystrokeStart() -> TimeInterval {
        let t = now()
        defer { unconsumedKeyDown = nil }
        if let ts = unconsumedKeyDown, ts <= t, t - ts < 1 { return ts }
        return t
    }

    // MARK: - Interaction → main thread idle

    private static var pending: (name: StaticString, start: TimeInterval, detail: String, state: OSSignpostIntervalState)?
    private static var lastBeforeWaiting: TimeInterval = 0
    /// Main-thread CPU time at `untilIdle` and at the last pre-sleep point: robust to a busy
    /// machine, where wall-clock latency also counts time the thread waited for a core.
    private static var cpuAtStart: UInt64 = 0
    private static var cpuAtLastBeforeWaiting: UInt64 = 0
    nonisolated static func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    /// End of the first run-loop pass (incl. its Core Animation commit) after `untilIdle`:
    /// when the interaction's first frame was handed to the render server.
    private static var firstFrame: TimeInterval?
    /// Run-loop passes (each ending in a CA commit) the interaction took before going idle.
    private static var passes = 0
    private static var passCPU: [Double] = []
    private static var observer: CFRunLoopObserver?

    /// Measures from `start` until the main run loop next goes idle (sleeps ≥ 8 ms) — i.e. the
    /// event, the model update, SwiftUI's re-render and the Core Animation commit have all run.
    /// This is what the user feels: the next keystroke can't be handled before that point.
    static func untilIdle(_ name: StaticString, since start: TimeInterval, detail: String = "") {
        finish()   // a new interaction ends the previous one at its last pre-sleep point
        pending = (name, start, detail, signposter.beginInterval(name))
        lastBeforeWaiting = now()
        cpuAtStart = threadCPU()
        cpuAtLastBeforeWaiting = cpuAtStart
        firstFrame = nil
        passes = 0
        passCPU = []
        installObserver()
    }

    private static func finish() {
        guard let p = pending else { return }
        pending = nil
        signposter.endInterval(p.name, p.state)
        let ms = (lastBeforeWaiting - p.start) * 1000
        let first = ((firstFrame ?? lastBeforeWaiting) - p.start) * 1000
        let cpu = Double(cpuAtLastBeforeWaiting - cpuAtStart) / 1e6
        log.notice("perf \(p.name, privacy: .public) \(String(format: "%.2f", ms), privacy: .public) ms first=\(String(format: "%.2f", first), privacy: .public)ms cpu=\(String(format: "%.2f", cpu), privacy: .public)ms passes=\(passes, privacy: .public) [\(passCPU.map { String(format: "%.1f", $0) }.joined(separator: ","), privacy: .public)] \(p.detail, privacy: .public)")
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
                    if pending != nil, firstFrame == nil { firstFrame = t }
                    let c = threadCPU()
                    if pending != nil {
                        passes += 1
                        passCPU.append(Double(c - cpuAtLastBeforeWaiting) / 1e6)
                    }
                    lastBeforeWaiting = t
                    cpuAtLastBeforeWaiting = c
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

// MARK: - Replay hook (measurement only, off unless opted in)

extension Perf {
    /// Scripted panel-open + typing session for measuring the installed build without driving the
    /// GUI from outside. Enabled only for a launch that opts in via the argument domain (never
    /// persisted):
    ///
    ///     open -a QuickStudy --args -perfReplay YES
    ///     notifyutil -p com.abbabon.quickstudy.perf.replay
    ///
    /// Each run opens the panel, types a few queries as real key events (through NSTextView,
    /// the binding and SwiftUI, like the keyboard), deletes them, and hides the panel: ~10 s.
    static func installReplayHook(show: @escaping () -> Void, hide: @escaping () -> Void,
                                  reset: @escaping () -> Void, window: @escaping () -> NSWindow?,
                                  setQuery: @escaping (String) -> Void) {
        guard UserDefaults.standard.bool(forKey: "perfReplay") else { return }
        var token: Int32 = 0
        let status = notify_register_dispatch("com.abbabon.quickstudy.perf.replay", &token, .main) { _ in
            log.notice("perf replay start")
            MainActor.assumeIsolated { replay(show: show, hide: hide, reset: reset, window: window) }
        }
        log.notice("perf replay armed status=\(status, privacy: .public)")
        var benchToken: Int32 = 0
        notify_register_dispatch("com.abbabon.quickstudy.perf.bench", &benchToken, .main) { _ in
            MainActor.assumeIsolated { bench(show: show, hide: hide, reset: reset, window: window, setQuery: setQuery) }
        }
    }

    /// Synchronous variant for low-noise A/B on a busy machine: sets the query, forces SwiftUI
    /// update + layout + display + commit inline, and keeps the minimum main-thread CPU per step
    /// over 5 repeats (contention only ever adds time). Blocks the main thread ~1–2 s.
    private static func bench(show: () -> Void, hide: () -> Void, reset: () -> Void,
                              window: () -> NSWindow?, setQuery: (String) -> Void) {
        reset(); show()
        guard let win = window() else { return }
        func render() {
            for _ in 0..<2 {   // second pass: the search runs in the field's onChange
                CATransaction.flush()
                win.layoutIfNeeded()
                win.displayIfNeeded()
                CATransaction.flush()
            }
        }
        render()
        var steps: [String] = []
        for w in ["lightning bolt", "llanowar elves", "sol ring"] {
            for i in 1...w.count { steps.append(String(w.prefix(i))) }
            for i in stride(from: w.count - 1, through: 0, by: -1) { steps.append(String(w.prefix(i))) }
        }
        var best = Array(repeating: UInt64.max, count: steps.count)
        // Optional idle gap before each step (-perfBenchGapMs 100) to mimic typing pace: the core
        // clocks down / work may land on an efficiency core between keys.
        let gap = UInt32(UserDefaults.standard.integer(forKey: "perfBenchGapMs")) * 1000
        for _ in 0..<(gap > 0 ? 2 : 5) {   // gapped runs are slow; keep them ~15 s
            for (k, q) in steps.enumerated() {
                if gap > 0 { usleep(gap) }
                let c0 = threadCPU()
                setQuery(q)
                render()
                best[k] = min(best[k], threadCPU() - c0)
            }
        }
        let slow = zip(steps, best).sorted { $0.1 > $1.1 }.prefix(8)
            .map { "\($0.0)=\(String(format: "%.1f", Double($0.1) / 1e6))" }.joined(separator: " ")
        log.notice("perf bench slowest \(slow, privacy: .public)")
        let ms = best.map { Double($0) / 1e6 }.sorted()
        log.notice("perf bench steps=\(ms.count, privacy: .public) p50=\(String(format: "%.2f", ms[ms.count / 2]), privacy: .public)ms p90=\(String(format: "%.2f", ms[ms.count * 9 / 10]), privacy: .public)ms max=\(String(format: "%.2f", ms.last ?? 0), privacy: .public)ms mean=\(String(format: "%.2f", ms.reduce(0, +) / Double(ms.count)), privacy: .public)ms")
        hide()
    }

    private static func replay(show: @escaping () -> Void, hide: @escaping () -> Void,
                               reset: @escaping () -> Void, window: @escaping () -> NSWindow?) {
        let words = ["lightning bolt", "llanowar elves", "sol ring"]
        var steps: [() -> Void] = []
        for w in words {
            steps.append(reset)
            steps.append(show)
            steps.append {}                                    // let the open settle
            for c in w { steps.append { key(String(c)) } }
            steps.append {}
            for _ in w { steps.append { key("\u{7F}", code: 51) } }
            steps.append(hide)
            steps.append {}
        }
        let previous = NSWorkspace.shared.frontmostApplication
        steps.append { previous?.activate() }                  // hand focus back to the user's app
        func key(_ chars: String, code: UInt16 = 0) {
            guard let win = window(), let e = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: now(),
                windowNumber: win.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
            NSApp.postEvent(e, atStart: false)
        }
        func run(_ i: Int) {
            guard i < steps.count else { return }
            steps[i]()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { run(i + 1) }
        }
        run(0)
    }
}

// MARK: - Fetcher smoke hook (debug/verification only, off unless opted in)

extension Perf {
    /// Triggers fetcher runs without driving the GUI — used to verify the bundled `mtg-fetcher`
    /// end-to-end inside the App Sandbox. Armed only for a launch that opts in:
    ///
    ///     open -a QuickStudy --args -debugFetcher YES
    ///     notifyutil -p com.abbabon.quickstudy.debug.refresh   # json → ingest → sets → printings
    ///     notifyutil -p com.abbabon.quickstudy.debug.images    # images for the on-disk bulk file
    static func installFetcherHook(refresh: @escaping () -> Void, images: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "debugFetcher") else { return }
        var t1: Int32 = 0, t2: Int32 = 0
        notify_register_dispatch("com.abbabon.quickstudy.debug.refresh", &t1, .main) { _ in refresh() }
        notify_register_dispatch("com.abbabon.quickstudy.debug.images", &t2, .main) { _ in images() }
        log.notice("debug fetcher hook armed")
    }
}
