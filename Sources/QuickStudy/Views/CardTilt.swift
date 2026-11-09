import SwiftUI
import Shared

/// Hover-driven 3D tilt: the content leans toward the cursor by a few degrees (perspective),
/// a soft sheen follows the pointer, and everything springs back on hover exit.
struct CardTilt: ViewModifier {
    var maxDegrees: Double = 7
    var cornerRadius: CGFloat = DS.Radius.img
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Cursor position normalised to -1...1 from the view's center; nil when not hovering.
    @State private var pointer: CGPoint?

    func body(content: Content) -> some View {
        let p = pointer ?? .zero
        return content
            .overlay(
                RadialGradient(colors: [.white.opacity(pointer == nil ? 0 : 0.22), .clear],
                               center: UnitPoint(x: 0.5 + p.x * 0.5, y: 0.5 + p.y * 0.5),
                               startRadius: 0, endRadius: 220)
                    .blendMode(.softLight)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .allowsHitTesting(false)
            )
            .rotation3DEffect(.degrees(-p.y * maxDegrees), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(p.x * maxDegrees), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .shadow(color: .black.opacity(pointer == nil ? 0 : 0.18), radius: 14, x: -p.x * 8, y: -p.y * 8 + 4)
            .background(GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard !reduceMotion else { return }
                        switch phase {
                        case .active(let loc):
                            let w = max(geo.size.width, 1), h = max(geo.size.height, 1)
                            let next = CGPoint(x: min(max((loc.x / w - 0.5) * 2, -1), 1),
                                               y: min(max((loc.y / h - 0.5) * 2, -1), 1))
                            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.8)) { pointer = next }
                        case .ended:
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { pointer = nil }
                        }
                    }
            })
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

/// Full-panel zoomed card over a darkened backdrop. Any click (or Esc, handled by the panel) dismisses.
struct CardZoomOverlay: View {
    let zoom: CardZoom
    let identity: ColorIdentity
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
            .padding(24)
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
