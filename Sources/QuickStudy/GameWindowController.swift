import AppKit
import SwiftUI

/// Hosts `GameView` in a normal, activating NSWindow. The SwiftUI `WindowGroup` scene
/// has historically been unreliable in this app (see `SettingsWindowController`), so we
/// own the window directly.
///
/// The app runs as a `.regular` Dock app at all times, so this controller only has to
/// surface and focus its window — no activation-policy juggling.
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
