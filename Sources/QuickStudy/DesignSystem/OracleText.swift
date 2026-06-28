import SwiftUI
import AppKit
import Shared

/// Renders MTG rules text, replacing `{…}` symbols (mana, `{T}`, etc.) with the
/// same disc pips used by ``ManaCostView``. The pips are rasterized once and
/// concatenated into a single flowing `Text`, so the paragraph still wraps and
/// the literal words stay selectable.
struct OracleTextView: View {
    let text: String
    /// Font for the literal words.
    var font: Font
    /// Diameter of an inline pip, in points (roughly the line's cap height).
    var symbolSize: CGFloat

    var body: some View {
        OracleText.styled(text, font: font, symbolSize: symbolSize)
    }
}

enum OracleText {
    private enum Token {
        case text(String)
        case symbol(ManaPip)
    }

    /// Splits rules text into literal runs and `{…}` symbol tokens. An
    /// unterminated `{` at the end is emitted verbatim rather than swallowed.
    private static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        var symbol = ""
        var inside = false
        for ch in s {
            switch ch {
            case "{":
                if !literal.isEmpty { tokens.append(.text(literal)); literal = "" }
                inside = true
                symbol = ""
            case "}" where inside:
                inside = false
                tokens.append(.symbol(ManaCost.pip(for: symbol)))
            default:
                if inside { symbol.append(ch) } else { literal.append(ch) }
            }
        }
        if inside { literal += "{" + symbol }   // unterminated brace
        if !literal.isEmpty { tokens.append(.text(literal)) }
        return tokens
    }

    /// Builds a `Text` interleaving the words with inline pip images.
    @MainActor
    static func styled(_ text: String, font: Font, symbolSize: CGFloat) -> Text {
        var result = Text(verbatim: "")
        for token in tokenize(text) {
            switch token {
            case .text(let run):
                result = result + Text(verbatim: run)
            case .symbol(let pip):
                let img = Image(nsImage: pipImage(pip, size: symbolSize))
                // Default inline images sit on the baseline (too high); nudge down
                // so the disc straddles the x-height like real card text.
                result = result + Text(img).baselineOffset(-symbolSize * 0.2)
            }
        }
        return result.font(font)
    }

    // MARK: Pip rasterization

    private static var cache: [String: NSImage] = [:]

    /// Tokens that show up in almost every card's rules/cost text. Pre-rasterizing these
    /// at launch keeps the first oracle-text preview from hitching while `ImageRenderer`
    /// builds each disc on demand.
    private static let commonTokens: [String] =
        ["W", "U", "B", "R", "G", "C", "T", "X"] + (0...9).map(String.init)

    /// Best-effort warm-up of the pip cache for the common symbols at the given preview
    /// size. Idempotent — `pipImage` no-ops on a cache hit. Call once after launch settles.
    @MainActor
    static func prewarm(size: CGFloat) {
        for token in commonTokens {
            _ = pipImage(ManaCost.pip(for: token), size: size)
        }
    }

    /// Rasterizes one disc pip. Pip colors are appearance-independent, so a
    /// single cache keyed by glyph + identity + rounded size is safe.
    @MainActor
    private static func pipImage(_ pip: ManaPip, size: CGFloat) -> NSImage {
        let key = "\(pip.glyph)|\(pip.identity)|\(Int(size.rounded()))"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content: ManaPipDisc(pip: pip, size: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = renderer.nsImage ?? NSImage()
        cache[key] = img
        return img
    }
}
