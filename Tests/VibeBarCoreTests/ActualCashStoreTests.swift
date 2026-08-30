import XCTest
@testable import VibeBarCore

@MainActor
final class ActualCashStoreTests: XCTestCase {
    func testMonthlyAndOneTimePaymentsStaySeparateFromEstimatesAndPersist() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeCLIBarCash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cash.json")
        let store = ActualCashStore(url: url, calendar: calendar)
        let subscriptionStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 15, hour: 9
        )))
        let creditDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 5, hour: 9
        )))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 20, hour: 12
        )))

        store.add(ActualCashEntry(
            provider: .claudeCode,
            kind: .subscription,
            title: "Claude Max",
            amountUSD: 20,
            startsAt: subscriptionStart,
            cadence: .monthly
        ))
        store.add(ActualCashEntry(
            provider: .openCodeGo,
            kind: .creditPurchase,
            title: "Go credits",
            amountUSD: 7.5,
            startsAt: creditDate,
            cadence: .once
        ))

        XCTAssertEqual(store.calendarMonthTotal(now: now), 27.5, accuracy: 0.001)
        XCTAssertEqual(store.todayTotal(now: now), 0, accuracy: 0.001)

        let reloaded = ActualCashStore(url: url, calendar: calendar)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.calendarMonthTotal(now: now), 27.5, accuracy: 0.001)
    }

    func testFutureMonthlyRenewalIsNotCountedAsPaidYet() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeCLIBarCashFuture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActualCashStore(
            url: directory.appendingPathComponent("cash.json"),
            calendar: calendar
        )
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 1, day: 25, hour: 9
        )))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 20, hour: 12
        )))
        store.add(ActualCashEntry(
            provider: .codex,
            kind: .subscription,
            title: "ChatGPT",
            amountUSD: 20,
            startsAt: start,
            cadence: .monthly
        ))

        XCTAssertEqual(store.calendarMonthTotal(now: now), 0, accuracy: 0.001)
    }
}
