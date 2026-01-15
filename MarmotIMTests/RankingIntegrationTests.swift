import XCTest
@testable import MarmotIM

/// Integration tests for the complete ranking flow
/// These tests verify that:
/// 1. Search finds candidates correctly
/// 2. Selection updates user learning data
/// 3. Subsequent searches rank selected candidates higher
final class RankingIntegrationTests: XCTestCase {

    // MARK: - Test: Selection Should Immediately Boost Ranking

    func testSelectionImmediatelyBoostsRanking() throws {
        // Create test entries simulating the "kham" scenario
        // 唬 (hu) - 1 char, higher short word bonus
        // 中英 (zhongying) - 2 chars, lower short word bonus
        let huEntry = DictionaryEntry(
            id: 1,
            text: "唬",
            pinyin: "hu",
            wubi: "kham",
            wubiBaseFrequency: 30000,
            pinyinBaseFrequency: 30000,
            source: 1, // wubi source
            length: 1
        )

        let zhongYingEntry = DictionaryEntry(
            id: 2,
            text: "中英",
            pinyin: "zhongying",
            wubi: "kham",
            wubiBaseFrequency: 30000,
            pinyinBaseFrequency: 30000,
            source: 1, // wubi source
            length: 2
        )

        // Create engine with test entries
        let engine = try DictionaryEngine(entries: [huEntry, zhongYingEntry])

        // First search - before any selection
        let matches1 = engine.search(code: "kham", limit: 10)
        XCTAssertEqual(matches1.count, 2, "Should find both entries")

        // Initial ranking - 唬 should be first due to short word bonus
        let candidates1 = CandidateRanker.rank(
            matches: matches1,
            inputCode: "kham",
            engine: engine
        )

        XCTAssertEqual(candidates1.count, 2)
        print("\n=== Before Selection ===")
        for (i, c) in candidates1.enumerated() {
            print("  \(i+1). '\(c.text)' (id=\(c.entryId)) score=\(c.score)")
        }

        // Verify 唬 is first (due to short word bonus: 40K vs 30K)
        XCTAssertEqual(candidates1[0].text, "唬", "唬 should be #1 initially due to short word bonus")

        // User selects 中英 (candidate at index 1)
        let selectedCandidate = candidates1[1]
        XCTAssertEqual(selectedCandidate.text, "中英")

        // Record the selection
        engine.recordSelection(entryId: selectedCandidate.entryId, baseFrequency: selectedCandidate.baseFrequency)

        // Verify user learning data was saved
        let userData = engine.getUserLearning(entryId: selectedCandidate.entryId)
        XCTAssertNotNil(userData, "User data should be saved after selection")
        XCTAssertEqual(userData?.accessCount, 1, "Access count should be 1")
        XCTAssertGreaterThan(userData?.lastAccessTimestamp ?? 0, 0, "Timestamp should be non-zero")

        print("\n=== After Selection ===")
        print("  中英 userData: accessCount=\(userData?.accessCount ?? 0), timestamp=\(userData?.lastAccessTimestamp ?? 0)")

        // Second search - after selection
        let matches2 = engine.search(code: "kham", limit: 10)
        let candidates2 = CandidateRanker.rank(
            matches: matches2,
            inputCode: "kham",
            engine: engine
        )

        print("\n=== Second Search Results ===")
        for (i, c) in candidates2.enumerated() {
            print("  \(i+1). '\(c.text)' (id=\(c.entryId)) score=\(c.score)")
        }

        // CRITICAL: 中英 should now be #1
        XCTAssertEqual(candidates2[0].text, "中英",
            "中英 should be #1 after selection due to ~10M recency boost")

        // Verify score difference
        let zhongYingScore = candidates2.first { $0.text == "中英" }?.score ?? 0
        let huScore = candidates2.first { $0.text == "唬" }?.score ?? 0
        let scoreDiff = zhongYingScore - huScore

        print("\n=== Score Analysis ===")
        print("  中英 score: \(zhongYingScore)")
        print("  唬 score: \(huScore)")
        print("  Difference: \(scoreDiff)")

        XCTAssertGreaterThan(scoreDiff, 9_900_000,
            "中英 should have ~10M score advantage from recency")
    }

    // MARK: - Test: Verify Recency Score Is Applied

    func testRecencyScoreIsApplied() throws {
        let entry = DictionaryEntry(
            id: 100,
            text: "测试",
            pinyin: "ceshi",
            wubi: nil,
            wubiBaseFrequency: 50000,
            pinyinBaseFrequency: 50000,
            source: 2,
            length: 2
        )

        let engine = try DictionaryEngine(entries: [entry])

        // Record selection
        engine.recordSelection(entryId: 100, baseFrequency: 50000)

        // Get user data
        guard let userData = engine.getUserLearning(entryId: 100) else {
            XCTFail("User data should exist")
            return
        }

        // Verify timestamp is recent (within last second)
        let now = UInt32(Date().timeIntervalSince1970)
        XCTAssertGreaterThan(userData.lastAccessTimestamp, now - 2, "Timestamp should be very recent")

        // Calculate recency score
        let recencyScore = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: userData.lastAccessTimestamp)

        print("\n=== Recency Score Test ===")
        print("  Timestamp: \(userData.lastAccessTimestamp)")
        print("  Now: \(now)")
        print("  Recency Score: \(recencyScore)")

        XCTAssertGreaterThan(recencyScore, 9_000_000,
            "Recency score should be close to 10M for just-selected entry")
    }

    // MARK: - Test: Multiple Selections Accumulate

    func testMultipleSelectionsAccumulate() throws {
        let entry = DictionaryEntry(
            id: 200,
            text: "累计",
            pinyin: "leiji",
            wubi: nil,
            wubiBaseFrequency: 30000,
            pinyinBaseFrequency: 30000,
            source: 2,
            length: 2
        )

        let engine = try DictionaryEngine(entries: [entry])

        // Record 3 selections
        for i in 1...3 {
            engine.recordSelection(entryId: 200, baseFrequency: 30000)

            let userData = engine.getUserLearning(entryId: 200)
            XCTAssertEqual(userData?.accessCount, UInt32(i), "Access count should be \(i)")

            print("After selection \(i): accessCount=\(userData?.accessCount ?? 0)")
        }
    }

    // MARK: - Test: Simulate Bug Scenario

    func testSimulateBugScenario() throws {
        // This test simulates the exact bug reported:
        // Input "cgx" (or similar), select "算法" (or "成功"),
        // on 2nd input it should be #1 but requires 3 inputs

        // Create entries with different lengths to trigger short word bonus difference
        let singleChar = DictionaryEntry(
            id: 1,
            text: "词",
            pinyin: "ci",
            wubi: "cgx",
            wubiBaseFrequency: 30000,
            pinyinBaseFrequency: 30000,
            source: 1,
            length: 1
        )

        let twoChar = DictionaryEntry(
            id: 2,
            text: "成功",
            pinyin: "chenggong",
            wubi: "cgx",
            wubiBaseFrequency: 30000,
            pinyinBaseFrequency: 30000,
            source: 1,
            length: 2
        )

        let engine = try DictionaryEngine(entries: [singleChar, twoChar])

        // First search
        let matches1 = engine.search(code: "cgx", limit: 10)
        let ranked1 = CandidateRanker.rank(matches: matches1, inputCode: "cgx", engine: engine)

        print("\n=== Bug Simulation: Initial State ===")
        for (i, c) in ranked1.enumerated() {
            print("  \(i+1). '\(c.text)' score=\(c.score)")
        }

        // 词 should be first due to short word bonus
        XCTAssertEqual(ranked1[0].text, "词", "Single char should be first initially")

        // User selects 成功
        let chengGong = ranked1.first { $0.text == "成功" }!
        engine.recordSelection(entryId: chengGong.entryId, baseFrequency: chengGong.baseFrequency)

        // IMMEDIATELY after selection, check user data
        let userDataAfterSelection = engine.getUserLearning(entryId: chengGong.entryId)
        print("\n=== User Data After Selection ===")
        print("  entryId: \(chengGong.entryId)")
        print("  accessCount: \(userDataAfterSelection?.accessCount ?? 0)")
        print("  timestamp: \(userDataAfterSelection?.lastAccessTimestamp ?? 0)")

        // Second search
        let matches2 = engine.search(code: "cgx", limit: 10)
        let ranked2 = CandidateRanker.rank(matches: matches2, inputCode: "cgx", engine: engine)

        print("\n=== Bug Simulation: After 1 Selection ===")
        for (i, c) in ranked2.enumerated() {
            let ud = engine.getUserLearning(entryId: c.entryId)
            print("  \(i+1). '\(c.text)' score=\(c.score) [accessCount=\(ud?.accessCount ?? 0), ts=\(ud?.lastAccessTimestamp ?? 0)]")
        }

        // 成功 SHOULD be first now
        XCTAssertEqual(ranked2[0].text, "成功",
            "成功 should be #1 after 1 selection (bug: it takes 3 selections)")

        // Calculate the expected advantage
        let recency = FrecencyScore.calculateRecencyScore(
            lastAccessTimestamp: userDataAfterSelection?.lastAccessTimestamp ?? 0
        )
        let freq = FrecencyScore.calculateFrequencyScore(accessCount: 1)
        let shortWordDiff = CandidateRanker.shortWordBonusPerChar // 10,000

        print("\n=== Score Analysis ===")
        print("  Recency: \(recency)")
        print("  Frequency: \(freq)")
        print("  Short word bonus difference: \(shortWordDiff)")
        print("  Total advantage: \(recency + freq - shortWordDiff)")

        // The advantage should be ~10M, way more than 10K
        XCTAssertGreaterThan(recency + freq, shortWordDiff * 100,
            "Recency + frequency should vastly exceed short word bonus difference")
    }
}
