import XCTest
@testable import VibeBarCore

final class PlanWeekWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_777_780_800)

    func testUsesExactWeeklyResetAndWindowLength() throws {
        let reset = now.addingTimeInterval(2 * 86_400)
        let quota = makeQuota(buckets: [
            QuotaBucket(
                id: "weekly",
                title: "Weekly",
                shortLabel: "Weekly",
                usedPercent: 40,
                resetAt: reset,
                rawWindowSeconds: 604_800
            )
        ])

        let window = try XCTUnwrap(PlanWeekWindow.resolve(quota: quota, now: now))

        XCTAssertEqual(window.start, reset.addingTimeInterval(-604_800))
        XCTAssertEqual(window.nextResetAt, reset)
        XCTAssertEqual(window.durationSeconds, 604_800)
        XCTAssertEqual(window.bucketID, "weekly")
    }

    func testWeeklyLabelSuppliesSevenDayDurationWhenProviderOmitsIt() throws {
        let reset = now.addingTimeInterval(3 * 86_400)
        let quota = makeQuota(buckets: [
            QuotaBucket(
                id: "provider_weekly_pool",
                title: "Weekly allowance",
                shortLabel: "Weekly",
                usedPercent: 12,
                resetAt: reset
            )
        ])

        let window = try XCTUnwrap(PlanWeekWindow.resolve(quota: quota, now: now))

        XCTAssertEqual(window.start, reset.addingTimeInterval(-PlanWeekWindow.sevenDays))
        XCTAssertEqual(window.durationSeconds, 604_800)
    }

    func testAdvancesStaleCachedResetByWholeCycles() throws {
        let staleReset = now.addingTimeInterval(-9 * 86_400)
        let quota = makeQuota(buckets: [
            QuotaBucket(
                id: "weekly",
                title: "Weekly",
                shortLabel: "Weekly",
                usedPercent: 90,
                resetAt: staleReset,
                rawWindowSeconds: 604_800
            )
        ])

        let window = try XCTUnwrap(PlanWeekWindow.resolve(quota: quota, now: now))

        XCTAssertEqual(window.nextResetAt, staleReset.addingTimeInterval(2 * 604_800))
        XCTAssertLessThanOrEqual(window.start, now)
        XCTAssertGreaterThan(window.nextResetAt, now)
    }

    func testPrefersAggregateWeeklyBucketOverModelSpecificPool() throws {
        let aggregateReset = now.addingTimeInterval(2 * 86_400)
        let quota = makeQuota(buckets: [
            QuotaBucket(
                id: "weekly_sonnet",
                title: "Weekly",
                shortLabel: "Sonnet Weekly",
                usedPercent: 70,
                resetAt: now.addingTimeInterval(1 * 86_400),
                rawWindowSeconds: 604_800,
                groupTitle: "Sonnet"
            ),
            QuotaBucket(
                id: "weekly",
                title: "Weekly",
                shortLabel: "All Models Weekly",
                usedPercent: 50,
                resetAt: aggregateReset,
                rawWindowSeconds: 604_800
            )
        ])

        let window = try XCTUnwrap(PlanWeekWindow.resolve(quota: quota, now: now))

        XCTAssertEqual(window.bucketID, "weekly")
        XCTAssertEqual(window.nextResetAt, aggregateReset)
    }

    func testDoesNotInventWeekFromNonWeeklyQuota() {
        let quota = makeQuota(buckets: [
            QuotaBucket(
                id: "five_hour",
                title: "5 Hours",
                shortLabel: "5 Hours",
                usedPercent: 20,
                resetAt: now.addingTimeInterval(3_600),
                rawWindowSeconds: 18_000
            )
        ])

        XCTAssertNil(PlanWeekWindow.resolve(quota: quota, now: now))
    }

    private func makeQuota(buckets: [QuotaBucket]) -> AccountQuota {
        AccountQuota(accountId: "test", tool: .claude, buckets: buckets, queriedAt: now)
    }
}
