import Foundation
import Shared

/// Thread-safe line buffer used by FetcherProcess to split stdout into NDJSON lines.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    /// Appends a chunk and returns any complete lines (without the trailing newline).
    func append(_ chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(data.subdata(in: 0..<nl))
            data.removeSubrange(0...nl)
        }
        return lines
    }
}

/// Spawns the bundled `mtg-fetcher` executable and streams its NDJSON progress events.
final class FetcherProcess {
    struct Event {
        let phase: String
        let done: Int?
        let total: Int?
        let message: String?
        let newCards: Int?
    }

    enum Mode {
        case full           // json → ingest → sets → printings → images
        case ingestOnly     // json → ingest (no images, no printings) — silent background sync
        case ingestPrintings // json → ingest → sets → printings (no images) — manual text-only refresh
        case imagesOnly     // reuse bulk JSON → images only
        case ingestArtwork  // unique_artwork → artwork metadata (no images)
        case downloadAllArt // unique_artwork → metadata + all art_crops

        var arguments: [String] {
            switch self {
            case .full: return ["--printings"]
            case .ingestOnly: return ["--no-images"]
            case .ingestPrintings: return ["--no-images", "--printings"]
            case .imagesOnly: return ["--images-only"]
            case .ingestArtwork: return ["--artwork"]
            case .downloadAllArt: return ["--artwork", "--download-art"]
            }
        }
    }

    private struct EventDecoded: Decodable {
        let phase: String
        let done: Int?
        let total: Int?
        let message: String?
        let newCards: Int?
    }

    /// Resolves the path to `mtg-fetcher`.
    /// Look order:
    ///   1. `MTG_FETCHER_PATH` env var (dev override)
    ///   2. Sibling in the same bundle's Contents/MacOS directory
    ///   3. Sibling in the same directory as the running executable (Swift CLI run)
    private func resolveFetcherPath() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MTG_FETCHER_PATH"] {
            return URL(fileURLWithPath: override)
        }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let dir = exe.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("mtg-fetcher")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Runs the fetcher and yields events as they arrive on stdout.
    func run(mode: Mode, onEvent: @escaping (Event) -> Void) async {
        guard let path = resolveFetcherPath() else {
            onEvent(Event(phase: "error", done: nil, total: nil, message: "mtg-fetcher not found", newCards: nil))
            return
        }
        let process = Process()
        process.executableURL = path
        process.arguments = mode.arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let buffer = LineBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            for line in buffer.append(chunk) {
                if let decoded = try? JSONDecoder().decode(EventDecoded.self, from: line) {
                    onEvent(Event(phase: decoded.phase, done: decoded.done, total: decoded.total,
                                  message: decoded.message, newCards: decoded.newCards))
                }
            }
        }

        do {
            try process.run()
        } catch {
            onEvent(Event(phase: "error", done: nil, total: nil, message: "spawn failed: \(error)", newCards: nil))
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume()
            }
        }
        onEvent(Event(phase: "exit", done: nil, total: nil, message: nil, newCards: nil))
    }
}
