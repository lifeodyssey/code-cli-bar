import SwiftUI
import VibeBarCore

struct CompactSettingsRoot: View {
    @ObservedObject private var productSettings: CodeCLIBarSettingsStore
    @ObservedObject private var inheritedSettings: SettingsStore
    @ObservedObject private var detectionService: CodeCLIProviderDetectionService
    @ObservedObject private var updateController: AppUpdateController
    @ObservedObject private var actualCashStore: ActualCashStore

    private let environment: AppEnvironment
    private let vibeBarImportService = VibeBarImportService()
    @State private var loginItemError: String?
    @State private var importPreview: VibeBarImportService.Preview?
    @State private var importError: String?
    @State private var importStatus: String?
    @State private var importIsBusy = false
    @State private var cashEditorIsVisible = false
    @State private var cashDraftProvider: CodeCLIProvider? = .claudeCode
    @State private var cashDraftKind: ActualCashKind = .subscription
    @State private var cashDraftTitle = ""
    @State private var cashDraftAmount = ""
    @State private var cashDraftDate = Date()
    @State private var cashDraftCadence: ActualCashCadence = .monthly
    @State private var cashValidationError: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.productSettings = environment.codeCLISettingsStore
        self.inheritedSettings = environment.settingsStore
        self.detectionService = environment.providerDetectionService
        self.updateController = environment.updateController
        self.actualCashStore = environment.actualCashStore
    }

    var body: some View {
        Form {
            generalSection
            providersSection
            actualCashSection
            privacySection
            importSection
            updatesSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, idealWidth: 660, minHeight: 560, idealHeight: 650)
        .onAppear {
            detectionService.refresh(settings: productSettings.settings)
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: launchAtLoginBinding)
            Text(loginItemError ?? LoginItemController.statusText)
                .font(.caption)
                .foregroundStyle(loginItemError == nil ? Color.secondary : Color.red)

            Picker("Local usage refresh", selection: usageRefreshBinding) {
                Text("1 minute").tag(60)
                Text("5 minutes").tag(300)
                Text("10 minutes").tag(600)
            }

            Picker("Plan quota refresh", selection: quotaRefreshBinding) {
                Text("5 minutes").tag(300)
                Text("10 minutes").tag(600)
                Text("30 minutes").tag(1_800)
            }

            Button("Refresh now") {
                environment.refreshCodeCLIBar()
            }
        }
    }

    private var providersSection: some View {
        Section {
            ForEach(CodeCLIProvider.allCases) { provider in
                CompactProviderSettingsRow(
                    provider: provider,
                    settingsStore: productSettings,
                    detection: detectionService.detection(for: provider),
                    onRescan: {
                        detectionService.refresh(settings: productSettings.settings)
                    }
                )
            }
        } header: {
            HStack {
                Text("Providers")
                Spacer()
                if detectionService.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Rescan") {
                        detectionService.refresh(settings: productSettings.settings)
                    }
                    .buttonStyle(.link)
                }
            }
        } footer: {
            Text("Code CLI Bar reads usage files and CLI credentials in place. It never edits provider logs or authentication state.")
        }
    }

    private var privacySection: some View {
        Section("Privacy & data") {
            LabeledContent("App data") {
                Text(VibeBarLocalStore.baseDirectory.path)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            Picker("Derived history retention", selection: retentionBinding) {
                Text("Forever").tag(0)
                Text("90 days").tag(90)
                Text("1 year").tag(365)
                Text("3 years").tag(1_095)
            }

            Label("No telemetry, cloud sync, prompt text, response text, or project paths.", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        }
    }

    private var actualCashSection: some View {
        Section {
            LabeledContent("Paid this month") {
                Text(formatUSD(actualCashStore.calendarMonthTotal()))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }

            ForEach(actualCashStore.entries) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title.isEmpty ? entry.kind.displayName : entry.title)
                        Text(cashEntrySubtitle(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatUSD(entry.amountUSD))
                        .monospacedDigit()
                    Button {
                        actualCashStore.remove(id: entry.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove cash entry")
                }
            }

            if cashEditorIsVisible {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Provider")
                        Picker("", selection: $cashDraftProvider) {
                            Text("General").tag(Optional<CodeCLIProvider>.none)
                            ForEach(CodeCLIProvider.allCases) { provider in
                                Text(provider.displayName).tag(Optional(provider))
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Type")
                        Picker("", selection: $cashDraftKind) {
                            ForEach(ActualCashKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Label")
                        TextField("Optional", text: $cashDraftTitle)
                    }
                    GridRow {
                        Text("Amount")
                        HStack {
                            Text("$")
                            TextField("0.00", text: $cashDraftAmount)
                                .frame(width: 100)
                            Text("USD").foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Cadence")
                        Picker("", selection: $cashDraftCadence) {
                            ForEach(ActualCashCadence.allCases, id: \.self) { cadence in
                                Text(cadence.displayName).tag(cadence)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text(cashDraftCadence == .monthly ? "First payment" : "Paid on")
                        DatePicker("", selection: $cashDraftDate, displayedComponents: .date)
                            .labelsHidden()
                    }
                }

                if let cashValidationError {
                    Text(cashValidationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Cancel") {
                        cashEditorIsVisible = false
                        cashValidationError = nil
                    }
                    Spacer()
                    Button("Add entry") {
                        addCashEntry()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Add subscription or payment…") {
                    cashEditorIsVisible = true
                }
            }
        } header: {
            Text("Actual cash")
        } footer: {
            Text("Manual bookkeeping only. API-equivalent cost is estimated from token logs and never changes this ledger.")
        }
    }

    private var importSection: some View {
        Section("Import") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vibe Bar cost history")
                    Text("Preview aggregate daily cost and token history before copying it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(importPreview == nil ? "Preview…" : "Refresh Preview") {
                    previewVibeBarImport()
                }
                .disabled(importIsBusy)
            }

            if importIsBusy {
                ProgressView().controlSize(.small)
            }

            if let preview = importPreview {
                LabeledContent("Read-only source") {
                    Text(preview.sourceURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .font(.caption)

                ForEach(preview.providers) { item in
                    HStack {
                        Text(item.provider.displayName)
                        Spacer()
                        Text("\(item.dayCount) days · \(formatTokens(item.totalTokens)) · \(formatUSD(item.totalCostUSD))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                if preview.isEmpty {
                    Text("No compatible provider history was found in the source file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Label(
                            "Only daily aggregates are copied. Credentials, request ids, projects, prompts, and responses are excluded.",
                            systemImage: "doc.on.doc"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Import \(preview.dayCount) days") {
                            importVibeBarHistory()
                        }
                        .disabled(importIsBusy)
                    }
                }
            }

            if let importStatus {
                Label(importStatus, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var updatesSection: some View {
        Section("Updates") {
            Picker("Channel", selection: updateChannelBinding) {
                Text("Stable").tag(UpdateChannel.main)
                Text("Preview").tag(UpdateChannel.dev)
            }

            HStack {
                Text("Version \(updateController.currentVersionDescription)")
                Spacer()
                Button("Check for Updates") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }

            if !updateController.canCheckForUpdates {
                Text("Automatic updates are disabled in development builds until Code CLI Bar has a signed feed and public key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Text("Code CLI Bar is an independent, local-first AGPL-3.0 app. Provider data stays on this Mac unless you explicitly export it.")
                .foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { productSettings.settings.launchAtLogin },
            set: { enabled in
                var settings = productSettings.settings
                settings.launchAtLogin = enabled
                productSettings.settings = settings
                do {
                    try LoginItemController.setEnabled(enabled)
                    loginItemError = nil
                } catch {
                    loginItemError = error.localizedDescription
                }
            }
        )
    }

    private var usageRefreshBinding: Binding<Int> {
        Binding(
            get: { productSettings.settings.usageRefreshIntervalSeconds },
            set: { value in
                var settings = productSettings.settings
                settings.usageRefreshIntervalSeconds = max(60, value)
                productSettings.settings = settings
            }
        )
    }

    private var quotaRefreshBinding: Binding<Int> {
        Binding(
            get: { productSettings.settings.quotaRefreshIntervalSeconds },
            set: { value in
                var settings = productSettings.settings
                settings.quotaRefreshIntervalSeconds = max(60, value)
                productSettings.settings = settings
            }
        )
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { inheritedSettings.settings.costData.retentionDays },
            set: { value in
                var settings = inheritedSettings.settings
                settings.costData.retentionDays = CostDataSettings.normalizedRetentionDays(value)
                inheritedSettings.settings = settings
            }
        )
    }

    private var updateChannelBinding: Binding<UpdateChannel> {
        Binding(
            get: { inheritedSettings.settings.updateChannel },
            set: { channel in
                var settings = inheritedSettings.settings
                settings.updateChannel = channel
                inheritedSettings.settings = settings
            }
        )
    }

    private func previewVibeBarImport() {
        importIsBusy = true
        importError = nil
        importStatus = nil
        Task { @MainActor in
            defer { importIsBusy = false }
            do {
                importPreview = try await vibeBarImportService.preview()
            } catch {
                importPreview = nil
                importError = error.localizedDescription
            }
        }
    }

    private func importVibeBarHistory() {
        importIsBusy = true
        importError = nil
        importStatus = nil
        let retentionDays = inheritedSettings.settings.costData.retentionDays
        Task { @MainActor in
            defer { importIsBusy = false }
            do {
                let imported = try await vibeBarImportService.importCostHistory(
                    retentionDays: retentionDays
                )
                importPreview = imported
                importStatus = "Imported \(imported.dayCount) aggregate days. The Vibe Bar source was not changed."
                environment.refreshCostUsage()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func addCashEntry() {
        guard let amount = Double(cashDraftAmount.trimmingCharacters(in: .whitespacesAndNewlines)),
              amount.isFinite,
              amount > 0
        else {
            cashValidationError = "Enter a positive USD amount."
            return
        }
        let fallbackTitle = cashDraftProvider?.displayName ?? cashDraftKind.displayName
        actualCashStore.add(ActualCashEntry(
            provider: cashDraftProvider,
            kind: cashDraftKind,
            title: cashDraftTitle.isEmpty ? fallbackTitle : cashDraftTitle,
            amountUSD: amount,
            startsAt: cashDraftDate,
            cadence: cashDraftCadence
        ))
        cashDraftTitle = ""
        cashDraftAmount = ""
        cashDraftDate = Date()
        cashValidationError = nil
        cashEditorIsVisible = false
    }

    private func cashEntrySubtitle(_ entry: ActualCashEntry) -> String {
        let provider = entry.provider?.displayName ?? "General"
        let cadence = entry.cadence == .monthly ? "monthly" : entry.startsAt.formatted(date: .abbreviated, time: .omitted)
        return "\(provider) · \(entry.kind.displayName) · \(cadence)"
    }
}

private struct CompactProviderSettingsRow: View {
    let provider: CodeCLIProvider
    @ObservedObject var settingsStore: CodeCLIBarSettingsStore
    let detection: CodeCLIProviderDetection
    let onRescan: () -> Void

    @EnvironmentObject private var environment: AppEnvironment
    @State private var isExpanded = false
    @State private var miscBrowserImportInFlight = false
    @State private var miscBrowserImportStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayName).fontWeight(.medium)
                        if provider.usesExperimentalQuota {
                            Text("Experimental quota")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(detection.isDetected ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(detection.isDetected ? "Detected" : "Not detected")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .buttonStyle(.borderless)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("Custom usage path", text: customPathBinding)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(onRescan)
                    Text("Default: ~/\(provider.defaultUsagePaths.joined(separator: ", ~/"))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if provider.supportsBrowserCredentialImport {
                        Toggle("Allow browser credential import", isOn: browserOptInBinding)
                        if settingsStore.configuration(for: provider).browserCredentialOptIn {
                            HStack(spacing: 8) {
                                Button {
                                    importBrowserCredentials()
                                } label: {
                                    if browserImportInFlight {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("Import from browser…", systemImage: "safari")
                                    }
                                }
                                .disabled(browserImportInFlight)
                                Spacer()
                            }
                            if let status = browserImportStatus {
                                Text(status)
                                    .font(.caption2)
                                    .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                            }
                        }
                        Text("The switch grants permission for a manual copy from readable browser stores. It never changes CLI authentication.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if provider == .zcode {
                        ApiKeyField(
                            tool: .zai,
                            instanceID: ToolType.zai.rawValue,
                            prompt: "Paste Z.ai API key (zai-…)",
                            helpText: "Used only for the experimental quota endpoint and stored in macOS Keychain."
                        )
                    }

                    if provider == .dsh {
                        Text("dsh plan quota and credentials are shared with OpenCode Go; configure them in the OpenCode Go row.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if provider.usesExperimentalQuota {
                        Toggle("Enable experimental quota endpoint", isOn: experimentalQuotaBinding)
                        Text("Last-known values remain cached; turn this off immediately if the provider changes its endpoint.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let path = detection.detectedPath {
                        LabeledContent("Detected source") {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 3)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.configuration(for: provider).isEnabled },
            set: { value in
                settingsStore.update(provider) { $0.isEnabled = value }
                onRescan()
            }
        )
    }

    private var customPathBinding: Binding<String> {
        Binding(
            get: { settingsStore.configuration(for: provider).customUsagePath ?? "" },
            set: { value in
                settingsStore.update(provider) {
                    $0.customUsagePath = CodeCLIProviderConfiguration.normalizedPath(value)
                }
            }
        )
    }

    private var browserOptInBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.configuration(for: provider).browserCredentialOptIn },
            set: { value in
                settingsStore.update(provider) { $0.browserCredentialOptIn = value }
            }
        )
    }

    private var browserImportInFlight: Bool {
        switch provider {
        case .claudeCode: environment.isImportingClaudeBrowserCookies
        case .codex: environment.isImportingOpenAIBrowserCookies
        case .grokBuild: environment.isImportingGrokBrowserCookies
        case .openCodeGo, .kimiCode: miscBrowserImportInFlight
        case .zcode, .dsh: false
        }
    }

    private var browserImportStatus: String? {
        switch provider {
        case .claudeCode: environment.claudeBrowserCookieImportStatus
        case .codex: environment.openAIBrowserCookieImportStatus
        case .grokBuild: environment.grokBrowserCookieImportStatus
        case .openCodeGo, .kimiCode: miscBrowserImportStatus
        case .zcode, .dsh: nil
        }
    }

    private func importBrowserCredentials() {
        guard settingsStore.configuration(for: provider).browserCredentialOptIn else { return }
        switch provider {
        case .claudeCode:
            environment.importClaudeBrowserCookies()
        case .codex:
            environment.importOpenAIBrowserCookies()
        case .grokBuild:
            environment.importGrokBrowserCookies()
        case .openCodeGo, .kimiCode:
            guard let tool = provider.legacyTool,
                  let spec = MiscCookieSpecCatalog.spec(for: tool)
            else { return }
            miscBrowserImportInFlight = true
            miscBrowserImportStatus = "Importing from browser…"
            DispatchQueue.global(qos: .userInitiated).async {
                let result = MiscCookieResolver.appendBrowserImport(
                    for: spec,
                    instanceID: tool.rawValue
                )
                DispatchQueue.main.async {
                    miscBrowserImportInFlight = false
                    if let result {
                        miscBrowserImportStatus = "Imported from \(result.sourceLabel)."
                        environment.reloadProviderCredentialsAndRefresh()
                    } else {
                        miscBrowserImportStatus = "No compatible credentials were found in readable browser stores."
                    }
                }
            }
        case .zcode, .dsh:
            break
        }
    }

    private var experimentalQuotaBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.configuration(for: provider).experimentalQuotaEnabled },
            set: { value in
                settingsStore.update(provider) { $0.experimentalQuotaEnabled = value }
            }
        )
    }
}
