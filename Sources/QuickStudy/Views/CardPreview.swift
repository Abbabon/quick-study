import SwiftUI
import AppKit
import Shared

struct CardPreview: View {
    let card: Card?
    var isPinned: Bool = false
    var onTogglePin: () -> Void = {}
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue

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
            cardImage(for: card.id)
                .frame(maxWidth: 330, maxHeight: 480)
            VStack(alignment: .leading, spacing: scale.pad(8)) {
                HStack(spacing: scale.pad(8)) {
                    Text(card.name).font(scale.font(17, weight: .bold))
                    Spacer()
                    if let cost = card.manaCost {
                        Text(cost)
                            .font(scale.font(13, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    pinButton(scale: scale)
                }
                if let type = card.typeLine {
                    Text(type).font(scale.font(12)).foregroundStyle(.secondary)
                }
                if let text = card.oracleText, !text.isEmpty {
                    Text(text)
                        .font(scale.font(13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = card.power, let t = card.toughness {
                    Text("\(p) / \(t)").font(scale.font(11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pinButton(scale: UIScale) -> some View {
        Button(action: onTogglePin) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(scale.font(14, weight: .medium))
                .foregroundStyle(isPinned ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("p", modifiers: .command)
        .help(isPinned ? "Unpin (⌘P)" : "Pin (⌘P)")
    }

    @ViewBuilder
    private func cardImage(for id: String) -> some View {
        let url = Paths.imageURL(forCardID: id)
        if FileManager.default.fileExists(atPath: url.path), let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.tertiary)
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Image not downloaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                )
        }
    }
}
