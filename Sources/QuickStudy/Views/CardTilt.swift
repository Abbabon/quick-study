import SwiftUI
import AppKit
import Shared

/// Hover-driven 3D tilt: the content leans toward the cursor by a few degrees (perspective),
/// a soft sheen follows the pointer, and everything springs back on hover exit.
struct CardTilt: ViewModifier {
    var maxDegrees: Double = 7
    var cornerRadius: CGFloat = DS.Radius.img
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Cursor position normalised to -1...1 from the view's center; nil when not hovering.
    @State private var pointer: CGPoint?
    @AppStorage(FoilStyle.storageKey) private var foilRaw = FoilStyle.none.rawValue

    func body(content: Content) -> some View {
        let p = pointer ?? .zero
        return content
            .modifier(FoilEffect(style: FoilStyle(stored: foilRaw), pointer: p))
            .overlay(
                // Sized relative to the card so the sheen looks the same in the preview and the zoom.
                EllipticalGradient(colors: [.white.opacity(pointer == nil ? 0 : 0.22), .clear],
                                   center: UnitPoint(x: 0.5 + p.x * 0.5, y: 0.5 + p.y * 0.5),
                                   startRadiusFraction: 0, endRadiusFraction: 0.65)
                    .blendMode(.softLight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            )
            .rotation3DEffect(.degrees(-p.y * maxDegrees), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(p.x * maxDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .shadow(color: .black.opacity(pointer == nil ? 0 : 0.18), radius: 14, x: -p.x * 8, y: -p.y * 8 + 4)
            // AppKit tracking area, not `onContinuousHover`: SwiftUI hover is hit-test based, so
            // the image above a background hover region (or any overlay) starved it of events, and
            // it only fires for the key window. A tracking area with `.activeAlways` and a
            // hit-test-transparent view works regardless of what sits above/below it, and doesn't
            // swallow the click that opens the zoom. Added after the rotations so it stays flat.
            .overlay(HoverTracker { loc in
                guard !reduceMotion else { return }
                if let loc {
                    let next = CGPoint(x: min(max((loc.x - 0.5) * 2, -1), 1), y: min(max((loc.y - 0.5) * 2, -1), 1))
                    withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.8)) { pointer = next }
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { pointer = nil }
                }
                if UserDefaults.standard.bool(forKey: "debugTilt") {
                    NSLog("QuickStudy tilt hover=%@ x=%.2f y=%.2f", loc == nil ? "exit" : "move",
                          pointer?.x ?? 0, pointer?.y ?? 0)
                }
            })
    }
}

/// Reports the pointer as a unit point (0...1, top-left origin) while it is over the view, nil on exit.
/// Never hit-tests, so clicks fall through to the SwiftUI views beneath it.
private struct HoverTracker: NSViewRepresentable {
    let onChange: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackerView { TrackerView() }
    func updateNSView(_ view: TrackerView, context: Context) { view.onChange = onChange }

    final class TrackerView: NSView {
        var onChange: (CGPoint?) -> Void = { _ in }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        private func report(_ e: NSEvent) {
            let p = convert(e.locationInWindow, from: nil)
            guard bounds.width > 0, bounds.height > 0 else { return }
            onChange(CGPoint(x: p.x / bounds.width, y: p.y / bounds.height))
        }
        override func mouseEntered(with e: NSEvent) { report(e) }
        override func mouseMoved(with e: NSEvent) { report(e) }
        override func mouseExited(with e: NSEvent) { onChange(nil) }
    }
}

extension View {
    func cardTilt() -> some View { modifier(CardTilt()) }
}

/// Which card face is shown in the zoom overlay.
struct CardZoom: Equatable {
    let id: String
    let back: Bool
}

/// Zoom size setting: percent of the screen's visible height the zoomed card occupies.
enum CardZoomSetting {
    static let storageKey = "zoomHeightPercent"
    static let defaultPercent: Double = 85
    static let range: ClosedRange<Double> = 40 ... 100
    static var percent: Double {
        let v = UserDefaults.standard.object(forKey: storageKey) as? Double ?? defaultPercent
        return min(max(v, range.lowerBound), range.upperBound)
    }
}

/// Content of the screen-sized zoom window: darkened backdrop plus the card. Any click dismisses.
struct CardZoomOverlay: View {
    let zoom: CardZoom
    let identity: ColorIdentity
    let cardSize: CGSize
    var onDismiss: () -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
            CardImageView(
                cacheKey: zoom.back ? "\(zoom.id)_back" : zoom.id,
                fileURL: zoom.back ? Paths.backImageURL(forCardID: zoom.id) : Paths.imageURL(forCardID: zoom.id),
                identity: identity
            )
            .cardTilt()
            .frame(width: cardSize.width, height: cardSize.height)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .scaleEffect(shown ? 1 : 0.85)
        }
        .opacity(shown ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { shown = true } }
        .accessibilityLabel("Zoomed card. Click to close.")
    }
}
