import AppKit
import Combine
import SwiftUI
import VibeBarCore

@MainActor
final class MinimalStatusItemController: NSObject, NSPopoverDelegate {
    private let environment: AppEnvironment
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables: Set<AnyCancellable> = []
    private var lastCloseAt: Date?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configurePopover()
        configureStatusButton()
        observeChanges()
        renderStatusItem()
    }

    func applicationWillTerminate() {
        if popover.isShown { popover.performClose(nil) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 390, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: CompactPopoverRoot(environment: environment)
                .vibeBarNoInitialFocus()
        )
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .medium
        )
        button.toolTip = "Code CLI Bar · today's API-equivalent cost"
    }

    private func observeChanges() {
        let triggers: [AnyPublisher<Void, Never>] = [
            environment.costService.$snapshots.map { _ in () }.eraseToAnyPublisher(),
            environment.costService.$isRefreshing.map { _ in () }.eraseToAnyPublisher(),
            environment.codeCLISettingsStore.$settings.map { _ in () }.eraseToAnyPublisher(),
            environment.providerDetectionService.$detections.map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(triggers)
            .receive(on: RunLoop.main)
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.renderStatusItem() }
            .store(in: &cancellables)
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }
        let snapshots = enabledSnapshots
        let todayCost = snapshots.reduce(0) { $0 + $1.todayCostUSD }
        let unpricedRequests = snapshots.reduce(0) { $0 + $1.todayUnpricedRequests }
        let hasKnownSource = snapshots.contains { $0.jsonlFilesFound > 0 }

        if snapshots.isEmpty || (unpricedRequests > 0 && todayCost <= 0) {
            button.title = "$—"
        } else if !hasKnownSource && environment.costService.isRefreshing {
            button.title = "$…"
        } else if unpricedRequests > 0 {
            button.title = "\(formatUSD(todayCost))+"
        } else {
            button.title = formatUSD(todayCost)
        }
        button.setAccessibilityLabel("Today API equivalent \(button.title)")
    }

    private var enabledSnapshots: [CostSnapshot] {
        CodeCLIProvider.allCases.compactMap { provider in
            guard environment.codeCLISettingsStore.settings
                .configuration(for: provider).isEnabled,
                  let tool = provider.legacyTool
            else { return nil }
            return environment.costService.snapshot(for: tool)
        }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton else { return }
        if shouldShowContextMenu(for: NSApp.currentEvent) {
            showContextMenu(from: button)
            return
        }
        togglePopover(relativeTo: button)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if let lastCloseAt, Date().timeIntervalSince(lastCloseAt) < 0.2 {
            self.lastCloseAt = nil
            return
        }

        environment.providerDetectionService.refresh(
            settings: environment.codeCLISettingsStore.settings
        )
        _ = environment.scheduler.triggerRefreshForStaleCacheIfNeeded()
        if environment.costService.lastRefreshedAt.map({ Date().timeIntervalSince($0) > 120 }) ?? true {
            environment.refreshCostUsage()
        }

        environment.setPopoverVisible(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    nonisolated func popoverWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.lastCloseAt = Date()
            self?.environment.setPopoverVisible(false)
        }
    }

    private func shouldShowContextMenu(for event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil) }
        let menu = NSMenu(title: "Code CLI Bar")
        menu.autoenablesItems = false

        let summary = NSMenuItem(title: "Today  \(statusItem.button?.title ?? "$—")", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh", action: #selector(refreshFromMenu), key: "r"))
        menu.addItem(actionItem("Settings…", action: #selector(openSettingsFromMenu), key: ","))
        let update = actionItem("Check for Updates…", action: #selector(checkForUpdatesFromMenu))
        update.isEnabled = environment.updateController.canCheckForUpdates
        menu.addItem(update)
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit Code CLI Bar", action: #selector(quitFromMenu), key: "q"))

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
        }
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func refreshFromMenu() {
        environment.refreshCodeCLIBar()
    }

    @objc private func openSettingsFromMenu() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: self)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdatesFromMenu() {
        environment.updateController.checkForUpdates()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}
