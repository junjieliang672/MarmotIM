import XCTest
@testable import MarmotIM

/// Tests for CandidateRanker.applyRelativeOrdering (spec-003, T3).
/// Pure post-processing behaviour: we construct Candidate arrays by
/// hand with the direct Candidate initializer so we don't need a
/// populated DictionaryEngine.
final class RelativeOrderingRankerTests: XCTestCase {

    // Construct a Candidate with only the fields the post-pass reads.
    private func makeCandidate(
        _ text: String,
        score: Double,
        isJianma: Bool = false,
        id: UInt32 = 0
    ) -> Candidate {
        return Candidate(
            entryId: id == 0 ? UInt32(truncatingIfNeeded: abs(text.hashValue)) : id,
            text: text,
            code: "abc",
            codeType: .pinyin,
            isFullMatch: true,
            wubiBaseFrequency: 0,
            pinyinBaseFrequency: 0,
            score: score,
            isJianma: isJianma,
            isBoosted: false
        )
    }

    // U-RANK-RO-01: A and B in list with B scoring higher — A becomes first.
    func testRuleMovesAToFirst() {
        let list = [
            makeCandidate("B", score: 100),
            makeCandidate("A", score: 50),
            makeCandidate("C", score: 30)
        ]
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [(wordA: "A", wordB: "B")]
        )
        XCTAssertEqual(result.map { $0.text }, ["A", "B", "C"])
    }

    // U-RANK-RO-03: no-op when none of the rule's words are present
    func testNoMatchingWords_noOp() {
        let list = [
            makeCandidate("X", score: 100),
            makeCandidate("Y", score: 50)
        ]
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [(wordA: "A", wordB: "B")]
        )
        XCTAssertEqual(result.map { $0.text }, ["X", "Y"])
    }

    // U-RANK-RO-05: rule references words that aren't in the list
    func testRuleWithOnlyOneWordPresent_noOp() {
        let list = [
            makeCandidate("A", score: 100),
            makeCandidate("X", score: 50)
        ]
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [(wordA: "A", wordB: "B")]
        )
        XCTAssertEqual(result.map { $0.text }, ["A", "X"],
                       "only A present — rule has no effect")
    }

    // U-RANK-RO-04: multiple rules converge
    func testTransitiveRulesConverge() {
        let list = [
            makeCandidate("C", score: 100),
            makeCandidate("B", score: 80),
            makeCandidate("A", score: 60)
        ]
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [
                (wordA: "A", wordB: "B"),
                (wordA: "B", wordB: "C")
            ]
        )
        XCTAssertEqual(result.map { $0.text }, ["A", "B", "C"])
    }

    // U-RANK-RO-02: protected tier (jianma) NOT swapped
    func testJianmaNeverSwapped() {
        let list = [
            makeCandidate("B", score: 1e12, isJianma: true),
            makeCandidate("A", score: 50)
        ]
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [(wordA: "A", wordB: "B")]
        )
        XCTAssertEqual(result.map { $0.text }, ["B", "A"],
                       "P1 jianma must remain #1 regardless of user rule")
    }

    // Rule where A and B are both P0/P1-protected — rule does NOT apply.
    func testBothJianma_notSwapped() {
        let list = [
            makeCandidate("B", score: 1e12, isJianma: true),
            makeCandidate("A", score: 5e11, isJianma: true)
        ]
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [(wordA: "A", wordB: "B")]
        )
        XCTAssertEqual(result.map { $0.text }, ["B", "A"])
    }

    // U-RANK-RO-07: empty store short-circuits
    func testEmptyRules_returnsUnchanged() {
        let list = [
            makeCandidate("B", score: 100),
            makeCandidate("A", score: 50)
        ]
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: []
        )
        XCTAssertEqual(result.map { $0.text }, ["B", "A"])
    }

    // Single-item list: guard doesn't trip.
    func testSingleCandidate_returnsUnchanged() {
        let list = [makeCandidate("A", score: 100)]
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [(wordA: "A", wordB: "B")]
        )
        XCTAssertEqual(result.map { $0.text }, ["A"])
    }

    // U-RANK-RO-06: idempotent
    func testIdempotent() {
        let list = [
            makeCandidate("B", score: 100),
            makeCandidate("A", score: 50),
            makeCandidate("C", score: 30)
        ]
        let once = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [(wordA: "A", wordB: "B")]
        )
        let twice = CandidateRanker.applyRelativeOrdering(
            candidates: once,
            rules: [(wordA: "A", wordB: "B")]
        )
        XCTAssertEqual(once.map { $0.text }, twice.map { $0.text })
    }

    // Stability: non-rule-matching neighbours keep their order.
    func testStability_unrelatedCandidatesUntouched() {
        let list = [
            makeCandidate("X", score: 200),
            makeCandidate("B", score: 100),
            makeCandidate("Y", score: 90),
            makeCandidate("A", score: 50),
            makeCandidate("Z", score: 10)
        ]
        // Rule A→B: A must come before B. X, Y, Z have no opinion.
        let result = CandidateRanker.applyRelativeOrdering(
            candidates: list,
            rules: [(wordA: "A", wordB: "B")]
        )
        // X must stay first (score dominates), A must come before B. Z stays last.
        let texts = result.map { $0.text }
        let idxA = texts.firstIndex(of: "A")!
        let idxB = texts.firstIndex(of: "B")!
        XCTAssertLessThan(idxA, idxB)
        XCTAssertEqual(texts.first, "X")
        XCTAssertEqual(texts.last, "Z")
    }
}
