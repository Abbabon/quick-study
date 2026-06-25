import AppKit
import SwiftUI

/// Hosts `SettingsView` in a normal NSWindow.
/// The SwiftUI `Settings` scene does not open reliably in `LSUIElement` apps,
/// so we own the window directly.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel

    /// Called when the Settings window opens and closes, so `AppDelegate` can keep the
    /// search panel pinned open (hovering) for as long as Settings is visible.
    var onVisibilityChange: ((_ visible: Bool) -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            // Make the hosting controller adopt the SwiftUI view's intrinsic size, then
            // propagate that to the window — without this the window opens collapsed.
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "Quick Study Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            // Float at the same level as the Spotlight search panel so the two hover
            // together instead of Settings opening behind (and dismissing) the panel.
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.delegate = self
            w.setContentSize(NSSize(width: 660, height: 460))
            w.center()
            window = w
        }
        // Pin the panel open BEFORE taking key focus: `makeKeyAndOrderFront` fires the
        // panel's `windowDidResignKey` synchronously, so the flag must already be set or the
        // panel would dismiss itself before we mark Settings as a companion window.
        onVisibilityChange?(true)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }
}
