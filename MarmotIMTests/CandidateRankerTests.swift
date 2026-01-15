import XCTest
@testable import MarmotIM

/// Comprehensive test suite for the CandidateRanker tier-based Frecency algorithm
/// Target: 100% test coverage for ranking logic
final class CandidateRankerTests: XCTestCase {

    // MARK: - Test Helpers

    /// Create a mock DictionaryEntry
    /// When baseFrequency is provided, it sets both wubiBaseFrequency and pinyinBaseFrequency to the same value
    private func makeEntry(
        id: UInt32,
        text: String,
        pinyin: String = "",
        wubi: String? = nil,
        baseFrequency: UInt16? = nil,
        wubiBaseFrequency: UInt16 = 50000,
        pinyinBaseFrequency: UInt16 = 50000,
        source: Int = 1,
        length: Int? = nil
    ) -> DictionaryEntry {
        let wubiFreq = baseFrequency ?? wubiBaseFrequency
        let pinyinFreq = baseFrequency ?? pinyinBaseFrequency
        return DictionaryEntry(
            id: id,
            text: text,
            pinyin: pinyin,
            wubi: wubi,
            wubiBaseFrequency: wubiFreq,
            pinyinBaseFrequency: pinyinFreq,
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

    // MARK: - Part 1: Tier System Tests (Short Code Mode ≤4)

    // MARK: 1.1 Individual Tier Tests

    func testTier1_FullWubiMatch_ShortCode() {
        // Tier 1: Full Wubi match with input length 3-4 (not 1-2, which are jiǎnmǎ)
        let entry = makeEntry(id: 1, text: "工期", wubi: "aaad")
        let match = makeMatch(entry: entry, matchedCode: "aaad", matchType: .full, codeType: .wubi)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 4)
        XCTAssertEqual(tierBonus, CandidateRanker.tier1Bonus)
        XCTAssertEqual(tierBonus, 100_000_000_000)
    }

    func testTier2_FullPinyinMatch_ShortCode() {
        // Tier 2: Full Pinyin match with input length ≤ 4
        let entry = makeEntry(id: 2, text: "我", pinyin: "wo")
        let match = makeMatch(entry: entry, matchedCode: "wo", matchType: .full, codeType: .pinyin)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 2)
        XCTAssertEqual(tierBonus, CandidateRanker.tier2Bonus)
        XCTAssertEqual(tierBonus, 10_000_000_000)
    }

    func testTier3_PrefixWubiMatch_ShortCode() {
        // Tier 3: Prefix Wubi match with input length ≤ 4
        let entry = makeEntry(id: 3, text: "我", wubi: "qkwy")
        let match = makeMatch(entry: entry, matchedCode: "qkwy", matchType: .prefix, codeType: .wubi)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 2)
        XCTAssertEqual(tierBonus, CandidateRanker.tier3Bonus)
        XCTAssertEqual(tierBonus, 1_000_000_000)
    }

    func testTier4_PrefixPinyinMatch_ShortCode() {
        // Tier 4: Prefix Pinyin match with input length ≤ 4
        let entry = makeEntry(id: 4, text: "国家", pinyin: "guojia")
        let match = makeMatch(entry: entry, matchedCode: "guojia", matchType: .prefix, codeType: .pinyin)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 2)
        XCTAssertEqual(tierBonus, 0)
    }

    // MARK: 1.2 Tier Ordering Tests

    func testTierOrdering_Tier1BeforesTier2() {
        let tier1Bonus = CandidateRanker.tier1Bonus
        let tier2Bonus = CandidateRanker.tier2Bonus

        // Tier 1 should be exactly 10x higher than Tier 2
        XCTAssertGreaterThanOrEqual(tier1Bonus, tier2Bonus * 10)
        XCTAssertEqual(tier1Bonus / tier2Bonus, 10)
    }

    func testTierOrdering_Tier2BeforesTier3() {
        let tier2Bonus = CandidateRanker.tier2Bonus
        let tier3Bonus = CandidateRanker.tier3Bonus

        // Tier 2 should be exactly 10x higher than Tier 3
        XCTAssertGreaterThanOrEqual(tier2Bonus, tier3Bonus * 10)
        XCTAssertEqual(tier2Bonus / tier3Bonus, 10)
    }

    func testTierOrdering_Tier3BeforesTier4() {
        let tier3Bonus = CandidateRanker.tier3Bonus
        let tier4Bonus: Double = 0

        // Tier 3 should be much higher than Tier 4 (which is 0)
        XCTAssertGreaterThan(tier3Bonus, tier4Bonus)
        XCTAssertEqual(tier3Bonus, 1_000_000_000)
    }

    func testTierOrdering_AllTiers() {
        // All four tiers in order
        XCTAssertGreaterThan(CandidateRanker.tier1Bonus, CandidateRanker.tier2Bonus)
        XCTAssertGreaterThan(CandidateRanker.tier2Bonus, CandidateRanker.tier3Bonus)
        XCTAssertGreaterThan(CandidateRanker.tier3Bonus, 0)
    }

    // MARK: - Part 2: Tier System Tests (Long Code Mode >4)

    func testTier1_FullMatch_LongCode() {
        // Tier 1: Full match with input length > 4
        let entry = makeEntry(id: 5, text: "我国", pinyin: "woguo")
        let match = makeMatch(entry: entry, matchedCode: "woguo", matchType: .full, codeType: .pinyin)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 5)
        XCTAssertEqual(tierBonus, CandidateRanker.tier1Bonus)
    }

    func testTier2_PrefixMatch_LongCode() {
        // Tier 2: Prefix match with input length > 4
        let entry = makeEntry(id: 6, text: "我国人民", pinyin: "woguorenmin")
        let match = makeMatch(entry: entry, matchedCode: "woguorenmin", matchType: .prefix, codeType: .pinyin)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 5)
        XCTAssertEqual(tierBonus, 0)
    }

    func testLongCode_NoWubiPriority() {
        // In long code mode, Wubi matches don't get priority over Pinyin
        let wubiEntry = makeEntry(id: 7, text: "测试", wubi: "ipfy")
        let pinyinEntry = makeEntry(id: 8, text: "测试", pinyin: "ceshi")

        let wubiMatch = makeMatch(entry: wubiEntry, matchedCode: "ipfy", matchType: .full, codeType: .wubi)
        let pinyinMatch = makeMatch(entry: pinyinEntry, matchedCode: "ceshi", matchType: .full, codeType: .pinyin)

        // Both should get Tier 1 bonus in long code mode
        let wubiBonus = CandidateRanker.getTierBonus(match: wubiMatch, inputLength: 5)
        let pinyinBonus = CandidateRanker.getTierBonus(match: pinyinMatch, inputLength: 5)

        XCTAssertEqual(wubiBonus, pinyinBonus)
        XCTAssertEqual(wubiBonus, CandidateRanker.tier1Bonus)
    }

    // MARK: - Part 3: Boundary Cases

    func testBoundary_InputLength4_ShortCodeMode() {
        // Input length 4 should use short code mode (Wubi priority)
        let entry = makeEntry(id: 9, text: "工期", wubi: "aaad")
        let match = makeMatch(entry: entry, matchedCode: "aaad", matchType: .full, codeType: .wubi)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 4)
        XCTAssertEqual(tierBonus, CandidateRanker.tier1Bonus)
    }

    func testBoundary_InputLength5_LongCodeMode() {
        // Input length 5 should use long code mode (no Wubi priority)
        let entry = makeEntry(id: 10, text: "工期", wubi: "aaad")
        let match = makeMatch(entry: entry, matchedCode: "aaad", matchType: .full, codeType: .wubi)

        // In long code mode, both full matches get tier1
        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 5)
        XCTAssertEqual(tierBonus, CandidateRanker.tier1Bonus)
    }

    func testBoundary_InputLength1_Minimum() {
        // Minimum input length - gets jianmaTierBonus because it's a 1-char Wubi code
        let entry = makeEntry(id: 11, text: "一", wubi: "g")
        let match = makeMatch(entry: entry, matchedCode: "g", matchType: .full, codeType: .wubi)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 1)
        XCTAssertEqual(tierBonus, CandidateRanker.jianmaTierBonus, "1-char Wubi code should get jianmaTierBonus")
    }

    func testBoundary_InputLength10_Long() {
        // Long input
        let entry = makeEntry(id: 12, text: "中华人民共和国", pinyin: "zhonghuarenmingongheguo")
        let match = makeMatch(entry: entry, matchedCode: "zhonghuarenmingongheguo", matchType: .full, codeType: .pinyin)

        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 10)
        XCTAssertEqual(tierBonus, CandidateRanker.tier1Bonus)
    }

    // MARK: - Part 4: Short Word Bonus Tests

    func testShortWordBonus_1Char() {
        // 1-char word should get +40,000 bonus
        let entry = makeEntry(id: 13, text: "一", length: 1)
        let bonus = Double(5 - entry.textLength) * CandidateRanker.shortWordBonusPerChar
        XCTAssertEqual(bonus, 40_000)
    }

    func testShortWordBonus_2Chars() {
        // 2-char word should get +30,000 bonus
        let entry = makeEntry(id: 14, text: "我们", length: 2)
        let bonus = Double(5 - entry.textLength) * CandidateRanker.shortWordBonusPerChar
        XCTAssertEqual(bonus, 30_000)
    }

    func testShortWordBonus_3Chars() {
        // 3-char word should get +20,000 bonus
        let entry = makeEntry(id: 15, text: "中国人", length: 3)
        let bonus = Double(5 - entry.textLength) * CandidateRanker.shortWordBonusPerChar
        XCTAssertEqual(bonus, 20_000)
    }

    func testShortWordBonus_4Chars() {
        // 4-char word should get +10,000 bonus
        let entry = makeEntry(id: 16, text: "中华人民", length: 4)
        let bonus = Double(5 - entry.textLength) * CandidateRanker.shortWordBonusPerChar
        XCTAssertEqual(bonus, 10_000)
    }

    func testShortWordBonus_5Chars() {
        // 5-char word should get 0 bonus
        let entry = makeEntry(id: 17, text: "中华人民共", length: 5)
        let textLength = entry.textLength
        var bonus: Double = 0
        if textLength < 5 {
            bonus = Double(5 - textLength) * CandidateRanker.shortWordBonusPerChar
        }
        XCTAssertEqual(bonus, 0)
    }

    func testShortWordBonus_10Chars() {
        // 10-char word should get 0 bonus
        let entry = makeEntry(id: 18, text: "中华人民共和国万岁", length: 10)
        let textLength = entry.textLength
        var bonus: Double = 0
        if textLength < 5 {
            bonus = Double(5 - textLength) * CandidateRanker.shortWordBonusPerChar
        }
        XCTAssertEqual(bonus, 0)
    }

    // MARK: - Part 5: Tier Separation Tests
    //
    // Wubi 1-2级简码 (jianmaTierBonus = 1T) are PROTECTED and cannot be overridden.
    // Other tiers CAN be overridden by tierOverrideBoost (500B) to respect user preferences.

    func testTierSeparation_JianmaCannotBeOverridden() {
        // Jiǎnmǎ tier (1T) cannot be overridden by tierOverrideBoost (500B)
        // Max score for non-jiǎnmǎ = tier1Bonus + tierOverride + recency + freq + base + short
        // = 100B + 500B + 1B + 10M + 65K + 40K ≈ 601B
        let maxNonJianmaScore: Double = CandidateRanker.tier1Bonus +
            FrecencyScore.tierOverrideInitialBoost +
            FrecencyScore.recencyInitialBoost +
            10_000_000 + 65_535 + 40_000

        XCTAssertLessThan(maxNonJianmaScore, CandidateRanker.jianmaTierBonus,
            "Jiǎnmǎ (1T) cannot be overridden by any combination of boosts (~601B)")
    }

    func testTierSeparation_TierOverrideBoostCanCrossRegularTiers() {
        // tierOverrideBoost (500B) CAN override regular tier gaps
        // This is intentional - allows user preferences to matter for non-jiǎnmǎ words
        let tierOverride = FrecencyScore.tierOverrideInitialBoost
        let tier1ToTier2Gap = CandidateRanker.tier1Bonus - CandidateRanker.tier2Bonus // 90B

        XCTAssertGreaterThan(tierOverride, tier1ToTier2Gap,
            "tierOverrideBoost (500B) should be able to cross tier1-tier2 gap (90B)")
    }

    func testTierSeparation_JianmaTierBonusValue() {
        // Verify jiǎnmǎ tier bonus is 1T
        XCTAssertEqual(CandidateRanker.jianmaTierBonus, 1_000_000_000_000)
    }

    func testTierSeparation_TierOverrideBoostIsEnabled() {
        // tierOverrideBoost should be enabled (500B) for non-jiǎnmǎ words
        XCTAssertEqual(FrecencyScore.tierOverrideInitialBoost, 500_000_000_000)
    }

    func testTierSeparation_RegularTierValues() {
        // Verify regular tier values
        XCTAssertEqual(CandidateRanker.tier1Bonus, 100_000_000_000)
        XCTAssertEqual(CandidateRanker.tier2Bonus, 10_000_000_000)
        XCTAssertEqual(CandidateRanker.tier3Bonus, 1_000_000_000)
    }

    // MARK: - Part 6: Boost Function Tests

    func testBoost_MovesToTop() {
        var candidates = [
            Candidate(from: makeMatch(entry: makeEntry(id: 1, text: "A"), matchedCode: "a", matchType: .full, codeType: .wubi), score: 100),
            Candidate(from: makeMatch(entry: makeEntry(id: 2, text: "B"), matchedCode: "b", matchType: .full, codeType: .wubi), score: 90),
            Candidate(from: makeMatch(entry: makeEntry(id: 3, text: "C"), matchedCode: "c", matchType: .full, codeType: .wubi), score: 80),
        ]

        CandidateRanker.boost(candidates: &candidates, at: 2)

        XCTAssertEqual(candidates[0].text, "C")
        XCTAssertEqual(candidates[1].text, "A")
        XCTAssertEqual(candidates[2].text, "B")
    }

    func testBoost_IndexZero_NoChange() {
        var candidates = [
            Candidate(from: makeMatch(entry: makeEntry(id: 1, text: "A"), matchedCode: "a", matchType: .full, codeType: .wubi), score: 100),
            Candidate(from: makeMatch(entry: makeEntry(id: 2, text: "B"), matchedCode: "b", matchType: .full, codeType: .wubi), score: 90),
        ]

        CandidateRanker.boost(candidates: &candidates, at: 0)

        // No change when boosting index 0
        XCTAssertEqual(candidates[0].text, "A")
        XCTAssertEqual(candidates[1].text, "B")
    }

    func testBoost_OutOfBounds_NoChange() {
        var candidates = [
            Candidate(from: makeMatch(entry: makeEntry(id: 1, text: "A"), matchedCode: "a", matchType: .full, codeType: .wubi), score: 100),
        ]

        CandidateRanker.boost(candidates: &candidates, at: 5)

        // No change when index out of bounds
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].text, "A")
    }

    func testBoost_NegativeIndex_NoChange() {
        var candidates = [
            Candidate(from: makeMatch(entry: makeEntry(id: 1, text: "A"), matchedCode: "a", matchType: .full, codeType: .wubi), score: 100),
        ]

        CandidateRanker.boost(candidates: &candidates, at: -1)

        // No change with negative index
        XCTAssertEqual(candidates.count, 1)
    }

    // MARK: - Part 7: Combined Tier and Match Type Tests

    func testAllFourTiers_ShortCodeMode() {
        // Create matches for all four tiers
        let fullWubi = makeMatch(
            entry: makeEntry(id: 1, text: "一", wubi: "g", baseFrequency: 64000),
            matchedCode: "g",
            matchType: .full,
            codeType: .wubi
        )
        let fullPinyin = makeMatch(
            entry: makeEntry(id: 2, text: "哥", pinyin: "ge", baseFrequency: 50000),
            matchedCode: "ge",
            matchType: .full,
            codeType: .pinyin
        )
        let prefixWubi = makeMatch(
            entry: makeEntry(id: 3, text: "该", wubi: "ghnv", baseFrequency: 60000),
            matchedCode: "ghnv",
            matchType: .prefix,
            codeType: .wubi
        )
        let prefixPinyin = makeMatch(
            entry: makeEntry(id: 4, text: "国家", pinyin: "guojia", baseFrequency: 65000),
            matchedCode: "guojia",
            matchType: .prefix,
            codeType: .pinyin
        )

        let t1 = CandidateRanker.getTierBonus(match: fullWubi, inputLength: 1)
        let t2 = CandidateRanker.getTierBonus(match: fullPinyin, inputLength: 1)
        let t3 = CandidateRanker.getTierBonus(match: prefixWubi, inputLength: 1)
        let t4 = CandidateRanker.getTierBonus(match: prefixPinyin, inputLength: 1)

        XCTAssertGreaterThan(t1, t2)
        XCTAssertGreaterThan(t2, t3)
        XCTAssertGreaterThan(t3, t4)
        XCTAssertEqual(t4, 0)
    }

    func testTwoTiers_LongCodeMode() {
        // Create matches for both tiers in long code mode
        let fullMatch = makeMatch(
            entry: makeEntry(id: 1, text: "我国", pinyin: "woguo"),
            matchedCode: "woguo",
            matchType: .full,
            codeType: .pinyin
        )
        let prefixMatch = makeMatch(
            entry: makeEntry(id: 2, text: "我国人民", pinyin: "woguorenmin"),
            matchedCode: "woguorenmin",
            matchType: .prefix,
            codeType: .pinyin
        )

        let t1 = CandidateRanker.getTierBonus(match: fullMatch, inputLength: 5)
        let t2 = CandidateRanker.getTierBonus(match: prefixMatch, inputLength: 5)

        XCTAssertEqual(t1, CandidateRanker.tier1Bonus)
        XCTAssertEqual(t2, 0)
        XCTAssertGreaterThan(t1, t2)
    }

    // MARK: - Part 8: Input Length Edge Cases

    func testInputLength_Zero() {
        // Edge case: input length 0 (should still work)
        let entry = makeEntry(id: 1, text: "一", wubi: "g")
        let match = makeMatch(entry: entry, matchedCode: "g", matchType: .full, codeType: .wubi)

        // Length 0 <= 2, so jianmaTierBonus for full Wubi match
        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 0)
        XCTAssertEqual(tierBonus, CandidateRanker.jianmaTierBonus, "Full Wubi with inputLength 0 gets jianmaTierBonus")
    }

    func testInputLength_Negative() {
        // Edge case: negative input length (should handle gracefully)
        let entry = makeEntry(id: 1, text: "一", wubi: "g")
        let match = makeMatch(entry: entry, matchedCode: "g", matchType: .full, codeType: .wubi)

        // Negative <= 2, so jianmaTierBonus for full Wubi match
        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: -1)
        XCTAssertEqual(tierBonus, CandidateRanker.jianmaTierBonus, "Full Wubi with negative inputLength gets jianmaTierBonus")
    }

    func testInputLength_VeryLarge() {
        // Edge case: very large input length
        let entry = makeEntry(id: 1, text: "测", pinyin: "ce")
        let match = makeMatch(entry: entry, matchedCode: "ce", matchType: .full, codeType: .pinyin)

        // 100 > 4, so long code mode
        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 100)
        XCTAssertEqual(tierBonus, CandidateRanker.tier1Bonus)
    }

    // MARK: - Part 9: Constants Validation

    func testConstants_TierBonuses() {
        XCTAssertEqual(CandidateRanker.tier1Bonus, 100_000_000_000)
        XCTAssertEqual(CandidateRanker.tier2Bonus, 10_000_000_000)
        XCTAssertEqual(CandidateRanker.tier3Bonus, 1_000_000_000)
    }

    func testConstants_ShortWordBonus() {
        XCTAssertEqual(CandidateRanker.shortWordBonusPerChar, 10_000)
    }

    // MARK: - Part 10: Comprehensive Ranking Scenarios

    func testRanking_TierDominatesWithinTierScore() {
        // Even with max within-tier score, lower tier cannot beat higher tier
        // Tier 3 with base 65535 should still rank below Tier 2 with base 0

        let tier2Entry = makeEntry(id: 1, text: "哥", pinyin: "ge", baseFrequency: 0)
        let tier3Entry = makeEntry(id: 2, text: "该", wubi: "ghnv", baseFrequency: 65535)

        let tier2Match = makeMatch(entry: tier2Entry, matchedCode: "ge", matchType: .full, codeType: .pinyin)
        let tier3Match = makeMatch(entry: tier3Entry, matchedCode: "ghnv", matchType: .prefix, codeType: .wubi)

        let tier2Bonus = CandidateRanker.getTierBonus(match: tier2Match, inputLength: 2)
        let tier3Bonus = CandidateRanker.getTierBonus(match: tier3Match, inputLength: 2)

        // Even with max base frequency difference
        let tier2Total = tier2Bonus + Double(tier2Entry.pinyinBaseFrequency)
        let tier3Total = tier3Bonus + Double(tier3Entry.wubiBaseFrequency)

        XCTAssertGreaterThan(tier2Total, tier3Total)
    }

    func testRanking_SameTier_BaseFrequencyTieBreaker() {
        // Within same tier, base frequency determines order (when no user data)
        let highFreqEntry = makeEntry(id: 1, text: "一", wubi: "g", baseFrequency: 64000)
        let lowFreqEntry = makeEntry(id: 2, text: "王", wubi: "g", baseFrequency: 62000)

        let highFreqMatch = makeMatch(entry: highFreqEntry, matchedCode: "g", matchType: .full, codeType: .wubi)
        let lowFreqMatch = makeMatch(entry: lowFreqEntry, matchedCode: "g", matchType: .full, codeType: .wubi)

        let highFreqBonus = CandidateRanker.getTierBonus(match: highFreqMatch, inputLength: 1)
        let lowFreqBonus = CandidateRanker.getTierBonus(match: lowFreqMatch, inputLength: 1)

        // Same tier
        XCTAssertEqual(highFreqBonus, lowFreqBonus)

        // Higher base frequency wins
        let highTotal = highFreqBonus + Double(highFreqEntry.wubiBaseFrequency)
        let lowTotal = lowFreqBonus + Double(lowFreqEntry.wubiBaseFrequency)

        XCTAssertGreaterThan(highTotal, lowTotal)
    }

    // MARK: - Part 11: Additional Frecency Integration Tests

    func testFrecency_RecencyDominatesImmediately() {
        // Immediately after selection, recency should dominate base frequency
        let now = UInt32(Date().timeIntervalSince1970)
        let recencyScore = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now)
        let maxBaseScore = FrecencyScore.calculateBaseScore(baseFrequency: 65535)

        // Recency (1B) is much higher than max base (65K)
        XCTAssertGreaterThan(recencyScore, maxBaseScore * 100) // Recency is 10000x+ higher
    }

    func testFrecency_FrequencyAccumulates() {
        let freq1 = FrecencyScore.calculateFrequencyScore(accessCount: 1)
        let freq10 = FrecencyScore.calculateFrequencyScore(accessCount: 10)
        let freq100 = FrecencyScore.calculateFrequencyScore(accessCount: 100)

        XCTAssertEqual(freq1, 10_000)
        XCTAssertEqual(freq10, 100_000)
        XCTAssertEqual(freq100, 1_000_000)
    }

    func testFrecency_BaseScoreRange() {
        let minBase = FrecencyScore.calculateBaseScore(baseFrequency: 0)
        let maxBase = FrecencyScore.calculateBaseScore(baseFrequency: 65535)

        XCTAssertEqual(minBase, 0)
        XCTAssertEqual(maxBase, 65535)
    }

    func testFrecency_CombinedScore_NoUserData() {
        let score = FrecencyScore.calculate(
            accessCount: 0,
            lastAccessTimestamp: 0,
            baseFrequency: 50000
        )
        XCTAssertEqual(score, 50000)
    }

    func testFrecency_CombinedScore_WithFrequencyOnly() {
        let score = FrecencyScore.calculate(
            accessCount: 10,
            lastAccessTimestamp: 0, // No recency
            baseFrequency: 50000
        )
        XCTAssertEqual(score, 50000 + 100_000) // base + 10 * 10000
    }

    // MARK: - Part 12: UserEntryData Tests

    func testUserEntryData_Initialization() {
        let data = UserEntryData(entryId: 12345)

        XCTAssertEqual(data.entryId, 12345)
        XCTAssertEqual(data.accessCount, 0)
        XCTAssertEqual(data.lastAccessTimestamp, 0)
        XCTAssertEqual(data.cachedScore, 0)
    }

    func testUserEntryData_InitializationWithValues() {
        let data = UserEntryData(
            entryId: 100,
            accessCount: 50,
            lastAccessTimestamp: 1000000,
            cachedScore: 500000.0
        )

        XCTAssertEqual(data.entryId, 100)
        XCTAssertEqual(data.accessCount, 50)
        XCTAssertEqual(data.lastAccessTimestamp, 1000000)
        XCTAssertEqual(data.cachedScore, 500000.0)
    }

    func testUserEntryData_RecordAccess() {
        var data = UserEntryData(entryId: 1)

        data.recordAccess()
        XCTAssertEqual(data.accessCount, 1)
        XCTAssertGreaterThan(data.lastAccessTimestamp, 0)

        let firstTimestamp = data.lastAccessTimestamp

        data.recordAccess()
        XCTAssertEqual(data.accessCount, 2)
        XCTAssertGreaterThanOrEqual(data.lastAccessTimestamp, firstTimestamp)
    }

    func testUserEntryData_UpdateCachedScore() {
        var data = UserEntryData(entryId: 1)
        data.accessCount = 10
        data.lastAccessTimestamp = UInt32(Date().timeIntervalSince1970)

        data.updateCachedScore(baseFrequency: 50000)

        // Should have recency + frequency + base
        XCTAssertGreaterThan(data.cachedScore, 10_000_000) // At least recency boost
    }

    // MARK: - Part 13: Candidate Struct Tests

    func testCandidate_InitFromMatch() {
        let entry = makeEntry(id: 42, text: "测试", pinyin: "ceshi", wubi: "ipfy", baseFrequency: 55000)
        let match = makeMatch(entry: entry, matchedCode: "ceshi", matchType: .full, codeType: .pinyin)

        let candidate = Candidate(from: match, score: 12345.67)

        XCTAssertEqual(candidate.entryId, 42)
        XCTAssertEqual(candidate.text, "测试")
        XCTAssertEqual(candidate.code, "ceshi")
        XCTAssertEqual(candidate.codeType, .pinyin)
        XCTAssertTrue(candidate.isFullMatch)
        XCTAssertEqual(candidate.baseFrequency, 55000)
        XCTAssertEqual(candidate.score, 12345.67)
    }

    func testCandidate_IsFullMatch_True() {
        let entry = makeEntry(id: 1, text: "我", pinyin: "wo")
        let match = makeMatch(entry: entry, matchedCode: "wo", matchType: .full, codeType: .pinyin)
        let candidate = Candidate(from: match)

        XCTAssertTrue(candidate.isFullMatch)
    }

    func testCandidate_IsFullMatch_False() {
        let entry = makeEntry(id: 1, text: "我们", pinyin: "women")
        let match = makeMatch(entry: entry, matchedCode: "women", matchType: .prefix, codeType: .pinyin)
        let candidate = Candidate(from: match)

        XCTAssertFalse(candidate.isFullMatch)
    }

    func testCandidate_Id() {
        let entry = makeEntry(id: 999, text: "测")
        let match = makeMatch(entry: entry, matchedCode: "ce", matchType: .full, codeType: .pinyin)
        let candidate = Candidate(from: match)

        XCTAssertEqual(candidate.id, 999)
        XCTAssertEqual(candidate.id, candidate.entryId)
    }

    // MARK: - Part 14: DictionaryEntry Tests

    func testDictionaryEntry_TextLength() {
        let entry1 = makeEntry(id: 1, text: "一", length: nil)
        let entry2 = makeEntry(id: 2, text: "中国", length: nil)
        let entry3 = makeEntry(id: 3, text: "中华人民共和国", length: 7)

        XCTAssertEqual(entry1.textLength, 1)
        XCTAssertEqual(entry2.textLength, 2)
        XCTAssertEqual(entry3.textLength, 7)
    }

    func testDictionaryEntry_IsWubiSource() {
        let wubiEntry = makeEntry(id: 1, text: "一", source: 1)
        let pinyinEntry = makeEntry(id: 2, text: "一", source: 2)
        let userEntry = makeEntry(id: 3, text: "一", source: 3)

        XCTAssertTrue(wubiEntry.isWubiSource)
        XCTAssertFalse(pinyinEntry.isWubiSource)
        XCTAssertFalse(userEntry.isWubiSource)
    }

    func testDictionaryEntry_EntryId() {
        let entry = makeEntry(id: 12345, text: "测试")
        XCTAssertEqual(entry.entryId, 12345)
        XCTAssertEqual(entry.entryId, entry.id)
    }

    // MARK: - Part 15: DictionaryMatch Tests

    func testDictionaryMatch_FullWubi() {
        let entry = makeEntry(id: 1, text: "一", wubi: "g")
        let match = DictionaryMatch(entry: entry, matchedCode: "g", matchType: .full, codeType: .wubi)

        XCTAssertEqual(match.matchType, .full)
        XCTAssertEqual(match.codeType, .wubi)
        XCTAssertEqual(match.matchedCode, "g")
    }

    func testDictionaryMatch_PrefixPinyin() {
        let entry = makeEntry(id: 1, text: "国家", pinyin: "guojia")
        let match = DictionaryMatch(entry: entry, matchedCode: "guojia", matchType: .prefix, codeType: .pinyin)

        XCTAssertEqual(match.matchType, .prefix)
        XCTAssertEqual(match.codeType, .pinyin)
    }

    // MARK: - Part 16: Edge Case Combinations

    func testEdgeCase_EmptyText() {
        let entry = makeEntry(id: 1, text: "", length: 0)
        XCTAssertEqual(entry.textLength, 0)
    }

    func testEdgeCase_MaxBaseFrequency() {
        let entry = makeEntry(id: 1, text: "一", baseFrequency: 65535)
        let match = makeMatch(entry: entry, matchedCode: "g", matchType: .full, codeType: .wubi)
        // Input length 1 with full Wubi match gets jianmaTierBonus
        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 1)

        let total = tierBonus + Double(entry.wubiBaseFrequency)
        XCTAssertEqual(total, CandidateRanker.jianmaTierBonus + 65535, "1-char Wubi gets jianmaTierBonus")
    }

    func testEdgeCase_ZeroBaseFrequency() {
        let entry = makeEntry(id: 1, text: "一", baseFrequency: 0)
        let match = makeMatch(entry: entry, matchedCode: "g", matchType: .full, codeType: .wubi)
        // Input length 1 with full Wubi match gets jianmaTierBonus
        let tierBonus = CandidateRanker.getTierBonus(match: match, inputLength: 1)

        let total = tierBonus + Double(entry.wubiBaseFrequency)
        XCTAssertEqual(total, CandidateRanker.jianmaTierBonus, "1-char Wubi gets jianmaTierBonus")
    }

    // MARK: - Part 17: Boost Edge Cases

    func testBoost_SingleElement() {
        var candidates = [
            Candidate(from: makeMatch(entry: makeEntry(id: 1, text: "A"), matchedCode: "a", matchType: .full, codeType: .wubi), score: 100)
        ]

        CandidateRanker.boost(candidates: &candidates, at: 1)
        XCTAssertEqual(candidates.count, 1)
    }

    func testBoost_LastElement() {
        var candidates = [
            Candidate(from: makeMatch(entry: makeEntry(id: 1, text: "A"), matchedCode: "a", matchType: .full, codeType: .wubi), score: 100),
            Candidate(from: makeMatch(entry: makeEntry(id: 2, text: "B"), matchedCode: "b", matchType: .full, codeType: .wubi), score: 90),
            Candidate(from: makeMatch(entry: makeEntry(id: 3, text: "C"), matchedCode: "c", matchType: .full, codeType: .wubi), score: 80),
            Candidate(from: makeMatch(entry: makeEntry(id: 4, text: "D"), matchedCode: "d", matchType: .full, codeType: .wubi), score: 70),
        ]

        CandidateRanker.boost(candidates: &candidates, at: 3)

        XCTAssertEqual(candidates[0].text, "D")
        XCTAssertEqual(candidates.count, 4)
    }

    func testBoost_EmptyArray() {
        var candidates: [Candidate] = []
        CandidateRanker.boost(candidates: &candidates, at: 0)
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Part 18: FrecencyScore Constants

    func testFrecencyConstants_HalfLife() {
        XCTAssertEqual(FrecencyScore.recencyHalfLife, 86400) // 1 day
    }

    func testFrecencyConstants_InitialBoost() {
        XCTAssertEqual(FrecencyScore.recencyInitialBoost, 1_000_000_000)
    }

    func testFrecencyConstants_FrequencyMultiplier() {
        XCTAssertEqual(FrecencyScore.frequencyMultiplier, 10_000)
    }

    func testFrecencyConstants_Lambda() {
        // lambda = ln(2) / halfLife
        let expectedLambda = log(2.0) / 86400.0
        XCTAssertEqual(FrecencyScore.lambda, expectedLambda, accuracy: 0.0000001)
    }

    // MARK: - Part 19: FrecencyScore Utility Methods

    func testFrecency_RecencyScoreAfterHours_Zero() {
        let score = FrecencyScore.recencyScoreAfterHours(0)
        XCTAssertEqual(score, FrecencyScore.recencyInitialBoost)
    }

    func testFrecency_RecencyScoreAfterHours_TwentyFour() {
        let score = FrecencyScore.recencyScoreAfterHours(24)
        // After 24 hours (1 day = half-life), should be roughly half
        XCTAssertEqual(score, FrecencyScore.recencyInitialBoost / 2, accuracy: 1)
    }

    func testFrecency_RecencyScoreAfterHours_SevenDays() {
        let score = FrecencyScore.recencyScoreAfterHours(168) // 7 days
        // After 7 days (7 half-lives), should be ~1/128 of initial (1B)
        // 1B / 128 ≈ 7,812,500
        XCTAssertLessThan(score, 10_000_000)
        XCTAssertGreaterThan(score, 5_000_000) // ~7,812,500
    }

    func testFrecency_WouldRankFirst_JustNow() {
        let now = UInt32(Date().timeIntervalSince1970)
        XCTAssertTrue(FrecencyScore.wouldRankFirst(lastAccessTimestamp: now))
    }

    func testFrecency_WouldRankFirst_OneDayAgo() {
        // With 1-day half-life, 1 day ago still has ~50M recency which is > 100K threshold
        let oneDayAgo = UInt32(Date().timeIntervalSince1970 - 86400)
        XCTAssertTrue(FrecencyScore.wouldRankFirst(lastAccessTimestamp: oneDayAgo))
    }

    func testFrecency_WouldRankFirst_TwoWeeksAgo() {
        // After 14 days, recency should be below threshold
        let twoWeeksAgo = UInt32(Date().timeIntervalSince1970 - 86400 * 14)
        XCTAssertFalse(FrecencyScore.wouldRankFirst(lastAccessTimestamp: twoWeeksAgo))
    }

    func testFrecency_WouldRankFirst_Never() {
        XCTAssertFalse(FrecencyScore.wouldRankFirst(lastAccessTimestamp: 0))
    }

    // MARK: - Part 20: Time Until Threshold

    func testFrecency_TimeUntilBelowThreshold_Zero() {
        let time = FrecencyScore.timeUntilRecencyBelowThreshold(FrecencyScore.recencyInitialBoost)
        XCTAssertEqual(time, 0)
    }

    func testFrecency_TimeUntilBelowThreshold_HalfValue() {
        let halfValue = FrecencyScore.recencyInitialBoost / 2
        if let time = FrecencyScore.timeUntilRecencyBelowThreshold(halfValue) {
            // Should be approximately 1 day (86400 seconds)
            XCTAssertEqual(time, 86400, accuracy: 1)
        }
    }

    func testFrecency_TimeUntilBelowThreshold_ZeroThreshold() {
        let time = FrecencyScore.timeUntilRecencyBelowThreshold(0)
        XCTAssertNil(time)
    }

    func testFrecency_TimeUntilBelowThreshold_AboveMax() {
        let time = FrecencyScore.timeUntilRecencyBelowThreshold(FrecencyScore.recencyInitialBoost * 2)
        XCTAssertEqual(time, 0)
    }

    // MARK: - Part 21: 彻底 Reranking Test Case
    // This test verifies that a word can be boosted to #1 position after user selection
    // even if it starts with lower base frequency

    func testCheDiReranking_BaseRankingByFrequency() {
        // Test: Words for "chedi" should be ranked by base_frequency initially
        // 彻底 (32823) should rank lower than 车底 (33691)

        let cheDi1 = makeEntry(id: 1, text: "车底", pinyin: "chedi", baseFrequency: 33691)
        let cheDi2 = makeEntry(id: 2, text: "车弟", pinyin: "chedi", baseFrequency: 33492)
        let cheDi3 = makeEntry(id: 3, text: "车低", pinyin: "chedi", baseFrequency: 33392)
        let cheDi4 = makeEntry(id: 4, text: "车笛", pinyin: "chedi", baseFrequency: 33092)
        let cheDi5 = makeEntry(id: 5, text: "澈底", pinyin: "chedi", baseFrequency: 33044)
        let cheDi6 = makeEntry(id: 6, text: "彻底", pinyin: "chedi", baseFrequency: 32823)

        // All are full pinyin matches for "chedi" (length=5, so long code mode)
        let matches = [
            makeMatch(entry: cheDi1, matchedCode: "chedi", matchType: .full, codeType: .pinyin),
            makeMatch(entry: cheDi2, matchedCode: "chedi", matchType: .full, codeType: .pinyin),
            makeMatch(entry: cheDi3, matchedCode: "chedi", matchType: .full, codeType: .pinyin),
            makeMatch(entry: cheDi4, matchedCode: "chedi", matchType: .full, codeType: .pinyin),
            makeMatch(entry: cheDi5, matchedCode: "chedi", matchType: .full, codeType: .pinyin),
            makeMatch(entry: cheDi6, matchedCode: "chedi", matchType: .full, codeType: .pinyin),
        ]

        // All should get Tier 1 bonus (long code mode, full match)
        for match in matches {
            let bonus = CandidateRanker.getTierBonus(match: match, inputLength: 5)
            XCTAssertEqual(bonus, CandidateRanker.tier1Bonus, "Full pinyin match should be Tier 1")
        }

        // Without any engine, calculate expected order by tier bonus + base frequency
        // All same tier, so order by base frequency descending
        let expectedOrder = [cheDi1, cheDi2, cheDi3, cheDi4, cheDi5, cheDi6]
        let sortedByFreq = [cheDi1, cheDi2, cheDi3, cheDi4, cheDi5, cheDi6]
            .sorted { $0.pinyinBaseFrequency > $1.pinyinBaseFrequency }

        for i in 0..<expectedOrder.count {
            XCTAssertEqual(sortedByFreq[i].text, expectedOrder[i].text)
        }

        // Verify 彻底 is last (lowest base frequency)
        XCTAssertEqual(sortedByFreq.last?.text, "彻底")
    }

    func testCheDiReranking_AfterUserSelection() {
        // Test: After user selects 彻底, it should jump to #1 due to recency boost
        // Recency boost (1,000,000,000) >> base frequency difference (< 1,000)

        let cheDi1 = makeEntry(id: 1, text: "车底", pinyin: "chedi", baseFrequency: 33691)
        let cheDi6 = makeEntry(id: 6, text: "彻底", pinyin: "chedi", baseFrequency: 32823)

        // User just selected 彻底
        let now = UInt32(Date().timeIntervalSince1970)
        // UserEntryData would be created by DictionaryEngine.recordSelection()
        // Here we just calculate the expected scores manually

        // Calculate recency score for just-selected word
        let recencyScore = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now)
        XCTAssertGreaterThan(recencyScore, 900_000_000, "Recent selection should have ~1B recency boost")

        // Calculate total scores (all Tier 1)
        let tier1Bonus = CandidateRanker.tier1Bonus

        // 车底: tier1 + 0 (no user data) + base freq
        let score1 = tier1Bonus + Double(cheDi1.pinyinBaseFrequency)

        // 彻底: tier1 + recency + frequency + base freq
        let frequencyScore = FrecencyScore.calculateFrequencyScore(accessCount: 1)
        let score6 = tier1Bonus + recencyScore + frequencyScore + Double(cheDi6.pinyinBaseFrequency)

        // 彻底 should now score higher than 车底
        XCTAssertGreaterThan(score6, score1, "彻底 should rank #1 after user selection")

        // The difference should be dominated by recency
        let scoreDifference = score6 - score1
        XCTAssertGreaterThan(scoreDifference, 900_000_000, "Score difference should be ~1B from recency")
    }

    func testCheDiReranking_7DaysLater() {
        // Test: 7 days after selection, recency fades significantly but frequency remains
        // With 1-day half-life, after 7 days recency is ~1/128 of initial (1B → ~7.8M)

        let now = UInt32(Date().timeIntervalSince1970)
        let sevenDaysAgo = now - 86400 * 7 // 7 days

        // User selected 彻底 once, 7 days ago
        let recencyScore7d = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: sevenDaysAgo)
        XCTAssertLessThan(recencyScore7d, 10_000_000, "Recency should be ~7.8M after 7 days")
        XCTAssertGreaterThan(recencyScore7d, 5_000_000, "Recency should be ~7.8M after 7 days")

        // After 7 days, with 1 selection:
        // 彻底: ~7.8M (recency) + 10,000 (frequency) + 32,823 (base) = ~7.84M
        // 车底: 33,691 (base) = 33,691
        // So 彻底 still wins due to recency + frequency bonus

        let frequencyFor1Selection = FrecencyScore.calculateFrequencyScore(accessCount: 1)
        let score6 = Double(32823) + recencyScore7d + frequencyFor1Selection
        let score1 = Double(33691) + 0 + 0  // No user data

        XCTAssertGreaterThan(score6, score1, "With 1 selection, 彻底 should still beat 车底 after 7 days")
    }

    func testCheDiReranking_NeverSelected() {
        // Test: If 彻底 was never selected, it stays at bottom of same-tier entries

        let cheDi1 = makeEntry(id: 1, text: "车底", pinyin: "chedi", baseFrequency: 33691)
        let cheDi6 = makeEntry(id: 6, text: "彻底", pinyin: "chedi", baseFrequency: 32823)

        // No user data for either
        let frecency1 = FrecencyScore.calculate(accessCount: 0, lastAccessTimestamp: 0, baseFrequency: cheDi1.pinyinBaseFrequency)
        let frecency6 = FrecencyScore.calculate(accessCount: 0, lastAccessTimestamp: 0, baseFrequency: cheDi6.pinyinBaseFrequency)

        // Without frecency, order is purely by base frequency
        XCTAssertGreaterThan(frecency1, frecency6, "车底 should rank higher with no user data")
        XCTAssertEqual(frecency1, Double(cheDi1.pinyinBaseFrequency))
        XCTAssertEqual(frecency6, Double(cheDi6.pinyinBaseFrequency))
    }

    // MARK: - Part 22: kham Wubi Ranking Test Case
    // Bug report: User inputs "kham", "唬" is #1, "中英" is #2
    // After selecting "中英", on second input it's still #2
    // Only after third input (2 selections) does "中英" rise to #1
    // This test investigates the expected behavior vs observed behavior

    func testKhamReranking_InitialRanking() {
        // Test: Initial ranking for "kham" input (4 chars = short code mode)
        // Both "唬" and "中英" are full Wubi matches for "kham"
        // "唬" should rank higher due to:
        //   1. Same tier (Tier 1: Full Wubi)
        //   2. Higher short word bonus (1 char vs 2 chars)

        // Note: Actual base frequencies may vary, using reasonable test values
        let hu = makeEntry(id: 1, text: "唬", wubi: "kham", baseFrequency: 35000, length: 1)
        let zhongYing = makeEntry(id: 2, text: "中英", wubi: "kham", baseFrequency: 35000, length: 2)

        let huMatch = makeMatch(entry: hu, matchedCode: "kham", matchType: .full, codeType: .wubi)
        let zhongYingMatch = makeMatch(entry: zhongYing, matchedCode: "kham", matchType: .full, codeType: .wubi)

        // Both are Tier 1 (Full Wubi, short code mode)
        let huTier = CandidateRanker.getTierBonus(match: huMatch, inputLength: 4)
        let zhongYingTier = CandidateRanker.getTierBonus(match: zhongYingMatch, inputLength: 4)

        XCTAssertEqual(huTier, CandidateRanker.tier1Bonus, "唬 should be Tier 1")
        XCTAssertEqual(zhongYingTier, CandidateRanker.tier1Bonus, "中英 should be Tier 1")

        // Calculate within-tier scores (no user data)
        // 唬: base(35000) + shortWord(40000) = 75000
        // 中英: base(35000) + shortWord(30000) = 65000
        let huFrecency = FrecencyScore.calculate(accessCount: 0, lastAccessTimestamp: 0, baseFrequency: hu.wubiBaseFrequency)
        let zhongYingFrecency = FrecencyScore.calculate(accessCount: 0, lastAccessTimestamp: 0, baseFrequency: zhongYing.wubiBaseFrequency)

        let huShortBonus: Double = 40_000 // 1 char
        let zhongYingShortBonus: Double = 30_000 // 2 chars

        let huTotal = huTier + huFrecency + huShortBonus
        let zhongYingTotal = zhongYingTier + zhongYingFrecency + zhongYingShortBonus

        XCTAssertGreaterThan(huTotal, zhongYingTotal, "唬 should rank higher initially due to short word bonus")
        XCTAssertEqual(huTotal - zhongYingTotal, 10_000, "Difference should be exactly 10,000 (short word bonus diff)")
    }

    func testKhamReranking_AfterOneSelection_ShouldRiseToFirst() {
        // Test: After selecting 中英 once, it should rise to #1
        // Note: "kham" is 4 characters, so both are Tier 1 (not jiǎnmǎ)
        // Recency boost of 1,000,000,000 >> short word bonus difference of 10,000

        let hu = makeEntry(id: 1, text: "唬", wubi: "kham", baseFrequency: 35000, length: 1)
        let zhongYing = makeEntry(id: 2, text: "中英", wubi: "kham", baseFrequency: 35000, length: 2)

        let now = UInt32(Date().timeIntervalSince1970)

        // 唬: no user data
        let huFrecency = FrecencyScore.calculate(accessCount: 0, lastAccessTimestamp: 0, baseFrequency: hu.wubiBaseFrequency)

        // 中英: just selected (1 access, just now)
        let zhongYingFrecency = FrecencyScore.calculate(accessCount: 1, lastAccessTimestamp: now, baseFrequency: zhongYing.wubiBaseFrequency)

        let huShortBonus: Double = 40_000
        let zhongYingShortBonus: Double = 30_000

        let tierBonus = CandidateRanker.tier1Bonus
        let huTotal = tierBonus + huFrecency + huShortBonus
        let zhongYingTotal = tierBonus + zhongYingFrecency + zhongYingShortBonus

        // 中英 should be MUCH higher due to recency boost
        XCTAssertGreaterThan(zhongYingTotal, huTotal, "中英 should rank #1 after 1 selection")

        let scoreDifference = zhongYingTotal - huTotal
        XCTAssertGreaterThan(scoreDifference, 990_000_000, "中英 should have ~1B score advantage")

        // Print detailed breakdown for debugging
        let recencyScore = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now)
        let frequencyScore = FrecencyScore.calculateFrequencyScore(accessCount: 1)
        print("""

        === kham Ranking Debug (After 1 Selection) ===
        唬 Score Breakdown:
          Tier Bonus: \(tierBonus)
          Recency: 0
          Frequency: 0
          Base: \(hu.wubiBaseFrequency)
          Short Word: \(huShortBonus)
          Total: \(huTotal)

        中英 Score Breakdown:
          Tier Bonus: \(tierBonus)
          Recency: \(recencyScore)
          Frequency: \(frequencyScore)
          Base: \(zhongYing.wubiBaseFrequency)
          Short Word: \(zhongYingShortBonus)
          Total: \(zhongYingTotal)

        Score Difference: \(scoreDifference)
        Expected: 中英 should be #1 (score diff > 990M)
        """)
    }

    func testKhamReranking_PossibleBugAnalysis() {
        // This test investigates possible causes for the observed bug
        // Bug: 中英 needs 2 selections to rise to #1 instead of just 1

        // Hypothesis 1: Different tiers (unlikely if both are full Wubi matches)
        // Hypothesis 2: Data persistence issue (not reflected in ranking algorithm)
        // Hypothesis 3: Different entry IDs between dictionary lookup and user data

        // Let's verify the algorithm is correct
        let now = UInt32(Date().timeIntervalSince1970)

        // Calculate how much frecency advantage is needed to overcome short word bonus difference
        let shortWordBonusDiff: Double = 10_000 // (40000 - 30000)

        // After 1 selection: recency ~10M + frequency 10K = ~10.01M advantage
        let advantage1Selection = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now) +
                                  FrecencyScore.calculateFrequencyScore(accessCount: 1)

        // After 2 selections: recency ~10M + frequency 20K = ~10.02M advantage
        let advantage2Selections = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now) +
                                   FrecencyScore.calculateFrequencyScore(accessCount: 2)

        XCTAssertGreaterThan(advantage1Selection, shortWordBonusDiff * 100,
            "1 selection advantage (\(advantage1Selection)) should be >> short word diff (\(shortWordBonusDiff))")

        XCTAssertGreaterThan(advantage2Selections, advantage1Selection,
            "2 selections should give more advantage than 1")

        // The math shows 1 selection SHOULD be enough
        // If bug exists, it's likely in:
        // 1. DictionaryEngine.recordSelection() not saving correctly
        // 2. DictionaryEngine.getUserLearning() not loading correctly
        // 3. Entry ID mismatch between search results and user data

        print("""

        === Bug Analysis: Why 中英 might not rise after 1 selection ===

        Expected advantage after 1 selection: \(advantage1Selection)
        Short word bonus difference to overcome: \(shortWordBonusDiff)
        Ratio: \(advantage1Selection / shortWordBonusDiff)x

        CONCLUSION: The ranking algorithm is mathematically correct.
        If the bug exists, check:
        1. DictionaryEngine.recordSelection() - is it saving the selection?
        2. DictionaryEngine.getUserLearning() - is it loading the user data?
        3. Are the entry IDs consistent between search and user data?

        To debug in the app, add logging to:
        - recordSelection() to verify it's called
        - getUserLearning() to verify data is returned
        - CandidateRanker.rank() to print score breakdowns
        """)
    }

    func testKhamReranking_FrequencyMultiplierEffect() {
        // Test what frequency multiplier would be needed for 2 selections to matter
        // but 1 selection to not matter

        // Current: frequencyMultiplier = 10,000
        // shortWordBonusDiff = 10,000

        // For the bug to be explained by frequency multiplier:
        // 1 selection: recency(~10M) + freq(10K) vs shortWord(10K) → wins
        // But if recency somehow doesn't apply...
        // 1 selection: freq(10K) vs shortWord(10K) → TIE
        // 2 selections: freq(20K) vs shortWord(10K) → wins by 10K

        // This could explain the bug if recency is NOT being applied correctly!

        let freq1 = FrecencyScore.calculateFrequencyScore(accessCount: 1)
        let freq2 = FrecencyScore.calculateFrequencyScore(accessCount: 2)
        let shortWordDiff: Double = 10_000

        XCTAssertEqual(freq1, 10_000, "1 selection = 10K frequency")
        XCTAssertEqual(freq2, 20_000, "2 selections = 20K frequency")

        // If recency is NOT applied (bug), then:
        // 1 selection: freq(10K) - shortWord(10K) = 0 (TIE, 唬 wins by base order)
        // 2 selections: freq(20K) - shortWord(10K) = 10K (中英 wins)

        print("""

        === Hypothesis: Recency NOT being applied ===

        If recency score is somehow NOT being added to 中英's score:
        - 1 selection: freq(10K) vs shortWord(10K) = TIE → 唬 wins by order
        - 2 selections: freq(20K) vs shortWord(10K) = 中英 wins by 10K

        This matches the observed bug behavior!

        Check if lastAccessTimestamp is being saved correctly.
        If timestamp is 0, recency score will be 0.
        """)

        // Verify that with timestamp=0, recency is indeed 0
        let recencyWithZeroTimestamp = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: 0)
        XCTAssertEqual(recencyWithZeroTimestamp, 0, "Zero timestamp should give zero recency")
    }

    // MARK: - Part 23: Wubi Jiǎnmǎ (简码) Always First Tests
    //
    // These tests verify that Wubi 1-2级简码 (Protected Tier: jianmaTierBonus = 1T)
    // ALWAYS ranks first, regardless of tierOverrideBoost on lower-tier entries.

    func testWubiJianma_TierBonusForJianma() {
        // Verify 1-2 character Wubi codes get jianmaTierBonus (1T)
        let jianma1 = makeEntry(id: 1, text: "一", wubi: "g", baseFrequency: 30000, length: 1)
        let jianma2 = makeEntry(id: 2, text: "中", wubi: "kh", baseFrequency: 30000, length: 1)

        let match1 = makeMatch(entry: jianma1, matchedCode: "g", matchType: .full, codeType: .wubi)
        let match2 = makeMatch(entry: jianma2, matchedCode: "kh", matchType: .full, codeType: .wubi)

        // Input length 1 and 2 should get jianmaTierBonus
        XCTAssertEqual(CandidateRanker.getTierBonus(match: match1, inputLength: 1), CandidateRanker.jianmaTierBonus)
        XCTAssertEqual(CandidateRanker.getTierBonus(match: match2, inputLength: 2), CandidateRanker.jianmaTierBonus)
    }

    func testWubiJianma_RegularWubiGetsTier1() {
        // 3-4 character Wubi codes should get tier1Bonus (not jianmaTierBonus)
        let wubi3 = makeEntry(id: 1, text: "国", wubi: "lgv", baseFrequency: 30000, length: 1)
        let wubi4 = makeEntry(id: 2, text: "我", wubi: "qkwy", baseFrequency: 30000, length: 1)

        let match3 = makeMatch(entry: wubi3, matchedCode: "lgv", matchType: .full, codeType: .wubi)
        let match4 = makeMatch(entry: wubi4, matchedCode: "qkwy", matchType: .full, codeType: .wubi)

        // Input length 3 and 4 should get tier1Bonus
        XCTAssertEqual(CandidateRanker.getTierBonus(match: match3, inputLength: 3), CandidateRanker.tier1Bonus)
        XCTAssertEqual(CandidateRanker.getTierBonus(match: match4, inputLength: 4), CandidateRanker.tier1Bonus)
    }

    func testWubiJianma_AlwaysBeforeFullPinyin_EvenWithMaxTierOverride() {
        // Scenario: User has selected a Pinyin word, triggering tierOverrideBoost
        // But Wubi jiǎnmǎ should STILL rank first due to protected tier (1T)

        // Wubi 一级简码 "一" (code: g) - gets jianmaTierBonus (1T)
        let wubiEntry = makeEntry(id: 1, text: "一", wubi: "g", baseFrequency: 30000, length: 1)
        // Pinyin word - gets tier2Bonus (10B) + tierOverrideBoost (500B)
        let pinyinEntry = makeEntry(id: 2, text: "衣", pinyin: "yi", baseFrequency: 60000, length: 1)

        let wubiMatch = makeMatch(entry: wubiEntry, matchedCode: "g", matchType: .full, codeType: .wubi)
        let pinyinMatch = makeMatch(entry: pinyinEntry, matchedCode: "y", matchType: .full, codeType: .pinyin)

        let now = UInt32(Date().timeIntervalSince1970)

        // Wubi jiǎnmǎ: jianmaTierBonus + base + shortWord (no user data)
        let wubiTier = CandidateRanker.getTierBonus(match: wubiMatch, inputLength: 1)
        let wubiScore = wubiTier + Double(wubiEntry.wubiBaseFrequency) + 40_000

        // Pinyin: tier2Bonus + tierOverrideBoost + recency + freq + base + shortWord
        let pinyinTier = CandidateRanker.getTierBonus(match: pinyinMatch, inputLength: 1)
        let pinyinTierOverride = FrecencyScore.calculateTierOverrideBoost(lastAccessTimestamp: now)
        let pinyinRecency = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now)
        let pinyinFrequency = FrecencyScore.calculateFrequencyScore(accessCount: 1000)
        let pinyinScore = pinyinTier + pinyinTierOverride + pinyinRecency + pinyinFrequency + Double(pinyinEntry.pinyinBaseFrequency) + 40_000

        // Verify tier bonuses
        XCTAssertEqual(wubiTier, CandidateRanker.jianmaTierBonus, "一级简码 should get jianmaTierBonus (1T)")
        XCTAssertEqual(pinyinTier, CandidateRanker.tier2Bonus, "Full Pinyin should get tier2Bonus")

        // CRITICAL: Jiǎnmǎ should ALWAYS win
        XCTAssertGreaterThan(wubiScore, pinyinScore,
            "Wubi jiǎnmǎ (1T) must ALWAYS rank above Full Pinyin with tierOverrideBoost (~510B)")

        // Calculate the margin
        let margin = wubiScore - pinyinScore
        XCTAssertGreaterThan(margin, 300_000_000_000,
            "Jiǎnmǎ should have ~400B margin over tier2 + tierOverride")
    }

    func testWubiJianma_AlwaysBeforeTier1Wubi_EvenWithMaxTierOverride() {
        // Scenario: 3-4 char Wubi word has tierOverrideBoost, but 1-2 char jiǎnmǎ still wins

        // Wubi 二级简码 "中" (code: kh) - gets jianmaTierBonus (1T)
        let jianmaEntry = makeEntry(id: 1, text: "中", wubi: "kh", baseFrequency: 30000, length: 1)
        // Regular Wubi "我" (code: qkwy) - gets tier1Bonus (100B) + tierOverrideBoost (500B)
        let regularWubiEntry = makeEntry(id: 2, text: "我", wubi: "qkwy", baseFrequency: 65000, length: 1)

        let jianmaMatch = makeMatch(entry: jianmaEntry, matchedCode: "kh", matchType: .full, codeType: .wubi)
        let regularMatch = makeMatch(entry: regularWubiEntry, matchedCode: "qkwy", matchType: .full, codeType: .wubi)

        let now = UInt32(Date().timeIntervalSince1970)

        // Jiǎnmǎ: jianmaTierBonus + base + shortWord
        let jianmaTier = CandidateRanker.getTierBonus(match: jianmaMatch, inputLength: 2)
        let jianmaScore = jianmaTier + Double(jianmaEntry.wubiBaseFrequency) + 40_000

        // Regular Wubi (input "qkwy" is 4 chars): tier1Bonus + tierOverride + recency + freq + base + shortWord
        let regularTier = CandidateRanker.getTierBonus(match: regularMatch, inputLength: 4)
        let regularTierOverride = FrecencyScore.calculateTierOverrideBoost(lastAccessTimestamp: now)
        let regularRecency = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now)
        let regularFrequency = FrecencyScore.calculateFrequencyScore(accessCount: 1000)
        let regularScore = regularTier + regularTierOverride + regularRecency + regularFrequency + Double(regularWubiEntry.wubiBaseFrequency) + 40_000

        // Verify tier bonuses
        XCTAssertEqual(jianmaTier, CandidateRanker.jianmaTierBonus, "二级简码 should get jianmaTierBonus (1T)")
        XCTAssertEqual(regularTier, CandidateRanker.tier1Bonus, "4-char Wubi should get tier1Bonus (100B)")

        // CRITICAL: Jiǎnmǎ should ALWAYS win
        XCTAssertGreaterThan(jianmaScore, regularScore,
            "Wubi 二级简码 (1T) must ALWAYS rank above regular Wubi with tierOverrideBoost (~600B)")
    }

    func testWubiJianma_TierOverrideCanCrossRegularTiers() {
        // Verify that tierOverrideBoost CAN cross regular tiers (Tier 2 over Tier 1)
        // This is the expected behavior for non-jiǎnmǎ words

        let now = UInt32(Date().timeIntervalSince1970)

        // Tier 1 word (3-4 char Wubi) with no user data
        let tier1Score = CandidateRanker.tier1Bonus + 0 + 0 + 65535 + 40_000

        // Tier 2 word (Full Pinyin) with max user data
        let tierOverride = FrecencyScore.calculateTierOverrideBoost(lastAccessTimestamp: now)
        let recency = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now)
        let frequency = FrecencyScore.calculateFrequencyScore(accessCount: 1000)
        let tier2Score = CandidateRanker.tier2Bonus + tierOverride + recency + frequency + 65535 + 40_000

        // Tier 2 with tierOverrideBoost CAN beat Tier 1 without user data
        XCTAssertGreaterThan(tier2Score, tier1Score,
            "tierOverrideBoost (500B) allows Tier 2 to beat Tier 1 (100B)")
    }

    func testWubiJianma_RealWorldScenario() {
        // Real-world scenario: User types "g" (Wubi code, 1 char = 一级简码)
        // Expected: "一" should ALWAYS be first, even with heavy tierOverrideBoost on other words

        // Wubi 一级简码
        let yi = makeEntry(id: 1, text: "一", wubi: "g", baseFrequency: 64000, length: 1)
        // Another word that user has selected many times
        let ge = makeEntry(id: 2, text: "个", pinyin: "ge", baseFrequency: 65535, length: 1)

        let yiMatch = makeMatch(entry: yi, matchedCode: "g", matchType: .full, codeType: .wubi)
        let geMatch = makeMatch(entry: ge, matchedCode: "ge", matchType: .prefix, codeType: .pinyin)

        // Input is "g" (length 1 = jiǎnmǎ mode)
        let inputLength = 1

        // Verify tiers
        let yiTier = CandidateRanker.getTierBonus(match: yiMatch, inputLength: inputLength)
        let geTier = CandidateRanker.getTierBonus(match: geMatch, inputLength: inputLength)

        XCTAssertEqual(yiTier, CandidateRanker.jianmaTierBonus, "一 should be jianmaTierBonus (1T)")
        XCTAssertEqual(geTier, 0, "个 should be Tier 4 (Prefix Pinyin)")

        // Even with extreme user data and tierOverrideBoost for "个"
        let now = UInt32(Date().timeIntervalSince1970)
        let geTierOverride = FrecencyScore.calculateTierOverrideBoost(lastAccessTimestamp: now)
        let geRecency = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: now)
        let geFrequency = FrecencyScore.calculateFrequencyScore(accessCount: 10000) // 100M

        let yiScore = yiTier + Double(yi.wubiBaseFrequency) + 40_000
        let geScore = geTier + geTierOverride + geRecency + geFrequency + Double(ge.pinyinBaseFrequency) + 40_000

        // 一 MUST win
        XCTAssertGreaterThan(yiScore, geScore,
            "Wubi 一级简码 '一' (1T) must ALWAYS beat any Tier 4 word regardless of user history")
    }
}
