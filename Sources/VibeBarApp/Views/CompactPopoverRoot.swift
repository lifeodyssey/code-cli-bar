import AppKit
import SwiftUI
import VibeBarCore

struct CompactPopoverRoot: View {
    @ObservedObject private var costService: CostUsageService
    @ObservedObject private var quotaService: QuotaService
    @ObservedObject private var accountStore: AccountStore
    @ObservedObject private var settingsStore: CodeCLIBarSettingsStore
    @ObservedObject private var detectionService: CodeCLIProviderDetectionService
    @ObservedObject private var actualCashStore: ActualCashStore

    private let environment: AppEnvironment
    @State private var expandedProvider: CodeCLIProvider?
    @State private var planWeekUsageByProvider: [CodeCLIProvider: CompactPlanWeekUsage] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
        self.costService = environment.costService
        self.quotaService = environment.quotaService
        self.accountStore = environment.accountStore
        self.settingsStore = environment.codeCLISettingsStore
        self.detectionService = environment.providerDetectionService
        self.actualCashStore = environment.actualCashStore
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    spendSummary
                    if visibleProviders.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleProviders) { provider in
                            CompactProviderRow(
                                provider: provider,
                                snapshot: snapshot(for: provider),
                                quota: quota(for: provider),
                                quotaFreshness: quotaFreshness(for: provider),
                                account: account(for: provider),
                                detection: detectionService.detection(for: provider),
                                planWeekUsage: planWeekUsage(for: provider),
                                quotaService: quotaService,
                                isExpanded: expandedProvider == provider,
                                onToggle: {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        expandedProvider = expandedProvider == provider ? nil : provider
                                    }
                                }
                            )
                        }
                    }
                    footer
                }
                .padding(12)
            }
        }
        .frame(width: 390, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: planWeekRefreshKey) {
            await refreshPlanWeekUsage()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Code CLI Bar")
                    .font(.system(size: 14, weight: .semibold))
                Text("Local usage and plan quota")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                environment.refreshCodeCLIBar()
            } label: {
                if costService.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh usage and quota")

            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var spendSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("API equivalent")
                    .font(.caption.weight(.semibold))
                Spacer()
                if !actualCashStore.entries.isEmpty {
                    Text("Actual cash \(formatUSD(actualCashStore.calendarMonthTotal())) this month")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 0) {
                summaryMetric(
                    "Today",
                    state: .available(
                        costUSD: summary.todayCost,
                        tokens: summary.todayTokens,
                        unpricedRequests: summary.todayUnpricedRequests
                    )
                )
                Divider().frame(height: 42)
                summaryMetric("Week", state: planWeekSummary)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
    }

    private func summaryMetric(
        _ title: String,
        state: CompactUsageMetricState
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            switch state {
            case .available(let costUSD, let tokens, let unpricedRequests):
                Text(formatKnownCost(costUSD, unpricedRequests: unpricedRequests))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("\(formatTokens(tokens)) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .loading:
                Text("$…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Calculating")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .unavailable:
                Text("$—")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Reset time unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 25))
                .foregroundStyle(.secondary)
            Text("No enabled CLI data detected")
                .font(.headline)
            Text("Open Settings to choose providers or add a custom data path.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: openSettings) {
                Text("Open Settings")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var footer: some View {
        HStack {
            Label("Local only", systemImage: "lock")
            Spacer()
            if let date = costService.lastRefreshedAt {
                Text("Updated \(date, style: .relative)")
            } else {
                Text("Waiting for first scan")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 2)
    }

    private var visibleProviders: [CodeCLIProvider] {
        CodeCLIProvider.allCases.filter { provider in
            let configuration = settingsStore.settings.configuration(for: provider)
            guard configuration.isEnabled else { return false }
            return detectionService.detection(for: provider).isDetected
                || (snapshot(for: provider)?.jsonlFilesFound ?? 0) > 0
                || rawQuota(for: provider) != nil
        }
    }

    private func snapshot(for provider: CodeCLIProvider) -> CostSnapshot? {
        guard let tool = provider.legacyTool else { return nil }
        return costService.snapshot(for: tool)
    }

    private func account(for provider: CodeCLIProvider) -> AccountIdentity? {
        if provider.usesExperimentalQuota,
           !settingsStore.settings.configuration(for: provider).experimentalQuotaEnabled {
            return nil
        }
        guard let tool = provider.legacyTool else { return nil }
        let accounts = accountStore.accounts(for: tool)
        return accounts.first(where: { $0.source != .notConfigured }) ?? accounts.first
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var quotaStaleAfter: TimeInterval {
        TimeInterval(max(300, settingsStore.settings.quotaRefreshIntervalSeconds * 2))
    }

    private func rawQuota(for provider: CodeCLIProvider) -> AccountQuota? {
        guard let account = account(for: provider) else { return nil }
        return quotaService.cachedQuota(for: account.id)
    }

    /// The only quota handed to bars and plan-week calculations. Keeping this
    /// gate at the composition boundary protects every compact provider row,
    /// including adapters added later.
    private func quota(for provider: CodeCLIProvider, now: Date = Date()) -> AccountQuota? {
        guard let account = account(for: provider) else { return nil }
        if let current = quotaService.currentCachedQuota(
            for: account.id,
            maxAge: quotaStaleAfter,
            now: now
        ) {
            return current
        }
        // Keep only provider-declared cycles that have not reset yet. The
        // freshness label below remains visible, so this is presented as a
        // last-known value rather than silently masquerading as live quota.
        return quotaService.lastKnownCurrentCycleQuota(
            for: account.id,
            now: now
        )
    }

    private func quotaFreshness(
        for provider: CodeCLIProvider,
        now: Date = Date()
    ) -> QuotaFreshnessLabel.Description? {
        guard let account = account(for: provider) else { return nil }
        return QuotaFreshnessLabel.describe(
            lastSuccessAt: quotaService.lastUpdatedByAccount[account.id],
            lastAttemptAt: quotaService.lastAttemptedByAccount[account.id],
            errorMessage: quotaService.lastErrorByAccount[account.id]?.userFacingMessage,
            staleAfter: quotaStaleAfter,
            now: now
        )
    }

    private var selectedSnapshots: [CostSnapshot] {
        CodeCLIProvider.allCases.compactMap { provider in
            guard settingsStore.settings.configuration(for: provider).isEnabled else { return nil }
            return snapshot(for: provider)
        }
    }

    private var summary: CompactUsageSummary {
        CompactUsageSummary(snapshots: selectedSnapshots)
    }

    private func planWeekUsage(for provider: CodeCLIProvider) -> CompactPlanWeekUsage {
        guard let window = PlanWeekWindow.resolve(quota: quota(for: provider)) else {
            return .unavailable
        }
        if let loaded = planWeekUsageByProvider[provider], loaded.window == window {
            return loaded
        }
        return .loading(window: window)
    }

    private var planWeekSummary: CompactUsageMetricState {
        let providers = CodeCLIProvider.allCases.filter { provider in
            settingsStore.settings.configuration(for: provider).isEnabled
                && snapshot(for: provider) != nil
        }
        guard !providers.isEmpty else { return .unavailable }

        var costUSD = 0.0
        var tokens = 0
        var unpricedRequests = 0
        var hasAvailableUsage = false
        var isLoading = false
        for provider in providers {
            switch planWeekUsage(for: provider) {
            case .available(_, let providerCost, let providerTokens, let providerUnpriced):
                hasAvailableUsage = true
                costUSD += providerCost
                tokens += providerTokens
                unpricedRequests += providerUnpriced
            case .loading:
                isLoading = true
            case .unavailable:
                continue
            }
        }
        if isLoading { return .loading }
        guard hasAvailableUsage else { return .unavailable }
        return .available(costUSD: costUSD, tokens: tokens, unpricedRequests: unpricedRequests)
    }

    /// A refresh key made only from aggregate timestamps and quota-window
    /// metadata. It changes after either a usage scan or quota refresh, while
    /// keeping account ids and source paths out of SwiftUI state.
    private var planWeekRefreshKey: String {
        CodeCLIProvider.allCases.map { provider in
            let snapshotStamp = snapshot(for: provider)?.updatedAt.timeIntervalSince1970 ?? 0
            let window = PlanWeekWindow.resolve(quota: quota(for: provider))
            return [
                provider.rawValue,
                String(snapshotStamp),
                String(window?.start.timeIntervalSince1970 ?? 0),
                String(window?.nextResetAt.timeIntervalSince1970 ?? 0)
            ].joined(separator: ":")
        }.joined(separator: "|")
    }

    @MainActor
    private func refreshPlanWeekUsage(now: Date = Date()) async {
        let enabledProviders = CodeCLIProvider.allCases.filter {
            settingsStore.settings.configuration(for: $0).isEnabled
        }
        var next = Dictionary(
            uniqueKeysWithValues: enabledProviders.map { ($0, CompactPlanWeekUsage.unavailable) }
        )
        var requests: [(CodeCLIProvider, ToolType, PlanWeekWindow)] = []
        for provider in enabledProviders {
            guard let tool = provider.legacyTool,
                  let window = PlanWeekWindow.resolve(quota: quota(for: provider), now: now)
            else { continue }
            next[provider] = .loading(window: window)
            requests.append((provider, tool, window))
        }
        planWeekUsageByProvider = next

        guard let ledger = environment.usageLedger else {
            for (provider, _, _) in requests { next[provider] = .unavailable }
            planWeekUsageByProvider = next
            return
        }

        for (provider, tool, window) in requests {
            guard !Task.isCancelled else { return }
            let filter = UsageQueryFilter(
                range: DateInterval(start: window.start, end: now),
                tools: [tool]
            )
            guard let metrics = try? await ledger.summary(filter) else {
                next[provider] = .unavailable
                continue
            }
            next[provider] = .available(
                window: window,
                costUSD: Double(metrics.costMicros ?? 0) / 1_000_000,
                tokens: Int(clamping: metrics.realTotalTokens),
                unpricedRequests: metrics.unpricedRequests
            )
        }
        guard !Task.isCancelled else { return }
        planWeekUsageByProvider = next
    }
}

private struct CompactProviderRow: View {
    let provider: CodeCLIProvider
    let snapshot: CostSnapshot?
    let quota: AccountQuota?
    let quotaFreshness: QuotaFreshnessLabel.Description?
    let account: AccountIdentity?
    let detection: CodeCLIProviderDetection
    let planWeekUsage: CompactPlanWeekUsage
    @ObservedObject var quotaService: QuotaService
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 10) {
                    providerIcon
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(provider.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            if provider.usesExperimentalQuota {
                                Text("Experimental quota")
                                    .font(.system(size: 8, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                        HStack(spacing: 0) {
                            providerPeriodMetric("Today", state: todayUsage)
                            Divider().frame(height: 28).padding(.horizontal, 9)
                            providerPeriodMetric(planWeekLabel, state: planWeekUsage.metricState)
                        }
                    }
                    Spacer(minLength: 8)
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)

            if let bucket = headlineBucket {
                VStack(alignment: .leading, spacing: 5) {
                    CompactQuotaBar(percent: bucket.usedPercent)
                    HStack {
                        Text("\(bucket.compactDetailTitle) · \(Int(bucket.usedPercent.rounded()))% used")
                        Spacer()
                        Text(resetText(bucket.resetAt))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, quotaFreshness == nil ? 11 : 6)
            } else {
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(hasLocalUsageSource ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(localUsageStatus)
                    }
                    Spacer()
                    Text("Quota unavailable")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, quotaFreshness == nil ? 11 : 6)
            }

            if let quotaFreshness {
                Label(quotaFreshness.label, systemImage: "clock.badge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(quotaFreshness.help)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
            }

            if isExpanded {
                Divider().padding(.horizontal, 12)
                expandedContent
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(.separator.opacity(0.5), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let tool = provider.legacyTool,
           let image = ProviderBrandIcon.image(for: tool, size: NSSize(width: 18, height: 18)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "terminal")
                .frame(width: 18, height: 18)
        }
    }

    private var todayUsage: CompactUsageMetricState {
        guard let snapshot else { return .unavailable }
        return .available(
            costUSD: snapshot.todayCostUSD,
            tokens: snapshot.todayTokens,
            unpricedRequests: snapshot.todayUnpricedRequests
        )
    }

    private var planWeekLabel: String {
        guard let window = planWeekUsage.window else { return "Week" }
        return "Week · \(compactResetCountdown(window.nextResetAt))"
    }

    private func providerPeriodMetric(
        _ title: String,
        state: CompactUsageMetricState
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(state.compactValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(state.isUnavailable ? .secondary : .primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibilityLabel(period: title))
    }

    private var hasLocalUsageSource: Bool {
        (snapshot?.jsonlFilesFound ?? 0) > 0 || detection.isDetected
    }

    private var localUsageStatus: String {
        if (snapshot?.jsonlFilesFound ?? 0) > 0 { return "Local usage scanned" }
        if detection.isDetected { return "CLI detected" }
        return "Usage data unavailable"
    }

    private var headlineBucket: QuotaBucket? {
        PlanWeekWindow.weeklyBucket(in: quota)
            ?? quota?.buckets.max { $0.usedPercent < $1.usedPercent }
    }

    private var isRefreshing: Bool {
        account.map { quotaService.inFlightAccountIds.contains($0.id) } ?? false
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if quotaFreshness == nil,
               let error = account.flatMap({ quotaService.lastErrorByAccount[$0.id] }) {
                Label(error.userFacingMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let buckets = quota?.buckets, !buckets.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Plan quota").font(.caption.weight(.semibold))
                    }
                    ForEach(buckets) { bucket in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(bucket.compactDetailTitle)
                                Spacer()
                                Text("\(Int(bucket.usedPercent.rounded()))% used")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            CompactQuotaBar(percent: bucket.usedPercent)
                            Text(resetText(bucket.resetAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let snapshot {
                HStack(spacing: 16) {
                    detailPeriodMetric(
                        "Month",
                        state: .available(
                            costUSD: calendarMonthCost(snapshot),
                            tokens: calendarMonthTokens(snapshot),
                            unpricedRequests: calendarMonthUnpricedRequests(snapshot)
                        )
                    )
                    detailPeriodMetric(
                        "All time",
                        state: .available(
                            costUSD: snapshot.allTimeCostUSD,
                            tokens: snapshot.allTimeTokens,
                            unpricedRequests: snapshot.allTimeUnpricedRequests
                        )
                    )
                }

                if snapshot.todayUnpricedRequests > 0 {
                    Label(
                        "\(snapshot.todayUnpricedRequests) request\(snapshot.todayUnpricedRequests == 1 ? "" : "s") "
                            + "today use models without a verified price; the dollar total is a known subtotal.",
                        systemImage: "info.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if planWeekUsage.unpricedRequests > 0 {
                    Label(
                        "\(planWeekUsage.unpricedRequests) request"
                            + "\(planWeekUsage.unpricedRequests == 1 ? "" : "s") in this plan week "
                            + "use models without a verified price.",
                        systemImage: "info.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Source")
                Spacer()
                Text(detection.detectedPath ?? "Not detected")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func detailPeriodMetric(
        _ title: String,
        state: CompactUsageMetricState
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(state.costText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text(state.tokenText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactQuotaBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("\(Int(percent.rounded())) percent used")
    }

    private var color: Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        return .blue
    }
}

private struct CompactUsageSummary {
    let todayCost: Double
    let todayTokens: Int
    let todayUnpricedRequests: Int

    init(snapshots: [CostSnapshot]) {
        todayCost = snapshots.reduce(0) { $0 + $1.todayCostUSD }
        todayTokens = snapshots.reduce(0) { $0 + $1.todayTokens }
        todayUnpricedRequests = snapshots.reduce(0) { $0 + $1.todayUnpricedRequests }
    }
}

private enum CompactUsageMetricState: Equatable {
    case available(costUSD: Double, tokens: Int, unpricedRequests: Int)
    case loading
    case unavailable

    var compactValue: String {
        switch self {
        case .available(let costUSD, let tokens, let unpricedRequests):
            return "\(formatTokens(tokens)) · \(formatKnownCost(costUSD, unpricedRequests: unpricedRequests))"
        case .loading:
            return "Calculating…"
        case .unavailable:
            return "— · $—"
        }
    }

    var costText: String {
        switch self {
        case .available(let costUSD, _, let unpricedRequests):
            return formatKnownCost(costUSD, unpricedRequests: unpricedRequests)
        case .loading:
            return "$…"
        case .unavailable:
            return "$—"
        }
    }

    var tokenText: String {
        switch self {
        case .available(_, let tokens, _): return "\(formatTokens(tokens)) tokens"
        case .loading: return "Calculating"
        case .unavailable: return "Reset time unavailable"
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    func accessibilityLabel(period: String) -> String {
        switch self {
        case .available(let costUSD, let tokens, let unpricedRequests):
            return "\(period), \(tokens) tokens, "
                + formatKnownCost(costUSD, unpricedRequests: unpricedRequests)
        case .loading:
            return "\(period), calculating usage"
        case .unavailable:
            return "\(period), weekly reset time unavailable"
        }
    }
}

private enum CompactPlanWeekUsage: Equatable {
    case unavailable
    case loading(window: PlanWeekWindow)
    case available(
        window: PlanWeekWindow,
        costUSD: Double,
        tokens: Int,
        unpricedRequests: Int
    )

    var window: PlanWeekWindow? {
        switch self {
        case .unavailable: return nil
        case .loading(let window), .available(let window, _, _, _): return window
        }
    }

    var metricState: CompactUsageMetricState {
        switch self {
        case .unavailable:
            return .unavailable
        case .loading:
            return .loading
        case .available(_, let costUSD, let tokens, let unpricedRequests):
            return .available(
                costUSD: costUSD,
                tokens: tokens,
                unpricedRequests: unpricedRequests
            )
        }
    }

    var unpricedRequests: Int {
        if case .available(_, _, _, let count) = self { return count }
        return 0
    }
}

private func calendarMonthCost(_ snapshot: CostSnapshot, now: Date = Date()) -> Double {
    let calendar = Calendar.current
    let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    let points = snapshot.dailyHistory.filter { $0.date >= start && $0.date <= now }
    return points.isEmpty ? snapshot.last30DaysCostUSD : points.reduce(0) { $0 + $1.costUSD }
}

private func calendarMonthTokens(_ snapshot: CostSnapshot, now: Date = Date()) -> Int {
    let calendar = Calendar.current
    let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    let points = snapshot.dailyHistory.filter { $0.date >= start && $0.date <= now }
    return points.isEmpty ? snapshot.last30DaysTokens : points.reduce(0) { $0 + $1.totalTokens }
}

private func calendarMonthUnpricedRequests(
    _ snapshot: CostSnapshot,
    now: Date = Date(),
    calendar: Calendar = .current
) -> Int {
    let start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
    let points = snapshot.dailyHistory.filter { $0.date >= start && $0.date <= now }
    return points.isEmpty
        ? snapshot.last30DaysUnpricedRequests
        : points.reduce(0) { $0 + $1.unpricedRequests }
}

func formatUSD(_ value: Double) -> String {
    String(format: "$%.2f", max(0, value))
}

func formatKnownCost(_ value: Double, unpricedRequests: Int) -> String {
    guard unpricedRequests > 0 else { return formatUSD(value) }
    return value > 0 ? "\(formatUSD(value))+" : "$—"
}

func formatTokens(_ value: Int) -> String {
    let amount = Double(max(0, value))
    if amount >= 1_000_000_000 { return String(format: "%.1fB", amount / 1_000_000_000) }
    if amount >= 1_000_000 { return String(format: "%.1fM", amount / 1_000_000) }
    if amount >= 1_000 { return String(format: "%.1fK", amount / 1_000) }
    return String(value)
}

private func resetText(_ date: Date?) -> String {
    guard let date else { return "Reset time unavailable" }
    if date <= Date() { return "Reset due" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Resets \(formatter.localizedString(for: date, relativeTo: Date()))"
}

private func compactResetCountdown(_ resetAt: Date, now: Date = Date()) -> String {
    let remaining = max(0, Int(resetAt.timeIntervalSince(now)))
    if remaining >= 86_400 { return "resets in \(remaining / 86_400)d" }
    if remaining >= 3_600 { return "resets in \(remaining / 3_600)h" }
    if remaining >= 60 { return "resets in \(remaining / 60)m" }
    return remaining > 0 ? "resets soon" : "reset due"
}
