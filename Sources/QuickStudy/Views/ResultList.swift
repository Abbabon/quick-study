import SwiftUI
import AppKit
import Shared

struct ResultList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.results, id: \.id) { mini in
                        Row(mini: mini, selected: mini.id == model.selectedID) {
                            model.select(mini.id)
                        }
                        .id(mini.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id = id {
                    withAnimation(.easeOut(duration: 0.08)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private struct Row: View {
        let mini: Card.Mini
        let selected: Bool
        let onTap: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                Thumbnail(id: mini.id)
                    .frame(width: 28, height: 40)
                Text(mini.name)
                    .lineLimit(1)
                    .font(.system(size: 14))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
        }
    }
}

private struct Thumbnail: View {
    let id: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 3).fill(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onAppear(perform: load)
    }

    private func load() {
        let url = Paths.imageURL(forCardID: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Cheap synchronous load — thumbnails are small JPEGs.
        if let img = NSImage(contentsOf: url) {
            self.image = img
        }
    }
}
