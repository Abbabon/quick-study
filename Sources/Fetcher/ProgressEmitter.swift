import Foundation

/// Emits structured NDJSON progress events to stdout so the parent app
/// can stream them into the UI. Also mirrors human-readable lines to the log file.
public final class ProgressEmitter {
    private let logHandle: FileHandle?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    public init(logURL: URL) {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        self.logHandle = try? FileHandle(forWritingTo: logURL)
        try? logHandle?.seekToEnd()
    }

    public struct Event: Encodable {
        public let phase: String        // "json" | "ingest" | "images" | "done" | "error"
        public let done: Int?
        public let total: Int?
        public let message: String?
    }

    public func emit(phase: String, done: Int? = nil, total: Int? = nil, message: String? = nil) {
        let event = Event(phase: phase, done: done, total: total, message: message)
        if let data = try? encoder.encode(event),
           var line = String(data: data, encoding: .utf8) {
            line.append("\n")
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let human = "[\(stamp)] \(phase) done=\(done.map(String.init) ?? "-") total=\(total.map(String.init) ?? "-") \(message ?? "")\n"
        logHandle?.write(Data(human.utf8))
    }
}
