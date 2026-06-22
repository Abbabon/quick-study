import AppKit
import SwiftUI

/// Hosts `GameView` in a normal, activating NSWindow. The SwiftUI `WindowGroup` scene
/// is unreliable in `LSUIElement` apps (see `SettingsWindowController`), so we own the
/// window directly.
///
/// Unlike Settings, the game window opts the app into `.regular` activation while it's
/// open, so it gets a Dock icon and shows up in ⌘-Tab. On close we revert to
/// `.accessory` to restore the menu-bar-only posture.
@MainActor
final class GameWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    private let session: GameSession

    init(model: AppModel) {
        self.model = model
        self.session = GameSession(model: model)
        super.init()
    }

    func show() {
        // Make sure the artwork count is current before deciding which screen to show.
        model.refreshArtworkState()
        if window == nil {
            let root = GameView(session: session).environmentObject(model)
            let host = NSHostingController(rootView: root)
            let w = NSWindow(contentViewController: host)
            w.title = "Quick Study — Play"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(NSSize(width: 600, height: 620))
            w.center()
            window = w
        }
        // Become a regular app so the window appears in the Dock and ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only once the game window is gone.
        NSApp.setActivationPolicy(.accessory)
    }
}
