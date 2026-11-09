import SwiftUI
import AppKit
import EngineBindings
import Shared

/// The empty-query screen: prompt, newest sets, a random-card button and a few stats.
struct StartScreen: View {
    @ObservedObject var model: AppModel
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        return VStack(spacing: scale.pad(16)) {
            AppTitleHeader(scale: scale)
            VStack(spacing: scale.pad(8)) {
                Text("Type a card name")
                    .font(scale.font(17))
                    .foregroundStyle(.secondary)
                Text("↑↓ to navigate • Esc to close")
                    .font(scale.font(11))
                    .foregroundStyle(.tertiary)
            }
            if !model.recentSets.isEmpty {
                VStack(alignment: .leading, spacing: scale.pad(2)) {
                    ForEach(model.recentSets, id: \.code) { s in
                        SetRowView(info: s, scale: scale) { model.searchSet(s.code) }
                    }
                }
                .fixedSize()
            }
            Button {
                model.openRandomCard()
            } label: {
                Label("Random card", systemImage: "dice")
                    .font(scale.font(13, weight: .medium))
            }
            .buttonStyle(.brandProminent)
            .controlSize(.regular)
            statsLine(scale: scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statsLine(scale: UIScale) -> some View {
        var parts = ["\(model.totalCards.formatted()) cards"]
        if model.artworkCount > 0 { parts.append("\(model.artworkCount.formatted()) artworks") }
        parts.append("\(model.lists.count) \(model.lists.count == 1 ? "list" : "lists")")
        if let s = model.lastRefresh, let d = ISO8601DateFormatter().date(from: s) {
            parts.append("updated \(RelativeTime.string(for: d))")
        }
        return Text(parts.joined(separator: " · "))
            .font(scale.font(11))
            .foregroundStyle(.tertiary)
    }
}

private struct SetRowView: View {
    let info: SetRow
    let scale: UIScale
    let onTap: () -> Void
    @State private var hovering = false

    /// Released today or earlier -> NEW; still in the preview window -> SOON.
    private var upcoming: Bool { info.releasedAt > Self.today }
    private static let today: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }()

    /// Badge tint by set type: mainline sets use the accent, commander gold, the rest neutral.
    private var tint: Color {
        switch info.setType {
        case "expansion", "core": return DS.accent
        case "commander": return Color(hex: 0xC49B3F)
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: scale.pad(8)) {
            Text(upcoming ? "SOON" : "NEW")
                .font(scale.font(10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: scale.size(42))   // fixed so NEW/SOON pills (and the names after them) line up
                .padding(.vertical, scale.pad(2))
                .background(Capsule().fill(tint))
            SetIconView(code: info.code, urlString: info.iconSvgUri)
                .frame(width: scale.size(18), height: scale.size(18))   // symbols vary in aspect; fit inside a fixed box
                .foregroundStyle(.secondary)
            Text(info.name)
                .font(scale.font(13))
                .lineLimit(1)
        }
        .padding(.horizontal, scale.pad(8))
        .padding(.vertical, scale.pad(4))
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm)
            .fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .help("Search set:\(info.code)")
    }
}

/// A set symbol: the SVG is downloaded once into `Paths.setIconsDir`, then rendered as a template
/// image (Scryfall's symbols are plain black, so it takes the foreground color).
struct SetIconView: View {
    let code: String
    let urlString: String?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: code) { image = await SetIconCache.image(code: code, urlString: urlString) }
    }
}

enum SetIconCache {
    private static let memory = NSCache<NSString, NSImage>()

    /// Disk cache first, then network. nil on any failure (the row just shows no symbol).
    static func image(code: String, urlString: String?) async -> NSImage? {
        if let hit = memory.object(forKey: code as NSString) { return hit }
        let file = Paths.setIconsDir.appendingPathComponent("\(code.filter { $0.isLetter || $0.isNumber }).svg")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let urlString, let url = URL(string: urlString),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try? data.write(to: file, options: .atomic)
        }
        guard let img = NSImage(contentsOf: file) else { return nil }
        img.isTemplate = true
        memory.setObject(img, forKey: code as NSString)
        return img
    }
}

/// Wordmark image (Resources/HeaderWordmark.png, copied into Contents/Resources by build-app.sh,
/// trimmed to the artwork). Bone-white art: used as-is in dark appearance, tinted `.primary`
/// (template) in light so it doesn't vanish. Falls back to text when the bundle lacks it (swift test).
struct AppTitleHeader: View {
    let scale: UIScale
    @Environment(\.colorScheme) private var colorScheme

    // Trimmed image is 1346x268 px; the "QUICK STUDY" lettering spans x 315...1337, so its center
    // (826) sits 153 px right of the image center (673). Shift left by that share of the width
    // so the lettering, not glyph+text, is centered over the column below.
    private static let imageAspect: CGFloat = 1346.0 / 268.0
    private static let letteringOffsetFraction: CGFloat = 153.0 / 1346.0

    private static let image: NSImage? = Bundle.main.url(forResource: "HeaderWordmark", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if let img = Self.image {
                let h = scale.size(44), w = h * Self.imageAspect
                Image(nsImage: img)
                    .renderingMode(colorScheme == .dark ? .original : .template)
                    .resizable()
                    .frame(width: w, height: h)
                    .offset(x: -w * Self.letteringOffsetFraction)
                    .foregroundStyle(.primary)
            } else {
                Text("Quick Study").font(scale.font(28, weight: .semibold)).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quick Study")
    }
}
