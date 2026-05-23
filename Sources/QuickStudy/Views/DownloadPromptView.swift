import SwiftUI
import Shared

struct DownloadPromptView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No card database yet")
                .font(.title3)
            Text("Download Scryfall's full card database (~50 MB JSON + ~3–5 GB images).\nYou can also start with cards only and skip images.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            switch model.refreshState {
            case .idle:
                HStack(spacing: 10) {
                    Button("Download Everything (~4 GB)") {
                        model.startRefresh(skipImages: false)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Cards Only (no images)") {
                        model.startRefresh(skipImages: true)
                    }
                }
            case let .running(phase, done, total):
                VStack(spacing: 6) {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                        .frame(width: 320)
                    Text("\(phase) — \(done)/\(total > 0 ? "\(total)" : "?")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case let .error(message):
                VStack(spacing: 8) {
                    Text("Refresh failed").font(.headline).foregroundStyle(.red)
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Retry") { model.startRefresh(skipImages: false) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
