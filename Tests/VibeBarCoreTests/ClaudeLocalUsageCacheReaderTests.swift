import XCTest
@testable import VibeBarCore

final class ClaudeLocalUsageCacheReaderTests: XCTestCase {
    func testUsableCLIUsageCacheDiscoversAReadOnlyClaudeAccount() {
        let now = Date()
        let fetchedAtMilliseconds = Int(now.addingTimeInterval(-86_400).timeIntervalSince1970 * 1_000)
        let weeklyReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 86_400))
        let data = Data(
            """
            {
              "cachedUsageUtilization": {
                "fetchedAtMs": \(fetchedAtMilliseconds),
                "utilization": {
                  "seven_day": {
                    "utilization": 63,
                    "resets_at": "\(weeklyReset)"
                  }
                }
              }
            }
            """.utf8
        )

        let account = ClaudeLocalUsageCacheReader.detectedAccount(data: data, now: now)

        XCTAssertEqual(account?.id, "cli-claude")
        XCTAssertEqual(account?.tool, .claude)
        XCTAssertEqual(account?.alias, "Claude Code")
        XCTAssertEqual(account?.source, .cliDetected)
    }

    func testCachedCLIUsageProvidesTheWeeklyReset() throws {
        let json = """
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": 1700000000000,
            "utilization": {
              "five_hour": {
                "utilization": 27,
                "resets_at": "2026-08-30T16:00:00Z"
              },
              "seven_day": {
                "utilization": 81,
                "resets_at": "2026-08-31T02:00:00Z"
              }
            }
          }
        }
        """
        let account = AccountIdentity(
            id: "claude-local",
            tool: .claude,
            plan: "Claude subscription",
            source: .cliDetected
        )

        let quota = try ClaudeLocalUsageCacheReader.parse(
            data: Data(json.utf8),
            for: account
        )

        XCTAssertEqual(quota.accountId, "claude-local")
        XCTAssertEqual(quota.tool, .claude)
        XCTAssertEqual(quota.queriedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(quota.bucket(id: "five_hour")?.usedPercent, 27)
        XCTAssertEqual(quota.weeklyBucket?.usedPercent, 81)
        XCTAssertEqual(
            quota.weeklyBucket?.resetAt,
            ISO8601DateFormatter().date(from: "2026-08-31T02:00:00Z")
        )
        XCTAssertEqual(quota.weeklyBucket?.rawWindowSeconds, 604_800)
    }

    func testAdapterUsesTheCLICacheWhenAuthenticationIsUnavailable() async throws {
        let now = Date()
        let fetchedAtMilliseconds = Int(now.addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        let weeklyReset = now.addingTimeInterval(3 * 86_400)
        let weeklyResetText = ISO8601DateFormatter().string(from: weeklyReset)
        let json = Data(
            """
            {
              "cachedUsageUtilization": {
                "fetchedAtMs": \(fetchedAtMilliseconds),
                "utilization": {
                  "seven_day": {
                    "utilization": 63,
                    "resets_at": "\(weeklyResetText)"
                  }
                }
              }
            }
            """.utf8
        )
        let adapter = ClaudeQuotaAdapter(
            credentialResolver: { _, _ in throw QuotaError.noCredential },
            reimportWebCookieOnStale: { false },
            localUsageCacheResolver: { account in
                try ClaudeLocalUsageCacheReader.parse(data: json, for: account)
            }
        )
        let account = AccountIdentity(
            id: "claude-local",
            tool: .claude,
            source: .cliDetected
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.weeklyBucket?.usedPercent, 63)
        XCTAssertEqual(
            quota.weeklyBucket?.resetAt,
            ISO8601DateFormatter().date(from: weeklyResetText)
        )
    }

    /// Regression: a provider-authored reset can still be in the future while
    /// the percentage beside it is days out of date. The fallback must not
    /// present that old percentage as a successful live refresh.
    func testAdapterDoesNotPresentStaleCLICacheAsLiveQuota() async {
        let now = Date()
        let staleQuota = AccountQuota(
            accountId: "claude-stale-fallback",
            tool: .claude,
            buckets: [
                QuotaBucket(
                    id: "weekly",
                    title: "Weekly",
                    shortLabel: "Weekly",
                    usedPercent: 81,
                    resetAt: now.addingTimeInterval(12 * 3_600),
                    rawWindowSeconds: 604_800
                )
            ],
            queriedAt: now.addingTimeInterval(-3 * 86_400)
        )
        let adapter = ClaudeQuotaAdapter(
            credentialResolver: { _, _ in throw QuotaError.noCredential },
            reimportWebCookieOnStale: { false },
            localUsageCacheResolver: { _ in staleQuota }
        )
        let account = AccountIdentity(
            id: staleQuota.accountId,
            tool: .claude,
            source: .cliDetected
        )

        do {
            _ = try await adapter.fetch(for: account)
            XCTFail("A three-day-old quota snapshot must not be returned as live data")
        } catch let error as QuotaError {
            XCTAssertEqual(error, .noCredential)
        } catch {
            XCTFail("Expected QuotaError.noCredential, got \(error)")
        }
    }

    func testAdapterSupplementsPartialLiveUsageWithCurrentCLIWeeklyBucket() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudePartialUsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let now = Date()
        let localQueriedAt = now.addingTimeInterval(-60)
        let weeklyReset = now.addingTimeInterval(3 * 86_400)
        ClaudePartialUsageURLProtocol.oauthUsageData = Data(
            #"{"five_hour":{"utilization":12}}"#.utf8
        )

        let adapter = ClaudeQuotaAdapter(
            session: session,
            credentialResolver: { source, _ in
                ClaudeCredential(
                    accessToken: "synthetic-test-token",
                    expiresAt: nil,
                    rateLimitTier: nil,
                    source: source
                )
            },
            reimportWebCookieOnStale: { false },
            localUsageCacheResolver: { account in
                AccountQuota(
                    accountId: account.id,
                    tool: .claude,
                    buckets: [
                        QuotaBucket(
                            id: "weekly",
                            title: "Weekly",
                            shortLabel: "Weekly",
                            usedPercent: 81,
                            resetAt: weeklyReset,
                            rawWindowSeconds: 604_800
                        )
                    ],
                    queriedAt: localQueriedAt
                )
            }
        )
        let account = AccountIdentity(
            id: "claude-partial-live",
            tool: .claude,
            source: .oauthCLI
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.bucket(id: "five_hour")?.usedPercent, 12)
        XCTAssertEqual(quota.weeklyBucket?.usedPercent, 81)
        XCTAssertEqual(quota.weeklyBucket?.resetAt, weeklyReset)
        XCTAssertEqual(quota.queriedAt, localQueriedAt)
    }

    func testAdapterDoesNotAppendAStaleCLIWeeklyPercentageToLiveUsage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudePartialUsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let now = Date()
        let localQueriedAt = now.addingTimeInterval(-86_400)
        ClaudePartialUsageURLProtocol.oauthUsageData = Data(
            #"{"five_hour":{"utilization":12}}"#.utf8
        )

        let adapter = ClaudeQuotaAdapter(
            session: session,
            credentialResolver: { source, _ in
                ClaudeCredential(
                    accessToken: "synthetic-test-token",
                    expiresAt: nil,
                    rateLimitTier: nil,
                    source: source
                )
            },
            reimportWebCookieOnStale: { false },
            localUsageCacheResolver: { account in
                AccountQuota(
                    accountId: account.id,
                    tool: .claude,
                    buckets: [
                        QuotaBucket(
                            id: "weekly",
                            title: "Weekly",
                            shortLabel: "Weekly",
                            usedPercent: 81,
                            resetAt: now.addingTimeInterval(3 * 86_400),
                            rawWindowSeconds: 604_800
                        )
                    ],
                    queriedAt: localQueriedAt
                )
            }
        )
        let account = AccountIdentity(
            id: "claude-partial-live-stale-cache",
            tool: .claude,
            source: .oauthCLI
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.bucket(id: "five_hour")?.usedPercent, 12)
        XCTAssertNil(quota.weeklyBucket)
        XCTAssertGreaterThan(quota.queriedAt, localQueriedAt)
    }

    func testAdapterUsesCurrentCLICacheToFillMissingLiveWeeklyReset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudePartialUsageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let now = Date()
        let localQueriedAt = now.addingTimeInterval(-86_400)
        let weeklyReset = now.addingTimeInterval(3 * 86_400)
        ClaudePartialUsageURLProtocol.oauthUsageData = Data(
            #"{"seven_day":{"utilization":22}}"#.utf8
        )

        let adapter = ClaudeQuotaAdapter(
            session: session,
            credentialResolver: { source, _ in
                ClaudeCredential(
                    accessToken: "synthetic-test-token",
                    expiresAt: nil,
                    rateLimitTier: nil,
                    source: source
                )
            },
            reimportWebCookieOnStale: { false },
            localUsageCacheResolver: { account in
                AccountQuota(
                    accountId: account.id,
                    tool: .claude,
                    buckets: [
                        QuotaBucket(
                            id: "weekly",
                            title: "Weekly",
                            shortLabel: "Weekly",
                            usedPercent: 81,
                            resetAt: weeklyReset,
                            rawWindowSeconds: 604_800
                        )
                    ],
                    queriedAt: localQueriedAt
                )
            }
        )
        let account = AccountIdentity(
            id: "claude-live-without-reset",
            tool: .claude,
            source: .oauthCLI
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.weeklyBucket?.usedPercent, 22)
        XCTAssertEqual(quota.weeklyBucket?.resetAt, weeklyReset)
        XCTAssertGreaterThan(quota.queriedAt, localQueriedAt)
    }
}

private final class ClaudePartialUsageURLProtocol: URLProtocol {
    nonisolated(unsafe) static var oauthUsageData = Data()

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isOAuthUsage = request.url?.host == "api.anthropic.com"
            && request.url?.path == "/api/oauth/usage"
        let statusCode = isOAuthUsage ? 200 : 404
        let data = isOAuthUsage ? Self.oauthUsageData : Data("{}".utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
