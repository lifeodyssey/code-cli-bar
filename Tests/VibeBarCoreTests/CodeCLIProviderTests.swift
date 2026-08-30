import XCTest
@testable import VibeBarCore

final class CodeCLIProviderTests: XCTestCase {
    func testProductBoundaryIsExactlyTheSixApprovedCLIs() {
        XCTAssertEqual(
            CodeCLIProvider.allCases,
            [
                .claudeCode, .codex, .openCodeGo, .kimiCode,
                .zcode, .grokBuild
            ]
        )
        XCTAssertEqual(Set(CodeCLIBarSettings.default.providers.keys), Set(CodeCLIProvider.allCases))
        XCTAssertFalse(CodeCLIProvider.allCases.contains(.dsh))
    }

    func testExperimentalQuotaStartsOffAndDoesNotDisableLocalUsage() {
        for provider in CodeCLIProvider.allCases {
            let configuration = CodeCLIBarSettings.default.configuration(for: provider)
            XCTAssertTrue(configuration.isEnabled, provider.displayName)
            XCTAssertFalse(configuration.experimentalQuotaEnabled, provider.displayName)
        }
        XCTAssertTrue(CodeCLIProvider.openCodeGo.usesExperimentalQuota)
        XCTAssertTrue(CodeCLIProvider.zcode.usesExperimentalQuota)
    }

    func testBrowserImportIsOffByDefaultAndOnlyOfferedWhereImplemented() {
        let supported: Set<CodeCLIProvider> = [
            .claudeCode, .codex, .openCodeGo, .kimiCode, .grokBuild
        ]
        for provider in CodeCLIProvider.allCases {
            XCTAssertEqual(provider.supportsBrowserCredentialImport, supported.contains(provider))
            XCTAssertFalse(
                CodeCLIBarSettings.default.configuration(for: provider).browserCredentialOptIn
            )
        }
    }
}
