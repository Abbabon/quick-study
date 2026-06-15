import AppKit
import SwiftUI

/// Hosts `SettingsView` in a normal NSWindow.
/// The SwiftUI `Settings` scene does not open reliably in `LSUIElement` apps,
/// so we own the window directly.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            // Make the hosting controller adopt the SwiftUI view's intrinsic size, then
            // propagate that to the window — without this the window opens collapsed.
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "Quick Study Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 520, height: 560))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
