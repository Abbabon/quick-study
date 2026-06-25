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
    private lazy var gameWindow = GameWindowController(model: model)
    private let notifier = NotificationManager()
    private var updateMenuItem: NSMenuItem!
    private var appUpdateMenuItem: NSMenuItem!
    private var openSearchMenuItem: NSMenuItem!
    private var checkTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular) // always show a Dock icon
        Appearance.apply(Appearance.current()) // honor the saved Light/Dark/Auto choice

        panel = PanelController(model: model)

        model.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        model.onOpenGame = { [weak self] in self?.gameWindow.show() }

        notifier.configure()
        notifier.onUpdateAction = { [weak self] in self?.model.startImageDownload() }
        notifier.onOpenPanel = { [weak self] in self?.panel.show() }
        notifier.onAppUpdateAction = { [weak self] in self?.model.installOrRelaunch() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Quick Study")
        }
        let menu = NSMenu()
        updateMenuItem = NSMenuItem(title: "Download Images…",
                                    action: #selector(downloadNewImages), keyEquivalent: "")
        updateMenuItem.isHidden = true
        menu.addItem(updateMenuItem)
        appUpdateMenuItem = NSMenuItem(title: "Update QuickStudy…",
                                       action: #selector(installAppUpdate), keyEquivalent: "")
        appUpdateMenuItem.isHidden = true
        menu.addItem(appUpdateMenuItem)
        openSearchMenuItem = menu.addItem(withTitle: "Open Search", action: #selector(openSearch), keyEquivalent: "")
        openSearchMenuItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Open Search")
        let playItem = menu.addItem(withTitle: "Play…", action: #selector(openGame), keyEquivalent: "")
        playItem.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Play")
        menu.addItem(.separator())
        let refreshItem = menu.addItem(withTitle: "Refresh Database…", action: #selector(refreshNow), keyEquivalent: "")
        refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Database")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quick Study", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action == #selector(openSearch)
            || item.action == #selector(openGame)
            || item.action == #selector(refreshNow)
            || item.action == #selector(downloadNewImages)
            || item.action == #selector(openSettings)
            || item.action == #selector(installAppUpdate) {
            item.target = self
        }
        menu.delegate = self
        statusItem.menu = menu

        KeyboardShortcuts.onKeyDown(for: .openSearch) { [weak self] in
            self?.panel.toggle()
            self?.model.checkForUpdates()
            self?.model.checkForAppUpdate()
        }

        // Reflect update state in the menu-bar badge, dropdown item, and notification.
        model.$newCardsPendingImages
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUpdateUI() }
            .store(in: &cancellables)
        model.$appUpdateState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshUpdateUI() }
            .store(in: &cancellables)

        // Check on launch, then keep checking. A single long Timer is unreliable for a
        // background app: App Nap throttles it and system sleep coalesces its fire date, so
        // a 24h timer effectively never fired across overnight sleep. Instead use a shorter
        // timer (the 1h network throttle in `checkForUpdates` caps actual Scryfall calls) plus
        // a wake-from-sleep trigger, which covers the common laptop-wakes-in-the-morning case.
        model.checkForUpdates(force: true)
        model.checkForAppUpdate(force: true)
        let timer = Timer(timeInterval: 2 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.model.checkForUpdates()
                self?.model.checkForAppUpdate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.checkForUpdates()
                self?.model.checkForAppUpdate()
            }
        }
    }

    /// Reflects both update kinds (Scryfall card data and the app itself) in the menu-bar
    /// badge, dropdown items, and native notifications. The red dot lights up when either is
    /// pending; each notification is deduped inside `NotificationManager`.
    private func refreshUpdateUI() {
        let cardUpdate = model.newCardsPendingImages > 0
        let appActionable = model.appUpdateState.isActionable

        if cardUpdate {
            let n = model.newCardsPendingImages
            updateMenuItem?.title = "Download Images (\(n) new card\(n == 1 ? "" : "s"))…"
        } else {
            updateMenuItem?.title = "Download Images…"
        }
        updateMenuItem?.isHidden = !cardUpdate

        switch model.appUpdateState {
        case let .available(version, _):
            appUpdateMenuItem?.title = "Update QuickStudy \(version)…"
            appUpdateMenuItem?.action = #selector(installAppUpdate)
            appUpdateMenuItem?.isHidden = false
        case let .readyToRelaunch(version):
            appUpdateMenuItem?.title = "Relaunch to Update to \(version)…"
            appUpdateMenuItem?.action = #selector(installAppUpdate)
            appUpdateMenuItem?.isHidden = false
        case .downloading:
            appUpdateMenuItem?.title = "Downloading Update…"
            appUpdateMenuItem?.action = nil
            appUpdateMenuItem?.isHidden = false
        case .installing:
            appUpdateMenuItem?.title = "Installing Update…"
            appUpdateMenuItem?.action = nil
            appUpdateMenuItem?.isHidden = false
        case .none, .failed:
            appUpdateMenuItem?.isHidden = true
        }

        if let button = statusItem?.button {
            if cardUpdate || appActionable {
                button.attributedTitle = NSAttributedString(
                    string: " ●",
                    attributes: [.foregroundColor: NSColor.systemRed,
                                 .font: NSFont.systemFont(ofSize: 9)])
            } else {
                button.attributedTitle = NSAttributedString(string: "")
            }
        }

        if cardUpdate, let stamp = model.availableUpdateStamp {
            notifier.notifyIfNeeded(stamp: stamp, newCards: model.newCardsPendingImages)
        }
        if appActionable, let version = model.appUpdateState.version {
            notifier.notifyAppUpdateIfNeeded(version: version)
        }
    }

    @objc private func openSearch() {
        panel.show()
        model.checkForUpdates()
        model.checkForAppUpdate()
    }

    @objc private func refreshNow() {
        model.startRefresh(skipImages: false)
    }

    @objc private func downloadNewImages() {
        model.startImageDownload()
    }

    @objc private func installAppUpdate() {
        model.installOrRelaunch()
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func openGame() {
        gameWindow.show()
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Reflect the current (user-configurable) global shortcut next to "Open Search"
    /// each time the menu opens, so it stays correct after a rebind in Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .openSearch),
           let keyEquivalent = shortcut.nsMenuItemKeyEquivalent {
            openSearchMenuItem.keyEquivalent = keyEquivalent
            openSearchMenuItem.keyEquivalentModifierMask = shortcut.modifiers
        } else {
            openSearchMenuItem.keyEquivalent = ""
            openSearchMenuItem.keyEquivalentModifierMask = []
        }
    }
}
