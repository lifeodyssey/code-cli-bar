import Foundation

/// The trust boundary for quota snapshots.
///
/// Provider reset timestamps describe the quota cycle; they do not prove the
/// utilization beside them is current. Every consumer that presents a value
/// as current should validate the snapshot timestamp through this policy.
public enum QuotaFreshnessPolicy {
    /// Tolerate small clock differences between the provider and this Mac,
    /// while rejecting timestamps far enough in the future to be corrupt.
    public static let allowedClockSkew: TimeInterval = 5 * 60

    /// A provider-authored on-disk snapshot can bridge a short credential
    /// outage. Beyond this limit it remains useful as cycle metadata only.
    public static let credentialFallbackMaxAge: TimeInterval = 30 * 60

    public static func isFresh(
        timestamp: Date?,
        maxAge: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let timestamp, maxAge > 0 else { return false }
        let age = now.timeIntervalSince(timestamp)
        return age >= -allowedClockSkew && age < maxAge
    }
}
