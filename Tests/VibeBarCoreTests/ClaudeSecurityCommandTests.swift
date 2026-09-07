import XCTest
@testable import VibeBarCore

final class ClaudeSecurityCommandTests: XCTestCase {
    func testUsesSystemSecurityWithCanonicalServiceAndPreservesOAuthSource() throws {
        var calls = 0
        let credential = try ClaudeCredentialReader.readFromKeychain(source: .oauthCLI, accessAllowed: true) {
            binary, arguments, timeout in
            calls += 1
            XCTAssertEqual(binary, "/usr/bin/security")
            XCTAssertEqual(arguments, ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            XCTAssertEqual(timeout, 5)
            return .init(
                stdout: "{\"claudeAiOauth\":{\"accessToken\":\"synthetic-token\",\"expiresAt\":1900000000000,\"rateLimitTier\":\"max\"}}\n",
                stderr: "", terminationStatus: 0
            )
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(credential.accessToken, "synthetic-token")
        XCTAssertEqual(credential.source, .oauthCLI)
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(credential.rateLimitTier, "max")
    }

    func testDisabledAccessNeverStartsProcess() {
        XCTAssertThrowsError(try ClaudeCredentialReader.readFromKeychain(accessAllowed: false) { _, _, _ in
            XCTFail("Disabled access must not launch security")
            return .init(stdout: "", stderr: "", terminationStatus: 0)
        }) { XCTAssertEqual($0 as? QuotaError, .noCredential) }
    }

    func testMissingItemAllowsFileFallback() throws {
        let credential = try ClaudeCredentialReader.loadCredential(preferred: {
            try ClaudeCredentialReader.readFromKeychain(accessAllowed: true) { _, _, _ in
                .init(stdout: "", stderr: "item missing", terminationStatus: 44)
            }
        }, fallback: {
            try ClaudeCredentialReader.decode(jsonString: "{\"accessToken\":\"file-token\"}", source: .cliDetected)
        })
        XCTAssertEqual(credential.accessToken, "file-token")
    }

    func testDenialIsNotMisreportedAsMissingLoginAndDoesNotExposeOutput() {
        XCTAssertThrowsError(try ClaudeCredentialReader.loadCredential(preferred: {
            try ClaudeCredentialReader.readFromKeychain(accessAllowed: true) { _, _, _ in
                .init(stdout: "synthetic-secret", stderr: "synthetic-secret", terminationStatus: 36)
            }
        }, fallback: { throw QuotaError.noCredential })) {
            XCTAssertEqual($0 as? QuotaError, .unknown("Keychain access unavailable for Claude Code"))
        }
    }

    func testTimeoutAndLaunchFailuresAreSanitized() {
        for error in [ProcessRunner.Error.timedOut("synthetic-secret"), .launchFailed("synthetic-secret")] {
            XCTAssertThrowsError(try ClaudeCredentialReader.readFromKeychain(accessAllowed: true) { _, _, _ in
                throw error
            }) {
                XCTAssertFalse(String(describing: $0).contains("synthetic-secret"))
                XCTAssertNotEqual($0 as? QuotaError, .noCredential)
            }
        }
    }

    func testInvalidSuccessfulOutputIsParseFailure() {
        XCTAssertThrowsError(try ClaudeCredentialReader.readFromKeychain(accessAllowed: true) { _, _, _ in
            .init(stdout: "synthetic-secret", stderr: "", terminationStatus: 0)
        }) {
            XCTAssertEqual($0 as? QuotaError, .parseFailure("credentials json is not an object"))
        }
    }

    func testSynchronousRunnerCapturesOutput() throws {
        let result = try ProcessRunner.runSynchronously(binary: "/bin/echo", arguments: ["synthetic-output"])
        XCTAssertEqual(result.stdout, "synthetic-output\n")
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testSynchronousRunnerBoundsUnresponsiveChild() throws {
        let start = Date()
        XCTAssertThrowsError(try ProcessRunner.runSynchronously(
            binary: "/usr/bin/perl", arguments: ["-e", "$SIG{TERM}='IGNORE'; sleep 10;"],
            timeout: 0.2, label: "test-child"
        )) {
            guard case ProcessRunner.Error.timedOut = $0 else { return XCTFail("Expected timeout") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
