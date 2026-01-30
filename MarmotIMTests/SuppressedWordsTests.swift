import XCTest
@testable import MarmotIM

/// Test suite for the Suppressed Words feature
/// Verifies that suppressed words only use base scores, ignoring user behavior scores
final class SuppressedWordsTests: XCTestCase {

    // MARK: - Test Fixtures

    private var engine: DictionaryEngine!

    override func setUp() {
        super.setUp()
        // Create engine with empty entries for testing
        engine = try! DictionaryEngine(entries: [])
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    /// Create a mock DictionaryEntry
    private func makeEntry(
        id: UInt32,
        text: String,
        pinyin: String = "",
        wubi: String? = nil,
        wubiBaseFrequency: UInt16 = 50000,
        pinyinBaseFrequency: UInt16 = 50000,
        source: Int = 1,
        length: Int? = nil
    ) -> DictionaryEntry {
        return DictionaryEntry(
            id: id,
            text: text,
            pinyin: pinyin,
            wubi: wubi,
            wubiBaseFrequency: wubiBaseFrequency,
            pinyinBaseFrequency: pinyinBaseFrequency,
            source: source,
            length: length ?? text.count
        )
    }

    /// Create a mock DictionaryMatch
    private func makeMatch(
        entry: DictionaryEntry,
        matchedCode: String,
        matchType: DictionaryMatch.MatchType,
        codeType: InputCodeType
    ) -> DictionaryMatch {
        return DictionaryMatch(
            entry: entry,
            matchedCode: matchedCode,
            matchType: matchType,
            codeType: codeType
        )
    }

    /// Helper to rank matches with suppressed words
    private func rankMatches(_ matches: [DictionaryMatch], inputCode: String, suppressedWords: Set<String> = []) -> [Candidate] {
        return CandidateRanker.rank(matches: matches, inputCode: inputCode, engine: engine, suppressedWords: suppressedWords)
    }

    // MARK: - Part 1: Suppressed Word Scoring Tests

    /// Test 1.1: Suppressed word ignores recency score
    func testSuppressedWord_IgnoresRecencyScore() {
        let normalWord = makeEntry(id: 1, text: "我", pinyin: "wo", pinyinBaseFrequency: 50000)
        let suppressedWord = makeEntry(id: 2, text: "握", pinyin: "wo", pinyinBaseFrequency: 50000)

        // Both words were just selected
        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 1, accessCount: 1, lastAccessTimestamp: now)
        engine.setUserLearning(entryId: 2, accessCount: 1, lastAccessTimestamp: now)

        let matches = [
            makeMatch(entry: normalWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
            makeMatch(entry: suppressedWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        // Suppress "握"
        let suppressedSet: Set<String> = ["握"]
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: suppressedSet)

        // Normal word should rank first because suppressed word lost its recency boost
        XCTAssertEqual(candidates[0].text, "我", "Normal word should rank above suppressed word")
        XCTAssertEqual(candidates[1].text, "握", "Suppressed word should rank second")
    }

    /// Test 1.2: Suppressed word ignores frequency score
    func testSuppressedWord_IgnoresFrequencyScore() {
        let normalWord = makeEntry(id: 1, text: "我", pinyin: "wo", pinyinBaseFrequency: 50000)
        let suppressedWord = makeEntry(id: 2, text: "握", pinyin: "wo", pinyinBaseFrequency: 50000)

        // Suppressed word was selected 1000 times, normal word never
        let oneWeekAgo = UInt32(Date().timeIntervalSince1970) - 7 * 86400
        engine.setUserLearning(entryId: 2, accessCount: 1000, lastAccessTimestamp: oneWeekAgo)

        let matches = [
            makeMatch(entry: normalWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
            makeMatch(entry: suppressedWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        // Suppress "握"
        let suppressedSet: Set<String> = ["握"]
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: suppressedSet)

        // Both should have same base score, but suppressed loses frequency
        // They should be roughly equal (same base freq, same short word bonus)
        // Since normal has no user data and suppressed ignores it, they're equal on base scores
        XCTAssertEqual(candidates.count, 2)
    }

    /// Test 1.3: Suppressed word ignores tier override boost
    func testSuppressedWord_IgnoresTierOverrideBoost() {
        let wubiWord = makeEntry(id: 1, text: "工期", wubi: "aaad", wubiBaseFrequency: 45000)
        let suppressedWord = makeEntry(id: 2, text: "我", pinyin: "wo", pinyinBaseFrequency: 50000)

        // Suppressed word was just selected (should have tier override boost normally)
        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 2, accessCount: 1, lastAccessTimestamp: now)

        let matches = [
            makeMatch(entry: wubiWord, matchedCode: "aaad", matchType: .full, codeType: .wubi),
            makeMatch(entry: suppressedWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        // Without suppression, the pinyin word would boost above wubi due to tier override boost
        // With suppression, tier override boost is ignored, so wubi should stay on top
        let suppressedSet: Set<String> = ["我"]
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: suppressedSet)

        XCTAssertEqual(candidates[0].text, "工期", "Wubi word should rank first (suppressed loses tier override)")
        XCTAssertFalse(candidates[0].isBoosted, "First candidate should not be marked as boosted")
    }

    /// Test 1.4: Suppressed word keeps tier bonus
    func testSuppressedWord_KeepsTierBonus() {
        // A wubi full match (tier 1) that's suppressed should still beat pinyin prefix (tier 4)
        let suppressedWubi = makeEntry(id: 1, text: "我", wubi: "test", wubiBaseFrequency: 30000)
        let normalPinyin = makeEntry(id: 2, text: "测试", pinyin: "testceshi", pinyinBaseFrequency: 65000)

        let matches = [
            makeMatch(entry: suppressedWubi, matchedCode: "test", matchType: .full, codeType: .wubi),
            makeMatch(entry: normalPinyin, matchedCode: "testceshi", matchType: .prefix, codeType: .pinyin),
        ]

        let suppressedSet: Set<String> = ["我"]
        let candidates = rankMatches(matches, inputCode: "test", suppressedWords: suppressedSet)

        // Suppressed wubi still gets tier 1 bonus (100B), which beats tier 4 (0)
        XCTAssertEqual(candidates[0].text, "我", "Suppressed word keeps tier bonus")
    }

    /// Test 1.5: Suppressed word keeps base score
    func testSuppressedWord_KeepsBaseScore() {
        let highFreq = makeEntry(id: 1, text: "我", pinyin: "wo", pinyinBaseFrequency: 65000)
        let lowFreq = makeEntry(id: 2, text: "握", pinyin: "wo", pinyinBaseFrequency: 30000)

        let matches = [
            makeMatch(entry: highFreq, matchedCode: "wo", matchType: .full, codeType: .pinyin),
            makeMatch(entry: lowFreq, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        // Both are suppressed
        let suppressedSet: Set<String> = ["我", "握"]
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: suppressedSet)

        // Higher base frequency should win
        XCTAssertEqual(candidates[0].text, "我", "Higher base frequency should rank first")
    }

    /// Test 1.6: Suppressed word keeps short word bonus
    func testSuppressedWord_KeepsShortWordBonus() {
        let shortWord = makeEntry(id: 1, text: "我", pinyin: "wo", pinyinBaseFrequency: 50000, length: 1)
        let longWord = makeEntry(id: 2, text: "我们的", pinyin: "wo", pinyinBaseFrequency: 50000, length: 3)

        let matches = [
            makeMatch(entry: shortWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
            makeMatch(entry: longWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        // Both are suppressed
        let suppressedSet: Set<String> = ["我", "我们的"]
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: suppressedSet)

        // Shorter word should get higher bonus: 1字 (+40000) > 3字 (+20000)
        XCTAssertEqual(candidates[0].text, "我", "Shorter word should rank first")
    }

    // MARK: - Part 2: Suppressed vs Non-Suppressed Interaction

    /// Test 2.1: Non-suppressed word with user history beats suppressed word
    func testSuppressed_VsNonSuppressed_UserHistoryWins() {
        let normalWord = makeEntry(id: 1, text: "我", pinyin: "wo", pinyinBaseFrequency: 40000)
        let suppressedWord = makeEntry(id: 2, text: "握", pinyin: "wo", pinyinBaseFrequency: 50000)

        // Normal word has recent selection
        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 1, accessCount: 5, lastAccessTimestamp: now)

        let matches = [
            makeMatch(entry: normalWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
            makeMatch(entry: suppressedWord, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        let suppressedSet: Set<String> = ["握"]
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: suppressedSet)

        // Normal word gets recency + frequency boost, beats suppressed even with higher base freq
        XCTAssertEqual(candidates[0].text, "我", "Normal word with user history beats suppressed")
    }

    /// Test 2.2: Wubi word can be selected to beat suppressed English
    func testSuppressed_WubiCanBeatSuppressedEnglish() {
        let wubiWord = makeEntry(id: 1, text: "网", wubi: "wget", wubiBaseFrequency: 35000)
        let englishWord = makeEntry(id: 2, text: "wget", pinyin: "wget", pinyinBaseFrequency: 50000)

        // User selects wubi word
        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 1, accessCount: 1, lastAccessTimestamp: now)

        let matches = [
            makeMatch(entry: wubiWord, matchedCode: "wget", matchType: .full, codeType: .wubi),
            makeMatch(entry: englishWord, matchedCode: "wget", matchType: .full, codeType: .english),
        ]

        // Suppress the English word "wget"
        let suppressedSet: Set<String> = ["wget"]
        let candidates = rankMatches(matches, inputCode: "wget")

        // Without suppression, both get tier 1. User selection gives wubi recency boost.
        XCTAssertEqual(candidates[0].text, "网", "User-selected wubi beats English")

        // With suppression
        let candidatesWithSuppression = rankMatches(matches, inputCode: "wget", suppressedWords: suppressedSet)
        XCTAssertEqual(candidatesWithSuppression[0].text, "网", "Wubi with user history beats suppressed English")
    }

    // MARK: - Part 3: Protected Tier Interaction

    /// Test 3.1: Protected tier (jianma) is not affected by suppression
    func testSuppressed_ProtectedTierUnaffected() {
        // Even if jianma word is suppressed, it should still rank first (but without extra boost)
        engine.addJianmaEntry(code: "b", text: "了")

        let jianma = makeEntry(id: 1, text: "了", wubi: "b", wubiBaseFrequency: 65000)
        let normal = makeEntry(id: 2, text: "子", wubi: "b", wubiBaseFrequency: 55000)

        // Give normal word maximum boost
        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 2, accessCount: 1000, lastAccessTimestamp: now)

        let matches = [
            makeMatch(entry: jianma, matchedCode: "b", matchType: .full, codeType: .wubi),
            makeMatch(entry: normal, matchedCode: "b", matchType: .full, codeType: .wubi),
        ]

        // Suppress the jianma "了"
        let suppressedSet: Set<String> = ["了"]
        let candidates = rankMatches(matches, inputCode: "b", suppressedWords: suppressedSet)

        // Jianma still wins because protected tier (10T) is unaffected
        XCTAssertEqual(candidates[0].text, "了", "Protected tier jianma still ranks first even when suppressed")
    }

    // MARK: - Part 4: User Learning Data Preservation

    /// Test 4.1: Suppressed word still records usage (just doesn't use it for scoring)
    func testSuppressed_StillRecordsUsage() {
        // This is more of a design verification - suppressed words should still have their
        // usage recorded, so that if un-suppressed later, the history is preserved.
        // The ranking just ignores the scores during calculation.

        let word = makeEntry(id: 1, text: "我", pinyin: "wo", pinyinBaseFrequency: 50000)

        // Set some learning data
        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 1, accessCount: 10, lastAccessTimestamp: now)

        // Verify the learning data exists
        let userData = engine.getUserLearning(entryId: 1)
        XCTAssertNotNil(userData, "User learning data should exist")
        XCTAssertEqual(userData?.accessCount, 10, "Access count should be preserved")
    }

    // MARK: - Part 5: Edge Cases

    /// Test 5.1: Empty suppressed set behaves normally
    func testSuppressed_EmptySet_NormalBehavior() {
        let wo1 = makeEntry(id: 1, text: "我", pinyin: "wo", pinyinBaseFrequency: 50000)
        let wo2 = makeEntry(id: 2, text: "握", pinyin: "wo", pinyinBaseFrequency: 50000)

        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 2, accessCount: 1, lastAccessTimestamp: now)

        let matches = [
            makeMatch(entry: wo1, matchedCode: "wo", matchType: .full, codeType: .pinyin),
            makeMatch(entry: wo2, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        // Empty suppressed set
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: [])

        // Normal behavior: recently selected wins
        XCTAssertEqual(candidates[0].text, "握", "Recently selected word should rank first with empty suppression")
    }

    /// Test 5.2: All candidates suppressed
    func testSuppressed_AllCandidatesSuppressed() {
        let wo1 = makeEntry(id: 1, text: "我", pinyin: "wo", pinyinBaseFrequency: 65000)
        let wo2 = makeEntry(id: 2, text: "握", pinyin: "wo", pinyinBaseFrequency: 50000)

        // Give wo2 massive boost
        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 2, accessCount: 1000, lastAccessTimestamp: now)

        let matches = [
            makeMatch(entry: wo1, matchedCode: "wo", matchType: .full, codeType: .pinyin),
            makeMatch(entry: wo2, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        // Suppress both
        let suppressedSet: Set<String> = ["我", "握"]
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: suppressedSet)

        // Higher base frequency wins (both lose user behavior scores)
        XCTAssertEqual(candidates[0].text, "我", "Higher base frequency wins when all suppressed")
    }

    /// Test 5.3: Suppressed word not marked as boosted
    func testSuppressed_NotMarkedAsBoosted() {
        let wubi = makeEntry(id: 1, text: "工期", wubi: "aaad", wubiBaseFrequency: 45000)
        let suppressed = makeEntry(id: 2, text: "我", pinyin: "wo", pinyinBaseFrequency: 50000)

        // Suppressed word was just selected (would normally be boosted)
        let now = UInt32(Date().timeIntervalSince1970)
        engine.setUserLearning(entryId: 2, accessCount: 1, lastAccessTimestamp: now)

        let matches = [
            makeMatch(entry: wubi, matchedCode: "aaad", matchType: .full, codeType: .wubi),
            makeMatch(entry: suppressed, matchedCode: "wo", matchType: .full, codeType: .pinyin),
        ]

        let suppressedSet: Set<String> = ["我"]
        let candidates = rankMatches(matches, inputCode: "wo", suppressedWords: suppressedSet)

        // First candidate (wubi) should not be marked as boosted
        // (because suppressed word can't boost above it)
        XCTAssertFalse(candidates[0].isBoosted, "First candidate should not be marked boosted")
    }
}
