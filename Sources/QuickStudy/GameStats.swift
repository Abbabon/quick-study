import Foundation
import Shared

/// Local best-score / longest-streak persistence per (mode, difficulty), backed by
/// `UserDefaults` (same approach as `AppModel`'s pins). Kept out of `Shared` so the
/// engine stays pure and portable.
enum GameStats {
    private static func key(_ mode: GameMode, _ difficulty: Difficulty, _ field: String) -> String {
        "game.\(mode.rawValue).\(difficulty.rawValue).\(field)"
    }

    static func bestScore(_ mode: GameMode, _ difficulty: Difficulty) -> Int {
        UserDefaults.standard.integer(forKey: key(mode, difficulty, "bestScore"))
    }

    static func longestStreak(_ mode: GameMode, _ difficulty: Difficulty) -> Int {
        UserDefaults.standard.integer(forKey: key(mode, difficulty, "longestStreak"))
    }

    /// Records the results of a finished run, keeping the maxima. Returns true if either
    /// the best score or longest streak improved (for a "new best!" message).
    @discardableResult
    static func record(_ state: GameState, mode: GameMode, difficulty: Difficulty) -> Bool {
        let d = UserDefaults.standard
        var improved = false
        if state.score > bestScore(mode, difficulty) {
            d.set(state.score, forKey: key(mode, difficulty, "bestScore"))
            improved = true
        }
        if state.longestStreak > longestStreak(mode, difficulty) {
            d.set(state.longestStreak, forKey: key(mode, difficulty, "longestStreak"))
            improved = true
        }
        return improved
    }
}
