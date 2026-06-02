import AppKit
import SwiftUI

/// A borderless, floating, non-activating NSPanel with vibrancy — the Spotlight look.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var panelScale: Double = UIScale.defaultValue
    private var lastHiddenAt: Date?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        model.onPinnedChange = { [weak self] in self?.adjustPanelForPins() }
    }

    /// Extra height reserved at the bottom for the pinned row. Sized a touch
    /// larger than the row's intrinsic height so the preview area never shrinks.
    private func pinnedBandHeight(_ scale: UIScale) -> CGFloat {
        model.pinned.isEmpty ? 0 : scale.size(124)
    }

    private func panelSize(scale: UIScale) -> NSSize {
        NSSize(width: scale.size(900), height: scale.size(560) + pinnedBandHeight(scale))
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
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        // Auto-dismiss when the user clicks elsewhere.
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
