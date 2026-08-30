import XCTest
@testable import VibeBarCore

final class ZCodeNativeQuotaTests: XCTestCase {
    override func tearDown() {
        ZCodeNativeURLProtocol.handler = nil
        super.tearDown()
    }

    func testReadsEnabledBigModelCodingPlanCredentialFromZCodeConfig() throws {
        let json = """
        {
          "provider": {
            "builtin:zai-coding-plan": {
              "name": "Z.ai - Coding Plan",
              "enabled": false,
              "systemDisabledReason": "oauth_provider_inactive",
              "options": {
                "apiKey": "unused.global.key",
                "baseURL": "https://api.z.ai/api/anthropic"
              }
            },
            "builtin:bigmodel-coding-plan": {
              "name": "BigModel - Coding Plan",
              "enabled": true,
              "options": {
                "apiKey": "synthetic.id.secret",
                "baseURL": "https://open.bigmodel.cn/api/anthropic"
              }
            }
          }
        }
        """

        let credential = try ZCodeCredentialReader.decode(data: Data(json.utf8))

        XCTAssertEqual(credential.apiKey, "synthetic.id.secret")
        XCTAssertEqual(credential.providerID, "builtin:bigmodel-coding-plan")
        XCTAssertEqual(credential.planName, "BigModel - Coding Plan")
        XCTAssertEqual(
            credential.quotaURL.absoluteString,
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        )
    }

    func testNativeCredentialFetchUsesRawAuthorizationAndExactWeeklyReset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZCodeNativeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let resetMilliseconds = 1_900_123_456_000
        ZCodeNativeURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "synthetic.id.secret"
            )
            return (200, Data(
                """
                {
                  "code": 200,
                  "msg": "OK",
                  "success": true,
                  "data": {
                    "planName": "GLM Coding Pro",
                    "limits": [
                      {
                        "type": "TOKENS_LIMIT",
                        "unit": 6,
                        "number": 1,
                        "usage": 1000,
                        "remaining": 620,
                        "currentValue": 380,
                        "percentage": 38,
                        "nextResetTime": \(resetMilliseconds)
                      },
                      {
                        "type": "TOKENS_LIMIT",
                        "unit": 3,
                        "number": 5,
                        "usage": 100,
                        "remaining": 88,
                        "currentValue": 12,
                        "percentage": 12,
                        "nextResetTime": 1900000000000
                      }
                    ]
                  }
                }
                """.utf8
            ))
        }
        let adapter = ZaiQuotaAdapter(
            session: session,
            environment: [:],
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            nativeCredentialResolver: {
                ZCodeCredential(
                    apiKey: "synthetic.id.secret",
                    providerID: "builtin:bigmodel-coding-plan",
                    planName: "BigModel - Coding Plan",
                    quotaURL: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
                )
            }
        )
        let account = AccountIdentity(
            id: "zcode-local",
            tool: .zai,
            source: .notConfigured
        )

        let quota = try await adapter.fetch(for: account)

        XCTAssertEqual(quota.buckets.map(\.title), ["Weekly", "5 Hours"])
        XCTAssertEqual(quota.buckets[0].usedPercent, 38, accuracy: 0.001)
        XCTAssertEqual(
            quota.buckets[0].resetAt,
            Date(timeIntervalSince1970: TimeInterval(resetMilliseconds) / 1_000)
        )
        XCTAssertEqual(quota.buckets[0].rawWindowSeconds, 604_800)
        XCTAssertEqual(quota.plan, "GLM Coding Pro")
    }
}

private final class ZCodeNativeURLProtocol: URLProtocol {
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
