import Foundation

public struct KimiCodeCredential: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

/// Read-only access to the OAuth credential maintained by Kimi Code.
public enum KimiCodeCredentialReader {
    public static func load(now: Date = Date()) throws -> KimiCodeCredential {
        let url = RealHomeDirectory.url
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        return try decode(data: Data(contentsOf: url), now: now)
    }

    public static func decode(data: Data, now _: Date = Date()) throws -> KimiCodeCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.parseFailure("Kimi Code credential is invalid")
        }
        let accessToken = string(root["access_token"])
        guard let accessToken else { throw QuotaError.needsLogin }

        return KimiCodeCredential(
            accessToken: accessToken,
            refreshToken: string(root["refresh_token"]),
            expiresAt: timestamp(root["expires_at"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func timestamp(_ value: Any?) -> Date? {
        let number: Double?
        switch value {
        case let value as NSNumber: number = value.doubleValue
        case let value as String: number = Double(value)
        default: number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number >= 1_000_000_000_000 ? number / 1_000 : number)
    }
}
