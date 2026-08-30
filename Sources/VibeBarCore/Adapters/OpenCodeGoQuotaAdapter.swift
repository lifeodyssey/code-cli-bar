import Foundation

/// OpenCode Go usage adapter.
///
/// Preferred auth: the dedicated `opencode-go` key from OpenCode's native
/// auth store. Browser cookies and workspace-page parsing remain available as
/// a compatibility fallback.
public struct OpenCodeGoQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .openCodeGo

    private let session: URLSession
    private let environment: [String: String]
    private let now: @Sendable () -> Date
    private let credentialResolver: @Sendable () throws -> OpenCodeGoCredential

    private static let nativeUsageEndpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    public static let cookieSpec = MiscCookieResolver.Spec(
        tool: .openCodeGo,
        domains: ["opencode.ai", "www.opencode.ai"],
        requiredNames: ["auth", "__Host-auth"],
        credentialNames: ["auth", "__Host-auth"]
    )

    public init(
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        credentialResolver: (@Sendable () throws -> OpenCodeGoCredential)? = nil
    ) {
        self.session = session
        self.environment = environment
        self.now = now
        self.credentialResolver = credentialResolver ?? {
            try OpenCodeGoCredentialReader.load()
        }
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        let queriedAt = now()
        var nativeError: QuotaError?
        do {
            let credential = try credentialResolver()
            return try await fetchWithNativeCredential(
                credential,
                account: account,
                queriedAt: queriedAt
            )
        } catch let error as QuotaError {
            nativeError = error
        } catch {
            nativeError = .noCredential
        }

        let resolutions = MiscCookieResolver.resolveAll(for: Self.cookieSpec, account: account)
        guard !resolutions.isEmpty else { throw nativeError ?? QuotaError.noCredential }

        let results = await MiscCookieAutoImporter.shared.gatherSlotResults(
            spec: Self.cookieSpec,
            account: account,
            resolutions: resolutions
        ) { resolution in
            try await self.fetchOneSlot(resolution, account: account, queriedAt: queriedAt)
        }
        return MiscQuotaAggregator.aggregate(
            tool: .openCodeGo,
            account: account,
            results: results,
            queriedAt: queriedAt
        )
    }

    private func fetchWithNativeCredential(
        _ credential: OpenCodeGoCredential,
        account: AccountIdentity,
        queriedAt: Date
    ) async throws -> AccountQuota {
        var request = URLRequest(url: Self.nativeUsageEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let text = try await fetchText(request)
        let snapshot = try OpenCodeGoResponseParser.parse(text: text, now: queriedAt)
        return AccountQuota(
            accountId: account.id,
            tool: .openCodeGo,
            buckets: snapshot.buckets,
            plan: account.plan,
            email: account.email,
            queriedAt: queriedAt,
            error: nil
        )
    }

    private func fetchOneSlot(
        _ resolution: MiscCookieResolver.Resolution,
        account: AccountIdentity,
        queriedAt: Date
    ) async throws -> AccountQuota {
        let instanceID = AccountStore.miscInstanceID(fromAccountID: account.id, fallbackTool: .openCodeGo)
        let settings = MiscProviderSettings.current(for: .openCodeGo, instanceID: instanceID)
        let workspaceID = try await resolveWorkspaceID(
            cookieHeader: resolution.header,
            configured: settings.workspaceID ?? environment["CODEXBAR_OPENCODEGO_WORKSPACE_ID"]
        )
        let text = try await fetchPage(
            url: URL(string: "https://opencode.ai/workspace/\(workspaceID)/go")!,
            cookieHeader: resolution.header
        )
        if OpenCodeGoResponseParser.looksSignedOut(text) {
            throw QuotaError.needsLogin
        }
        let snapshot = try OpenCodeGoResponseParser.parse(text: text, now: queriedAt)
        return AccountQuota(
            accountId: account.id,
            tool: .openCodeGo,
            buckets: snapshot.buckets,
            plan: nil,
            email: account.email,
            queriedAt: queriedAt,
            error: nil
        )
    }

    private func resolveWorkspaceID(cookieHeader: String, configured: String?) async throws -> String {
        if let id = OpenCodeGoResponseParser.normalizeWorkspaceID(configured) {
            return id
        }

        let getText = try await fetchServerFunction(
            cookieHeader: cookieHeader,
            method: "GET",
            args: nil
        )
        if OpenCodeGoResponseParser.looksSignedOut(getText) {
            throw QuotaError.needsLogin
        }
        if let id = OpenCodeGoResponseParser.workspaceIDs(from: getText).first {
            return id
        }

        let postText = try await fetchServerFunction(
            cookieHeader: cookieHeader,
            method: "POST",
            args: "[]"
        )
        if OpenCodeGoResponseParser.looksSignedOut(postText) {
            throw QuotaError.needsLogin
        }
        if let id = OpenCodeGoResponseParser.workspaceIDs(from: postText).first {
            return id
        }
        throw QuotaError.parseFailure("OpenCode Go workspace id was not found.")
    }

    private func fetchServerFunction(
        cookieHeader: String,
        method: String,
        args: String?
    ) async throws -> String {
        let serverID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
        var components = URLComponents(string: "https://opencode.ai/_server")!
        if method == "GET" {
            var items = [URLQueryItem(name: "id", value: serverID)]
            if let args { items.append(URLQueryItem(name: "args", value: args)) }
            components.queryItems = items
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(serverID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://opencode.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://opencode.ai", forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if method != "GET", let args {
            request.httpBody = Data(args.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await fetchText(request)
    }

    private func fetchPage(url: URL, cookieHeader: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return try await fetchText(request)
    }

    private func fetchText(_ request: URLRequest) async throws -> String {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw QuotaError.network("OpenCode Go network error: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("OpenCode Go: invalid response object")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 || OpenCodeGoResponseParser.looksSignedOut(text) {
                throw QuotaError.needsLogin
            }
            if http.statusCode == 429 {
                throw QuotaError.rateLimited
            }
            throw QuotaError.network("OpenCode Go returned HTTP \(http.statusCode).")
        }
        guard !text.isEmpty else {
            throw QuotaError.parseFailure("OpenCode Go returned an empty body.")
        }
        return text
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
}

enum OpenCodeGoResponseParser {
    struct Snapshot {
        var buckets: [QuotaBucket]
    }

    private struct ParsedWindow {
        var percent: Double
        var resetAt: Date?
    }

    static func parse(text: String, now: Date) throws -> Snapshot {
        if let snapshot = parseJSON(text: text, now: now) {
            return snapshot
        }

        guard let rollingPercent = extractDouble(pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
              let rollingReset = extractInt(pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text),
              let weeklyPercent = extractDouble(pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text),
              let weeklyReset = extractInt(pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text) else {
            throw QuotaError.parseFailure("OpenCode Go usage fields were not found.")
        }
        let monthlyPercent = extractDouble(pattern: #"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text)
        let monthlyReset = extractInt(pattern: #"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        return buildSnapshot(
            rolling: ParsedWindow(
                percent: rollingPercent,
                resetAt: rollingPercent == 0 ? nil : now.addingTimeInterval(TimeInterval(rollingReset))
            ),
            weekly: ParsedWindow(
                percent: weeklyPercent,
                resetAt: weeklyPercent == 0 ? nil : now.addingTimeInterval(TimeInterval(weeklyReset))
            ),
            monthly: monthlyPercent.map {
                ParsedWindow(
                    percent: $0,
                    resetAt: $0 == 0 ? nil : monthlyReset.map { now.addingTimeInterval(TimeInterval($0)) }
                )
            }
        )
    }

    static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 {
            return trimmed
        }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"),
               parts.count > index + 1,
               parts[index + 1].hasPrefix("wrk_") {
                return parts[index + 1]
            }
        }
        if let match = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    static func workspaceIDs(from text: String) -> [String] {
        var ids: [String] = []
        collectWorkspaceIDs(object: jsonObject(from: text) as Any, out: &ids)
        let pattern = #"id\s*:\s*\"(wrk_[^\"]+)\""#
        for match in matches(pattern: pattern, text: text) {
            if !ids.contains(match) { ids.append(match) }
        }
        return ids
    }

    static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login") ||
            lower.contains("sign in") ||
            lower.contains("auth/authorize") ||
            lower.contains("not associated with an account") ||
            lower.contains("actor of type \"public\"")
    }

    private static func parseJSON(text: String, now: Date) -> Snapshot? {
        guard let object = jsonObject(from: text) else { return nil }
        return parseUsageCandidates(object: object, path: [], now: now)
    }

    private static func parseUsageCandidates(object: Any, path: [String], now: Date) -> Snapshot? {
        if let dict = object as? [String: Any] {
            if let snapshot = parseNamedUsageDictionary(dict, now: now) {
                return snapshot
            }
            for (key, value) in dict {
                if let snapshot = parseUsageCandidates(object: value, path: path + [key], now: now) {
                    return snapshot
                }
            }
        } else if let array = object as? [Any] {
            for (index, value) in array.enumerated() {
                if let snapshot = parseUsageCandidates(object: value, path: path + ["[\(index)]"], now: now) {
                    return snapshot
                }
            }
        }
        return nil
    }

    private static func parseNamedUsageDictionary(_ dict: [String: Any], now: Date) -> Snapshot? {
        let rolling = firstDict(from: dict, keys: ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"])
        let weekly = firstDict(from: dict, keys: ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"])
        let monthly = firstDict(from: dict, keys: ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow", "monthly_window"])
        guard let rolling,
              let weekly,
              let rollingWindow = parseWindow(rolling, now: now),
              let weeklyWindow = parseWindow(weekly, now: now) else {
            return nil
        }
        return buildSnapshot(
            rolling: rollingWindow,
            weekly: weeklyWindow,
            monthly: monthly.flatMap { parseWindow($0, now: now) }
        )
    }

    private static func parseWindow(_ dict: [String: Any], now: Date) -> ParsedWindow? {
        let percentKeys = ["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "used_percent", "utilization", "utilizationPercent", "utilization_percent", "usage"]
        let resetInKeys = ["resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec", "resetsInSec", "resetsInSeconds", "resetIn", "resetSec"]
        let resetAtKeys = ["resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "next_reset", "renewAt", "renew_at"]
        var percent = firstDouble(forKeys: percentKeys, in: dict)
        if percent == nil,
           let used = firstDouble(forKeys: ["used", "usage", "consumed", "count", "usedTokens"], in: dict),
           let limit = firstDouble(forKeys: ["limit", "total", "quota", "max", "cap", "tokenLimit"], in: dict),
           limit > 0 {
            percent = used / limit * 100
        }
        guard var resolvedPercent = percent else { return nil }
        if resolvedPercent <= 1, resolvedPercent >= 0 { resolvedPercent *= 100 }
        resolvedPercent = max(0, min(100, resolvedPercent))
        let resetAt = firstInt(forKeys: resetInKeys, in: dict)
            .map { now.addingTimeInterval(TimeInterval(max(0, $0))) }
            ?? firstDate(forKeys: resetAtKeys, in: dict)
        return ParsedWindow(
            percent: resolvedPercent,
            // OpenCode currently emits now + window placeholders before a
            // quota cycle has started. At 0% that is not a trustworthy plan
            // anchor, so keep utilization while withholding the fake reset.
            resetAt: resolvedPercent == 0 ? nil : resetAt
        )
    }

    private static func buildSnapshot(
        rolling: ParsedWindow,
        weekly: ParsedWindow,
        monthly: ParsedWindow?
    ) -> Snapshot {
        var buckets = [
            QuotaBucket(
                id: "opencodego.rolling",
                title: "5 Hours",
                shortLabel: "5h",
                usedPercent: rolling.percent,
                resetAt: rolling.resetAt,
                rawWindowSeconds: 5 * 3600
            ),
            QuotaBucket(
                id: "opencodego.weekly",
                title: "Weekly",
                shortLabel: "Wk",
                usedPercent: weekly.percent,
                resetAt: weekly.resetAt,
                rawWindowSeconds: 7 * 86_400
            )
        ]
        if let monthly {
            buckets.append(QuotaBucket(
                id: "opencodego.monthly",
                title: "Monthly",
                shortLabel: "Month",
                usedPercent: monthly.percent,
                resetAt: monthly.resetAt,
                rawWindowSeconds: 30 * 86_400
            ))
        }
        return Snapshot(buckets: buckets)
    }

    private static func jsonObject(from text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func collectWorkspaceIDs(object: Any?, out: inout [String]) {
        if let dict = object as? [String: Any] {
            for value in dict.values { collectWorkspaceIDs(object: value, out: &out) }
        } else if let array = object as? [Any] {
            for value in array { collectWorkspaceIDs(object: value, out: &out) }
        } else if let string = object as? String,
                  string.hasPrefix("wrk_"),
                  !out.contains(string) {
            out.append(string)
        }
    }

    private static func firstDict(from dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func firstDouble(forKeys keys: [String], in dict: [String: Any]) -> Double? {
        for key in keys {
            if let value = double(from: dict[key]) { return value }
        }
        return nil
    }

    private static func firstInt(forKeys keys: [String], in dict: [String: Any]) -> Int? {
        for key in keys {
            if let value = int(from: dict[key]) { return value }
        }
        return nil
    }

    private static func firstDate(forKeys keys: [String], in dict: [String: Any]) -> Date? {
        for key in keys {
            if let value = date(from: dict[key]) { return value }
        }
        return nil
    }

    private static func matches(pattern: String, text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func extractDouble(pattern: String, text: String) -> Double? {
        matches(pattern: pattern, text: text).first.flatMap(Double.init)
    }

    private static func extractInt(pattern: String, text: String) -> Int? {
        matches(pattern: pattern, text: text).first.flatMap(Int.init)
    }

    private static func double(from raw: Any?) -> Double? {
        switch raw {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func int(from raw: Any?) -> Int? {
        switch raw {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func date(from raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let number = double(from: raw) {
            if number > 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
            if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
        }
        guard let string = raw as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: string) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
