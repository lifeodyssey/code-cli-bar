import Foundation
import SQLite3
import XCTest
@testable import VibeBarCore

final class PrivacyPersistenceTests: XCTestCase {
    func testClaudeCookieMinimizationKeepsOnlySessionKey() {
        let raw = "Cookie: other=value; sessionKey=sk-ant-test-session-key; analytics=abc"

        XCTAssertEqual(
            ClaudeWebCookieStore.minimizedCookieHeader(from: raw),
            "sessionKey=sk-ant-test-session-key"
        )
        XCTAssertNil(ClaudeWebCookieStore.minimizedCookieHeader(from: "other=value"))
        XCTAssertNil(ClaudeWebCookieStore.minimizedCookieHeader(from: "sessionKey=not-claude"))
    }

    func testClaudeStoredHeadersUseKeychainBackedSources() throws {
        try SecureCookieHeaderStore.withInMemoryStoreForTesting {
            try ClaudeWebCookieStore.writeCookieHeader(
                "sessionKey=sk-ant-webview",
                source: .webView
            )
            try ClaudeWebCookieStore.writeCookieHeader(
                "sessionKey=sk-ant-browser",
                source: .browser
            )

            XCTAssertEqual(
                try ClaudeWebCookieStore.readCookieHeader(source: .browser),
                "sessionKey=sk-ant-browser"
            )
            XCTAssertEqual(
                ClaudeWebCookieStore.candidateCookieHeaders(),
                [
                    "sessionKey=sk-ant-browser",
                    "sessionKey=sk-ant-webview"
                ]
            )
        }
    }

    func testQuotaStoredPayloadOmitsAccountIdentifiers() throws {
        let quota = AccountQuota(
            accountId: "acct_real_codex",
            tool: .codex,
            buckets: [QuotaBucket(id: "five_hour", title: "5h", shortLabel: "5h", usedPercent: 42)],
            plan: "Pro",
            email: "person@example.com",
            queriedAt: Date(timeIntervalSince1970: 1_700_000_000),
            providerExtras: ProviderExtras(
                tool: .codex,
                creditsRemainingUSD: 12.34,
                creditsTopupURL: URL(string: "https://example.com/account/acct_real_codex"),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
        )

        let stored = QuotaCacheStore.StoredQuota(quota)
        let data = try JSONEncoder().encode(stored)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("acct_real_codex"))
        XCTAssertFalse(json.contains("person@example.com"))
        XCTAssertFalse(json.contains("accountId"))
        XCTAssertFalse(json.contains("email"))
        XCTAssertFalse(json.contains("creditsTopupURL"))

        let restored = stored.quota(accountId: quota.accountId)
        XCTAssertEqual(restored.accountId, quota.accountId)
        XCTAssertNil(restored.email)
        XCTAssertNil(restored.providerExtras)
    }

    func testQuotaCacheFileComponentDoesNotExposeAccountId() {
        let accountId = "acct_real_codex"
        let component = QuotaCacheStore.cacheFileComponent(for: accountId)

        XCTAssertTrue(component.hasPrefix("quota-v1-"))
        XCTAssertFalse(component.contains(accountId))
        XCTAssertEqual(component, QuotaCacheStore.cacheFileComponent(for: accountId))
        XCTAssertNotEqual(component, VibeBarLocalStore.safeFileComponent(accountId))
    }

    func testGeminiStoredQuotaNormalizesKnownBucketOrder() {
        let quota = AccountQuota(
            accountId: "gemini-web",
            tool: .gemini,
            buckets: [
                QuotaBucket(id: "weekly", title: "Weekly", shortLabel: "Weekly", usedPercent: 2),
                QuotaBucket(id: "five_hour", title: "5 Hours", shortLabel: "5 Hours", usedPercent: 0)
            ],
            queriedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let restored = QuotaCacheStore.StoredQuota(quota).quota(accountId: quota.accountId)

        XCTAssertEqual(restored.buckets.map(\.id), ["five_hour", "weekly"])
    }

    func testScanCacheStoresHashedPathKeys() throws {
        var cache = CostUsageScanCache()
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let path = "/Users/example/.codex/sessions/private-project/session.jsonl"
        let event = CostUsageScanCache.ParsedEvent(
            date: mtime,
            model: "gpt-5",
            input: 1,
            output: 2,
            cache: 3,
            sessionId: "raw-session-id",
            messageId: "raw-message-id",
            requestId: "raw-request-id",
            sourceKey: "raw-source-key",
            projectPath: "/Users/example/private-project"
        )

        cache.store([event], for: path, mtime: mtime, size: 123)

        XCTAssertNil(cache.entries[path])
        let key = try XCTUnwrap(cache.entries.keys.first)
        XCTAssertTrue(key.hasPrefix("path-v1-"))
        XCTAssertFalse(key.contains("/Users"))
        XCTAssertFalse(key.contains("private-project"))

        let data = try JSONEncoder().encode(cache)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("/Users/example"))
        XCTAssertFalse(json.contains("private-project"))
        XCTAssertFalse(json.contains("raw-session-id"))
        XCTAssertFalse(json.contains("raw-message-id"))
        XCTAssertFalse(json.contains("raw-request-id"))
        XCTAssertFalse(json.contains("raw-source-key"))
        XCTAssertEqual(cache.reusable(for: path, mtime: mtime, size: 123)?.count, 1)
        let stored = try XCTUnwrap(cache.reusable(for: path, mtime: mtime, size: 123)?.first)
        XCTAssertTrue(stored.sessionId?.hasPrefix("session-v1-") == true)
        XCTAssertTrue(stored.messageId?.hasPrefix("message-v1-") == true)
        XCTAssertTrue(stored.requestId?.hasPrefix("request-v1-") == true)
        XCTAssertTrue(stored.sourceKey?.hasPrefix("source-v1-") == true)
        XCTAssertNil(stored.projectPath)
    }

    func testScanCacheMigratesLegacyPlainPathKeyOnReuse() {
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        let path = "/Users/example/.claude/projects/private-project/session.jsonl"
        let entry = CostUsageScanCache.FileEntry(mtime: mtime, size: 456, events: [])
        var cache = CostUsageScanCache(entries: [path: entry])

        XCTAssertNotNil(cache.reusable(for: path, mtime: mtime, size: 456))
        XCTAssertNil(cache.entries[path])
        XCTAssertNotNil(cache.entries[CostUsageScanCache.entryKey(for: path)])
    }

    func testUsageLedgerPersistsOpaqueIdentifiersAndNoProjectPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeCLIBarLedgerPrivacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite3")
        let ledger = try UsageEventLedger(url: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let event = CostUsageScanCache.ParsedEvent(
            date: date,
            model: "claude-sonnet-4-5",
            input: 10,
            output: 2,
            cache: 0,
            sessionId: "raw-session-id",
            messageId: "raw-message-id",
            requestId: "raw-request-id",
            sourceKey: "raw-source-key",
            harness: .claudeCode,
            projectPath: "/Users/example/private-project"
        )
        try await ledger.ingest(UsageEventFileBatch(
            tool: .claude,
            filePath: "/Users/example/private-project/session.jsonl",
            mtime: date,
            size: 100,
            events: [PricedUsageEvent(event: event, costUSD: 0.01)]
        ))

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "SELECT project, session_id, message_id, request_id, source_key FROM usage_events LIMIT 1",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { if let statement { sqlite3_finalize(statement) } }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_type(statement, 0), SQLITE_NULL)
        let session = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 1)))
        let message = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 2)))
        let request = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 3)))
        let source = String(cString: try XCTUnwrap(sqlite3_column_text(statement, 4)))
        XCTAssertTrue(session.hasPrefix("session-v1-"))
        XCTAssertTrue(message.hasPrefix("message-v1-"))
        XCTAssertTrue(request.hasPrefix("request-v1-"))
        XCTAssertTrue(source.hasPrefix("source-v1-"))
    }

    func testUsageLedgerRestrictsMainAndSidecarPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeCLIBarLedgerPermissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite3")
        let ledger = try UsageEventLedger(url: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let event = CostUsageScanCache.ParsedEvent(
            date: date,
            model: "gpt-5",
            input: 10,
            output: 2,
            cache: 0
        )
        try await ledger.ingest(UsageEventFileBatch(
            tool: .codex,
            filePath: "/Users/example/.codex/sessions/private.jsonl",
            mtime: date,
            size: 100,
            events: [PricedUsageEvent(event: event, costUSD: 0.01)]
        ))

        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Missing SQLite file \(path)")
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o777, 0o600, "Unsafe permissions for \(path)")
        }
        _ = await ledger.contentRevision()
    }
}
