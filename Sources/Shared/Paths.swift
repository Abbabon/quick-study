import Foundation

public enum Paths {
    public static let appName = "QuickStudy"
    private static let legacyAppName = "MTGSpotlight"

    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        // One-time migration from the old name. If the legacy dir exists and the new
        // one doesn't, move it so the user keeps their card DB and image cache.
        let legacy = base.appendingPathComponent(legacyAppName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) && fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var imagesDir: URL {
        let dir = supportDir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var databaseURL: URL {
        supportDir.appendingPathComponent("cards.sqlite", isDirectory: false)
    }

    public static var logsDir: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs/\(appName)", isDirectory: true)
        let legacy = base.appendingPathComponent("Logs/\(legacyAppName)", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) && fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var fetcherLogURL: URL {
        logsDir.appendingPathComponent("fetcher.log", isDirectory: false)
    }

    public static func imageURL(forCardID id: String) -> URL {
        imagesDir.appendingPathComponent("\(id).jpg", isDirectory: false)
    }
}
