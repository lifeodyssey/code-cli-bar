import Foundation

public enum ActualCashKind: String, Codable, CaseIterable, Sendable {
    case subscription
    case creditPurchase
    case overage
    case other

    public var displayName: String {
        switch self {
        case .subscription: "Subscription"
        case .creditPurchase: "Credit purchase"
        case .overage: "Overage"
        case .other: "Other"
        }
    }
}
public enum ActualCashCadence: String, Codable, CaseIterable, Sendable {
    case once
    case monthly

    public var displayName: String {
        switch self {
        case .once: "One time"
        case .monthly: "Monthly"
        }
    }
}

/// A user-confirmed cash payment rule. It is intentionally manual: provider
/// token logs estimate API value but cannot prove what a credit card was
/// charged. Monthly entries generate occurrences from their first payment
/// date; one-time entries contribute only on `startsAt`.
public struct ActualCashEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var provider: CodeCLIProvider?
    public var kind: ActualCashKind
    public var title: String
    public var amountUSD: Double
    public var startsAt: Date
    public var cadence: ActualCashCadence

    public init(
        id: UUID = UUID(),
        provider: CodeCLIProvider? = nil,
        kind: ActualCashKind,
        title: String,
        amountUSD: Double,
        startsAt: Date,
        cadence: ActualCashCadence
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.amountUSD = amountUSD.isFinite ? max(0, amountUSD) : 0
        self.startsAt = startsAt
        self.cadence = cadence
    }
}
