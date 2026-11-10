import SwiftUI

/// Foil treatments for the card image (prototype for a future supporter-only feature).
/// Gating hook: `isUnlocked` is the single place to check entitlement; the picker only lists unlocked styles.
enum FoilStyle: String, CaseIterable, Identifiable {
    case none, holo, etched, galaxy, gilded
    static let storageKey = "foilStyle"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .holo: "Holo"
        case .etched: "Etched"
        case .galaxy: "Galaxy"
        case .gilded: "Gilded"
        }
    }
    var isUnlocked: Bool { true }
    static var available: [FoilStyle] { allCases.filter(\.isUnlocked) }
}

/// Pure SwiftUI foil: gradients + blend modes (GPU-composited, no per-pixel CPU work, no Metal
/// library to bundle). `pointer` is -1...1 from the card centre, the same value `CardTilt` drives.
struct FoilLayer<Source: View>: View {
    let style: FoilStyle
    let pointer: CGPoint
    let cornerRadius: CGFloat
    let source: Source

    private var c: UnitPoint { UnitPoint(x: 0.5 + pointer.x * 0.5, y: 0.5 + pointer.y * 0.5) }
    /// Diagonal band axis whose centre follows the pointer.
    private func band(width: CGFloat = 0.45) -> (UnitPoint, UnitPoint) {
        (UnitPoint(x: c.x - width, y: c.y - width), UnitPoint(x: c.x + width, y: c.y + width))
    }

    var body: some View {
        Group {
            switch style {
            case .none: Color.clear
            case .holo: holo
            case .etched: etched
            case .galaxy: galaxy
            case .gilded: gilded
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .allowsHitTesting(false)
    }

    private var holo: some View {
        let (s, e) = band(width: 0.55)
        let rainbow: [Color] = [.clear, .pink, .orange, .yellow, .green, .cyan, .blue, .purple, .clear]
        return ZStack {
            // faint full-card tint that slides with the pointer
            LinearGradient(colors: rainbow.dropFirst().dropLast().map { $0.opacity(0.35) },
                           startPoint: UnitPoint(x: c.x - 1, y: c.y - 1), endPoint: UnitPoint(x: c.x + 1, y: c.y + 1))
                .blendMode(.softLight)
            LinearGradient(colors: rainbow.map { $0.opacity($0 == .clear ? 0 : 0.55) }, startPoint: s, endPoint: e)
                .blendMode(.overlay)
            LinearGradient(colors: [.clear, .white.opacity(0.28), .clear], startPoint: s, endPoint: e)
                .blendMode(.plusLighter)
        }
    }

    private var etched: some View {
        let (s, e) = band(width: 0.6)
        // Linework/frame = the dark parts of the art: invert, boost contrast, use luminance as alpha.
        let lines = source.colorInvert().brightness(-0.3).contrast(2.8).luminanceToAlpha()
        return ZStack {
            Color.gray.opacity(0.22).blendMode(.saturation)
            LinearGradient(colors: [Color(white: 0.55), .white, Color(white: 0.7), Color(white: 0.35), .white, Color(white: 0.55)],
                           startPoint: s, endPoint: e)
                .mask(lines)
                .opacity(0.9)
                .blendMode(.screen)
            LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: s, endPoint: e)
                .blendMode(.softLight)
        }
    }

    private var galaxy: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.45, green: 0.2, blue: 0.9).opacity(0.5), .clear],
                           center: UnitPoint(x: 0.3 - pointer.x * 0.15, y: 0.25 - pointer.y * 0.15), startRadius: 0, endRadius: 260)
                .blendMode(.softLight)
            RadialGradient(colors: [Color(red: 0.1, green: 0.7, blue: 0.9).opacity(0.45), .clear],
                           center: UnitPoint(x: 0.75 - pointer.x * 0.2, y: 0.7 - pointer.y * 0.2), startRadius: 0, endRadius: 280)
                .blendMode(.softLight)
            RadialGradient(colors: [Color(red: 1, green: 0.3, blue: 0.7).opacity(0.35), .clear],
                           center: UnitPoint(x: 0.6 + pointer.x * 0.25, y: 0.2 + pointer.y * 0.25), startRadius: 0, endRadius: 200)
                .blendMode(.overlay)
            Canvas { ctx, size in
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func rnd() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 33) / Double(1 << 31)
                }
                for _ in 0 ..< 70 {
                    let x = rnd() * size.width, y = rnd() * size.height
                    let phase = rnd() * 6.28, r = 0.6 + rnd() * 1.4
                    // twinkle: each star's brightness depends on where the pointer is
                    let a = max(0, sin(phase + pointer.x * 3.5 + pointer.y * 2.5 + x * 0.02))
                    guard a > 0.15 else { continue }
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(a * 0.9)))
                    if r > 1.4 {
                        var cross = Path()
                        cross.move(to: CGPoint(x: x - r * 3.2, y: y)); cross.addLine(to: CGPoint(x: x + r * 3.2, y: y))
                        cross.move(to: CGPoint(x: x, y: y - r * 3.2)); cross.addLine(to: CGPoint(x: x, y: y + r * 3.2))
                        ctx.stroke(cross, with: .color(.white.opacity(a * 0.6)), lineWidth: 0.6)
                    }
                }
            }
            .blendMode(.plusLighter)
        }
    }

    private var gilded: some View {
        let (s, e) = band(width: 0.5)
        let gold = Color(red: 0.95, green: 0.74, blue: 0.28)
        return ZStack {
            LinearGradient(colors: [gold.opacity(0.35), Color(red: 1, green: 0.9, blue: 0.55).opacity(0.5), gold.opacity(0.2)],
                           startPoint: UnitPoint(x: c.x - 0.8, y: c.y - 0.8), endPoint: UnitPoint(x: c.x + 0.8, y: c.y + 0.8))
                .blendMode(.softLight)
            LinearGradient(colors: [.clear, Color(red: 1, green: 0.85, blue: 0.45).opacity(0.45), .white.opacity(0.3),
                                    Color(red: 1, green: 0.85, blue: 0.45).opacity(0.45), .clear], startPoint: s, endPoint: e)
                .blendMode(.overlay)
            LinearGradient(colors: [.clear, .white.opacity(0.1), .clear], startPoint: s, endPoint: e)
                .blendMode(.plusLighter)
        }
    }
}

/// Compact style picker shown directly below the card art.
struct FoilPicker: View {
    @AppStorage(FoilStyle.storageKey) private var raw = FoilStyle.none.rawValue
    var body: some View {
        Picker("Foil", selection: $raw) {
            ForEach(FoilStyle.available) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .help("Foil effect")
        .accessibilityLabel("Foil effect")
    }
}
