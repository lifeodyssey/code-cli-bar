import XCTest
@testable import VibeBarCore

final class CostSnapshotTests: XCTestCase {
    func testYesterdayUsesFullDisplayLabel() {
        XCTAssertEqual(CostTimeframe.yesterday.label, "Yesterday")
        XCTAssertEqual(CostTimeframe.yesterday.shortLabel, "Yesterday")
    }

    func testRebasedForCurrentDayClearsStaleTodayTotalsAndHours() throws {
        let shanghai = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = shanghai

        let yesterdayNow = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: shanghai,
            year: 2026,
            month: 5,
            day: 6,
            hour: 20
        )))
        let todayNow = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: shanghai,
            year: 2026,
            month: 5,
            day: 7,
            hour: 3
        )))
        let yesterday = calendar.startOfDay(for: yesterdayNow)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: todayNow)))
        let staleHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 20, to: yesterday))

        let snapshot = CostSnapshot(
            tool: .codex,
            todayCostUSD: 720,
            last7DaysCostUSD: 720,
            last30DaysCostUSD: 720,
            allTimeCostUSD: 720,
            todayTokens: 1_043_270_000,
            last7DaysTokens: 1_043_270_000,
            last30DaysTokens: 1_043_270_000,
            allTimeTokens: 1_043_270_000,
            dailyHistory: [
                DailyCostPoint(date: yesterday, costUSD: 720, totalTokens: 1_043_270_000),
                DailyCostPoint(date: tomorrow, costUSD: 999, totalTokens: 9_990)
            ],
            todayHourlyHistory: [
                HourlyCostPoint(date: staleHour, costUSD: 720, totalTokens: 1_043_270_000)
            ],
            heatmap: .empty(tool: .codex),
            modelBreakdowns: [],
            jsonlFilesFound: 1,
            updatedAt: yesterdayNow
        )

        let rebased = snapshot.rebasedForCurrentDay(now: todayNow, calendar: calendar)

        XCTAssertEqual(rebased.todayCostUSD, 0, accuracy: 0.001)
        XCTAssertEqual(rebased.todayTokens, 0)
        XCTAssertTrue(rebased.todayHourlyHistory.isEmpty)
        XCTAssertEqual(rebased.last7DaysCostUSD, 720, accuracy: 0.001)
        XCTAssertEqual(rebased.last7DaysTokens, 1_043_270_000)
        XCTAssertEqual(rebased.allTimeCostUSD, 720, accuracy: 0.001)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func hourlySnapshot(
        hours: [Date],
        coverageStart: Date?,
        updatedAt: Date
    ) -> CostSnapshot {
        CostSnapshot(
            tool: .codex,
            todayCostUSD: 0, last7DaysCostUSD: 0, last30DaysCostUSD: 0, allTimeCostUSD: 0,
            todayTokens: 0, last7DaysTokens: 0, last30DaysTokens: 0, allTimeTokens: 0,
            dailyHistory: [],
            recentHourlyHistory: hours.map { HourlyCostPoint(date: $0, costUSD: 1, totalTokens: 10) },
            hourlyCoverageStart: coverageStart,
            heatmap: .empty(tool: .codex),
            modelBreakdowns: [],
            jsonlFilesFound: 1,
            updatedAt: updatedAt
        )
    }

    /// The wide hourly lane ages by dropping days off its old end, not by being
    /// emptied the way the today / yesterday lanes are — otherwise rebasing a
    /// cached snapshot on load would undo the whole retention window.
    func testRebasedForCurrentDayKeepsTheHourlyWindowAndTrimsItsEdges() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 9)))
        let today = calendar.startOfDay(for: now)
        func hoursBack(_ days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: today)!.addingTimeInterval(3_600)
        }
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))

        let rebased = hourlySnapshot(
            hours: [hoursBack(20), hoursBack(13), hoursBack(4), hoursBack(0), tomorrow],
            coverageStart: calendar.date(byAdding: .day, value: -30, to: today),
            updatedAt: now
        ).rebasedForCurrentDay(now: now, calendar: calendar)

        XCTAssertEqual(rebased.recentHourlyHistory.map(\.date), [hoursBack(13), hoursBack(4), hoursBack(0)])
        // A start older than the window would have the chart claim coverage it
        // no longer has.
        XCTAssertEqual(
            rebased.hourlyCoverageStart,
            CostChartWindowPolicy.hourlyRetentionStart(now: now, calendar: calendar)
        )
    }

    func testRebasedForCurrentDayEmptiesAnHourlyWindowThatFellOutOfRange() throws {
        let calendar = utcCalendar()
        let scannedAt = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 9)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 9)))

        let rebased = hourlySnapshot(
            hours: [scannedAt],
            coverageStart: calendar.startOfDay(for: scannedAt),
            updatedAt: scannedAt
        ).rebasedForCurrentDay(now: now, calendar: calendar)

        XCTAssertTrue(rebased.recentHourlyHistory.isEmpty)
    }

    /// Snapshots cached before the window widened decode to an empty lane and
    /// no declared coverage, which is what makes the chart fall back to the two
    /// days it can still prove rather than drawing twelve days of false zeros.
    func testDecodingASnapshotWithoutTheHourlyWindowIsEmptyRatherThanOptimistic() throws {
        let calendar = utcCalendar()
        let hour = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 9)))
        let legacy = CostSnapshot(
            tool: .codex,
            todayCostUSD: 1, last7DaysCostUSD: 1, last30DaysCostUSD: 1, allTimeCostUSD: 1,
            todayTokens: 10, last7DaysTokens: 10, last30DaysTokens: 10, allTimeTokens: 10,
            dailyHistory: [],
            todayHourlyHistory: [HourlyCostPoint(date: hour, costUSD: 1, totalTokens: 10)],
            heatmap: .empty(tool: .codex),
            modelBreakdowns: [],
            jsonlFilesFound: 1,
            updatedAt: hour
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(legacy)) as? [String: Any]
        )
        json.removeValue(forKey: "recentHourlyHistory")
        json.removeValue(forKey: "hourlyCoverageStart")

        let decoded = try JSONDecoder().decode(
            CostSnapshot.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertTrue(decoded.recentHourlyHistory.isEmpty)
        XCTAssertNil(decoded.hourlyCoverageStart)
        XCTAssertEqual(decoded.todayHourlyHistory.count, 1)
    }

    func testHourlyWindowRoundTripsThroughCoding() throws {
        let calendar = utcCalendar()
        let hour = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 9)))
        let start = calendar.startOfDay(for: hour)
        let original = hourlySnapshot(hours: [hour], coverageStart: start, updatedAt: hour)

        let decoded = try JSONDecoder().decode(
            CostSnapshot.self,
            from: try JSONEncoder().encode(original)
        )

        XCTAssertEqual(decoded.recentHourlyHistory, original.recentHourlyHistory)
        XCTAssertEqual(decoded.hourlyCoverageStart, start)
    }

    func testDailyCoverageRebasesRequestAndUnpricedWindows() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 30, hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let snapshot = CostSnapshot(
            tool: .zai,
            todayCostUSD: 0,
            last7DaysCostUSD: 2,
            last30DaysCostUSD: 2,
            allTimeCostUSD: 2,
            todayTokens: 100,
            last7DaysTokens: 300,
            last30DaysTokens: 300,
            allTimeTokens: 300,
            todayRequests: 99,
            last7DaysRequests: 99,
            last30DaysRequests: 99,
            allTimeRequests: 99,
            todayUnpricedRequests: 99,
            last7DaysUnpricedRequests: 99,
            last30DaysUnpricedRequests: 99,
            allTimeUnpricedRequests: 99,
            dailyHistory: [
                DailyCostPoint(
                    date: yesterday,
                    costUSD: 2,
                    totalTokens: 200,
                    requests: 2,
                    unpricedRequests: 0
                ),
                DailyCostPoint(
                    date: today,
                    costUSD: 0,
                    totalTokens: 100,
                    requests: 1,
                    unpricedRequests: 1
                )
            ],
            heatmap: .empty(tool: .zai),
            modelBreakdowns: [],
            jsonlFilesFound: 1,
            updatedAt: now
        )

        let rebased = snapshot.rebasedForCurrentDay(now: now, calendar: calendar)

        XCTAssertEqual(rebased.todayRequests, 1)
        XCTAssertEqual(rebased.todayUnpricedRequests, 1)
        XCTAssertEqual(rebased.last7DaysRequests, 3)
        XCTAssertEqual(rebased.last7DaysUnpricedRequests, 1)
        XCTAssertEqual(rebased.allTimeRequests, 3)
    }

    func testLegacyDailyCostPointDecodesWithoutCoverageFields() throws {
        let data = Data(#"{"date":0,"costUSD":1.25,"totalTokens":42}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let point = try decoder.decode(DailyCostPoint.self, from: data)

        XCTAssertEqual(point.requests, 0)
        XCTAssertEqual(point.unpricedRequests, 0)
    }
}
