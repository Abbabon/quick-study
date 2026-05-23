import SwiftUI
import AppKit
import Shared

struct CardPreview: View {
    let card: Card?

    var body: some View {
        Group {
            if let card = card {
                content(card: card)
            } else {
                Color.clear
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func content(card: Card) -> some View {
        HStack(alignment: .top, spacing: 16) {
            cardImage(for: card.id)
                .frame(maxWidth: 220, maxHeight: 320)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(card.name).font(.title3).bold()
                    Spacer()
                    if let cost = card.manaCost {
                        Text(cost).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                if let type = card.typeLine {
                    Text(type).font(.subheadline).foregroundStyle(.secondary)
                }
                if let text = card.oracleText, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = card.power, let t = card.toughness {
                    Text("\(p) / \(t)").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
