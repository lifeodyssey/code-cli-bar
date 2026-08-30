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

    func testReaderReturnsExpiredCredentialSoAdapterCanRefreshIt() throws {
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

    func testExpiredNativeOAuthRefreshesInMemoryBeforeFetchingUsage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiCodeNativeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        KimiCodeNativeURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                XCTAssertEqual(request.url?.absoluteString, "https://auth.kimi.com/api/oauth/token")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Content-Type"),
                    "application/x-www-form-urlencoded"
                )
                let body = String(data: requestBody(request), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains("client_id=17e5f671-d194-4dfb-9706-5516cb48c098"))
                XCTAssertTrue(body.contains("grant_type=refresh_token"))
                XCTAssertTrue(body.contains("refresh_token=refresh.header.signature"))
                return (200, Data(
                    """
                    {
                      "access_token": "fresh.header.signature",
                      "refresh_token": "rotated.header.signature",
                      "expires_in": 3600,
                      "token_type": "Bearer",
                      "scope": "kimi-code"
                    }
                    """.utf8
                ))
            }

            XCTAssertEqual(request.url?.absoluteString, "https://api.kimi.com/coding/v1/usages")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer fresh.header.signature"
            )
            return (200, Data(
                """
                {
                  "usage": {
                    "limit": 1000,
                    "remaining": 750,
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
                    accessToken: "expired.header.signature",
                    refreshToken: "refresh.header.signature",
                    expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            }
        )
        let account = AccountIdentity(
            id: "kimi-code-local",
            tool: .kimi,
            source: .notConfigured
        )

        let quota = try await adapter.fetch(for: account)
        let secondQuota = try await adapter.fetch(for: account)

        XCTAssertEqual(requestCount, 3, "The second fetch must reuse the in-memory rotated credential.")
        XCTAssertEqual(quota.buckets.map(\.id), ["kimi.weekly"])
        XCTAssertEqual(quota.buckets[0].usedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(secondQuota.buckets[0].usedPercent, 25, accuracy: 0.001)
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

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        body.append(buffer, count: count)
    }
    return body
}
