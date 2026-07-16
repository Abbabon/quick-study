import SwiftUI
import AppKit
import Shared

struct CardPreview: View {
    let card: Card?
    var isPinned: Bool = false
    var onTogglePin: () -> Void = {}
    /// Existing lists offered in the "Add to list" menu.
    var lists: [CardList] = []
    /// Adds the previewed card to an existing list (by id).
    var onAddToList: (String) -> Void = { _ in }
    /// Adds the previewed card to a freshly-created list.
    var onAddToNewList: () -> Void = {}
    /// Printings of the previewed card (Scryfall-style list).
    var printings: [Card.Printing] = []
    /// Called when the user taps a printing — opens that exact printing on Scryfall.
    var onPrintingTap: (Card.Printing) -> Void = { _ in }
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
    @AppStorage("showMTGOPrintings") private var showMTGOPrintings: Bool = true
    @AppStorage("showArenaPrintings") private var showArenaPrintings: Bool = true

    var body: some View {
        let scale = UIScale(value: uiScaleValue)
        return Group {
            if let card = card {
                content(card: card, scale: scale)
            } else {
                Color.clear
            }
        }
        .padding(scale.pad(16))
    }

    @ViewBuilder
    private func content(card: Card, scale: UIScale) -> some View {
        HStack(alignment: .top, spacing: scale.pad(16)) {
            FlippableCardImage(cardID: card.id, identity: card.identity)
                .frame(maxWidth: 330, maxHeight: 480)
                .dsCardShadow()
            VStack(alignment: .leading, spacing: scale.pad(8)) {
                header(card: card, scale: scale)
                if let type = card.typeLine {
                    Text(type).font(scale.font(12)).foregroundStyle(.secondary)
                }
                if let text = card.oracleText, !text.isEmpty {
                    OracleTextView(text: text, font: scale.font(13), symbolSize: scale.size(13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = card.power, let t = card.toughness {
                    Text("\(p) / \(t)").font(scale.font(11)).foregroundStyle(.secondary)
                }
                if !visiblePrintings.isEmpty {
                    printingsSection(scale: scale)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Card name + identity badge + mana cost + pin. Prefers a single row, but
    /// when the name would be squished it drops the badge/cost/pin to a second
    /// row so the title always gets the full width (wrapping if it must).
    @ViewBuilder
    private func header(card: Card, scale: UIScale) -> some View {
        let title = Text(card.name).font(scale.font(17, weight: .bold))
        ViewThatFits(in: .horizontal) {
            HStack(spacing: scale.pad(8)) {
                title.lineLimit(1).fixedSize(horizontal: true, vertical: false)
                IdentityBadge(colors: card.colors)
                Spacer(minLength: scale.pad(8))
                metaControls(card: card, scale: scale)
            }
            VStack(alignment: .leading, spacing: scale.pad(6)) {
                title.fixedSize(horizontal: false, vertical: true)
                HStack(spacing: scale.pad(8)) {
                    IdentityBadge(colors: card.colors)
                    if let cost = card.manaCost, !cost.isEmpty {
                        ManaCostView(cost: cost, size: scale.size(16))
                    }
                    RarityBadge(rarity: card.rarity, size: scale.size(16))
                    Spacer(minLength: scale.pad(8))
                    addToListMenu(scale: scale)
                    pinButton(scale: scale)
                }
            }
        }
    }

    @ViewBuilder
    private func metaControls(card: Card, scale: UIScale) -> some View {
        if let cost = card.manaCost, !cost.isEmpty {
            ManaCostView(cost: cost, size: scale.size(16))
        }
        RarityBadge(rarity: card.rarity, size: scale.size(16))
        addToListMenu(scale: scale)
        pinButton(scale: scale)
    }

    private func addToListMenu(scale: UIScale) -> some View {
        Menu {
            ForEach(lists) { list in
                Button("Add to \(list.name)") { onAddToList(list.id) }
            }
            if !lists.isEmpty { Divider() }
            Button("New list…") { onAddToNewList() }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(scale.font(14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add to list")
    }

    private func pinButton(scale: UIScale) -> some View {
        Button(action: onTogglePin) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(scale.font(14, weight: .medium))
                .foregroundStyle(isPinned ? DS.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: .command)
        .help(isPinned ? "Unpin (⌘P)" : "Pin (⌘P)")
    }

    /// Printings minus the digital platforms the user has hidden in Settings.
    private var visiblePrintings: [Card.Printing] {
        printings.filter { p in
            if p.isMTGOOnly && !showMTGOPrintings { return false }
            if p.isArenaOnly && !showArenaPrintings { return false }
            return true
        }
    }

    @ViewBuilder
    private func printingsSection(scale: UIScale) -> some View {
        VStack(alignment: .leading, spacing: scale.pad(4)) {
            Text("Printings (\(visiblePrintings.count))")
                .font(scale.font(11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                // Lazy: some cards (basic lands) have 800+ printings — don't build them all up front.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visiblePrintings) { p in
                        Button { onPrintingTap(p) } label: {
                            HStack(spacing: scale.pad(6)) {
                                Text(p.setName).font(scale.font(12)).lineLimit(1)
                                Text("(\(p.setCode))").font(scale.font(11)).foregroundStyle(.secondary)
                                Spacer(minLength: scale.pad(4))
                                if let y = p.year {
                                    Text(y).font(scale.font(11)).foregroundStyle(.tertiary)
                                }
                                if let r = p.rarity, !r.isEmpty {
                                    Text(r.capitalized).font(scale.font(10)).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, scale.pad(2))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(p.setName) printing on Scryfall")
                    }
                }
            }
            .frame(maxHeight: scale.size(150))
        }
        .padding(.top, scale.pad(4))
    }

}

/// Wraps the card image with a flip affordance for double-faced cards. The rotate
/// button appears only when the fetcher has downloaded `images/{id}_back.jpg`
/// (presence on disk is the whole state); flipping runs a Y-axis 3D rotation,
/// swapping the displayed face at the 90° midpoint so it reads like turning a
/// physical card.
private struct FlippableCardImage: View {
    let cardID: String
    let identity: ColorIdentity
    @State private var hasBack = false
    @State private var showingBack = false
    @State private var angle: Double = 0

    var body: some View {
        CardImageView(
            cacheKey: showingBack ? "\(cardID)_back" : cardID,
            fileURL: showingBack ? Paths.backImageURL(forCardID: cardID)
                                 : Paths.imageURL(forCardID: cardID),
            identity: identity
        )
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
        .overlay(alignment: .topTrailing) {
            if hasBack { flipButton }
        }
        .onAppear(perform: refresh)
        .onChange(of: cardID) { _, _ in
            showingBack = false
            angle = 0
            refresh()
        }
    }

    private var flipButton: some View {
        Button(action: flip) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: .command)
        .help(showingBack ? "Show front face (⌘F)" : "Show back face (⌘F)")
        .padding(8)
    }

    private func refresh() {
        hasBack = FileManager.default.fileExists(atPath: Paths.backImageURL(forCardID: cardID).path)
    }

    private func flip() {
        withAnimation(.easeIn(duration: 0.15)) {
            angle = 90
        } completion: {
            showingBack.toggle()
            angle = -90
            withAnimation(.easeOut(duration: 0.15)) { angle = 0 }
        }
    }
}

/// The large card image in the preview. Reads from the shared `ThumbnailCache` — the same
/// on-disk file the results/recently-added rows already decoded for their thumbnails — so a
/// previously-listed card shows instantly. On a miss it decodes off the main thread instead of
/// blocking the preview's render (these JPEGs are ~100–300 KB and previously decoded
/// synchronously inside `body` on every re-render).
private struct CardImageView: View {
    let cacheKey: String
    let fileURL: URL
    let identity: ColorIdentity
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.img))
            } else {
                IdentityPlaceholder(identity: identity, cornerRadius: DS.Radius.img, symbol: "photo")
            }
        }
        .onAppear(perform: load)
        // Reused as the selection (or shown face) changes — reload when the key does.
        .onChange(of: cacheKey) { _, _ in image = nil; load() }
    }

    private func load() {
        if let cached = ThumbnailCache.cached(cacheKey) {
            image = cached
            return
        }
        let key = cacheKey
        let url = fileURL
        Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let img = NSImage(contentsOf: url) else { return }
            ThumbnailCache.store(img, for: key)
            await MainActor.run {
                if self.cacheKey == key { self.image = img }
            }
        }
    }
}
