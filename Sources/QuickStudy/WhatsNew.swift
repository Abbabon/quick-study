import AppKit
import SwiftUI

/// Release notes for the running version, bundled as Resources/WhatsNew.md:
/// a `version: X.Y.Z` line, then `- ` bullets. Edit that file at release time.
struct WhatsNew: Equatable {
    static let dismissedKey = "whatsNewDismissedVersion"
    static let releasesURL = URL(string: "https://github.com/Abbabon/quick-study/releases")!

    let version: String
    let items: [String]

    static func parse(_ text: String) -> WhatsNew? {
        var version: String?
        var items: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("version:") {
                version = line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") {
                items.append(String(line.dropFirst(2)))
            }
        }
        guard let version, !version.isEmpty, !items.isEmpty else { return nil }
        return WhatsNew(version: version, items: items)
    }

    static func bundled() -> WhatsNew? {
        Bundle.main.url(forResource: "WhatsNew", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap(parse)
    }

    /// Pending = notes exist for the running version and that version hasn't been dismissed.
    /// A fresh install has no dismissed version, so it sees the notes once too.
    static func isPending(notes: WhatsNew?, running: String, dismissed: String?) -> Bool {
        guard let notes else { return false }
        return notes.version == running && dismissed != running
    }
}

@MainActor
final class WhatsNewWindowController: NSObject, NSWindowDelegate {
    static let shared = WhatsNewWindowController()
    private var window: NSWindow?

    /// Launch hook: show only if this version's notes haven't been dismissed.
    func showIfPending(defaults: UserDefaults = .standard) {
        let running = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if WhatsNew.isPending(notes: WhatsNew.bundled(), running: running,
                              dismissed: defaults.string(forKey: WhatsNew.dismissedKey)) {
            show()
        }
    }

    /// Always opens (Settings button); shows whatever notes are bundled.
    func show() {
        guard let notes = WhatsNew.bundled() else { return }
        if window == nil {
            let host = NSHostingController(rootView: WhatsNewView(notes: notes) { [weak self] in
                self?.window?.close()
            })
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "What's New"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.level = .floating  // same level as Settings, so it isn't hidden behind it
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing by any route counts as dismissing.
    func windowWillClose(_ notification: Notification) {
        if let v = WhatsNew.bundled()?.version {
            UserDefaults.standard.set(v, forKey: WhatsNew.dismissedKey)
        }
    }
}

private struct WhatsNewView: View {
    let notes: WhatsNew
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AppTitleHeader(scale: UIScale(value: 1)).frame(maxWidth: .infinity)
            Text("What's new in \(notes.version)").font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(notes.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(DS.accent).frame(width: 5, height: 5).offset(y: -2)
                        Text(item).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Link("Previous versions", destination: WhatsNew.releasesURL).font(.system(size: 12))
                Spacer()
                Button("Got it", action: onDone).buttonStyle(.brandProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 420)
        .background(DS.window)
    }
}
