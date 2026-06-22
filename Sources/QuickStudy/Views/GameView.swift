import SwiftUI
import AppKit
import Shared

/// Root of the dedicated game window. Switches between the first-run art prompt, the
/// mode menu, an active question, and the game-over screen. Celebratory dark-HUD
/// redesign — see the "Quick Study — Play" design handoff.
struct GameView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: GameSession

    var body: some View {
        Group {
            if !model.hasArtwork {
                NeedsArtworkView(session: session)
            } else {
                switch session.phase {
                case .menu:
                    GameMenuView(session: session)
                case .question, .feedback:
                    PlayingView(session: session)
                case let .gameOver(newBest):
                    GameOverView(session: session, newBest: newBest)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GameBackground())
    }
}

/// In-window backdrop: the solid `--qs-window` surface with a faint violet bloom at
/// the top in dark mode (echoing the celebratory page gradient from the design).
private struct GameBackground: View {
    var body: some View {
        ZStack {
            DS.window
            RadialGradient(
                colors: [Color(light: .clear, dark: Color(hex: 0x2A2540).opacity(0.6)), .clear],
                center: .init(x: 0.5, y: -0.1),
                startRadius: 0, endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - First-run prompt

private struct NeedsArtworkView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.artframe")
                .font(.system(size: 48))
                .foregroundStyle(DS.accent)
            Text("Download artwork to play")
                .font(.title2.weight(.semibold))
            Text("The art games need Scryfall's artwork data (~48k illustrations). "
                 + "Metadata downloads now; each card's art streams as you play.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            if case let .running(phase, done, total) = model.refreshState {
                VStack(spacing: 6) {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : nil)
                        .frame(width: 260)
                    Text(progressLabel(phase: phase, done: done, total: total))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case let .error(message) = model.refreshState {
                Text(message).font(.caption).foregroundStyle(DS.statusRed)
                Button("Try Again") { session.downloadArtwork() }
                    .buttonStyle(.brandProminent)
            } else {
                Button("Download Artwork Data") { session.downloadArtwork() }
                    .buttonStyle(.brandProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progressLabel(phase: String, done: Int, total: Int) -> String {
        switch phase {
        case "json": return "Downloading artwork index…"
        case "artwork": return "Ingesting artwork \(done) / \(total)…"
        case "images": return "Downloading art \(done) / \(total)…"
        default: return "Working…"
        }
    }
}

// MARK: - Menu

private struct GameMenuView: View {
    @ObservedObject var session: GameSession
    @State private var mode: GameMode = .guessCard
    @State private var difficulty: Difficulty = .easy

    private var effectiveDifficulty: Difficulty { mode == .guessCard ? difficulty : .easy }

    var body: some View {
        VStack(spacing: 17) {
            HeroCard(artworkCount: session.artworkCount)

            Field("Choose a mode") {
                HStack(spacing: 10) {
                    ModeCard(icon: "magnifyingglass", title: "Guess the Card",
                             desc: "Name the card from its illustration",
                             selected: mode == .guessCard) { mode = .guessCard }
                    ModeCard(icon: "paintbrush", title: "Guess the Artist",
                             desc: "Name who painted the illustration",
                             selected: mode == .guessArtist) { mode = .guessArtist }
                }
            }

            if mode == .guessCard {
                Field("Difficulty") {
                    HStack(spacing: 10) {
                        DiffPill(title: "Easy", desc: "Pick from search",
                                 selected: difficulty == .easy) { difficulty = .easy }
                        DiffPill(title: "Hard", desc: "Type the name",
                                 selected: difficulty == .hard) { difficulty = .hard }
                    }
                }
            }

            HStack(spacing: 10) {
                StatCard(label: "Best", value: session.bestScore(mode, effectiveDifficulty), symbol: "trophy")
                StatCard(label: "Longest streak", value: session.longestStreak(mode, effectiveDifficulty), symbol: "flame.fill")
            }

            Spacer(minLength: 0)

            Button {
                session.start(mode: mode, difficulty: effectiveDifficulty)
            } label: {
                Text("Start").font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.brandProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: 420)
        .animation(DS.Motion.fast, value: mode)
    }
}

private struct HeroCard: View {
    let artworkCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(DS.accent)
                Text("Play")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.primary)
            }
            Text("\(artworkCount.formatted()) illustrations · endless survival, 3 lives")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.lg).fill(DS.surface)
                RoundedRectangle(cornerRadius: DS.Radius.lg).fill(DS.accentGradient).opacity(0.14)
                DS.accentBloom(opacity: 0.45)
                    .frame(width: 180, height: 180)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .offset(x: 30, y: -34)
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(DS.separator, lineWidth: 0.5)
        )
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModeCard: View {
    let icon: String
    let title: String
    let desc: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    Circle().fill(selected ? AnyShapeStyle(DS.accent) : AnyShapeStyle(DS.track))
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary))
                }
                .frame(width: 34, height: 34)
                .shadow(color: selected ? DS.brandViolet.opacity(0.4) : .clear, radius: 6, y: 4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 15)
            .background(SelectionSurface(cornerRadius: DS.Radius.lg, selected: selected))
        }
        .buttonStyle(.plain)
        .offset(y: selected ? -1 : 0)
        .shadow(color: selected ? DS.selection : .clear, radius: 5)
        .shadow(color: selected ? .black.opacity(0.18) : .clear, radius: 12, y: 8)
        .animation(DS.Motion.fast, value: selected)
    }
}

private struct DiffPill: View {
    let title: String
    let desc: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(SelectionSurface(cornerRadius: DS.Radius.md, selected: selected))
        }
        .buttonStyle(.plain)
        .shadow(color: selected ? DS.selection : .clear, radius: 4)
        .animation(DS.Motion.fast, value: selected)
    }
}

/// Shared selected/unselected surface for mode cards and difficulty pills: surface
/// fill, accent-gradient wash + accent ring when selected, hairline ring otherwise.
private struct SelectionSurface: View {
    let cornerRadius: CGFloat
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius).fill(DS.surface)
            if selected {
                RoundedRectangle(cornerRadius: cornerRadius).fill(DS.accentGradient).opacity(0.16)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(selected ? DS.accent : DS.separator, lineWidth: selected ? 1.5 : 0.5)
        )
    }
}

private struct StatCard: View {
    let label: String
    let value: Int
    let symbol: String

    private var lit: Bool { value > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if lit {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.manaGold)
                }
                Text("\(value)")
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.lg).fill(DS.surface)
                if lit {
                    RadialGradient(colors: [DS.manaGold.opacity(0.10), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: 130)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(DS.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - Playing (question + feedback)

private struct PlayingView: View {
    @ObservedObject var session: GameSession

    private var ring: GameArtPanel.Ring {
        if case let .feedback(correct, _) = session.phase { return correct ? .correct : .wrong }
        return .none
    }
    private var isCorrectFeedback: Bool {
        if case .feedback(true, _) = session.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 16) {
            GameHeader(session: session)

            ZStack {
                GameArtPanel(image: session.artImage,
                             identity: session.round?.artwork.identity ?? .colorless,
                             ring: ring)
                if isCorrectFeedback {
                    SparkBurst()
                        .id((session.round?.artwork.illustrationID ?? "") + "\(session.state.score)")
                }
            }

            switch session.phase {
            case .feedback:
                FeedbackView(session: session)
            default:
                AnswerInput(session: session)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct GameHeader: View {
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(spacing: 12) {
            Hearts(lives: session.state.lives)
            Spacer()
            ScoreBar(score: session.state.score, streak: session.state.streak)
            Button {
                session.quit()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.textTertiary)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("End game")
        }
    }
}

private struct Hearts: View {
    let lives: Int
    var max = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max, id: \.self) { i in
                let on = i < lives
                Image(systemName: on ? "heart.fill" : "heart")
                    .font(.system(size: 16))
                    .foregroundStyle(on ? DS.statusRed : DS.textQuaternary)
                    .scaleEffect(on ? 1 : 0.9)
            }
        }
        .animation(DS.Motion.base, value: lives)
    }
}

private struct ScoreBar: View {
    let score: Int
    let streak: Int

    private var hot: Bool { streak >= 3 }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").foregroundStyle(DS.statusGreen)
                Text("\(score)").foregroundStyle(.primary)
            }
            HStack(spacing: 6) {
                Image(systemName: streak > 0 ? "flame.fill" : "flame")
                    .foregroundStyle(hot ? DS.statusOrange : DS.textTertiary)
                    .shadow(color: hot ? DS.statusOrange.opacity(0.5) : .clear, radius: 6)
                Text("\(streak)").foregroundStyle(streak > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.textTertiary))
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .monospacedDigit()
        .animation(DS.Motion.base, value: hot)
    }
}

private struct GameArtPanel: View {
    enum Ring { case none, correct, wrong }

    let image: NSImage?
    let identity: ColorIdentity
    var ring: Ring = .none

    private var dim: Bool { ring == .wrong }
    private var ringColor: Color? {
        switch ring {
        case .none: return nil
        case .correct: return DS.ringCorrect
        case .wrong: return DS.ringWrong
        }
    }

    var body: some View {
        Color.clear
            .aspectRatio(1.34, contentMode: .fit)
            .overlay {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(DS.identityGradient(for: identity))
                            .overlay { ProgressView() }
                    }
                    vignette
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.img))
            .saturation(dim ? 0.85 : 1)
            .brightness(dim ? -0.04 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.img)
                    .strokeBorder(ringColor ?? Color.white.opacity(0.12),
                                  lineWidth: ringColor != nil ? 3 : 0.5)
            )
            .frame(maxWidth: 430)
            .dsCardShadow()
            .animation(DS.Motion.base, value: ring)
    }

    /// Painterly depth: a soft top light, a bottom vignette, and an inset edge darken.
    private var vignette: some View {
        ZStack {
            LinearGradient(colors: [.white.opacity(0.16), .clear],
                           startPoint: .top, endPoint: .center)
            LinearGradient(colors: [.clear, .black.opacity(0.30)],
                           startPoint: .center, endPoint: .bottom)
            RadialGradient(colors: [.clear, .black.opacity(0.22)],
                           center: .center, startRadius: 70, endRadius: 320)
        }
        .allowsHitTesting(false)
    }
}

private struct AnswerInput: View {
    @ObservedObject var session: GameSession

    private var prompt: String {
        session.round?.mode == .guessArtist
            ? "Who painted this illustration?"
            : "Which card is this art from?"
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(prompt)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Group {
                if session.round?.mode == .guessArtist {
                    ArtistChoices(session: session)
                } else if session.difficulty == .easy {
                    CardSearchInput(session: session)
                } else {
                    CardTypeInput(session: session)
                }
            }
        }
        .frame(maxWidth: 430)
    }
}

private struct ArtistChoices: View {
    @ObservedObject var session: GameSession

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(session.round?.choices ?? [], id: \.self) { artist in
                Button {
                    session.submit(artist)
                } label: {
                    Text(artist)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.brandDefault)
            }
        }
    }
}

private struct CardTypeInput: View {
    @ObservedObject var session: GameSession
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Type the card name…", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onAppear { DispatchQueue.main.async { focused = true } }
                .onSubmit(submit)
            Button("Guess", action: submit)
                .buttonStyle(.brandProminent)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let answer = text.trimmingCharacters(in: .whitespaces)
        guard !answer.isEmpty else { return }
        session.submit(answer)
        text = ""
    }
}

private struct CardSearchInput: View {
    @ObservedObject var session: GameSession
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [Card.Mini] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : session.searchCards(query)
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search for the card…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onAppear { DispatchQueue.main.async { focused = true } }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(results, id: \.id) { mini in
                        Button {
                            session.submit(mini.name)
                            query = ""
                        } label: {
                            HStack(spacing: 10) {
                                Thumbnail(id: mini.id, identity: mini.identity)
                                    .frame(width: 30, height: 22)
                                Text(mini.name).font(.system(size: 14)).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.gameRow)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }
}

/// Subtle hover-highlighted row used by the Card-Easy search results.
private struct GameRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .fill(hovering ? DS.hover : .clear)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.08), value: hovering)
    }
}

extension ButtonStyle where Self == GameRowButtonStyle {
    static var gameRow: GameRowButtonStyle { GameRowButtonStyle() }
}

private struct FeedbackView: View {
    @ObservedObject var session: GameSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isCorrect: Bool = {
            if case let .feedback(correct, _) = session.phase { return correct }
            return false
        }()
        let answer: String = {
            if case let .feedback(_, answer) = session.phase { return answer }
            return ""
        }()

        return VStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: isCorrect ? "checkmark.circle" : "xmark.circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isCorrect ? DS.statusGreen : DS.statusRed)
                    .modifier(PopIn(reduceMotion: reduceMotion, from: 0.5, animation: DS.Motion.base))
                Text(isCorrect ? "Correct!" : "Answer: \(answer)")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            if let round = session.round {
                Text(round.mode == .guessArtist ? round.artwork.cardName : "by \(round.artwork.artist)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if let url = ScryfallLink.card(round.artwork.cardName) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label("View Card", systemImage: "safari")
                        }
                    }
                    if let url = ScryfallLink.artist(round.artwork.artist) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label("More by Artist", systemImage: "paintpalette")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }

            Button(session.state.isOver ? "See Results" : "Next") {
                session.next()
            }
            .buttonStyle(.brandProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
        .frame(maxWidth: 430)
    }
}

/// Builds Scryfall web links from the data we already have (no extra ingest needed).
private enum ScryfallLink {
    /// The specific card by exact name.
    static func card(_ name: String) -> URL? { url(query: "!\"\(name)\"") }
    /// All cards illustrated by this artist — "study the artist".
    static func artist(_ artist: String) -> URL? { url(query: "artist:\"\(artist)\"") }

    private static func url(query: String) -> URL? {
        var components = URLComponents(string: "https://scryfall.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

// MARK: - Game over

private struct GameOverView: View {
    @ObservedObject var session: GameSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let newBest: Bool

    var body: some View {
        ZStack {
            if newBest { Confetti() }

            VStack(spacing: 14) {
                Text("Game Over")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(.primary)

                if newBest { newBestPill }

                HStack(spacing: 44) {
                    BigStat(label: "Score", value: session.state.score)
                    BigStat(label: "Longest streak", value: session.state.longestStreak)
                }
                .padding(.top, 4)

                HStack(spacing: 10) {
                    Button("Play Again") {
                        session.start(mode: session.mode, difficulty: session.difficulty)
                    }
                    .buttonStyle(.brandProminent)
                    .controlSize(.large)
                    Button("Menu") { session.backToMenu() }
                        .buttonStyle(.brandDefault)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newBestPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "trophy").font(.system(size: 14))
            Text("New personal best!").font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(DS.manaGold)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(hex: 0xD6B458).opacity(0.14)))
        .overlay(Capsule().strokeBorder(Color(hex: 0xD6B458).opacity(0.5), lineWidth: 0.5))
        .modifier(PopIn(reduceMotion: reduceMotion, from: 0.86, animation: DS.Motion.slow))
    }
}

private struct BigStat: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 44, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared motion

/// Scale pop-in that rests at its visible end-state, so reduced-motion / static
/// contexts always show the content at full size.
private struct PopIn: ViewModifier {
    let reduceMotion: Bool
    var from: CGFloat = 0.5
    var animation: Animation = DS.Motion.base
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (shown ? 1 : from))
            .onAppear {
                guard !reduceMotion else { shown = true; return }
                withAnimation(animation) { shown = true }
            }
    }
}
