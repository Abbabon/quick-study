import XCTest
@testable import QuickStudy

final class ImageCacheTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickstudy-imagecache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testSizeIsZeroForEmptyDirectory() throws {
        XCTAssertEqual(try ImageCache.size(at: tmpDir), 0)
    }

    func testSizeSumsFileBytes() throws {
        try Data(repeating: 0x41, count: 1000).write(to: tmpDir.appendingPathComponent("a.jpg"))
        try Data(repeating: 0x42, count: 2500).write(to: tmpDir.appendingPathComponent("b.jpg"))
        XCTAssertEqual(try ImageCache.size(at: tmpDir), 3500)
    }

    func testSizeIsZeroForMissingDirectory() throws {
        let missing = tmpDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(try ImageCache.size(at: missing), 0)
    }

    func testClearDeletesFilesAndReturnsBytesFreed() throws {
        try Data(repeating: 0x41, count: 1000).write(to: tmpDir.appendingPathComponent("a.jpg"))
        try Data(repeating: 0x42, count: 2500).write(to: tmpDir.appendingPathComponent("b.jpg"))
        let freed = try ImageCache.clear(at: tmpDir)
        XCTAssertEqual(freed, 3500)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmpDir.path).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.path), "directory itself should be preserved")
    }

    func testClearOnMissingDirectoryReturnsZero() throws {
        let missing = tmpDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(try ImageCache.clear(at: missing), 0)
    }
}
