import AppKit
import Foundation

/// Installs app updates without a third-party framework. Two paths, chosen by how the app
/// was installed:
///
/// - **Homebrew** (`~/Library/Caskroom/quick-study` present): a detached helper runs
///   `brew upgrade --cask quick-study` *after* we quit (so brew isn't fighting a running app),
///   then relaunches.
/// - **Manual** (dragged to /Applications): we download the release's `QuickStudy-<ver>.zip`,
///   extract + verify it, then a detached helper swaps the new bundle over the running one and
///   relaunches. Swapping a running bundle has to happen from outside the process, hence the
///   helper that waits for our PID to exit.
///
/// All of this requires a real `.app` bundle and an unsandboxed process — both true here
/// (the app already shells out to `mtg-fetcher`). Under `swift run` there is no bundle, so
/// callers gate on `isRunningFromAppBundle`.
enum AppUpdater {
    enum InstallKind: Equatable { case homebrew, manual }

    enum UpdateError: LocalizedError {
        case extractFailed
        case bundleNotFound
        case signatureInvalid
        case versionMismatch(expected: String, got: String?)
        case brewNotFound
        case notAnAppBundle

        var errorDescription: String? {
            switch self {
            case .extractFailed: return "Could not unpack the downloaded update."
            case .bundleNotFound: return "The downloaded update did not contain QuickStudy.app."
            case .signatureInvalid: return "The downloaded update failed code-signature verification."
            case let .versionMismatch(expected, got):
                return "The downloaded update was \(got ?? "an unknown version"), expected \(expected)."
            case .brewNotFound: return "Homebrew was not found, so the update could not be installed."
            case .notAnAppBundle: return "Self-update is only available from the installed app."
            }
        }
    }

    /// True only when running from a `.app` bundle (false under `swift run`).
    static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Homebrew installs always have a Caskroom entry; everything else is a manual install.
    static func detect() -> InstallKind {
        let caskroom = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caskroom/quick-study")
        return FileManager.default.fileExists(atPath: caskroom.path) ? .homebrew : .manual
    }

    // MARK: - Manual path

    /// Downloads the release zip, extracts and verifies the bundle, and returns the staged
    /// `.app` URL (in a temp dir) ready to be swapped in. Throws on any failure.
    static func downloadAndStage(zipURL: URL, expectedVersion: String) async throws -> URL {
        let (downloaded, _) = try await URLSession.shared.download(from: zipURL)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickStudyUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // `download(from:)` deletes its temp file when this scope ends, so move it first.
        let zipCopy = workDir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: downloaded, to: zipCopy)

        let extractDir = workDir.appendingPathComponent("extracted")
        guard try run("/usr/bin/ditto", ["-x", "-k", zipCopy.path, extractDir.path]) == 0 else {
            throw UpdateError.extractFailed
        }

        let stagedApp = extractDir.appendingPathComponent("QuickStudy.app")
        guard FileManager.default.fileExists(atPath: stagedApp.path) else {
            throw UpdateError.bundleNotFound
        }

        guard try run("/usr/bin/codesign", ["--verify", "--deep", stagedApp.path]) == 0 else {
            throw UpdateError.signatureInvalid
        }

        let plist = stagedApp.appendingPathComponent("Contents/Info.plist")
        let got = NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String
        guard got == expectedVersion else {
            throw UpdateError.versionMismatch(expected: expectedVersion, got: got)
        }

        return stagedApp
    }

    /// Spawns a detached helper that waits for us to quit, swaps `stagedApp` over the running
    /// bundle (with rollback on failure), strips quarantine, and relaunches — then terminates.
    @MainActor
    static func installStagedAndRelaunch(stagedApp: URL) throws {
        guard isRunningFromAppBundle else { throw UpdateError.notAnAppBundle }
        let target = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        PID="$1"; STAGED="$2"; TARGET="$3"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BACKUP="${TARGET}.bak.$$"
        if mv "$TARGET" "$BACKUP" 2>/dev/null; then
          if /usr/bin/ditto "$STAGED" "$TARGET" 2>/dev/null; then
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
            rm -rf "$BACKUP"
          else
            rm -rf "$TARGET"
            mv "$BACKUP" "$TARGET"
          fi
        fi
        /usr/bin/open "$TARGET"
        """
        try spawnDetachedHelper(script: script,
                                args: [String(pid), stagedApp.path, target])
        NSApp.terminate(nil)
    }

    // MARK: - Homebrew path

    /// Spawns a detached helper that waits for us to quit, runs `brew upgrade --cask
    /// quick-study`, and relaunches — then terminates.
    @MainActor
    static func brewUpgradeAndRelaunch() throws {
        guard let brew = brewPath() else { throw UpdateError.brewNotFound }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        PID="$1"; BREW="$2"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        "$BREW" upgrade --cask quick-study
        /usr/bin/open -a "QuickStudy"
        """
        try spawnDetachedHelper(script: script, args: [String(pid), brew])
        NSApp.terminate(nil)
    }

    private static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    // MARK: - Helpers

    /// Writes `script` to a temp file and launches it under `/bin/sh`, detached — we do not
    /// wait, so it outlives the app it's about to replace.
    private static func spawnDetachedHelper(script: String, args: [String]) throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickstudy-update-\(UUID().uuidString).sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path.path] + args
        try process.run()
    }

    /// Runs a tool to completion and returns its exit status.
    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
