import XCTest
@testable import VibeBarCore

final class VibeBarImportServiceTests: XCTestCase {
    func testPreviewAndImportAreReadOnlyFilteredAndIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeCLIBarVibeImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("legacy.json")
        let original = Data(#"""
        {
          "schemaVersion": 2,
          "entries": [
            {"tool":"codex","date":"2026-08-28","costUSD":1.25,"totalTokens":100},
            {"tool":"codex","date":"2026-08-28","costUSD":1.50,"totalTokens":120},
            {"tool":"claude","date":"2026-08-29","costUSD":2.00,"totalTokens":200},
            {"tool":"gemini","date":"2026-08-29","costUSD":99.00,"totalTokens":999},
            {"tool":"grok","date":"2026-08-30","costUSD":-1.00,"totalTokens":100}
          ]
        }
        """#.utf8)
        try original.write(to: source)
        let destinationURL = directory.appendingPathComponent("destination.json")
        let destination = CostHistoryStore(fileURL: destinationURL)
        let service = VibeBarImportService(sourceURL: source)

        let preview = try await service.preview()

        XCTAssertEqual(preview.providers.map(\.provider), [.claudeCode, .codex])
        XCTAssertEqual(preview.dayCount, 2)
        XCTAssertEqual(preview.totalCostUSD, 3.5, accuracy: 0.001)
        XCTAssertEqual(preview.totalTokens, 320)

        _ = try await service.importCostHistory(into: destination)
        _ = try await service.importCostHistory(into: destination)
        let codex = await destination.history(
            for: .codex,
            days: nil,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )
        let claude = await destination.history(
            for: .claude,
            days: nil,
            retentionDays: CostDataSettings.unlimitedRetentionDays
        )

        XCTAssertEqual(codex.days.count, 1)
        XCTAssertEqual(codex.days.first?.costUSD ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(codex.days.first?.totalTokens, 120)
        XCTAssertEqual(claude.days.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), original, "preview/import must never rewrite Vibe Bar data")
    }
}
