import XCTest
@testable import VibeBarCore

final class ClaudeCredentialFallbackTests: XCTestCase {
    func testMissingFileDoesNotHideDeniedKeychainAccess() {
        XCTAssertThrowsError(try ClaudeCredentialReader.loadCredential(
            preferred: { throw KeychainStore.KeychainError.interactionNotAllowed },
            fallback: { throw QuotaError.noCredential }
        )) { error in
            XCTAssertEqual(error as? QuotaError, .unknown("Keychain access unavailable for Claude Code"))
        }
    }

    func testOAuthFileFallbackPreservesKeychainFailure() {
        XCTAssertThrowsError(try ClaudeCredentialReader.loadCredential(
            preferred: { throw QuotaError.noCredential },
            fallback: { throw KeychainStore.KeychainError.interactionNotAllowed }
        )) { error in
            XCTAssertEqual(error as? QuotaError, .unknown("Keychain access unavailable for Claude Code"))
        }
    }

    func testMissingSourcesStillReportNoCredential() {
        XCTAssertThrowsError(try ClaudeCredentialReader.loadCredential(
            preferred: { throw KeychainStore.KeychainError.itemNotFound },
            fallback: { throw QuotaError.noCredential }
        )) { error in
            XCTAssertEqual(error as? QuotaError, .noCredential)
        }
    }

    func testReadableFileRecoversFromKeychainDenial() throws {
        let result = try ClaudeCredentialReader.loadCredential(
            preferred: { throw KeychainStore.KeychainError.interactionNotAllowed },
            fallback: {
                try ClaudeCredentialReader.decode(
                    jsonString: "{\"accessToken\":\"synthetic-token\"}", source: .cliDetected
                )
            }
        )
        XCTAssertEqual(result.accessToken, "synthetic-token")
    }
}
