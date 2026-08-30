import Combine
import Foundation

@MainActor
public final class ActualCashStore: ObservableObject {
    @Published public private(set) var entries: [ActualCashEntry] {
        didSet { persist() }
    }

    private struct Storage: Codable {
        var schemaVersion: Int = 1
        var entries: [ActualCashEntry]
    }

    private let url: URL
    private let calendar: Calendar

    public init(
        url: URL = VibeBarLocalStore.actualCashLedgerURL,
        calendar: Calendar = .current
    ) {
        self.url = url
        self.calendar = calendar
        let loaded = try? VibeBarLocalStore.readJSON(Storage.self, from: url)
        self.entries = Self.normalized(loaded?.entries ?? [])
    }

    public func add(_ entry: ActualCashEntry) {
        guard entry.amountUSD > 0 else { return }
        entries.append(entry)
        entries = Self.normalized(entries)
    }

    public func remove(id: ActualCashEntry.ID) {
        entries.removeAll { $0.id == id }
    }

    public func total(
        from start: Date,
        to end: Date,
        now: Date = Date()
    ) -> Double {
        guard end > start else { return 0 }
        let effectiveEnd = min(end, now.addingTimeInterval(0.001))
        guard effectiveEnd > start else { return 0 }
        return entries.reduce(0) { partial, entry in
            partial + occurrences(of: entry, from: start, to: effectiveEnd)
        }
    }

    public func todayTotal(now: Date = Date()) -> Double {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        return total(from: start, to: end, now: now)
    }

    public func lastSevenDaysTotal(now: Date = Date()) -> Double {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return total(from: start, to: end, now: now)
    }

    public func calendarMonthTotal(now: Date = Date()) -> Double {
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return 0 }
        return total(from: interval.start, to: interval.end, now: now)
    }

    private func occurrences(
        of entry: ActualCashEntry,
        from start: Date,
        to end: Date
    ) -> Double {
        switch entry.cadence {
        case .once:
            return entry.startsAt >= start && entry.startsAt < end ? entry.amountUSD : 0
        case .monthly:
            guard entry.startsAt < end else { return 0 }
            var total = 0.0
            // 200 years is a corruption guard, not a product limit.
            for offset in 0..<2_400 {
                guard let occurrence = calendar.date(
                    byAdding: .month,
                    value: offset,
                    to: entry.startsAt
                ) else { break }
                if occurrence >= end { break }
                if occurrence >= start { total += entry.amountUSD }
            }
            return total
        }
    }

    private static func normalized(_ entries: [ActualCashEntry]) -> [ActualCashEntry] {
        var seen = Set<UUID>()
        return entries
            .filter { $0.amountUSD.isFinite && $0.amountUSD > 0 && seen.insert($0.id).inserted }
            .sorted {
                if $0.startsAt != $1.startsAt { return $0.startsAt > $1.startsAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private func persist() {
        do {
            try VibeBarLocalStore.writeJSON(Storage(entries: entries), to: url)
        } catch {
            SafeLog.warn("Saving actual cash ledger failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
    }
}
