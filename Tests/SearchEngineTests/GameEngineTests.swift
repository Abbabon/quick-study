import XCTest
import Shared

final class GameEngineTests: XCTestCase {
    private func artworks(_ n: Int) -> [Artwork] {
        (0..<n).map { i in
            Artwork(illustrationID: "ill-\(i)", cardID: "card-\(i)", cardName: "Card \(i)",
                    artist: "Artist \(i)", artCropURL: "https://example/\(i).jpg",
                    colors: [], setCode: "SET")
        }
    }

    func testSameSeedReproducesRoundSequence() {
        let arts = artworks(50)
        let a = GameEngine(artworks: arts, mode: .guessCard, difficulty: .hard, seed: 42)
        let b = GameEngine(artworks: arts, mode: .guessCard, difficulty: .hard, seed: 42)
        for _ in 0..<20 {
            XCTAssertEqual(a.nextRound()?.artwork.illustrationID,
                           b.nextRound()?.artwork.illustrationID)
        }
    }

    func testSameSeedReproducesArtistChoiceOrder() {
        let arts = artworks(50)
        let a = GameEngine(artworks: arts, mode: .guessArtist, difficulty: .easy, seed: 7)
        let b = GameEngine(artworks: arts, mode: .guessArtist, difficulty: .easy, seed: 7)
        for _ in 0..<20 {
            XCTAssertEqual(a.nextRound()?.choices, b.nextRound()?.choices)
        }
    }

    func testDifferentSeedDiffersSomewhere() {
        let arts = artworks(50)
        let a = GameEngine(artworks: arts, mode: .guessCard, difficulty: .hard, seed: 1)
        let b = GameEngine(artworks: arts, mode: .guessCard, difficulty: .hard, seed: 2)
        let seqA = (0..<20).compactMap { _ in a.nextRound()?.artwork.illustrationID }
        let seqB = (0..<20).compactMap { _ in b.nextRound()?.artwork.illustrationID }
        XCTAssertNotEqual(seqA, seqB)
    }

    func testArtistRoundHasFourDistinctChoicesIncludingCorrect() {
        let engine = GameEngine(artworks: artworks(50), mode: .guessArtist, difficulty: .easy, seed: 3)
        let round = try! XCTUnwrap(engine.nextRound())
        let choices = try! XCTUnwrap(round.choices)
        XCTAssertEqual(choices.count, 4)
        XCTAssertEqual(Set(choices).count, 4, "choices must be distinct")
        XCTAssertTrue(choices.contains(round.correctAnswer))
    }

    func testScoringAndStreak() {
        let engine = GameEngine(artworks: artworks(50), mode: .guessCard, difficulty: .hard, seed: 9)
        let r1 = try! XCTUnwrap(engine.nextRound())
        XCTAssertTrue(engine.submit(r1.correctAnswer, for: r1))
        XCTAssertEqual(engine.state.score, 1)
        XCTAssertEqual(engine.state.streak, 1)
        XCTAssertEqual(engine.state.longestStreak, 1)

        let r2 = try! XCTUnwrap(engine.nextRound())
        XCTAssertFalse(engine.submit("definitely wrong", for: r2))
        XCTAssertEqual(engine.state.score, 1)
        XCTAssertEqual(engine.state.streak, 0)
        XCTAssertEqual(engine.state.longestStreak, 1)
        XCTAssertEqual(engine.state.lives, 2)
    }

    func testGameOverAfterThreeWrong() {
        let engine = GameEngine(artworks: artworks(50), mode: .guessCard, difficulty: .hard, seed: 11)
        for _ in 0..<3 {
            let r = try! XCTUnwrap(engine.nextRound())
            _ = engine.submit("nope", for: r)
        }
        XCTAssertEqual(engine.state.lives, 0)
        XCTAssertTrue(engine.state.isOver)
    }

    func testHardModeAcceptsCaseAndHyphenVariants() {
        let arts = [Artwork(illustrationID: "i", cardID: "c", cardName: "Niv-Mizzet, Parun",
                            artist: "A", artCropURL: "u", colors: [])]
        let engine = GameEngine(artworks: arts, mode: .guessCard, difficulty: .hard, seed: 1)
        let r = try! XCTUnwrap(engine.nextRound())
        XCTAssertTrue(engine.submit("niv mizzet, parun", for: r))
    }

    func testEmptyArtworksProducesNoRounds() {
        let engine = GameEngine(artworks: [], mode: .guessCard, difficulty: .easy, seed: 1)
        XCTAssertFalse(engine.hasRounds)
        XCTAssertNil(engine.nextRound())
    }
}
