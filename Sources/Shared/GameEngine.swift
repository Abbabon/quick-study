import Foundation

// MARK: - Public game vocabulary

public enum GameMode: String, Codable, Sendable, CaseIterable {
    case guessCard
    case guessArtist
}

/// Difficulty only varies the *input* of Guess the Card (Easy = fuzzy search,
/// Hard = type the exact name). Guess the Artist ignores it (always 1-of-4).
public enum Difficulty: String, Codable, Sendable, CaseIterable {
    case easy
    case hard
}

public struct Round: Sendable, Equatable {
    public let artwork: Artwork
    public let mode: GameMode
    /// Four artist names for `guessArtist` (1 correct + 3 distractors), nil for `guessCard`.
    public let choices: [String]?
    /// Card name (`guessCard`) or artist (`guessArtist`).
    public let correctAnswer: String

    public init(artwork: Artwork, mode: GameMode, choices: [String]?, correctAnswer: String) {
        self.artwork = artwork
        self.mode = mode
        self.choices = choices
        self.correctAnswer = correctAnswer
    }
}

public struct GameState: Sendable, Equatable {
    public var lives: Int
    public var score: Int          // correct answers this run
    public var streak: Int         // current consecutive-correct
    public var longestStreak: Int

    public init(lives: Int = 3, score: Int = 0, streak: Int = 0, longestStreak: Int = 0) {
        self.lives = lives
        self.score = score
        self.streak = streak
        self.longestStreak = longestStreak
    }

    public var isOver: Bool { lives <= 0 }
}

// MARK: - Hard-mode name matching

/// Folds a card name for Hard-mode comparison: case-insensitive and treating
/// hyphens / whitespace runs as a single space. All other characters (apostrophes,
/// commas, accents) must still match — so "Niv Mizzet" ≈ "Niv-Mizzet" and
/// "jace beleren" ≈ "Jace Beleren", but spelling/punctuation differences are rejected.
public func normalizeCardName(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var lastWasSpace = false
    for ch in s.lowercased() {
        if ch == "-" || ch == "_" || ch.isWhitespace {
            if !lastWasSpace { out.append(" ") }
            lastWasSpace = true
        } else {
            out.append(ch)
            lastWasSpace = false
        }
    }
    return out.trimmingCharacters(in: .whitespaces)
}

public func hardMatch(_ guess: String, _ answer: String) -> Bool {
    normalizeCardName(guess) == normalizeCardName(answer)
}

// MARK: - Seedable RNG

/// SplitMix64 — a tiny, deterministic PRNG. The same `seed` reproduces the same
/// `Round` sequence and the same option ordering, which is what a future shared
/// daily/weekly web challenge needs (date-seed → identical game for everyone).
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public extension UInt64 {
    /// Stable 64-bit seed from a "YYYY-MM-DD" string (FNV-1a), for date-based challenges.
    static func dateSeed(_ ymd: String) -> UInt64 {
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in ymd.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001B3
        }
        return hash
    }
}

// MARK: - Engine

/// Pure, deterministic round generator + scorekeeper. No AppKit/SwiftUI — unit-testable
/// and portable to a future web/SwiftWasm build.
public final class GameEngine {
    public let mode: GameMode
    public let difficulty: Difficulty
    public private(set) var state: GameState

    private let artworks: [Artwork]
    /// Distinct artists, used to build Guess-the-Artist distractors.
    private let artistPool: [String]
    private var rng: SplitMix64
    /// Artworks shuffled once with the seed; we walk this so a run never repeats an art.
    private let order: [Int]
    private var cursor = 0

    public init(artworks: [Artwork], mode: GameMode, difficulty: Difficulty, seed: UInt64) {
        self.artworks = artworks
        self.mode = mode
        self.difficulty = difficulty
        self.state = GameState()
        var rng = SplitMix64(seed: seed)
        self.order = Array(artworks.indices).shuffled(using: &rng)
        // Build the distinct-artist pool deterministically (sorted -> stable across runs).
        self.artistPool = Array(Set(artworks.map(\.artist))).sorted()
        self.rng = rng
    }

    public var hasRounds: Bool { !artworks.isEmpty }

    /// Returns the next round, cycling through the seeded order if the deck is exhausted.
    public func nextRound() -> Round? {
        guard !artworks.isEmpty else { return nil }
        if cursor >= order.count { cursor = 0 }
        let artwork = artworks[order[cursor]]
        cursor += 1

        switch mode {
        case .guessCard:
            return Round(artwork: artwork, mode: mode, choices: nil, correctAnswer: artwork.cardName)
        case .guessArtist:
            let choices = artistChoices(correct: artwork.artist)
            return Round(artwork: artwork, mode: mode, choices: choices, correctAnswer: artwork.artist)
        }
    }

    /// Scores an answer against the round, mutates `state`, and returns whether it was correct.
    @discardableResult
    public func submit(_ answer: String, for round: Round) -> Bool {
        let correct: Bool
        switch round.mode {
        case .guessCard:
            // Both Easy (selected card name) and Hard (typed) compare on the normalized name,
            // so reprints under different print ids still match.
            correct = hardMatch(answer, round.correctAnswer)
        case .guessArtist:
            correct = answer == round.correctAnswer
        }

        if correct {
            state.score += 1
            state.streak += 1
            state.longestStreak = max(state.longestStreak, state.streak)
        } else {
            state.lives -= 1
            state.streak = 0
        }
        return correct
    }

    /// 1 correct + up to 3 distinct distractor artists, all shuffled with the seeded RNG.
    private func artistChoices(correct: String) -> [String] {
        var distractors: [String] = []
        var pool = artistPool.filter { $0 != correct }
        pool.shuffle(using: &rng)
        for artist in pool {
            distractors.append(artist)
            if distractors.count == 3 { break }
        }
        var choices = [correct] + distractors
        choices.shuffle(using: &rng)
        return choices
    }
}
