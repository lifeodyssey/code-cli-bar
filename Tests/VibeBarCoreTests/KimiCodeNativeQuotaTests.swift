import XCTest
@testable import VibeBarCore

final class KimiCodeNativeQuotaTests: XCTestCase {
    override func tearDown() {
        KimiCodeNativeURLProtocol.handler = nil
        super.tearDown()
    }

    func testReadsKimiCodeOAuthCredential() throws {
        let json = """
        {
          "access_token": "synthetic.header.signature",
          "refresh_token": "refresh.header.signature",
          "expires_at": 1900000000,
          "scope": "kimi-code",
          "token_type": "Bearer"
        }
        """

        let credential = try KimiCodeCredentialReader.decode(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(credential.accessToken, "synthetic.header.signature")
        XCTAssertEqual(credential.refreshToken, "refresh.header.signature")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
    }

    func testReaderPreservesExpiryForReadOnlyConsumer() throws {
        let json = """
        {
          "access_token": "expired.header.signature",
          "refresh_token": "refresh.header.signature",
          "expires_at": 1700000000
        }
        """

        let credential = try KimiCodeCredentialReader.decode(
            data: Data(json.utf8),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertTrue(credential.isExpired(at: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(credential.refreshToken, "refresh.header.signature")
    }

    func testNativeOAuthFetchesCodingPlanUsageAndWeeklyReset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiCodeNativeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        KimiCodeNativeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.kimi.com/coding/v1/usages")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer synthetic.header.signature"
            )
            return (200, Data(
                """
                {
                  "limits": [
                    {
                      "window": {"duration": 5, "timeUnit": "HOUR"},
                      "detail": {
                        "limit": "100",
                        "remaining": "88",
                        "resetTime": "2026-08-30T20:00:00Z"
                      }
                    }
                  ],
                  "usage": {
                    "limit": 1000,
                    "remaining": 660,
                    "resetTime": "2026-09-03T04:00:00Z"
                  }
                }
                """.utf8
            ))
        }
        let adapter = KimiQuotaAdapter(
            session: session,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            nativeCredentialResolver: {
                KimiCodeCredential(
                    accessToken: "synthetic.header.signature",
                    expiresAt: Date(timeIntervalSince1970: 1_900_000_000)
                )
            }
        )
        let account = AccountIdentity(
            id: "kimi-code-local",
            tool: .kimi,
            source: .notConfigured
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.buckets.map(\.id), ["kimi.weekly", "kimi.rate"])
        XCTAssertEqual(quota.buckets[0].usedPercent, 34, accuracy: 0.001)
        XCTAssertEqual(quota.buckets[1].usedPercent, 12, accuracy: 0.001)
        XCTAssertEqual(
            quota.buckets[0].resetAt,
            ISO8601DateFormatter().date(from: "2026-09-03T04:00:00Z")
        )
        XCTAssertEqual(quota.buckets[0].rawWindowSeconds, 604_800)
    }

    func testExpiredNativeCredentialDoesNotMakeAnyRequest() async throws {
        var requests = 0
        let adapter = makeAdapter { _ in
            requests += 1
            return (401, Data())
        }
        do {
            _ = try await adapter.fetchNativeQuota(
                KimiCodeCredential(accessToken: "expired", refreshToken: "must-not-use", expiresAt: .distantPast),
                account: testAccount, queriedAt: Date()
            )
            XCTFail("Expired credentials must wait for Kimi Code to renew them")
        } catch {
            XCTAssertEqual(error as? QuotaError, .unknown("Open Kimi Code to renew its login, then refresh quota"))
        }
        XCTAssertEqual(requests, 0, "The monitor must never rotate a CLI-owned refresh token")
    }

    func testRejectedNativeCredentialDoesNotRefreshOrRetry() async throws {
        for status in [401, 403] {
            var requests = 0
            let adapter = makeAdapter { request in
                requests += 1
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.absoluteString, "https://api.kimi.com/coding/v1/usages")
                return (status, Data())
            }
            do {
                _ = try await adapter.fetchNativeQuota(
                    KimiCodeCredential(accessToken: "rejected", refreshToken: "must-not-use", expiresAt: .distantFuture),
                    account: testAccount, queriedAt: Date()
                )
                XCTFail("Rejected credentials must be left to Kimi Code")
            } catch {
                XCTAssertEqual(error as? QuotaError, .unknown("Open Kimi Code to renew its login, then refresh quota"))
            }
            XCTAssertEqual(requests, 1)
        }
    }

    func testNextFetchUsesCredentialRenewedByCLI() async throws {
        let credentials = CredentialBox()
        var requests = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiCodeNativeURLProtocol.self]
        KimiCodeNativeURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), requests == 1 ? "Bearer first" : "Bearer renewed")
            return (200, Data("{\"usage\":{\"limit\":100,\"remaining\":75}}".utf8))
        }
        let adapter = KimiQuotaAdapter(
            session: URLSession(configuration: configuration),
            nativeCredentialResolver: { credentials.get() }
        )
        _ = try await adapter.fetch(for: testAccount)
        credentials.renew()
        _ = try await adapter.fetch(for: testAccount)
        XCTAssertEqual(requests, 2)
    }

    private var testAccount: AccountIdentity {
        AccountIdentity(id: "kimi-code-local", tool: .kimi, source: .notConfigured)
    }

    private func makeAdapter(
        handler: @escaping (URLRequest) throws -> (Int, Data)
    ) -> KimiQuotaAdapter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiCodeNativeURLProtocol.self]
        KimiCodeNativeURLProtocol.handler = handler
        return KimiQuotaAdapter(session: URLSession(configuration: configuration))
    }

}

private final class KimiCodeNativeURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token = "first"

    func get() -> KimiCodeCredential {
        lock.lock()
        defer { lock.unlock() }
        return KimiCodeCredential(accessToken: token, expiresAt: .distantFuture)
    }

    func renew() {
        lock.lock()
        defer { lock.unlock() }
        token = "renewed"
    }
}
