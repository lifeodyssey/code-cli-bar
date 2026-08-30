import Foundation

/// The six user-facing sources Code CLI Bar promises to support.
///
/// This is intentionally separate from `ToolType`. `ToolType` is inherited
/// from Vibe Bar and also contains many quota-only services; product UI should
/// not accidentally grow when a new upstream adapter is added there. `dsh`
/// remains decodable for settings written by older builds, but is deliberately
/// absent from `allCases` so it is no longer scanned or shown as a product.
public enum CodeCLIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case openCodeGo
    case kimiCode
    case zcode
    case grokBuild
    case dsh

    public static let allCases: [CodeCLIProvider] = [
        .claudeCode,
        .codex,
        .openCodeGo,
        .kimiCode,
        .zcode,
        .grokBuild
    ]

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCodeGo: "OpenCode Go"
        case .kimiCode: "Kimi Code"
        case .zcode: "ZCode"
        case .grokBuild: "Grok Build"
        case .dsh: "dsh"
        }
    }

    /// Existing quota/cost identity used until every scanner has moved to the
    /// product model. The dsh mapping is retained only for decoding and
    /// migrating settings written by older builds.
    public var legacyTool: ToolType? {
        switch self {
        case .claudeCode: .claude
        case .codex: .codex
        case .openCodeGo: .openCodeGo
        case .kimiCode: .kimi
        case .zcode: .zai
        case .grokBuild: .grok
        case .dsh: .dsh
        }
    }

    public var defaultUsagePaths: [String] {
        switch self {
        case .claudeCode: [".claude/projects"]
        case .codex: [".codex/sessions"]
        case .openCodeGo: [".local/share/opencode/opencode.db"]
        case .kimiCode: [".kimi-code/sessions"]
        case .zcode: [".zcode/cli/db/db.sqlite"]
        case .grokBuild: [".grok/sessions"]
        case .dsh: [".dsh/sessions"]
        }
    }

    public var usesExperimentalQuota: Bool {
        self == .openCodeGo || self == .zcode
    }

    /// Providers whose plan credentials can be copied explicitly from a
    /// browser profile. ZCode uses an API key; dsh reuses OpenCode Go's quota
    /// and therefore has no separate browser credential of its own.
    public var supportsBrowserCredentialImport: Bool {
        switch self {
        case .claudeCode, .codex, .openCodeGo, .kimiCode, .grokBuild:
            return true
        case .zcode, .dsh:
            return false
        }
    }
}

public struct CodeCLIProviderConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var customUsagePath: String?
    public var browserCredentialOptIn: Bool
    public var experimentalQuotaEnabled: Bool

    public init(
        isEnabled: Bool = true,
        customUsagePath: String? = nil,
        browserCredentialOptIn: Bool = false,
        experimentalQuotaEnabled: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.customUsagePath = Self.normalizedPath(customUsagePath)
        self.browserCredentialOptIn = browserCredentialOptIn
        self.experimentalQuotaEnabled = experimentalQuotaEnabled
    }

    public static func defaults(for provider: CodeCLIProvider) -> Self {
        // Experimental provider endpoints are a separate explicit opt-in.
        // The row remains visible and local usage still scans while this is
        // off; only remote quota polling is suppressed.
        Self(experimentalQuotaEnabled: false)
    }

    public static func normalizedPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

public struct CodeCLIBarSettings: Codable, Equatable, Sendable {
    public var providers: [CodeCLIProvider: CodeCLIProviderConfiguration]
    public var usageRefreshIntervalSeconds: Int
    public var quotaRefreshIntervalSeconds: Int
    public var launchAtLogin: Bool
    public var hasCompletedOnboarding: Bool

    public init(
        providers: [CodeCLIProvider: CodeCLIProviderConfiguration] = [:],
        usageRefreshIntervalSeconds: Int = 60,
        quotaRefreshIntervalSeconds: Int = 600,
        launchAtLogin: Bool = false,
        hasCompletedOnboarding: Bool = false
    ) {
        self.providers = Self.normalizedProviders(providers)
        self.usageRefreshIntervalSeconds = max(60, usageRefreshIntervalSeconds)
        self.quotaRefreshIntervalSeconds = max(60, quotaRefreshIntervalSeconds)
        self.launchAtLogin = launchAtLogin
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    public static let `default` = CodeCLIBarSettings()

    public func configuration(for provider: CodeCLIProvider) -> CodeCLIProviderConfiguration {
        providers[provider] ?? .defaults(for: provider)
    }

    public mutating func setConfiguration(
        _ configuration: CodeCLIProviderConfiguration,
        for provider: CodeCLIProvider
    ) {
        var normalized = configuration
        normalized.customUsagePath = CodeCLIProviderConfiguration.normalizedPath(
            configuration.customUsagePath
        )
        providers[provider] = normalized
    }

    private static func normalizedProviders(
        _ providers: [CodeCLIProvider: CodeCLIProviderConfiguration]
    ) -> [CodeCLIProvider: CodeCLIProviderConfiguration] {
        var result = providers
        for provider in CodeCLIProvider.allCases where result[provider] == nil {
            result[provider] = .defaults(for: provider)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case providers
        case usageRefreshIntervalSeconds
        case quotaRefreshIntervalSeconds
        case launchAtLogin
        case hasCompletedOnboarding
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            providers: try container.decodeIfPresent(
                [CodeCLIProvider: CodeCLIProviderConfiguration].self,
                forKey: .providers
            ) ?? [:],
            usageRefreshIntervalSeconds: try container.decodeIfPresent(
                Int.self,
                forKey: .usageRefreshIntervalSeconds
            ) ?? 60,
            quotaRefreshIntervalSeconds: try container.decodeIfPresent(
                Int.self,
                forKey: .quotaRefreshIntervalSeconds
            ) ?? 600,
            launchAtLogin: try container.decodeIfPresent(
                Bool.self,
                forKey: .launchAtLogin
            ) ?? false,
            hasCompletedOnboarding: try container.decodeIfPresent(
                Bool.self,
                forKey: .hasCompletedOnboarding
            ) ?? false
        )
    }
}

public struct CodeCLIProviderDetection: Equatable, Sendable {
    public let provider: CodeCLIProvider
    public let detectedPath: String?

    public init(provider: CodeCLIProvider, detectedPath: String?) {
        self.provider = provider
        self.detectedPath = detectedPath
    }

    public var isDetected: Bool { detectedPath != nil }
}
