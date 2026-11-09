import AppKit
import Combine
import SwiftUI

/// Presents the zoomed card in its own screen-sized, borderless window (a child of the search
/// panel) so it can be larger than the panel. The window never becomes key: the search panel stays
/// key (so its Esc handling works and `windowDidResignKey` doesn't dismiss it), and ordering it as
/// a child means it hides with the panel.
@MainActor
final class ZoomWindowController {
    private let model: AppModel
    private let parent: () -> NSWindow?
    private var window: NSPanel?
    private var cancellable: AnyCancellable?

    init(model: AppModel, parent: @escaping () -> NSWindow?) {
        self.model = model
        self.parent = parent
        cancellable = model.$zoom.removeDuplicates().sink { [weak self] _ in
            // @Published fires before the value lands; read it on the next tick.
            DispatchQueue.main.async { self?.sync() }
        }
    }

    private func sync() {
        guard let zoom = model.zoom, let card = model.selectedCard, card.id == zoom.id,
              let parent = parent(), parent.isVisible else { return close() }
        let screen = parent.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let height = screen.visibleFrame.height * CardZoomSetting.percent / 100
        // Card aspect is 63x88mm; never wider than the screen.
        let width = min(height * 63 / 88, screen.frame.width * 0.95)
        let fitted = CGSize(width: width, height: width * 88 / 63)

        let w = window ?? makeWindow()
        window = w
        w.setFrame(screen.frame, display: false)
        // Fresh hosting view each time so the pop-in animation replays.
        w.contentView = NSHostingView(rootView: CardZoomOverlay(zoom: zoom, identity: card.identity, cardSize: fitted) { [weak self] in
            self?.model.zoom = nil
            self?.model.focusSearchField()
        })
        if w.parent == nil { parent.addChildWindow(w, ordered: .above) }
        w.orderFront(nil)
    }

    private func close() {
        guard let w = window else { return }
        w.parent?.removeChildWindow(w)
        w.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let w = ZoomPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        w.hidesOnDeactivate = true
        return w
    }
}

private final class ZoomPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
