import AppKit
import SwiftUI

/// A borderless, floating, non-activating NSPanel with vibrancy — the Spotlight look.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var panelScale: Double = UIScale.defaultValue
    private var lastHiddenAt: Date?
    private let model: AppModel

    /// Set while a floating companion window (the hovering Settings window) is open, so the
    /// panel does not auto-dismiss when that window takes key focus — the two hover together.
    /// `AppDelegate` flips this on when opening Settings and off when it closes.
    var companionWindowActive = false

    init(model: AppModel) {
        self.model = model
        super.init()
        model.onPinnedChange = { [weak self] in self?.adjustPanelForPins() }
        model.onListsColumnChange = { [weak self] in self?.adjustPanelForLists() }
    }

    /// Extra height reserved at the bottom for the pinned row. Sized a touch
    /// larger than the row's intrinsic height so the preview area never shrinks.
    private func pinnedBandHeight(_ scale: UIScale) -> CGFloat {
        model.pinned.isEmpty ? 0 : scale.size(124)
    }

    /// Extra width reserved on the right for the Lists column (matches the column's
    /// 252pt frame plus its divider), so showing it never squeezes the preview.
    private func listsBandWidth(_ scale: UIScale) -> CGFloat {
        model.listsColumnVisible ? scale.size(253) : 0
    }

    private func panelSize(scale: UIScale) -> NSSize {
        NSSize(width: scale.size(900) + listsBandWidth(scale),
               height: scale.size(560) + pinnedBandHeight(scale))
    }

    /// Grows/shrinks the live panel downward (top edge fixed) when the pinned
    /// row appears or disappears, clamped to the active screen.
    private func adjustPanelForPins() {
        guard let panel = panel else { return }
        let target = panelSize(scale: UIScale(value: panelScale))
        let current = panel.frame
        guard abs(current.height - target.height) > 0.5 else { return }
        let topY = current.maxY
        var origin = NSPoint(x: current.origin.x, y: topY - target.height)
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            origin.y = min(max(origin.y, visible.minY), visible.maxY - target.height)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - target.width)
        }
        panel.setFrame(NSRect(origin: origin, size: target), display: true, animate: true)
    }

    /// Grows/shrinks the live panel horizontally when the Lists column is toggled,
    /// keeping the panel's center fixed and clamping to the active screen.
    private func adjustPanelForLists() {
        guard let panel = panel else { return }
        let target = panelSize(scale: UIScale(value: panelScale))
        let current = panel.frame
        guard abs(current.width - target.width) > 0.5 else { return }
        let centerX = current.midX
        var origin = NSPoint(x: centerX - target.width / 2, y: current.maxY - target.height)
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - target.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - target.height)
        }
        panel.setFrame(NSRect(origin: origin, size: target), display: true, animate: true)
    }

    func toggle() {
        if let panel = panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let currentScale = UIScale.current().value
        if let existing = panel, currentScale != panelScale {
            existing.orderOut(nil)
            panel = nil
        }
        if panel == nil {
            panel = makePanel()
            panelScale = currentScale
        }
        guard let panel = panel else { return }
        clearSearchIfTimedOut()
        centerOnActiveScreen(panel)
        // Activate FIRST, then order the panel key/front LAST. As a `.regular` Dock app,
        // `NSApp.activate` performs a full app activation that surfaces another of our
        // windows (e.g. the closed-but-not-released Settings window). If we order the panel
        // front before activating, that surfaced window steals key focus from the panel and
        // `windowDidResignKey` immediately dismisses it — so the hotkey appears to do nothing
        // when the app isn't already frontmost. Ordering the panel front after activation
        // makes it the last (and therefore key) window.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        lastHiddenAt = Date()
    }

    private func clearSearchIfTimedOut() {
        guard let hiddenAt = lastHiddenAt else { return }
        let stored = UserDefaults.standard.object(forKey: ClearSearchTimeout.storageKey) as? Double
        let timeout = stored ?? ClearSearchTimeout.defaultValue
        guard timeout > 0 else { return }
        if Date().timeIntervalSince(hiddenAt) >= timeout {
            model.resetSearchState()
        }
    }

    private func makePanel() -> NSPanel {
        let size = panelSize(scale: UIScale.current())
        let panel = SpotlightPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.delegate = self

        let host = NSHostingView(rootView: SearchPanel(model: model, onDismiss: { [weak self] in self?.hide() }))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.frame = NSRect(origin: .zero, size: size)
        blur.autoresizingMask = [.width, .height]
        blur.addSubview(host)

        panel.contentView = blur
        return panel
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let rawX = screenFrame.midX - size.width / 2
        let rawY = screenFrame.midY - size.height / 2 + screenFrame.height * 0.15
        let clampedX = min(max(rawX, screenFrame.minX), screenFrame.maxX - size.width)
        let clampedY = min(max(rawY, screenFrame.minY), screenFrame.maxY - size.height)
        panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Stay open while a floating companion window (Settings) is up, so the two hover
        // together. Otherwise auto-dismiss when the user clicks elsewhere. Leaving the app
        // entirely is still handled separately by `hidesOnDeactivate`.
        if companionWindowActive { return }
        hide()
    }
}

/// NSPanel subclass that accepts key window status so the search field can receive input.
private final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        // Esc closes the panel.
        orderOut(nil)
    }
}
