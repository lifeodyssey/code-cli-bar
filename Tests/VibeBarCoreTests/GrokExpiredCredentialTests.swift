import XCTest
@testable import VibeBarCore

final class GrokExpiredCredentialTests: XCTestCase {
    func testExpiredNativeLoginWithoutBrowserFallbackSurfacesNeedsLogin() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credential = GrokCredentials(
            accessToken: "expired.synthetic.token",
            scope: "https://auth.x.ai::synthetic-client",
            authMode: "oidc",
            email: "user@example.com",
            firstName: nil,
            lastName: nil,
            teamId: nil,
            subscriptionTier: "supergrok",
            expiresAt: now.addingTimeInterval(-60)
        )
        let adapter = GrokQuotaAdapter(
            session: .shared,
            homeDirectory: "/unused",
            now: { now },
            credentialResolver: { credential },
            cookieHeaderResolver: { throw QuotaError.noCredential }
        )
        let account = AccountIdentity(
            id: "grok-local",
            tool: .grok,
            source: .cliDetected
        )

        do {
            _ = try await adapter.fetch(for: account)
            XCTFail("Expected needsLogin")
        } catch let error as QuotaError {
            XCTAssertEqual(error, .needsLogin)
        }
    }
}
