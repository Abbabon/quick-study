import Foundation

/// Pure helpers for measuring and clearing a directory of cached image
/// files. The directory itself is preserved on `clear` so the fetcher
/// can write into it again on the next refresh.
enum ImageCache {
    /// Total size in bytes of all regular files directly inside `dir`.
    /// Returns 0 if the directory does not exist.
    static func size(at dir: URL) throws -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let entries = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var total: Int64 = 0
        for url in entries {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, let bytes = values.fileSize {
                total += Int64(bytes)
            }
        }
        return total
    }

    /// Deletes all regular files inside `dir` (keeping `dir` itself).
    /// Returns the number of bytes freed. Returns 0 for a missing dir.
    @discardableResult
    static func clear(at dir: URL) throws -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let entries = try fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var freed: Int64 = 0
        for url in entries {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true {
                if let bytes = values.fileSize { freed += Int64(bytes) }
                try fm.removeItem(at: url)
            }
        }
        return freed
    }
}
