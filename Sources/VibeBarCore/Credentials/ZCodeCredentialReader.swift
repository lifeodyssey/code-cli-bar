import Foundation

public struct ZCodeCredential: Sendable, Equatable {
    public let apiKey: String
    public let providerID: String
    public let planName: String?
    public let quotaURL: URL

    public init(apiKey: String, providerID: String, planName: String?, quotaURL: URL) {
        self.apiKey = apiKey
        self.providerID = providerID
        self.planName = planName
        self.quotaURL = quotaURL
    }
}

/// Read-only access to the Coding Plan API key generated and maintained by ZCode.
///
/// ZCode's login JWTs live in an encrypted credential store, but the quota API
/// does not use those JWTs. Its own quota client reads the generated provider
/// API key from `~/.zcode/v2/config.json` and sends it as the raw
/// `Authorization` header. Mirroring that distinction avoids a false 401 from
/// otherwise-valid local ZCode sessions.
public enum ZCodeCredentialReader {
    public static func load(homeDirectory: String = RealHomeDirectory.path) throws -> ZCodeCredential {
        let url = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".zcode/v2/config.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        do {
            return try decode(data: Data(contentsOf: url))
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.parseFailure("Could not read the ZCode provider configuration.")
        }
    }

    public static func decode(data: Data) throws -> ZCodeCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["provider"] as? [String: Any]
        else {
            throw QuotaError.parseFailure("ZCode provider configuration is invalid.")
        }

        let candidates = providers.compactMap { providerID, raw -> Candidate? in
            guard providerID == "builtin:bigmodel-coding-plan"
                    || providerID == "builtin:zai-coding-plan",
                  let provider = raw as? [String: Any],
                  (provider["enabled"] as? Bool) != false,
                  string(provider["systemDisabledReason"]) == nil,
                  let options = provider["options"] as? [String: Any],
                  let apiKey = string(options["apiKey"])
            else { return nil }

            let quotaURL = quotaURL(
                providerID: providerID,
                baseURL: string(options["baseURL"])
            )
            return Candidate(
                credential: ZCodeCredential(
                    apiKey: apiKey,
                    providerID: providerID,
                    planName: string(provider["name"]),
                    quotaURL: quotaURL
                ),
                isExplicitlyEnabled: (provider["enabled"] as? Bool) == true
            )
        }

        guard let selected = candidates.sorted(by: { lhs, rhs in
            if lhs.isExplicitlyEnabled != rhs.isExplicitlyEnabled {
                return lhs.isExplicitlyEnabled && !rhs.isExplicitlyEnabled
            }
            return lhs.credential.providerID < rhs.credential.providerID
        }).first else {
            throw QuotaError.noCredential
        }
        return selected.credential
    }

    private struct Candidate {
        let credential: ZCodeCredential
        let isExplicitlyEnabled: Bool
    }

    private static func quotaURL(providerID: String, baseURL: String?) -> URL {
        if let baseURL,
           let components = URLComponents(string: baseURL),
           let host = components.host?.lowercased() {
            if host.contains("bigmodel.cn") {
                return URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
            }
            if host.contains("z.ai") || host.contains("chatglm.site") {
                return URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
            }
        }
        if providerID == "builtin:bigmodel-coding-plan" {
            return URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
        }
        return URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    }

    private static func string(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
