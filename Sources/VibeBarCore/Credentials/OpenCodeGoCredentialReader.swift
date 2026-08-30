import Foundation

public struct OpenCodeGoCredential: Sendable, Equatable {
    public let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

/// Read-only access to the credential that OpenCode stores for the Go plan.
public enum OpenCodeGoCredentialReader {
    public static func load() throws -> OpenCodeGoCredential {
        let url = RealHomeDirectory.url
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw QuotaError.noCredential
        }
        return try decode(data: Data(contentsOf: url))
    }

    public static func decode(data: Data) throws -> OpenCodeGoCredential {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any]
        else {
            throw QuotaError.noCredential
        }
        let apiKey = (entry["key"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { throw QuotaError.needsLogin }
        return OpenCodeGoCredential(apiKey: apiKey)
    }
}
