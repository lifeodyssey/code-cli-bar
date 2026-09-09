import XCTest
@testable import VibeBarCore

final class CostUsageScanCacheSizeTests: XCTestCase {
    func testCacheAbovePrevious64MiBLimitRemainsReusable() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = "/Users/example/.claude/projects/session.jsonl"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var cache = CostUsageScanCache(retentionDays: 365)
        cache.store([
            .init(date: date, model: "synthetic-model", input: 12, output: 34, cache: 56)
        ], for: path, mtime: date, size: 123)
        cache.save(homeDirectory: home.path, tool: .claude)
        let file = CostUsageScanCache.fileURL(homeDirectory: home.path, tool: .claude)
        let handle = try FileHandle(forWritingTo: file)
        // JSON whitespace crosses the old guard without making a large
        // object graph or spending CI memory constructing 135k events.
        try handle.seekToEnd()
        let padding = Data(repeating: 0x20, count: 1024 * 1024)
        for _ in 0..<65 { try handle.write(contentsOf: padding) }
        try handle.close()

        var loaded = CostUsageScanCache.load(homeDirectory: home.path, tool: .claude, retentionDays: 365)
        let events = try XCTUnwrap(loaded.reusable(for: path, mtime: date, size: 123))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.input, 12)
        XCTAssertEqual(events.first?.output, 34)
        XCTAssertEqual(events.first?.cache, 56)
        XCTAssertNil(loaded.reusable(for: path, mtime: date, size: 124))
    }

    func testOversizedCacheStillFailsClosed() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        CostUsageScanCache().save(homeDirectory: home.path, tool: .claude)
        let file = CostUsageScanCache.fileURL(homeDirectory: home.path, tool: .claude)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(CostUsageScanCache.maxFileBytes + 1))
        try handle.close()
        let loaded = CostUsageScanCache.load(homeDirectory: home.path, tool: .claude)
        XCTAssertTrue(loaded.entries.isEmpty)
    }
}
