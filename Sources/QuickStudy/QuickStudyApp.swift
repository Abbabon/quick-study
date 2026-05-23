import SwiftUI
import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon

        panel = PanelController(model: model)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Quick Study")
        }
        let menu = NSMenu()
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
        }
    }

    @objc private func openSearch() { panel.show() }

    @objc private func refreshNow() {
        model.startRefresh(skipImages: false)
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }
}
