import Foundation

/// Read-only bridge from Vibe Bar's aggregate cost history into Code CLI Bar.
///
/// The source file is decoded directly instead of opening it through
/// `CostHistoryStore`: that store may migrate an old schema in place, while an
/// import must never write to `~/.vibebar`. Only daily aggregate cost/token
/// facts for the seven product providers cross the boundary. Credentials,
/// scan caches, request identifiers, projects, prompts, and responses do not.
public actor VibeBarImportService {
    public struct ProviderSummary: Sendable, Equatable, Identifiable {
        public let provider: CodeCLIProvider
        public let dayCount: Int
        public let totalCostUSD: Double
        public let totalTokens: Int

        public var id: CodeCLIProvider { provider }
    }

    public struct Preview: Sendable, Equatable {
        public let sourceURL: URL
        public let providers: [ProviderSummary]

        public var dayCount: Int { providers.reduce(0) { $0 + $1.dayCount } }
        public var totalCostUSD: Double { providers.reduce(0) { $0 + $1.totalCostUSD } }
        public var totalTokens: Int { providers.reduce(0) { $0 + $1.totalTokens } }
        public var isEmpty: Bool { providers.isEmpty }
    }

    public enum ImportError: LocalizedError, Sendable {
        case sourceMissing
        case sourceTooLarge
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .sourceMissing:
                "No Vibe Bar cost history was found."
            case .sourceTooLarge:
                "The Vibe Bar cost history is unexpectedly large and was not opened."
            case .unreadable:
                "The Vibe Bar cost history could not be decoded."
            }
        }
    }

    private struct Storage: Decodable {
        let entries: [Entry]
    }

    private struct Entry: Decodable {
        let tool: String
        let date: String
        let costUSD: Double
        let totalTokens: Int
    }

    private struct ImportedDay: Sendable {
        let provider: CodeCLIProvider
        let point: DailyCostPoint
    }

    private static let maximumSourceBytes = 64 * 1024 * 1024
    private let sourceURL: URL
    private let calendar: Calendar
    private let dateFormatter: DateFormatter

    public init(
        sourceURL: URL = URL(fileURLWithPath: RealHomeDirectory.path, isDirectory: true)
            .appendingPathComponent(".vibebar", isDirectory: true)
            .appendingPathComponent("cost_history.json")
    ) {
        self.sourceURL = sourceURL
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        self.dateFormatter = formatter
    }

    public func preview() throws -> Preview {
        let days = try loadDays()
        let grouped = Dictionary(grouping: days, by: \ImportedDay.provider)
        let summaries = CodeCLIProvider.allCases.compactMap { provider -> ProviderSummary? in
            guard let values = grouped[provider], !values.isEmpty else { return nil }
            return ProviderSummary(
                provider: provider,
                dayCount: values.count,
                totalCostUSD: values.reduce(0) { $0 + $1.point.costUSD },
                totalTokens: values.reduce(0) { $0 + $1.point.totalTokens }
            )
        }
        return Preview(sourceURL: sourceURL, providers: summaries)
    }

    /// Max-merges imported daily aggregates into the product store. Repeating
    /// the same import is idempotent and the legacy source remains untouched.
    @discardableResult
    public func importCostHistory(
        into destination: CostHistoryStore = .shared,
        retentionDays: Int = CostDataSettings.unlimitedRetentionDays
    ) async throws -> Preview {
        let days = try loadDays()
        let grouped = Dictionary(grouping: days, by: \ImportedDay.provider)
        for provider in CodeCLIProvider.allCases {
            guard let tool = provider.legacyTool,
                  let values = grouped[provider],
                  !values.isEmpty
            else { continue }
            await destination.mergeSeries(
                values.map(\.point),
                tool: tool,
                retentionDays: retentionDays
            )
        }
        await destination.flushPendingWrites()
        return try preview()
    }

    private func loadDays() throws -> [ImportedDay] {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ImportError.sourceMissing
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        if let size = (attributes?[.size] as? NSNumber)?.intValue,
           size > Self.maximumSourceBytes {
            throw ImportError.sourceTooLarge
        }
        guard let data = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]),
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else { throw ImportError.unreadable }

        var byProviderAndDay: [String: ImportedDay] = [:]
        for entry in storage.entries {
            guard let tool = ToolType(rawValue: entry.tool),
                  let provider = CodeCLIProvider.allCases.first(where: { $0.legacyTool == tool }),
                  let date = dateFormatter.date(from: entry.date),
                  entry.costUSD.isFinite,
                  entry.costUSD >= 0,
                  entry.totalTokens >= 0
            else { continue }
            let day = calendar.startOfDay(for: date)
            let point = DailyCostPoint(
                date: day,
                costUSD: entry.costUSD,
                totalTokens: entry.totalTokens
            )
            let key = "\(provider.rawValue)\u{0}\(entry.date)"
            if let existing = byProviderAndDay[key] {
                byProviderAndDay[key] = ImportedDay(
                    provider: provider,
                    point: DailyCostPoint(
                        date: day,
                        costUSD: max(existing.point.costUSD, point.costUSD),
                        totalTokens: max(existing.point.totalTokens, point.totalTokens)
                    )
                )
            } else {
                byProviderAndDay[key] = ImportedDay(provider: provider, point: point)
            }
        }
        return byProviderAndDay.values.sorted {
            if $0.provider != $1.provider {
                let left = CodeCLIProvider.allCases.firstIndex(of: $0.provider) ?? 0
                let right = CodeCLIProvider.allCases.firstIndex(of: $1.provider) ?? 0
                return left < right
            }
            return $0.point.date < $1.point.date
        }
    }
}
