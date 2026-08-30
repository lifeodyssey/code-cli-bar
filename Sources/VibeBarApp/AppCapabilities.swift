struct AppCapabilities: Sendable {
    let updater: Bool
    let mcpServer: Bool
    let serviceStatus: Bool
    let remoteProbe: Bool
    let automaticBrowserCookieImport: Bool
    let cookieRefreshScheduler: Bool
    let sessionIndexMaintenance: Bool
    let periodicUsageRefresh: Bool

    static let codeCLIBar = AppCapabilities(
        updater: false,
        mcpServer: false,
        serviceStatus: false,
        remoteProbe: false,
        automaticBrowserCookieImport: false,
        cookieRefreshScheduler: false,
        sessionIndexMaintenance: false,
        periodicUsageRefresh: true
    )

    /// Keeps the inherited screenshot/demo harness working while production
    /// follows the deliberately small Code CLI Bar surface.
    static let inheritedDemo = AppCapabilities(
        updater: false,
        mcpServer: true,
        serviceStatus: true,
        remoteProbe: true,
        automaticBrowserCookieImport: false,
        cookieRefreshScheduler: false,
        sessionIndexMaintenance: false,
        periodicUsageRefresh: false
    )
}
