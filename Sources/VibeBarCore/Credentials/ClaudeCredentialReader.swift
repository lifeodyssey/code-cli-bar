import Foundation

public struct ClaudeCredential: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let rateLimitTier: String?
    public let source: CredentialSource
}

public enum ClaudeCredentialReader {
    private static let keychainService = "Claude Code-credentials"

    public static func loadFromCLI() throws -> ClaudeCredential {
        try loadCredential(
            preferred: { try readFromKeychain() },
            fallback: { try readFromCredentialsJSON() }
        )
    }

    public static func loadFromOAuth() throws -> ClaudeCredential {
        try loadCredential(
            preferred: { try readFromCredentialsJSON(source: .oauthCLI) },
            fallback: { try readFromKeychain(source: .oauthCLI) }
        )
    }

    static func loadCredential(
        preferred: () throws -> ClaudeCredential,
        fallback: () throws -> ClaudeCredential
    ) throws -> ClaudeCredential {
        let preferredError: QuotaError
        do {
            return try preferred()
        } catch {
            preferredError = credentialError(error)
        }
        do {
            return try fallback()
        } catch {
            // A missing alternative does not mean the existing login is
            // missing too. Preserve an access/parse failure for the UI.
            throw preferredError == .noCredential ? credentialError(error) : preferredError
        }
    }

    private static func credentialError(_ error: Error) -> QuotaError {
        if let error = error as? QuotaError { return error }
        switch error as? KeychainStore.KeychainError {
        case .itemNotFound:
            return .noCredential
        case .interactionNotAllowed:
            return .unknown("Keychain access unavailable for Claude Code")
        case .ambiguousItem:
            return .unknown("Multiple Claude Code logins found in Keychain")
        case .unhandledStatus(let status):
            SafeLog.warn("Claude Keychain read failed with status \(status)")
            return .unknown("Could not read Claude Code login from Keychain")
        case nil:
            return .unknown("Could not read Claude Code login")
        }
    }

    public static func decode(jsonString: String, source: CredentialSource) throws -> ClaudeCredential {
        guard let data = jsonString.data(using: .utf8) else {
            throw QuotaError.parseFailure("credentials json is not utf8")
        }
        return try decode(data: data, source: source)
    }

    public static func decode(data: Data, source: CredentialSource) throws -> ClaudeCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("credentials json is not an object")
        }

        let oauth: [String: Any] =
            (root["claudeAiOauth"] as? [String: Any])
            ?? (root["claude.ai_oauth"] as? [String: Any])
            ?? root

        let accessToken = (oauth["accessToken"] as? String)
            ?? (oauth["access_token"] as? String)
            ?? ""

        if accessToken.isEmpty {
            throw QuotaError.needsLogin
        }

        let expiresAt = parseExpiresAt(oauth["expiresAt"] ?? oauth["expires_at"])
        let rateLimitTier = stringValue(oauth["rateLimitTier"] ?? oauth["rate_limit_tier"])

        return ClaudeCredential(
            accessToken: accessToken,
            expiresAt: expiresAt,
            rateLimitTier: rateLimitTier,
            source: source
        )
    }

    static func readFromKeychain(
        source: CredentialSource = .cliDetected,
        accessAllowed: Bool = !DemoMode.isEnabled && !KeychainAccessGate.isDisabled,
        run: (String, [String], TimeInterval) throws -> ProcessRunner.Result = { binary, arguments, timeout in
            try ProcessRunner.runSynchronously(
                binary: binary, arguments: arguments, timeout: timeout, label: "Claude Keychain"
            )
        }
    ) throws -> ClaudeCredential {
        guard accessAllowed else { throw QuotaError.noCredential }
        let result: ProcessRunner.Result
        do {
            // Use Apple's stable executable identity, as CC Switch does.
            // Credentials stay in memory; never log either output stream.
            result = try run("/usr/bin/security", [
                "find-generic-password", "-s", keychainService, "-w"
            ], 5)
        } catch ProcessRunner.Error.timedOut {
            throw QuotaError.unknown("Timed out reading Claude Code login from Keychain")
        } catch {
            throw QuotaError.unknown("Could not read Claude Code login from Keychain")
        }
        switch result.terminationStatus {
        case 0:
            return try decode(jsonString: result.stdout, source: source)
        case 44: // errSecItemNotFound (-25300), truncated to a process exit code.
            throw QuotaError.noCredential
        default:
            SafeLog.warn("Claude security read failed with exit status \(result.terminationStatus)")
            throw QuotaError.unknown("Keychain access unavailable for Claude Code")
        }
    }

    private static func readFromCredentialsJSON(source: CredentialSource = .cliDetected) throws -> ClaudeCredential {
        let url = RealHomeDirectory.url
            .appendingPathComponent(".claude/.credentials.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        let data = try Data(contentsOf: url)
        return try decode(data: data, source: source)
    }

    private static func parseExpiresAt(_ any: Any?) -> Date? {
        switch any {
        case let n as NSNumber:
            // Could be seconds or milliseconds; assume ms if very large.
            let v = n.doubleValue
            return v > 1_000_000_000_000 ? Date(timeIntervalSince1970: v / 1000.0)
                                         : Date(timeIntervalSince1970: v)
        case let s as String:
            if let d = Double(s) {
                return d > 1_000_000_000_000 ? Date(timeIntervalSince1970: d / 1000.0)
                                             : Date(timeIntervalSince1970: d)
            }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        default:
            return nil
        }
    }

    private static func stringValue(_ any: Any?) -> String? {
        guard let string = any as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
