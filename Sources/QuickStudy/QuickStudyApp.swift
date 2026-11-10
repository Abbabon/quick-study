import SwiftUI
import AppKit
import Combine
import KeyboardShortcuts
import Shared

extension KeyboardShortcuts.Name {
    static let openSearch = Self("openSearch", default: .init(.m, modifiers: [.option, .command]))
}

// AppKit entry point: a SwiftUI `App` needs a Scene, and the placeholder `Settings` scene made
// SwiftUI open an empty "Quick Study Settings" window at launch. Settings, the panel and Play
// are all owned by AppKit controllers, so no scene is needed — but we build the main menu
// ourselves (Edit gives text fields their Cmd-C/V/A/Z).
@main
@MainActor
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = mainMenu(delegate)
        app.run()
    }

    private static func mainMenu(_ d: AppDelegate) -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            return host
        }
        let name = "Quick Study"
        let main = NSMenu()
        main.addItem(submenu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.openSettings), ",", target: d),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
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
        Perf.installKeyMonitor()
        Perf.installReplayHook(show: { [weak self] in self?.panel.show() },
                               hide: { [weak self] in self?.panel.hide() },
                               reset: { [weak self] in self?.model.resetSearchState() },
                               window: { [weak self] in self?.panel.window },
                               setQuery: { [weak self] in self?.model.query = $0 })

        Perf.installFetcherHook(refresh: { [weak self] in self?.model.startRefresh(skipImages: true) },
                                images: { [weak self] in self?.model.startImageDownload() })

        Perf.installSearchHook { [weak self] q in
            guard let engine = self?.model.engine else { return "no model" }
            let r = engine.search(query: q)
            return "cards=\(engine.cardCount()) total=\(r.total) top=\(r.hits.prefix(3).map(\.name).joined(separator: " | "))"
        }

        Perf.installDatabaseHook { [weak self] write in await self?.model.debugDatabaseReport(write: write) ?? ["no model"] }

        model.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        model.onOpenGame = { [weak self] in self?.gameWindow.show() }

        // Keep the search panel pinned open (hovering) while the Settings window is visible,
        // so the two can be used side by side instead of Settings dismissing the panel.
        settingsWindow.onVisibilityChange = { [weak self] visible in
            self?.panel.companionWindowActive = visible
        }

        WhatsNewWindowController.shared.showIfPending()

        notifier.configure()
        notifier.onUpdateAction = { [weak self] in self?.model.startImageDownload() }
        notifier.onOpenPanel = { [weak self] in self?.panel.show() }
        notifier.onAppUpdateAction = { [weak self] in self?.model.installOrRelaunch() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
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

        // Warm the mana-symbol pip cache for the common glyphs at the preview's font size,
        // so the first card preview doesn't hitch rasterizing them on demand. Low priority
        // so it yields to launch work.
        Task(priority: .low) { @MainActor in
            OracleText.prewarm(size: UIScale.current().size(13))
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

    @objc func openSettings() {
        settingsWindow.show()
    }

    @objc private func openGame() {
        gameWindow.show()
    }

    // MARK: Dock integration

    /// Right-clicking the Dock icon shows the app's actions (mirroring the status-bar menu)
    /// above the system-supplied items (Show All Windows, Hide, Quit). Rebuilt on demand so
    /// the conditional update entries reflect current state.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        if model.newCardsPendingImages > 0 {
            let n = model.newCardsPendingImages
            menu.addItem(withTitle: "Download Images (\(n) new card\(n == 1 ? "" : "s"))…",
                         action: #selector(downloadNewImages), keyEquivalent: "")
        }
        if model.appUpdateState.isActionable, let version = model.appUpdateState.version {
            let title = model.appUpdateState.isReadyToRelaunch
                ? "Relaunch to Update to \(version)…"
                : "Update QuickStudy \(version)…"
            menu.addItem(withTitle: title, action: #selector(installAppUpdate), keyEquivalent: "")
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }

        let search = menu.addItem(withTitle: "Open Search", action: #selector(openSearch), keyEquivalent: "")
        search.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Open Search")
        let play = menu.addItem(withTitle: "Play…", action: #selector(openGame), keyEquivalent: "")
        play.image = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: "Play")
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: "Refresh Database…", action: #selector(refreshNow), keyEquivalent: "")
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Database")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")

        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    /// Cmd-Tab into the app, a Dock-icon click, and a fresh launch all bring the app
    /// forward via activation (Cmd-Tab does NOT trigger `applicationShouldHandleReopen`).
    /// Surface the Spotlight search panel on activation — unless the user is returning to
    /// another of our windows (Settings or Play), which should just come forward on their own.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !panel.isVisible else { return }          // re-entrancy / already-open guard
        guard !hasVisibleStandardWindow else { return } // let Settings/Play come forward
        openSearch()
    }

    /// True when a normal titled window (Settings or Play) is currently visible. The search
    /// panel is borderless and the status item's window is system-owned, so a visible
    /// `.titled` window can only be one of our auxiliary windows.
    private var hasVisibleStandardWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
    }

    /// Clicking the Dock icon opens the Spotlight-style search panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSearch()
        // Return false so AppKit skips its default reopen handling, which would otherwise
        // restore the last closed-but-not-released window (e.g. Settings) and steal key
        // focus from the panel — making it auto-dismiss right after we show it.
        return false
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
