import Foundation

/// The provider's current subscription-week window.
///
/// This is deliberately not a rolling seven-day range. The anchor comes from
/// a weekly quota bucket, so local token/cost usage lines up with the exact
/// cycle whose percentage the provider reports.
public struct PlanWeekWindow: Sendable, Equatable, Hashable {
    public static let sevenDays: TimeInterval = 7 * 24 * 60 * 60

    public let start: Date
    public let nextResetAt: Date
    public let durationSeconds: Int
    public let bucketID: String

    public init(start: Date, nextResetAt: Date, durationSeconds: Int, bucketID: String) {
        self.start = start
        self.nextResetAt = nextResetAt
        self.durationSeconds = durationSeconds
        self.bucketID = bucketID
    }

    /// Resolves the cycle containing `now`. A cached quota may still point to
    /// an earlier reset after an offline launch; advance that anchor by whole
    /// weekly windows instead of discarding otherwise valid cycle metadata.
    public static func resolve(quota: AccountQuota?, now: Date = Date()) -> PlanWeekWindow? {
        guard let bucket = weeklyBucket(in: quota),
              let resetAt = bucket.resetAt,
              let durationSeconds = weeklyDurationSeconds(for: bucket)
        else { return nil }

        let duration = TimeInterval(durationSeconds)
        var nextReset = resetAt
        if nextReset <= now {
            let elapsed = now.timeIntervalSince(nextReset)
            let cycles = floor(elapsed / duration) + 1
            nextReset = nextReset.addingTimeInterval(cycles * duration)
        } else if nextReset.timeIntervalSince(now) > duration {
            let cycles = floor(nextReset.timeIntervalSince(now) / duration)
            nextReset = nextReset.addingTimeInterval(-cycles * duration)
            if nextReset <= now {
                nextReset = nextReset.addingTimeInterval(duration)
            }
        }

        return PlanWeekWindow(
            start: nextReset.addingTimeInterval(-duration),
            nextResetAt: nextReset,
            durationSeconds: durationSeconds,
            bucketID: bucket.id
        )
    }

    /// Prefer the provider's aggregate `weekly` pool over model-specific
    /// weekly lanes. When an adapter uses a different id, a seven-day window
    /// or an explicit Weekly label is still sufficient evidence.
    public static func weeklyBucket(in quota: AccountQuota?) -> QuotaBucket? {
        guard let buckets = quota?.buckets else { return nil }
        let candidates = buckets.filter { weeklyDurationSeconds(for: $0) != nil && $0.resetAt != nil }
        return candidates.first(where: { $0.id.lowercased() == "weekly" && $0.groupTitle == nil })
            ?? candidates.first(where: { $0.id.lowercased() == "weekly" })
            ?? candidates.first(where: { $0.groupTitle == nil })
            ?? candidates.first
    }

    private static func weeklyDurationSeconds(for bucket: QuotaBucket) -> Int? {
        if let seconds = bucket.rawWindowSeconds,
           (6 * 86_400 ... 8 * 86_400).contains(seconds) {
            return seconds
        }
        let weeklyText = [bucket.id, bucket.title, bucket.shortLabel]
            .joined(separator: " ")
            .lowercased()
        guard weeklyText.contains("week") else { return nil }
        return Int(sevenDays)
    }
}
