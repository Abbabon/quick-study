import SwiftUI
import AppKit
import Shared

extension Color {
    /// Build a color from a 0xRRGGBB literal.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// A color that resolves differently in light vs dark appearance.
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: return NSColor(dark)
            default:        return NSColor(light)
            }
        })
    }
}

/// Design-system tokens. Text/surfaces/separators intentionally keep native
/// macOS semantics (`.primary`, `.secondary`, `.separator`) — those already
/// match the design's label opacities and adapt to the OS appearance.
enum DS {
    // MARK: Brand (marketing mark only)
    static let brandBlue = Color(hex: 0x283C8C)
    static let brandViolet = Color(hex: 0x7846B4)
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandBlue, brandViolet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Interactive accent
    static let accent = Color(light: Color(hex: 0x5B45C2), dark: Color(hex: 0x9B8AF2))
    static let accentGradientStart = Color(light: Color(hex: 0x3E4FB5), dark: Color(hex: 0x4A5BC8))
    static let accentGradientEnd = Color(light: Color(hex: 0x7A45B6), dark: Color(hex: 0x8E54CE))
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentGradientStart, accentGradientEnd],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Selection wash
    static let selection = Color(light: Color(hex: 0x5B45C2).opacity(0.16),
                                 dark: Color(hex: 0x9B8AF2).opacity(0.30))
    static let selectionStrong = Color(light: Color(hex: 0x5B45C2).opacity(0.26),
                                       dark: Color(hex: 0x9B8AF2).opacity(0.42))

    // MARK: MTG mana tints (theme-independent)
    static let manaW = Color(hex: 0xFFFBD5)
    static let manaU = Color(hex: 0xAAE0FA)
    static let manaB = Color(hex: 0xCBC2BF)
    static let manaR = Color(hex: 0xF9AA8F)
    static let manaG = Color(hex: 0x9BD3AE)
    static let manaC = Color(hex: 0xCAC5C0)
    static let manaGold = Color(hex: 0xD6B458)
    static let manaInk = Color(hex: 0x1A1714)
    static var goldGradient: LinearGradient {
        LinearGradient(colors: [Color(hex: 0xE6CC74), Color(hex: 0xC49B3F)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The solid frame/thumbnail tint for a color identity.
    static func tint(for identity: ColorIdentity) -> Color {
        switch identity {
        case .white: return manaW
        case .blue: return manaU
        case .black: return manaB
        case .red: return manaR
        case .green: return manaG
        case .colorless: return manaC
        case .multicolor: return manaGold
        }
    }

    /// A subtle gradient fill for placeholders; gold gradient for multicolor.
    static func identityGradient(for identity: ColorIdentity) -> LinearGradient {
        if identity == .multicolor { return goldGradient }
        let base = tint(for: identity)
        return LinearGradient(colors: [base, base.opacity(0.82)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Surfaces & lines (explicit design opacities for the game HUD)
    /// Window backdrop (`--qs-window` #1C1C1E in dark).
    static let window = Color(light: Color(hex: 0xF2F2F5), dark: Color(hex: 0x1C1C1E))
    /// Cards / hero / pills (`--qs-surface` #2A2A2C in dark).
    static let surface = Color(light: .white, dark: Color(hex: 0x2A2A2C))
    /// Unselected icon-chip fill (`--qs-track`).
    static let track = Color(light: .black.opacity(0.06), dark: .white.opacity(0.09))
    /// Row hover (`--qs-hover`).
    static let hover = Color(light: .black.opacity(0.05), dark: .white.opacity(0.07))
    /// Hairline ring (`--qs-separator`).
    static let separator = Color(light: .black.opacity(0.10), dark: .white.opacity(0.12))
    /// Idle close button / cold streak (`--qs-text-tertiary`).
    static let textTertiary = Color(light: .black.opacity(0.32), dark: .white.opacity(0.32))
    /// Empty hearts (`--qs-text-quaternary`).
    static let textQuaternary = Color(light: .black.opacity(0.14), dark: .white.opacity(0.14))

    // MARK: Rarity tints (MTG-conventional: grey / silver-blue / gold / orange)
    static let rarityCommon = Color(light: Color(hex: 0x595959), dark: Color(hex: 0xB6B6BC))
    static let rarityUncommon = Color(light: Color(hex: 0x5E7A8C), dark: Color(hex: 0x9FBDCE))
    static let rarityRare = Color(light: Color(hex: 0x9A741F), dark: Color(hex: 0xD8B36A))
    static let rarityMythic = Color(light: Color(hex: 0xC4471B), dark: Color(hex: 0xE9714A))

    // MARK: Status
    static let statusRed = Color(hex: 0xFF3B30)
    static let statusGreen = Color(hex: 0x34C759)
    static let statusOrange = Color(hex: 0xFF9500)
    /// Art-panel status ring tints (translucent so the art shows through).
    static let ringCorrect = Color(hex: 0x34C759).opacity(0.55)
    static let ringWrong = Color(hex: 0xFF3B30).opacity(0.55)

    // MARK: Radii
    enum Radius {
        static let xs: CGFloat = 3
        static let sm: CGFloat = 6
        static let md: CGFloat = 7
        static let lg: CGFloat = 10
        static let img: CGFloat = 12
        static let panel: CGFloat = 14
    }

    // MARK: Motion
    enum Motion {
        static let selectScroll = Animation.easeOut(duration: 0.08)
        static let resize = Animation.easeInOut(duration: 0.2)

        /// `--ease-out` cubic-bezier(0.16, 0.84, 0.44, 1) at a given duration.
        static func easeOut(_ duration: Double) -> Animation {
            .timingCurve(0.16, 0.84, 0.44, 1, duration: duration)
        }
        static let fast = easeOut(0.12)   // --dur-fast: selection ring/halo/lift
        static let base = easeOut(0.2)    // --dur-base: feedback icon, streak heat
        static let slow = easeOut(0.35)   // --dur-slow: new-best pill pop
    }

    /// Soft violet radial bloom used in the hero corner. `endRadius` is kept well
    /// under half the host frame so the gradient fades fully to clear before the
    /// frame edge (otherwise it gets clipped into a hard square).
    static func accentBloom(opacity: Double, radius: CGFloat = 70) -> RadialGradient {
        RadialGradient(
            colors: [accent.opacity(opacity), .clear],
            center: .center, startRadius: 0, endRadius: radius
        )
    }
}

extension View {
    /// Soft medium shadow for card images (design: 0 8 24 black @ .18).
    func dsCardShadow() -> some View {
        shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 8)
    }

    /// 0.5px hairline ring used around thumbnails and real card images.
    func dsHairlineRing(cornerRadius: CGFloat) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5)
        )
    }
}
