import AppKit
import SwiftUI
import KeyboardShortcuts
import Shared

// MARK: - Local design tokens (sidebar-settings surfaces & lines)

private enum S {
    static let surface = Color(light: .white, dark: Color(hex: 0x2A2A2C))
    static let surface2 = Color(light: Color(hex: 0xF6F6F7), dark: Color(hex: 0x232325))
    static let separator = Color(light: .black.opacity(0.10), dark: .white.opacity(0.12))
    static let separatorSoft = Color(light: .black.opacity(0.06), dark: .white.opacity(0.07))
    static let hover = Color(light: .black.opacity(0.045), dark: .white.opacity(0.07))
    static let textTertiary = Color(light: .black.opacity(0.26), dark: .white.opacity(0.32))
}

/// One of the four sidebar categories.
private enum Category: String, CaseIterable, Identifiable {
    case general, search, database, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .search: return "Search"
        case .database: return "Database"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .search: return "magnifyingglass"
        case .database: return "cylinder.split.1x2.fill"
        case .about: return "info.circle.fill"
        }
    }
    var tile: TileStyle {
        switch self {
        case .general: return TileStyle(0x8E8E93, 0x5B5B60, font: 15)
        case .search: return TileStyle(0x7A45B6, 0x5B45C2, font: 16)
        case .database: return TileStyle(0xFF9F0A, 0xFF7A00, font: 15)
        case .about: return TileStyle(0x30C0C8, 0x1E9AA6, font: 16)
        }
    }
}

/// A colored icon-tile gradient + glyph point size.
private struct TileStyle {
    let start: UInt32
    let end: UInt32
    let font: CGFloat
    init(_ start: UInt32, _ end: UInt32, font: CGFloat = 14) {
        self.start = start
        self.end = end
        self.font = font
    }
    var gradient: LinearGradient {
        LinearGradient(colors: [Color(hex: start), Color(hex: end)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Reusable pieces

/// 28×28 rounded gradient tile with a centered white SF Symbol.
private struct IconTile: View {
    let symbol: String
    let style: TileStyle
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(style.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: style.font, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    .blendMode(.overlay)
            )
            .shadow(color: .black.opacity(0.18), radius: 0.75, x: 0, y: 1)
    }
}

/// A grouped card wrapping a stack of rows (the macOS grouped-form container).
private struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(S.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(S.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.05), radius: 1, x: 0, y: 1)
    }
}

/// One settings row: tile + label (+ optional subtitle) + trailing control.
private struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let style: TileStyle
    let label: String
    var sub: String? = nil
    var last: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, style: style)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 14))
                if let sub {
                    Text(sub).font(.system(size: 11)).foregroundStyle(S.textTertiary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 30)
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle().fill(S.separatorSoft).frame(height: 0.5)
            }
        }
    }
}

/// A small grouped-settings section title.
private struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Footnote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(S.textTertiary)
            .lineSpacing(1)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A sidebar navigation row with a colored tile and gradient selection wash.
private struct NavItem: View {
    let category: Category
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: category.symbol, style: category.tile)
                Text(category.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.accentGradient)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(S.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Settings root

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("enterBehavior") private var enterBehaviorRaw: String = EnterBehavior.copyName.rawValue
    @AppStorage(UIScale.storageKey) private var uiScaleValue: Double = UIScale.defaultValue
    @AppStorage(ClearSearchTimeout.storageKey) private var clearSearchTimeoutSeconds: Double = ClearSearchTimeout.defaultValue
    @AppStorage("appUpdateAutoCheck") private var appUpdateAutoCheck: Bool = true
    @AppStorage("showRecentlyAdded") private var showRecentlyAdded: Bool = true
    @AppStorage("showMTGOPrintings") private var showMTGOPrintings: Bool = true
    @AppStorage("showArenaPrintings") private var showArenaPrintings: Bool = true
    @AppStorage(Appearance.storageKey) private var appearanceRaw: String = Appearance.defaultValue.rawValue
    // The OS (SMAppService) is the source of truth; seed from it and resync onAppear.
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var selection: Category = .general

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(220)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 660, height: 460)
        .tint(DS.accent)
        .onAppear {
            model.refreshImageCacheSize()
            model.refreshArtworkState()
            // Pick up changes made in System Settings while this window was closed.
            launchAtLogin = LoginItem.isEnabled
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
            VStack(spacing: 3) {
                ForEach(Category.allCases) { category in
                    NavItem(category: category, isSelected: selection == category) {
                        selection = category
                    }
                }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .background(S.surface2)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DS.brandGradient)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("Quick Study").font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text("MTG card search")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch selection {
                case .general: generalPane
                case .search: searchPane
                case .database: databasePane
                case .about: aboutPane
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .scrollContentBackground(.hidden)
        .background(Color(light: Color(hex: 0xECECEC), dark: Color(hex: 0x1C1C1E)))
        .navigationTitle(selection.title)
    }

    // MARK: General

    private var generalPane: some View {
        SettingsCard {
            SettingsRow(symbol: "circle.lefthalf.filled", style: TileStyle(0x5B6BE0, 0x7A45B6),
                        label: "Appearance") {
                Picker("", selection: appearanceBinding) {
                    ForEach(Appearance.allCases) { a in Text(a.label).tag(a) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(symbol: "power", style: TileStyle(0x34C759, 0x28A148),
                        label: "Launch at login") {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                        } catch {
                            NSLog("QuickStudy: failed to set launch-at-login to \(newValue): \(error)")
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
            }
            SettingsRow(symbol: "arrow.triangle.2.circlepath", style: TileStyle(0x3E9BFF, 0x1E6FE0),
                        label: "Check for updates automatically") {
                Toggle("", isOn: $appUpdateAutoCheck).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(symbol: "textformat.size", style: TileStyle(0x283C8C, 0x7846B4),
                        label: "UI scale", last: true) {
                HStack(spacing: 10) {
                    Slider(value: $uiScaleValue, in: UIScale.minValue ... UIScale.maxValue, step: 0.05)
                        .frame(width: 150)
                    Text("\(Int((uiScaleValue * 100).rounded()))%")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
    }

    private var appearanceBinding: Binding<Appearance> {
        Binding(
            get: { Appearance(rawValue: appearanceRaw) ?? .auto },
            set: { newValue in
                appearanceRaw = newValue.rawValue
                Appearance.apply(newValue)
            }
        )
    }

    // MARK: Search

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                SettingsRow(symbol: "command", style: TileStyle(0x8E8E93, 0x636366, font: 13),
                            label: "Open search") {
                    KeyboardShortcuts.Recorder("", name: .openSearch)
                }
                SettingsRow(symbol: "return", style: TileStyle(0x30C0C8, 0x1E9AA6),
                            label: "On Enter") {
                    Picker("", selection: $enterBehaviorRaw) {
                        ForEach(EnterBehavior.allCases) { b in
                            Text(b.shortLabel).tag(b.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(symbol: "clock.arrow.circlepath", style: TileStyle(0x5B6BE0, 0x7A45B6),
                            label: "Show recently added cards") {
                    Toggle("", isOn: $showRecentlyAdded).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(symbol: "o.circle.fill", style: TileStyle(0x3E9BFF, 0x1E6FE0),
                            label: "Show MTGO printings") {
                    Toggle("", isOn: $showMTGOPrintings).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(symbol: "a.circle.fill", style: TileStyle(0xFF9F0A, 0xE0457A),
                            label: "Show Arena printings") {
                    Toggle("", isOn: $showArenaPrintings).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(symbol: "clock", style: TileStyle(0xFF9F0A, 0xFF7A00),
                            label: "Clear search after", last: true) {
                    Picker("", selection: $clearSearchTimeoutSeconds) {
                        ForEach(ClearSearchTimeout.allCases) { t in
                            Text(t.label).tag(t.seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Footnote(text: "The search field resets after this idle delay so the next query starts clean.")
        }
    }

    // MARK: Database

    private var databasePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(text: "Card Search")
            SettingsCard {
                SettingsRow(symbol: "square.grid.2x2.fill", style: TileStyle(0x3E9BFF, 0x1E6FE0),
                            label: "Cards in database") {
                    Text("\(model.totalCards)")
                        .font(.system(size: 14)).foregroundStyle(.secondary).monospacedDigit()
                }
                SettingsRow(symbol: "clock", style: TileStyle(0x8E8E93, 0x636366),
                            label: "Last refresh") {
                    Text(model.lastRefresh ?? "never")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                SettingsRow(symbol: "checkmark", style: TileStyle(0x34C759, 0x28A148),
                            label: "Status", last: true) {
                    statusBadge
                }
            }

            refreshSection
                .padding(.top, 10)
                .padding(.bottom, 16)

            SettingsCard {
                SettingsRow(symbol: "photo.fill", style: TileStyle(0xFF5E8A, 0xE0457A),
                            label: "Image cache", sub: "Downloaded card art") {
                    Text(model.imageCacheSizeFormatted)
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                SettingsRow(symbol: "trash.fill", style: TileStyle(0xFF453A, 0xD8362C, font: 13),
                            label: "Clear cached images", last: true) {
                    Button("Clear Image Cache…", role: .destructive) { confirmClearImageCache() }
                        .controlSize(.small)
                        .disabled(model.refreshState != .idle)
                }
            }
            Footnote(text: "The card database and images power search and previews.")

            SectionHeader(text: "Games")
                .padding(.top, 18)
            artworkSection
        }
    }

    // MARK: Artwork & games

    @ViewBuilder
    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                SettingsRow(symbol: "photo.artframe", style: TileStyle(0x7A45B6, 0x5B45C2),
                            label: "Artwork data", sub: "Powers the Play games") {
                    Text(model.hasArtwork ? "\(model.artworkCount) arts" : "not downloaded")
                        .font(.system(size: 14)).foregroundStyle(.secondary).monospacedDigit()
                }
                SettingsRow(symbol: "arrow.down.circle.fill", style: TileStyle(0x3E9BFF, 0x1E6FE0),
                            label: "Download artwork data",
                            sub: "Metadata only (~260 MB); art streams as you play") {
                    Button(model.hasArtwork ? "Update" : "Download") {
                        model.startArtworkIngest(downloadAll: false)
                    }
                    .controlSize(.small)
                    .disabled(model.refreshState != .idle)
                }
                SettingsRow(symbol: "square.and.arrow.down.fill", style: TileStyle(0x34C759, 0x28A148),
                            label: "Download all art for offline",
                            sub: "~3.5 GB of illustrations") {
                    Button("Download All") { model.startArtworkIngest(downloadAll: true) }
                        .controlSize(.small)
                        .disabled(model.refreshState != .idle)
                }
                SettingsRow(symbol: "internaldrive.fill", style: TileStyle(0xFF5E8A, 0xE0457A),
                            label: "Art cache") {
                    Text(model.artCacheSizeFormatted)
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                SettingsRow(symbol: "trash.fill", style: TileStyle(0xFF453A, 0xD8362C, font: 13),
                            label: "Clear cached art", last: true) {
                    Button("Clear Art Cache…", role: .destructive) { confirmClearArtCache() }
                        .controlSize(.small)
                        .disabled(model.refreshState != .idle)
                }
            }
            Footnote(text: "These illustrations power the Play games (Guess the Card / Guess the Artist). Courtesy of Scryfall.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if model.updateAvailable {
            Label {
                Text("\(model.newCardsPendingImages) new card\(model.newCardsPendingImages == 1 ? "" : "s") added — images pending")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tint)
        } else {
            Text("Up to date")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.statusGreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DS.statusGreen.opacity(0.14), in: Capsule())
        }
    }

    @ViewBuilder
    private var refreshSection: some View {
        switch model.refreshState {
        case .idle:
            HStack(spacing: 8) {
                Button {
                    model.startRefresh(skipImages: false)
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                Button("Refresh Cards Only") { model.startRefresh(skipImages: true) }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        case let .running(phase, done, total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                Text("\(phase) — \(done)/\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .error(msg):
            VStack(alignment: .leading, spacing: 4) {
                Text("Error: \(msg)").font(.caption).foregroundStyle(.red)
                Button("Retry") { model.startRefresh(skipImages: false) }.controlSize(.small)
            }
        }
    }

    // MARK: About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                SettingsRow(symbol: "sparkles", style: TileStyle(0x283C8C, 0x7846B4, font: 14),
                            label: "Quick Study", sub: "MTG card search for macOS", last: true) {
                    Text("Version \(model.currentAppVersion)")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 10)

            SettingsCard {
                SettingsRow(symbol: "arrow.triangle.2.circlepath", style: TileStyle(0x3E9BFF, 0x1E6FE0),
                            label: "Updates", last: true) {
                    HStack(spacing: 10) {
                        appUpdateStatusLabel
                        appUpdateButton
                    }
                }
            }
            Footnote(text: "Card data & images courtesy of Scryfall. Quick Study is unofficial Fan Content.")
        }
    }

    // MARK: Helpers

    private func confirmClearImageCache() {
        let alert = NSAlert()
        alert.messageText = "Clear Image Cache?"
        alert.informativeText = "This will delete \(model.imageCacheSizeFormatted) of cached card images. The card database is preserved — you can re-download images via Refresh Now."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        // Make "Clear" the destructive (non-default) button.
        if alert.buttons.count >= 2 {
            alert.buttons[1].hasDestructiveAction = true
        }
        let response = alert.runModal()
        // First button = Cancel (.alertFirstButtonReturn), second = Clear.
        if response == .alertSecondButtonReturn {
            model.clearImageCache()
        }
    }

    private func confirmClearArtCache() {
        let alert = NSAlert()
        alert.messageText = "Clear Art Cache?"
        alert.informativeText = "This will delete \(model.artCacheSizeFormatted) of cached illustrations. Artwork metadata is preserved — art re-streams as you play."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear")
        if alert.buttons.count >= 2 {
            alert.buttons[1].hasDestructiveAction = true
        }
        if alert.runModal() == .alertSecondButtonReturn {
            model.clearArtCache()
        }
    }

    @ViewBuilder
    private var appUpdateStatusLabel: some View {
        switch model.appUpdateState {
        case .none:
            Text("Up to date").font(.system(size: 14)).foregroundStyle(.secondary)
        case let .available(version, _):
            Label("Update available (\(version))", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.tint).font(.system(size: 13))
        case let .downloading(version):
            Text("Downloading \(version)…").font(.system(size: 14)).foregroundStyle(.secondary)
        case let .readyToRelaunch(version):
            Label("Ready to install \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.tint).font(.system(size: 13))
        case .installing:
            Text("Installing…").font(.system(size: 14)).foregroundStyle(.secondary)
        case let .failed(message):
            Text(message).font(.system(size: 13)).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var appUpdateButton: some View {
        switch model.appUpdateState {
        case let .available(_, kind):
            Button(kind == .homebrew ? "Install Update" : "Get Update") { model.installOrRelaunch() }
                .controlSize(.small)
        case .readyToRelaunch:
            Button("Relaunch to Update") { model.installOrRelaunch() }.controlSize(.small)
        case .downloading, .installing:
            Button("Check for Updates") { model.checkForAppUpdate(force: true) }
                .controlSize(.small).disabled(true)
        case .none, .failed:
            Button("Check for Updates") { model.checkForAppUpdate(force: true) }.controlSize(.small)
        }
    }
}
