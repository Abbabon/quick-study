import AppKit
import SwiftUI
import Shared

/// Drives one sitting at the game window: menu → questions → feedback → game over.
/// Wraps the pure `GameEngine` and adds the app-side concerns (art loading, stats).
@MainActor
final class GameSession: ObservableObject {
    enum Phase: Equatable {
        case menu
        case question
        case feedback(correct: Bool, answer: String)
        case gameOver(newBest: Bool)
    }

    @Published var phase: Phase = .menu
    @Published var mode: GameMode = .guessCard
    @Published var difficulty: Difficulty = .easy
    @Published var round: Round?
    @Published var artImage: NSImage?
    @Published var state = GameState()

    private let model: AppModel
    private let artLoader = ArtCropLoader()
    private var engine: GameEngine?

    init(model: AppModel) {
        self.model = model
    }

    var hasArtwork: Bool { model.hasArtwork }
    var artworkCount: Int { model.artworkCount }

    func bestScore(_ mode: GameMode, _ difficulty: Difficulty) -> Int {
        GameStats.bestScore(mode, difficulty)
    }

    func longestStreak(_ mode: GameMode, _ difficulty: Difficulty) -> Int {
        GameStats.longestStreak(mode, difficulty)
    }

    /// Search the loaded card index for Guess-the-Card Easy mode.
    func searchCards(_ query: String) -> [Card.Mini] {
        model.engine.search(query, limit: 8)
    }

    /// Starts a fresh endless run. Seeds randomly for local play (the engine is still
    /// seedable for a future shared daily/weekly challenge).
    func start(mode: GameMode, difficulty: Difficulty) {
        guard model.hasArtwork else { return }
        self.mode = mode
        self.difficulty = difficulty
        let artworks = model.loadArtworks()
        let engine = GameEngine(artworks: artworks, mode: mode, difficulty: difficulty,
                                seed: UInt64.random(in: .min ... .max))
        self.engine = engine
        self.state = engine.state
        advance()
    }

    func backToMenu() {
        engine = nil
        round = nil
        artImage = nil
        state = GameState()
        phase = .menu
    }

    /// Ends the current run early: the score earned so far still counts toward best
    /// stats, then returns to the menu.
    func quit() {
        if let engine {
            GameStats.record(engine.state, mode: mode, difficulty: difficulty)
        }
        backToMenu()
    }

    /// Submits an answer for the current round, scores it, and shows feedback.
    func submit(_ answer: String) {
        guard let engine, let round else { return }
        let correct = engine.submit(answer, for: round)
        state = engine.state
        phase = .feedback(correct: correct, answer: round.correctAnswer)
    }

    /// Advances from feedback to the next question, or ends the run.
    func next() {
        guard let engine else { return }
        if engine.state.isOver {
            let newBest = GameStats.record(engine.state, mode: mode, difficulty: difficulty)
            phase = .gameOver(newBest: newBest)
            return
        }
        advance()
    }

    private func advance() {
        guard let engine, let nextRound = engine.nextRound() else { return }
        round = nextRound
        artImage = nil
        phase = .question
        loadArt(for: nextRound)
    }

    private func loadArt(for round: Round) {
        let artwork = round.artwork
        Task { [weak self] in
            guard let self else { return }
            let image = await self.artLoader.image(for: artwork)
            // Ignore if the user already moved on to a different round.
            if self.round?.artwork.illustrationID == artwork.illustrationID {
                self.artImage = image
            }
        }
    }

    /// Kicks off artwork-metadata ingest from the first-run prompt.
    func downloadArtwork() {
        model.startArtworkIngest(downloadAll: false)
    }
}
