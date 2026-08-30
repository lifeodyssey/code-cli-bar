import Foundation

/// Reads Claude Code's provider-authored usage snapshot from `~/.claude.json`.
///
/// Claude Code writes this cache after a successful usage lookup. It contains
/// the same utilization payload as Anthropic's usage endpoint, including the
/// reset timestamps that cannot be reconstructed from local session logs.
/// Vibe Bar treats the file as read-only input and never persists its account
/// identifier or any other Claude configuration field.
public enum ClaudeLocalUsageCacheReader {
    private static var cacheURL: URL {
        RealHomeDirectory.url.appendingPathComponent(".claude.json")
    }

    public static func load(for account: AccountIdentity) throws -> AccountQuota {
        let url = cacheURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        return try parse(data: Data(contentsOf: url), for: account)
    }

    /// Claude Code can retain a current provider-authored usage snapshot even
    /// when its OAuth credential is temporarily unavailable. That snapshot is
    /// sufficient to register a read-only quota account so the adapter gets a
    /// chance to use the local fallback instead of dropping Claude entirely.
    static func detectedAccount(now: Date = Date()) -> AccountIdentity? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return detectedAccount(data: data, now: now)
    }

    static func detectedAccount(data: Data, now: Date = Date()) -> AccountIdentity? {
        let account = AccountIdentity(
            id: "cli-claude",
            tool: .claude,
            alias: "Claude Code",
            source: .cliDetected,
            createdAt: now,
            updatedAt: now
        )
        guard let quota = try? parse(data: data, for: account),
              quota.buckets.contains(where: { isCurrent($0, in: quota, now: now) })
        else { return nil }
        return account
    }

    public static func parse(data: Data, for account: AccountIdentity) throws -> AccountQuota {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any]
        else {
            throw QuotaError.parseFailure("Claude CLI usage cache is unavailable")
        }

        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: utilization)
        } catch {
            throw QuotaError.parseFailure("Claude CLI usage cache is invalid")
        }

        let buckets = try ClaudeResponseParser.parse(data: payload)
        let queriedAt = timestamp(cache["fetchedAtMs"] ?? cache["fetched_at_ms"]) ?? Date()

        return AccountQuota(
            accountId: account.id,
            tool: .claude,
            buckets: buckets,
            plan: account.plan,
            email: account.email,
            queriedAt: queriedAt,
            error: nil,
            providerExtras: ClaudeResponseParser.parseExtraUsage(data: payload)
        )
    }

    private static func timestamp(_ value: Any?) -> Date? {
        let number: Double?
        switch value {
        case let value as NSNumber:
            number = value.doubleValue
        case let value as String:
            number = Double(value)
        default:
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
        return Date(timeIntervalSince1970: seconds)
    }

    static func isCurrent(
        _ bucket: QuotaBucket,
        in snapshot: AccountQuota,
        now: Date
    ) -> Bool {
        guard let resetAt = bucket.resetAt,
              resetAt > now,
              let windowSeconds = bucket.rawWindowSeconds,
              windowSeconds > 0
        else { return false }
        let age = now.timeIntervalSince(snapshot.queriedAt)
        guard age >= -300, age <= TimeInterval(windowSeconds) else { return false }
        return resetAt.timeIntervalSince(snapshot.queriedAt) <= TimeInterval(windowSeconds) + 300
    }

    /// A snapshot can describe the current quota cycle without containing a
    /// current utilization value. Only this stricter check permits an adapter
    /// to return the local snapshot as if a live request had succeeded.
    static func isFreshForLiveFallback(
        _ snapshot: AccountQuota,
        now: Date = Date()
    ) -> Bool {
        !snapshot.buckets.isEmpty
            && QuotaFreshnessPolicy.isFresh(
                timestamp: snapshot.queriedAt,
                maxAge: QuotaFreshnessPolicy.credentialFallbackMaxAge,
                now: now
            )
    }
}
