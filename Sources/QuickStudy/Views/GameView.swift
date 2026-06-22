import SwiftUI
import AppKit
import Shared

/// Root of the dedicated game window. Switches between the first-run art prompt, the
/// mode menu, an active question, and the game-over screen.
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
        .frame(minWidth: 560, minHeight: 540)
        .padding(24)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Play").font(.largeTitle.weight(.bold))
                Text("\(session.artworkCount) illustrations · endless survival, 3 lives")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Picker("Mode", selection: $mode) {
                Text("Guess the Card").tag(GameMode.guessCard)
                Text("Guess the Artist").tag(GameMode.guessArtist)
            }
            .pickerStyle(.segmented)

            if mode == .guessCard {
                Picker("Difficulty", selection: $difficulty) {
                    Text("Easy — search").tag(Difficulty.easy)
                    Text("Hard — type it").tag(Difficulty.hard)
                }
                .pickerStyle(.segmented)
            }

            let effectiveDifficulty = mode == .guessCard ? difficulty : .easy
            HStack(spacing: 24) {
                stat("Best", session.bestScore(mode, effectiveDifficulty))
                stat("Longest streak", session.longestStreak(mode, effectiveDifficulty))
            }
            .padding(.top, 4)

            Spacer()

            Button {
                session.start(mode: mode, difficulty: effectiveDifficulty)
            } label: {
                Text("Start").frame(maxWidth: .infinity)
            }
            .buttonStyle(.brandProminent)
            .controlSize(.large)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Playing (question + feedback)

private struct PlayingView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 16) {
            GameHeader(session: session)
            ArtPanel(image: session.artImage, identity: session.round?.artwork.identity ?? .colorless)

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
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: i < session.state.lives ? "heart.fill" : "heart")
                        .foregroundStyle(i < session.state.lives ? DS.statusRed : Color.secondary.opacity(0.4))
                }
            }
            Spacer()
            Label("\(session.state.score)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(DS.statusGreen)
            Label("\(session.state.streak)", systemImage: "flame.fill")
                .foregroundStyle(DS.statusOrange)
            Button {
                session.quit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("End game")
        }
        .font(.headline)
        .monospacedDigit()
    }
}

private struct ArtPanel: View {
    let image: NSImage?
    let identity: ColorIdentity

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.img))
                    .dsHairlineRing(cornerRadius: DS.Radius.img)
                    .dsCardShadow()
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.img)
                    .fill(DS.identityGradient(for: identity))
                    .overlay { ProgressView() }
                    .dsHairlineRing(cornerRadius: DS.Radius.img)
            }
        }
        .frame(maxWidth: 460, maxHeight: 320)
    }
}

private struct AnswerInput: View {
    @ObservedObject var session: GameSession

    var body: some View {
        Group {
            if session.round?.mode == .guessArtist {
                ArtistChoices(session: session)
            } else if session.difficulty == .easy {
                CardSearchInput(session: session)
            } else {
                CardTypeInput(session: session)
            }
        }
        .frame(maxWidth: 460)
    }
}

private struct ArtistChoices: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 10) {
            ForEach(session.round?.choices ?? [], id: \.self) { artist in
                Button {
                    session.submit(artist)
                } label: {
                    Text(artist).frame(maxWidth: .infinity)
                }
                .buttonStyle(.brandProminent)
                .controlSize(.large)
            }
        }
    }
}

private struct CardTypeInput: View {
    @ObservedObject var session: GameSession
    @State private var text = ""

    var body: some View {
        HStack {
            TextField("Type the card name…", text: $text)
                .textFieldStyle(.roundedBorder)
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

    private var results: [Card.Mini] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : session.searchCards(query)
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search for the card…", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(results, id: \.id) { mini in
                        Button {
                            session.submit(mini.name)
                            query = ""
                        } label: {
                            HStack {
                                Thumbnail(id: mini.id, identity: mini.identity)
                                    .frame(width: 26, height: 36)
                                Text(mini.name).foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }
}

private struct FeedbackView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        let isCorrect: Bool = {
            if case let .feedback(correct, _) = session.phase { return correct }
            return false
        }()
        let answer: String = {
            if case let .feedback(_, answer) = session.phase { return answer }
            return ""
        }()

        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isCorrect ? DS.statusGreen : DS.statusRed)
                Text(isCorrect ? "Correct!" : "Answer: \(answer)")
                    .font(.title3.weight(.semibold))
            }
            if let round = session.round {
                Text(round.mode == .guessArtist ? round.artwork.cardName : "by \(round.artwork.artist)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button(session.state.isOver ? "See Results" : "Next") {
                session.next()
            }
            .buttonStyle(.brandProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 460)
    }
}

// MARK: - Game over

private struct GameOverView: View {
    @ObservedObject var session: GameSession
    let newBest: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Game Over").font(.largeTitle.weight(.bold))
            if newBest {
                Label("New personal best!", systemImage: "trophy.fill")
                    .foregroundStyle(DS.manaGold)
                    .font(.headline)
            }
            HStack(spacing: 32) {
                resultStat("Score", session.state.score)
                resultStat("Longest streak", session.state.longestStreak)
            }
            HStack(spacing: 12) {
                Button("Play Again") {
                    session.start(mode: session.mode, difficulty: session.difficulty)
                }
                .buttonStyle(.brandProminent)
                .controlSize(.large)
                Button("Menu") { session.backToMenu() }
                    .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultStat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.system(size: 40, weight: .bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
