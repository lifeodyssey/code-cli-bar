import XCTest
@testable import VibeBarCore

final class OpenCodeGoNativeQuotaTests: XCTestCase {
    override func tearDown() {
        OpenCodeGoNativeURLProtocol.handler = nil
        super.tearDown()
    }

    func testReadsTheOpenCodeGoKeyFromTheNativeAuthFile() throws {
        let json = """
        {
          "opencode": {"type": "api", "key": "synthetic-general-key"},
          "opencode-go": {"type": "api", "key": "synthetic-go-key"}
        }
        """

        let credential = try OpenCodeGoCredentialReader.decode(data: Data(json.utf8))

        XCTAssertEqual(credential.apiKey, "synthetic-go-key")
    }

    func testNativeKeyFetchesTheUsageAPIWithExactResetTimes() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeGoNativeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OpenCodeGoNativeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/zen/go/v1/usage")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer synthetic-go-key"
            )
            let body = Data(
                """
                {
                  "usage": {
                    "rolling": {
                      "status": "ok",
                      "percent": 12,
                      "resetsAt": "2026-08-30T20:00:00Z"
                    },
                    "weekly": {
                      "status": "ok",
                      "percent": 34,
                      "resetsAt": "2026-09-03T04:00:00Z"
                    },
                    "monthly": {
                      "status": "ok",
                      "percent": 56,
                      "resetsAt": "2026-09-24T04:00:00Z"
                    }
                  }
                }
                """.utf8
            )
            return (200, body)
        }
        let adapter = OpenCodeGoQuotaAdapter(
            session: session,
            environment: [:],
            now: { Date(timeIntervalSince1970: 1_777_800_000) },
            credentialResolver: { OpenCodeGoCredential(apiKey: "synthetic-go-key") }
        )
        let account = AccountIdentity(
            id: "opencode-go-local",
            tool: .openCodeGo,
            source: .notConfigured
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(
            quota.buckets.map(\.id),
            ["opencodego.rolling", "opencodego.weekly", "opencodego.monthly"]
        )
        XCTAssertEqual(quota.buckets[0].usedPercent, 12)
        XCTAssertEqual(quota.buckets[1].usedPercent, 34)
        XCTAssertEqual(
            quota.buckets[1].resetAt,
            ISO8601DateFormatter().date(from: "2026-09-03T04:00:00Z")
        )
        XCTAssertEqual(quota.buckets[1].rawWindowSeconds, 604_800)
    }

    func testZeroUsageDoesNotPretendThePlaceholderResetIsExact() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeGoNativeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OpenCodeGoNativeURLProtocol.handler = { _ in
            let body = Data(
                """
                {
                  "usage": {
                    "rolling": {"status": "ok", "percent": 0, "resetsAt": "2026-08-30T20:00:00Z"},
                    "weekly": {"status": "ok", "percent": 0, "resetsAt": "2026-09-03T04:00:00Z"}
                  }
                }
                """.utf8
            )
            return (200, body)
        }
        let adapter = OpenCodeGoQuotaAdapter(
            session: session,
            environment: [:],
            now: { Date(timeIntervalSince1970: 1_777_800_000) },
            credentialResolver: { OpenCodeGoCredential(apiKey: "synthetic-go-key") }
        )
        let account = AccountIdentity(
            id: "opencode-go-local",
            tool: .openCodeGo,
            source: .notConfigured
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.buckets.map(\.usedPercent), [0, 0])
        XCTAssertTrue(quota.buckets.allSatisfy { $0.resetAt == nil })
    }

    func testNativePercentFieldsBelowOrEqualToOneStayPercentages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeGoNativeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        OpenCodeGoNativeURLProtocol.handler = { _ in
            (200, Data("""
            {"usage": {
              "rolling": {"percent": 0.5, "resetsAt": "2026-09-06T20:00:00Z"},
              "weekly": {"percent": 5, "resetsAt": "2026-09-07T00:00:00Z"},
              "monthly": {"percent": 1, "resetsAt": "2026-10-04T00:00:00Z"}
            }}
            """.utf8))
        }
        let adapter = OpenCodeGoQuotaAdapter(
            session: session,
            environment: [:],
            credentialResolver: { OpenCodeGoCredential(apiKey: "synthetic-go-key") }
        )
        let quota = try await adapter.fetch(for: AccountIdentity(
            id: "opencode-go-local", tool: .openCodeGo, source: .notConfigured
        ))

        XCTAssertEqual(quota.buckets.map(\.usedPercent), [0.5, 5, 1])
        XCTAssertTrue(quota.buckets.allSatisfy { $0.resetAt != nil })
    }
}

private final class OpenCodeGoNativeURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
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
