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
    /// Main-thread CPU time at `untilIdle` and at the last pre-sleep point: robust to a busy
    /// machine, where wall-clock latency also counts time the thread waited for a core.
    private static var cpuAtStart: UInt64 = 0
    private static var cpuAtLastBeforeWaiting: UInt64 = 0
    nonisolated static func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    /// End of the first run-loop pass (incl. its Core Animation commit) after `untilIdle`:
    /// when the interaction's first frame was handed to the render server.
    private static var firstFrame: TimeInterval?
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
        installObserver()
    }

    private static func finish() {
        guard let p = pending else { return }
        pending = nil
        signposter.endInterval(p.name, p.state)
        let ms = (lastBeforeWaiting - p.start) * 1000
        let first = ((firstFrame ?? lastBeforeWaiting) - p.start) * 1000
        let cpu = Double(cpuAtLastBeforeWaiting - cpuAtStart) / 1e6
        log.notice("perf \(p.name, privacy: .public) \(String(format: "%.2f", ms), privacy: .public) ms first=\(String(format: "%.2f", first), privacy: .public)ms cpu=\(String(format: "%.2f", cpu), privacy: .public)ms \(p.detail, privacy: .public)")
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
                    lastBeforeWaiting = t
                    cpuAtLastBeforeWaiting = threadCPU()
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
                                  reset: @escaping () -> Void, window: @escaping () -> NSWindow?) {
        guard UserDefaults.standard.bool(forKey: "perfReplay") else { return }
        var token: Int32 = 0
        let status = notify_register_dispatch("com.abbabon.quickstudy.perf.replay", &token, .main) { _ in
            log.notice("perf replay start")
            MainActor.assumeIsolated { replay(show: show, hide: hide, reset: reset, window: window) }
        }
        log.notice("perf replay armed status=\(status, privacy: .public)")
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
