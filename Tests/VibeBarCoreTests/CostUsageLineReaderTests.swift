import XCTest
@testable import VibeBarCore

final class CostUsageLineReaderTests: XCTestCase {
    func testChunkBoundariesBlankLinesAndUnterminatedTail() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = [
            Data(repeating: 0x61, count: 65_535),
            Data("中文🙂\r".utf8),
            Data(repeating: 0x62, count: 3 * 65_536 + 17),
            Data("tail".utf8)
        ]
        var input = Data([0x0A])
        for line in expected.dropLast() {
            input.append(line)
            input.append(contentsOf: [0x0A, 0x0A])
        }
        input.append(expected.last!)
        try input.write(to: file)
        var actual: [Data] = []
        // Exercise the production entry point and retain records beyond the
        // callback, including beyond buffer compaction and pool drainage.
        XCTAssertTrue(CostUsageScanner.forEachJSONLLine(in: file) { actual.append($0) })
        XCTAssertEqual(actual, expected)
    }

    func testEmptyFileAndReadFailures() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var calls = 0
        XCTAssertFalse(CostUsageScanner.forEachJSONLLine(in: file) { _ in calls += 1 })
        try Data().write(to: file)
        XCTAssertTrue(CostUsageScanner.forEachJSONLLine(in: file) { _ in calls += 1 })
        let handle = try FileHandle(forReadingFrom: file)
        try handle.close()
        XCTAssertFalse(CostUsageLineReader.forEachLine(from: handle) { _ in calls += 1 })
        XCTAssertEqual(calls, 0)
    }
}
