import Foundation

/// Ranks candidates using tier-based Frecency algorithm
///
/// ## Tier Structure
///
/// ### Protected Tier (CANNOT be overridden by tierOverrideBoost):
/// - Tier 0: Wubi 1-2级简码 (+1T) - Full Wubi match with code length 1-2
///   These ALWAYS rank first, regardless of user selection history.
///
/// ### Regular Tiers (CAN be overridden by tierOverrideBoost):
/// When input length <= 4 (Wubi-priority mode):
/// - Tier 1: Full Wubi match / Full English match (+100B) - 3-4 character codes or exact English word
/// - Tier 2: Full Pinyin match (+10B)
/// - Tier 3: Prefix Wubi match (+1B)
/// - Tier 4: Prefix Pinyin match (0)
///
/// When input length > 4 (Pinyin-priority mode):
/// - Tier 1: Full match (+100B)
/// - Tier 2: Prefix match (0)
///
/// ## Within-Tier Ranking (Frecency)
///
/// 1. **Tier Override Boost**: Short-term boost that can cross regular tiers
///    - Initial: 500B, Half-life: 1 hour
///    - Allows user preferences to override tier priority (except jiǎnmǎ)
///
/// 2. **Recency Score**: Exponentially decaying boost
///    - Immediately after selection: ~1,000,000,000 (guarantees #1 in tier)
///    - Half-life: 1 day
///
/// 3. **Frequency Score**: Permanent accumulating score
///    - 10,000 points per selection
///
/// 4. **Base Score**: Dictionary frequency (0-65535)
///
/// 5. **Short Word Bonus**: Prefer shorter words
///
/// Total = TierBonus + TierOverrideBoost + Recency + Frequency + Base + ShortWordBonus
struct CandidateRanker {

    // MARK: - Tier Bonus Constants

    /// Protected Tier P0: 一级简码 (1-char jianma from jianma.txt)
    /// This is set to 10T which is higher than:
    /// - jianmaLevel2Bonus (1T) + tierOverrideBoost (500B) = ~1.5T
    /// So 一级简码 will ALWAYS rank above 二级简码 regardless of user history.
    static let jianmaLevel1Bonus: Double = 10_000_000_000_000

    /// Protected Tier P1: 二级简码 (2-char jianma from jianma.txt)
    /// This is set to 1T which is higher than:
    /// - tier1Bonus (100B) + tierOverrideBoost (500B) = 600B
    /// So 二级简码 will ALWAYS rank above regular tiers regardless of user history.
    static let jianmaLevel2Bonus: Double = 1_000_000_000_000

    /// Legacy constant for backward compatibility
    static let jianmaTierBonus: Double = jianmaLevel2Bonus

    /// Tier 1: Full Wubi (short) or Full (long) - highest regular priority
    static let tier1Bonus: Double = 100_000_000_000

    /// Tier 2: Full Pinyin (short only)
    static let tier2Bonus: Double = 10_000_000_000

    /// Tier 3: Prefix Wubi (short only)
    static let tier3Bonus: Double = 1_000_000_000

    // Tier 4 is 0 (baseline)

    /// Short word bonus per character under 5
    static let shortWordBonusPerChar: Double = 10_000

    // MARK: - Main Ranking

    /// Rank matches and return sorted candidates
    ///
    /// - Parameters:
    ///   - matches: Dictionary matches to rank
    ///   - inputCode: The input code used for matching
    ///   - engine: Dictionary engine for user learning data
    ///   - suppressedWords: Set of words that should ignore user behavior scores (optional)
    /// - Returns: Ranked and sorted candidates
    static func rank(
        matches: [DictionaryMatch],
        inputCode: String,
        engine: DictionaryEngine,
        suppressedWords: Set<String>? = nil
    ) -> [Candidate] {
        // Get suppressed words from engine if not provided
        let suppressedSet = suppressedWords ?? engine.getSuppressedWords()
        // STEP 1: Deduplicate by text, preferring entries with user data
        // This fixes the bug where duplicate entries for the same word have different IDs
        var textToMatch: [String: (match: DictionaryMatch, userData: UserEntryData?)] = [:]

        for match in matches {
            let text = match.entry.text
            let userData = engine.getUserLearning(entryId: match.entry.id)

            if let existing = textToMatch[text] {
                // Prefer entry with userData, or higher tier, or existing entry
                let existingHasUserData = existing.userData != nil
                let newHasUserData = userData != nil

                if newHasUserData && !existingHasUserData {
                    // New entry has userData, existing doesn't - prefer new
                    textToMatch[text] = (match, userData)
                } else if !newHasUserData && existingHasUserData {
                    // Existing has userData - keep existing
                } else {
                    // Both have or both lack userData - prefer higher tier match
                    let existingTier = getTierBonus(match: existing.match, inputCode: inputCode, engine: engine)
                    let newTier = getTierBonus(match: match, inputCode: inputCode, engine: engine)
                    if newTier > existingTier {
                        textToMatch[text] = (match, userData)
                    }
                    // Otherwise keep existing
                }
            } else {
                textToMatch[text] = (match, userData)
            }
        }

        // STEP 2: Calculate scores for deduplicated matches
        // Also track tierOverrideBoost for boost detection
        var candidates: [Candidate] = []
        var tierOverrideBoosts: [UInt32: Double] = [:]  // entryId -> tierOverrideBoost

        for (_, (match, userData)) in textToMatch {
            // Calculate score components
            let tierBonus = getTierBonus(match: match, inputCode: inputCode, engine: engine)
            let isSuppressed = suppressedSet.contains(match.entry.text)
            let timestamp = userData?.lastAccessTimestamp ?? 0
            // Suppressed words have no tierOverrideBoost
            let tierOverrideBoost = isSuppressed ? 0.0 : FrecencyScore.calculateTierOverrideBoost(lastAccessTimestamp: timestamp)

            // Calculate full score using tier-based Frecency
            let score = calculateScore(
                match: match,
                userData: userData,
                inputCode: inputCode,
                engine: engine,
                isSuppressed: isSuppressed
            )

            // Determine if this is a jianma (protected wubi shortcode)
            // Protected tier includes both level 1 (10T) and level 2 (1T)
            let isJianma = tierBonus >= jianmaLevel2Bonus

            let candidate = Candidate(from: match, score: score, isJianma: isJianma)
            candidates.append(candidate)
            tierOverrideBoosts[match.entry.id] = tierOverrideBoost
        }

        // Sort by score descending
        candidates.sort { $0.score > $1.score }

        // STEP 3: Detect if #1 is boosted
        // A candidate is "boosted" if:
        // 1. It has active tierOverrideBoost (> 0)
        // 2. It would NOT be #1 without the tierOverrideBoost and recency score
        // Note: Suppressed words never have boost, so they can't be "boosted"
        if candidates.count >= 2 {
            let first = candidates[0]
            let second = candidates[1]
            let firstBoost = tierOverrideBoosts[first.entryId] ?? 0

            // Only check for boost if this word is not suppressed
            if firstBoost > 0 && !suppressedSet.contains(first.text) {
                // Get the userData for first candidate to calculate actual recency
                if let (_, userData) = textToMatch[first.text] {
                    let actualRecency = FrecencyScore.calculateRecencyScore(
                        lastAccessTimestamp: userData?.lastAccessTimestamp ?? 0
                    )
                    let scoreWithoutBoostAndRecency = first.score - firstBoost - actualRecency

                    // If without boost components, #1 would have lower score than #2
                    if scoreWithoutBoostAndRecency < second.score {
                        candidates[0].isBoosted = true
                    }
                }
            }
        }

        return candidates
    }

    // MARK: - Tier Calculation

    /// Determine tier bonus based on match type, code type, and jianma table
    ///
    /// - Parameters:
    ///   - match: The dictionary match
    ///   - inputCode: The actual input code string
    ///   - engine: Dictionary engine for jianma validation
    /// - Returns: Tier bonus value
    static func getTierBonus(
        match: DictionaryMatch,
        inputCode: String,
        engine: DictionaryEngine
    ) -> Double {
        let isFullMatch = match.matchType == .full
        let isWubiCode = match.codeType == .wubi
        let isEnglishCode = match.codeType == .english
        let inputLength = inputCode.count

        // Check for Protected Tier (jianma) using jianma table
        // Only full wubi matches with 1-2 char codes can be jianma
        if isFullMatch && isWubiCode && inputLength <= 2 {
            let text = match.entry.text
            if engine.isOfficialJianma(code: inputCode, text: text) {
                // This is an official jianma from jianma.txt
                if inputLength == 1 {
                    return jianmaLevel1Bonus  // P0: 一级简码
                } else {
                    return jianmaLevel2Bonus  // P1: 二级简码
                }
            }
        }

        // English full match -> Tier 1 (same as Wubi full match)
        if isFullMatch && isEnglishCode {
            return tier1Bonus
        }

        if inputLength <= 4 {
            // Short code mode: Wubi priority
            switch (isFullMatch, isWubiCode) {
            case (true, true):   return tier1Bonus  // Full Wubi (3-4 chars)
            case (true, false):  return tier2Bonus  // Full Pinyin
            case (false, true):  return tier3Bonus  // Prefix Wubi
            case (false, false): return 0           // Prefix Pinyin
            }
        } else {
            // Long code mode: Full match priority only
            return isFullMatch ? tier1Bonus : 0
        }
    }

    // MARK: - Score Calculation

    /// Calculate score for a single match
    ///
    /// For suppressed words, only word-intrinsic scores are used:
    /// - TierBonus: tier level from match type (kept)
    /// - BaseScore: dictionary base frequency (kept)
    /// - ShortWordBonus: shorter word preference (kept)
    ///
    /// User behavior scores are ignored for suppressed words:
    /// - TierOverrideBoost: recent selection boost
    /// - RecencyScore: time since last use
    /// - FrequencyScore: total usage count
    private static func calculateScore(
        match: DictionaryMatch,
        userData: UserEntryData?,
        inputCode: String,
        engine: DictionaryEngine,
        isSuppressed: Bool = false
    ) -> Double {
        let inputLength = inputCode.count
        let isFullMatch = match.matchType == .full
        let isWubiCode = match.codeType == .wubi

        // 1. Tier bonus (absolute, determines tier) - KEPT for suppressed words
        let tierBonus = getTierBonus(match: match, inputCode: inputCode, engine: engine)

        // 2. Base score from dictionary frequency - KEPT for suppressed words
        let baseFrequency = match.entry.baseFrequency(for: match.codeType)
        let baseScore = FrecencyScore.calculateBaseScore(baseFrequency: baseFrequency)

        // 3. Short word bonus (prefer shorter words within tier) - KEPT for suppressed words
        var shortWordBonus: Double = 0
        let textLength = match.entry.textLength
        if isFullMatch && isWubiCode && inputLength == 4 && textLength == 2 {
            // Wubi 4-char full match: 2-char words get higher bonus than 1-char words
            shortWordBonus = 50_000
        } else if textLength < 5 {
            // Default: shorter words get higher bonus
            shortWordBonus = Double(5 - textLength) * shortWordBonusPerChar
        }

        // 4. User behavior scores - IGNORED for suppressed words
        var tierOverrideBoost: Double = 0
        var recencyScore: Double = 0
        var frequencyScore: Double = 0

        if !isSuppressed {
            let accessCount = userData?.accessCount ?? 0
            let timestamp = userData?.lastAccessTimestamp ?? 0
            tierOverrideBoost = FrecencyScore.calculateTierOverrideBoost(lastAccessTimestamp: timestamp)
            recencyScore = FrecencyScore.calculateRecencyScore(lastAccessTimestamp: timestamp)
            frequencyScore = FrecencyScore.calculateFrequencyScore(accessCount: accessCount)
        }

        let totalScore = tierBonus + tierOverrideBoost + recencyScore + frequencyScore + baseScore + shortWordBonus

        return totalScore
    }

    // MARK: - Re-ranking

    /// Re-rank candidates after user interaction (e.g., manual boost)
    /// - Parameters:
    ///   - candidates: Current candidate list
    ///   - boostIndex: Index of candidate to boost
    static func boost(candidates: inout [Candidate], at boostIndex: Int) {
        guard boostIndex > 0 && boostIndex < candidates.count else { return }

        // Move the boosted candidate to the top
        let boosted = candidates.remove(at: boostIndex)
        candidates.insert(boosted, at: 0)
    }
}

// MARK: - Debug Helpers

#if DEBUG
extension CandidateRanker {
    /// Print score breakdown for debugging
    static func printScoreBreakdown(
        match: DictionaryMatch,
        userData: UserEntryData?,
        inputCode: String,
        engine: DictionaryEngine
    ) {
        let inputLength = inputCode.count
        let tierBonus = getTierBonus(match: match, inputCode: inputCode, engine: engine)
        let recency = FrecencyScore.calculateRecencyScore(
            lastAccessTimestamp: userData?.lastAccessTimestamp ?? 0
        )
        let frequency = FrecencyScore.calculateFrequencyScore(
            accessCount: userData?.accessCount ?? 0
        )
        let base = FrecencyScore.calculateBaseScore(
            baseFrequency: match.entry.baseFrequency(for: match.codeType)
        )

        let isFullMatch = match.matchType == .full
        let isWubiCode = match.codeType == .wubi
        var shortWordBonus: Double = 0
        let textLength = match.entry.textLength
        if isFullMatch && isWubiCode && inputLength == 4 && textLength == 2 {
            shortWordBonus = 50_000
        } else if textLength < 5 {
            shortWordBonus = Double(5 - textLength) * shortWordBonusPerChar
        }

        let total = tierBonus + recency + frequency + base + shortWordBonus

        let tierName: String
        if tierBonus >= jianmaLevel1Bonus {
            tierName = "P0 (一级简码)"
        } else if tierBonus >= jianmaLevel2Bonus {
            tierName = "P1 (二级简码)"
        } else if inputLength <= 4 {
            switch (isFullMatch, isWubiCode) {
            case (true, true): tierName = "Tier 1 (Full Wubi)"
            case (true, false): tierName = "Tier 2 (Full Pinyin)"
            case (false, true): tierName = "Tier 3 (Prefix Wubi)"
            case (false, false): tierName = "Tier 4 (Prefix Pinyin)"
            }
        } else {
            tierName = isFullMatch ? "Tier 1 (Full)" : "Tier 2 (Prefix)"
        }

        NSLog("Score breakdown for '\(match.entry.text)' [\(tierName)]:")
        NSLog("  Tier:      %.0f", tierBonus)
        NSLog("  Recency:   %.0f", recency)
        NSLog("  Frequency: %.0f (count: \(userData?.accessCount ?? 0))", frequency)
        NSLog("  Base:      %.0f", base)
        NSLog("  ShortWord: %.0f", shortWordBonus)
        NSLog("  Total:     %.0f", total)
    }
}
#endif
