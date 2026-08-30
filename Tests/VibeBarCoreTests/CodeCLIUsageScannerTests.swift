import SQLite3
import XCTest
@testable import VibeBarCore

final class CodeCLIUsageScannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    func testOpenCodeGoReadsReportedCostAndOnlyGoProvider() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent(".local/share/opencode/opencode.db")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try openDatabase(database)
        defer { sqlite3_close(db) }
        try execute(
            """
            CREATE TABLE message(
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL, data TEXT NOT NULL
            )
            """,
            db: db
        )
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        try insertMessage(
            id: "raw-message-id",
            session: "raw-session-id",
            timestamp: timestamp,
            object: [
                "role": "assistant", "providerID": "opencode-go",
                "modelID": "deepseek-v4-flash",
                "time": ["created": timestamp],
                "tokens": [
                    "input": 1_000, "output": 500, "reasoning": 25,
                    "cache": ["read": 100, "write": 20]
                ],
                "cost": 0.0123
            ],
            db: db
        )
        try insertMessage(
            id: "other-provider-message",
            session: "other-provider-session",
            timestamp: timestamp,
            object: [
                "role": "assistant", "providerID": "openai", "modelID": "gpt-test",
                "time": ["created": timestamp],
                "tokens": ["input": 99_000, "output": 99_000, "reasoning": 0,
                           "cache": ["read": 0, "write": 0]],
                "cost": 99
            ],
            db: db
        )

        let scanned = await CostUsageScanner.scan(
            tool: .openCodeGo,
            homeDirectory: home.path,
            now: now
        )
        let snapshot = try XCTUnwrap(scanned)
        XCTAssertEqual(snapshot.allTimeTokens, 1_645)
        XCTAssertEqual(snapshot.allTimeRequests, 1)
        XCTAssertEqual(snapshot.allTimeCostUSD, 0.0123, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.allTimeUnpricedRequests, 0)

        let cache = try String(
            contentsOf: CostUsageScanCache.fileURL(homeDirectory: home.path, tool: .openCodeGo),
            encoding: .utf8
        )
        XCTAssertFalse(cache.contains("raw-message-id"))
        XCTAssertFalse(cache.contains("raw-session-id"))
    }

    func testKimiCountsTurnRecordsButNotSessionSummaryAndEstimatesK3() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent("custom-kimi")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let usage: [String: Any] = [
            "inputOther": 1_000_000,
            "output": 1_000_000,
            "inputCacheRead": 1_000_000,
            "inputCacheCreation": 1_000_000
        ]
        let lines = try [
            jsonLine([
                "type": "usage.record", "usageScope": "turn", "agentId": "agent-raw",
                "model": "kimi-code/k3", "time": timestamp, "usage": usage
            ]),
            jsonLine([
                "type": "usage.record", "usageScope": "session", "agentId": "agent-raw",
                "model": "kimi-code/k3", "time": timestamp, "usage": usage
            ])
        ]
        try lines.joined(separator: "\n").write(
            to: source.appendingPathComponent("wire.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let scanned = await CostUsageScanner.scan(
            tool: .kimi,
            homeDirectory: home.path,
            now: now,
            sourcePath: source.path
        )
        let snapshot = try XCTUnwrap(scanned)
        XCTAssertEqual(snapshot.allTimeTokens, 4_000_000)
        XCTAssertEqual(snapshot.allTimeRequests, 1)
        XCTAssertEqual(snapshot.allTimeCostUSD, 21.3, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.allTimeUnpricedRequests, 0)
    }

    func testZCodeSeparatesCachedInputAndMarksUnknownPrice() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent(".zcode/cli/db/db.sqlite")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try openDatabase(database)
        defer { sqlite3_close(db) }
        try execute(
            """
            CREATE TABLE model_usage(
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, model_id TEXT NOT NULL,
                status TEXT NOT NULL, started_at INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER NOT NULL,
                cache_creation_input_tokens INTEGER NOT NULL,
                cache_read_input_tokens INTEGER NOT NULL
            );
            """,
            db: db
        )
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        try execute(
            """
            INSERT INTO model_usage VALUES(
                'usage-1', 'session-1', 'GLM-5.3-Flash', 'completed', \(timestamp),
                1000, 200, 0, 100, 300
            );
            INSERT INTO model_usage VALUES(
                'usage-running', 'session-1', 'GLM-5.3-Flash', 'running', \(timestamp),
                9000, 9000, 0, 0, 0
            );
            """,
            db: db
        )

        let scanned = await CostUsageScanner.scan(
            tool: .zai,
            homeDirectory: home.path,
            now: now
        )
        let snapshot = try XCTUnwrap(scanned)
        XCTAssertEqual(snapshot.allTimeTokens, 1_200)
        XCTAssertEqual(snapshot.allTimeRequests, 1)
        XCTAssertEqual(snapshot.allTimeCostUSD, 0)
        XCTAssertEqual(snapshot.allTimeUnpricedRequests, 1)
    }

    func testDSHDeduplicatesCopiedMessageAndUsesGoAccountingRate() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".dsh/sessions")
        let first = sessions.appendingPathComponent("one")
        let second = sessions.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let transcript = try [
            jsonLine(["type": "session", "id": "raw-dsh-session", "createdAt": timestamp]),
            jsonLine([
                "type": "request/context", "time": timestamp,
                "data": ["provider": "opencode-go", "model": "deepseek-v4-flash"]
            ]),
            jsonLine([
                "type": "assistant/message", "time": timestamp,
                "data": [
                    "message": ["id": "raw-dsh-message"],
                    "usage": [
                        "inputTokens": 1_000_000, "outputTokens": 1_000_000,
                        "cacheReadTokens": 1_000_000
                    ]
                ]
            ])
        ].joined(separator: "\n")
        try transcript.write(
            to: first.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8
        )
        try transcript.write(
            to: second.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8
        )

        let scanned = await CostUsageScanner.scan(
            tool: .dsh,
            homeDirectory: home.path,
            now: now
        )
        let snapshot = try XCTUnwrap(scanned)
        XCTAssertEqual(snapshot.jsonlFilesFound, 2)
        XCTAssertEqual(snapshot.allTimeTokens, 3_000_000)
        XCTAssertEqual(snapshot.allTimeRequests, 1)
        XCTAssertEqual(snapshot.allTimeCostUSD, 0.4228, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.allTimeUnpricedRequests, 0)

        let cache = try String(
            contentsOf: CostUsageScanCache.fileURL(homeDirectory: home.path, tool: .dsh),
            encoding: .utf8
        )
        XCTAssertFalse(cache.contains("raw-dsh-session"))
        XCTAssertFalse(cache.contains("raw-dsh-message"))
    }

    // MARK: - Fixtures

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeCLIUsageScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openDatabase(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "CodeCLIUsageScannerTests", code: 1)
        }
        return database
    }

    private func execute(_ sql: String, db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(error)
            throw NSError(
                domain: "CodeCLIUsageScannerTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func insertMessage(
        id: String,
        session: String,
        timestamp: Int64,
        object: [String: Any],
        db: OpaquePointer
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO message(id, session_id, time_created, data) VALUES(?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(domain: "CodeCLIUsageScannerTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, session, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, timestamp)
        sqlite3_bind_text(statement, 4, json, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "CodeCLIUsageScannerTests", code: 4)
        }
    }

    private func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
