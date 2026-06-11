import SwiftUI
import AppKit
import Combine
import KeyboardShortcuts
import Shared

extension KeyboardShortcuts.Name {
    static let openSearch = Self("openSearch", default: .init(.m, modifiers: [.option, .command]))
}

@main
struct QuickStudyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Placeholder Scene — the real settings window is owned by SettingsWindowController.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private lazy var settingsWindow = SettingsWindowController(model: model)
    private let notifier = NotificationManager()
    private var updateMenuItem: NSMenuItem!
    private var dailyTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon

        panel = PanelController(model: model)

        notifier.configure()
        notifier.onUpdateAction = { [weak self] in self?.model.startRefresh(skipImages: false) }
        notifier.onOpenPanel = { [weak self] in self?.panel.show() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Quick Study")
        }
        let menu = NSMenu()
        updateMenuItem = NSMenuItem(title: "Update Available — Refresh…",
                                    action: #selector(refreshNow), keyEquivalent: "")
        updateMenuItem.isHidden = true
        menu.addItem(updateMenuItem)
        menu.addItem(withTitle: "Open Search", action: #selector(openSearch), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Database…", action: #selector(refreshNow), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quick Study", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action == #selector(openSearch)
            || item.action == #selector(refreshNow)
            || item.action == #selector(openSettings) {
            item.target = self
        }
        statusItem.menu = menu

        KeyboardShortcuts.onKeyDown(for: .openSearch) { [weak self] in
            self?.panel.toggle()
            self?.model.checkForUpdates()
        }

        // Reflect update state in the menu-bar badge, dropdown item, and notification.
        model.$updateAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] available in self?.updateBadge(available) }
            .store(in: &cancellables)

        // Check on launch and once per day thereafter.
        model.checkForUpdates(force: true)
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.checkForUpdates() }
        }
    }

    /// Badges the menu-bar icon and reveals the dropdown item when an update exists, and
    /// fires the native notification (deduped per stamp inside `NotificationManager`).
    private func updateBadge(_ available: Bool) {
        updateMenuItem?.isHidden = !available
        if let button = statusItem?.button {
            if available {
                button.attributedTitle = NSAttributedString(
                    string: " ●",
                    attributes: [.foregroundColor: NSColor.systemRed,
                                 .font: NSFont.systemFont(ofSize: 9)])
            } else {
                button.attributedTitle = NSAttributedString(string: "")
            }
        }
        if available, let stamp = model.availableUpdateStamp {
            notifier.notifyIfNeeded(stamp: stamp)
        }
    }

    @objc private func openSearch() {
        panel.show()
        model.checkForUpdates()
    }

    @objc private func refreshNow() {
        model.startRefresh(skipImages: false)
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
