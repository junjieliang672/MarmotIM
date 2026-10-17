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
/// - English prefix match (+1B) - completions
/// - Tier 2: Prefix match (0)
///
/// English scores only order English candidates among themselves. Whenever
/// the list also holds wubi or pinyin candidates, `placeEnglishAtPageEnds`
/// moves the English ones to the last slot of each page after ranking,
/// except an exact match on an English-first word (英文置顶词), which it
/// moves to the first slot.
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
///    - 5,000,000 points per selection
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

    /// Full Wubi on a secondary code (DictionaryEngine.isSecondaryWubiCode):
    /// below every other full Wubi match, above full Pinyin
    static let secondaryWubiBonus: Double = 50_000_000_000

    /// Tier 2: Full Pinyin (short only)
    static let tier2Bonus: Double = 10_000_000_000

    /// Tier 3: Prefix Wubi (short only)
    static let tier3Bonus: Double = 1_000_000_000

    // Tier 4 is 0 (baseline)

    /// English prefix match (completion): above pinyin prefix matches (0),
    /// below every full match
    static let englishPrefixBonus: Double = tier3Bonus

    /// Short word bonus per character under 5
    static let shortWordBonusPerChar: Double = 10_000

    // MARK: - Main Ranking

    /// Rank matches and return sorted candidates
    ///
    /// - Parameters:
    ///   - matches: Dictionary matches to rank
    ///   - inputCode: The input code used for matching
    ///   - engine: Dictionary engine for user learning data
    /// - Returns: Ranked and sorted candidates
    static func rank(
        matches: [DictionaryMatch],
        inputCode: String,
        engine: DictionaryEngine
    ) -> [Candidate] {
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
            // Learning data is keyed by entry, not by code: picks of 次 at
            // `uqw` must not lift it over the phrases at `uqwy`
            let ignoresLearning = isSecondaryWubi(match: match, inputCode: inputCode, engine: engine)
            let timestamp = userData?.lastAccessTimestamp ?? 0
            let tierOverrideBoost = effectiveTierOverrideBoost(
                match: match,
                inputCode: inputCode,
                lastAccessTimestamp: timestamp,
                ignoresLearning: ignoresLearning
            )

            // Calculate full score using tier-based Frecency
            let score = calculateScore(
                match: match,
                userData: userData,
                inputCode: inputCode,
                engine: engine,
                ignoresLearning: ignoresLearning
            )

            // Determine if this is a jianma (protected wubi shortcode)
            // Protected tier includes both level 1 (10T) and level 2 (1T)
            let isJianma = tierBonus >= jianmaLevel2Bonus

            let candidate = Candidate(from: match, score: score, isJianma: isJianma)
            candidates.append(candidate)
            tierOverrideBoosts[match.entry.id] = tierOverrideBoost
        }

        // Sort by score descending; equal scores fall back to the text so the
        // order does not depend on dictionary iteration order
        candidates.sort { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }

        // STEP 3: Detect if #1 is boosted
        // A candidate is "boosted" if:
        // 1. It has active tierOverrideBoost (> 0)
        // 2. It would NOT be #1 without the tierOverrideBoost and recency score
        if candidates.count >= 2 {
            let first = candidates[0]
            let second = candidates[1]
            let firstBoost = tierOverrideBoosts[first.entryId] ?? 0

            if firstBoost > 0 {
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

    // MARK: - Relative Ordering Post-Processing (spec-003)

    /// Stable post-processing pass that enforces user-defined relative
    /// ordering rules of the form "wordA must come before wordB when both
    /// appear in the candidate list". Called explicitly by the caller AFTER
    /// `rank()` — this is a sibling function, NOT a new pass inside rank.
    /// See decision 001-comparator-location in spec-003.
    ///
    /// Invariants:
    /// - Protected tiers (P0/P1 jianma, isJianma==true) are NEVER reordered
    ///   by this pass. See decision 003-respect-protected-tiers and
    ///   docs/ranking.md.
    /// - No-op when `rules` is empty (early return, zero comparisons).
    /// - No-op when neither wordA nor wordB of any rule is present — the
    ///   function may still iterate once to verify this but it performs
    ///   no swaps.
    /// - Stability: non-rule-matching candidates keep their pre-call order.
    ///
    /// Algorithm: stable topological-bubble pass. For each candidate pair
    /// (i, j) with i < j, if some rule says "candidate[j] ranks before
    /// candidate[i]", swap them. Repeat until a fixed point, capped at
    /// `candidates.count * 3` iterations as a defensive guard against
    /// contradictory rules (which the insert-time cycle check should have
    /// prevented, but depth-in-depth is cheap).
    ///
    /// - Parameters:
    ///   - candidates: Candidate list in post-rank() order.
    ///   - rules: List of (wordA, wordB) pairs from VocabularyDatabase.
    ///     Expected to be small (user rule cardinality is in the tens).
    /// - Returns: A new candidate list with relative-ordering applied.
    static func applyRelativeOrdering(
        candidates: [Candidate],
        rules: [(wordA: String, wordB: String)]
    ) -> [Candidate] {
        // Early exit: empty rule set means true no-op.
        guard !rules.isEmpty else { return candidates }
        // Early exit: list too short to reorder.
        guard candidates.count >= 2 else { return candidates }

        var result = candidates
        var movesTotal = 0
        // Iterate to a fixed point. A pair can only be resolved once it is
        // visited in the correct order; after a move, cascading rules may
        // apply — hence the outer loop. The cap is generous but bounded to
        // guard against contradictory rules.
        let cap = max(candidates.count * rules.count * 2, rules.count + 1)

        for _ in 0..<cap {
            var movedThisPass = false

            for rule in rules {
                // Find positions of wordA and wordB in the current result.
                // We only act if BOTH are present — a rule with only one
                // side in the list is a no-op.
                guard let posA = result.firstIndex(where: { $0.text == rule.wordA }),
                      let posB = result.firstIndex(where: { $0.text == rule.wordB }) else {
                    continue
                }
                // Already in the desired order.
                if posA < posB { continue }

                // Protected-tier guard: never reorder across a jianma. Per
                // decision 003 / docs/ranking.md, P0/P1 candidates are
                // inviolable and user relative-ordering rules do not apply.
                let candA = result[posA]
                let candB = result[posB]
                if candA.isJianma || candB.isJianma { continue }

                // Move wordA to just before wordB. Preserves the stable
                // order of everything else (insertion-sort semantics).
                let moving = result.remove(at: posA)
                // After removing an index greater than posB, posB is unchanged.
                result.insert(moving, at: posB)
                movesTotal += 1
                movedThisPass = true
            }

            if !movedThisPass { break }
        }

        if movesTotal > 0 {
            NSLog("MarmotIM: [D][rank] relative ordering applied rule_count=\(rules.count) candidates_swapped=\(movesTotal)")
        }
        return result
    }

    // MARK: - English at Page Ends

    /// Moves English candidates to the last slot of each page when the list
    /// also holds wubi or pinyin candidates.
    ///
    /// The first `pageSize - 1` slots of every page then always read as
    /// Chinese, in their ranked order, and Space commits Chinese. English has
    /// one predictable place per page, which the select-English-candidate key
    /// (Tab) commits. Scores, including the boost from a recent pick, still
    /// decide which English word gets the earlier page; they cannot move it
    /// out of the last slot.
    ///
    /// Once the Chinese candidates run out, the remaining English ones follow
    /// in order: two Chinese and three English give 中 中 英 英 英.
    ///
    /// A list of only English, or with no English, is returned as it is.
    /// Uppercase input produces an English-only list (DictionaryEngine.search),
    /// so it is ordered by score alone.
    ///
    /// The exception is `first`, the user's English-first words (英文置顶词,
    /// lowercased): an exact English match on one of them goes to the very
    /// first slot, above jianma and learned picks, so Space commits it. With
    /// `agent` in the list, typing `agent` gives agent 中 中 … 英; typing
    /// `agen` does not, because there `agent` is only a completion. The
    /// first page still holds `pageSize` candidates.
    ///
    /// Called by the caller after `applyRelativeOrdering`, like that pass.
    static func placeEnglishAtPageEnds(
        candidates: [Candidate],
        pageSize: Int,
        first: Set<String> = []
    ) -> [Candidate] {
        guard pageSize >= 2 else { return candidates }

        func isFirst(_ candidate: Candidate) -> Bool {
            candidate.codeType == .english && candidate.isFullMatch
                && first.contains(candidate.text.lowercased())
        }
        let leading = first.isEmpty ? [] : candidates.filter(isFirst)
        let rest = leading.isEmpty ? candidates : candidates.filter { !isFirst($0) }

        let english = rest.filter { $0.codeType == .english }
        let chinese = rest.filter { $0.codeType != .english }
        guard !english.isEmpty, !chinese.isEmpty else { return leading + rest }

        var result: [Candidate] = leading
        result.reserveCapacity(candidates.count)
        var nextEnglish = 0
        var nextChinese = 0
        // Slots already taken on the page being filled
        var taken = leading.count % pageSize

        while nextChinese < chinese.count {
            let pageEnd = min(nextChinese + max(pageSize - 1 - taken, 0), chinese.count)
            taken = 0
            result.append(contentsOf: chinese[nextChinese..<pageEnd])
            nextChinese = pageEnd

            if nextEnglish < english.count {
                result.append(english[nextEnglish])
                nextEnglish += 1
            }
        }
        result.append(contentsOf: english[nextEnglish...])
        return result
    }

    // MARK: - Continuous Input (连续输入)

    /// Explicit segment boundary in the buffer: `zhege'yijg`
    static let segmentDelimiter: Character = "'"

    /// Candidates whose code is the start of the buffer, for buffers that
    /// hold more than one word: in `zhegeyijg`, `zhege` -> 这个, then
    /// `zhe` -> 这. Each carries `headLength`, the letters it uses up.
    ///
    /// Heads are looked up longest first, so a candidate covering more of
    /// the buffer comes before one covering less. Each head is ranked as if
    /// it had been typed on its own (jianma, secondary wubi codes and the
    /// short-word bonus all depend on the code length), so 就是 holds the
    /// same place under `yijg` here as when `yijg` is typed alone.
    ///
    /// Without a delimiter, only a buffer longer than 4 letters (any wubi
    /// code) gets head candidates; up to 4 letters nothing changes. With
    /// one, heads come from the letters before the first delimiter, at any
    /// length: `wf'yi` -> 会. Those letters first get the ordinary search,
    /// completions included, so `chaichen'` lists what `chaichen` does
    /// (拆成 from `chaicheng`), then the shorter heads. A buffer with an
    /// uppercase letter gets none, since it is English only.
    ///
    /// Callers append these after the whole-buffer candidates and drop
    /// texts already listed there.
    static func headCandidates(buffer: String, engine: DictionaryEngine, limit: Int = 100,
                               englishCompletion: Bool = true) -> [Candidate] {
        guard !buffer.contains(where: { $0.isUppercase }) else { return [] }

        let isLetter: (Character) -> Bool = { $0.isASCII && $0.isLetter }
        let letters: Substring
        var longest: Int
        if let delimiter = buffer.firstIndex(of: segmentDelimiter) {
            letters = buffer[..<delimiter].prefix(while: isLetter)
            longest = letters.count
        } else {
            guard buffer.count > 4 else { return [] }
            letters = buffer.prefix(while: isLetter)
            // The whole buffer is the ordinary search
            longest = letters.count == buffer.count ? letters.count - 1 : letters.count
        }
        guard longest > 0 else { return [] }

        let rules = engine.getRelativeOrderingRules()
        var result: [Candidate] = []
        var seen = Set<String>()

        // Delimited: the segment as if typed alone, then its shorter heads
        if buffer.contains(segmentDelimiter) {
            let segment = String(letters)
            let ranked = applyRelativeOrdering(
                candidates: rank(matches: engine.search(code: segment, limit: limit,
                                                        englishCompletion: englishCompletion),
                                 inputCode: segment, engine: engine),
                rules: rules
            )
            for var candidate in ranked where seen.insert(candidate.text).inserted {
                candidate.headLength = longest
                candidate.isBoosted = false
                result.append(candidate)
                if result.count >= limit { return result }
            }
            longest -= 1
        }

        for length in stride(from: longest, through: 1, by: -1) {
            let head = String(letters.prefix(length))
            let matches = engine.searchHead(code: head)
            guard !matches.isEmpty else { continue }
            let ranked = applyRelativeOrdering(
                candidates: rank(matches: matches, inputCode: head, engine: engine),
                rules: rules
            )
            for var candidate in ranked where seen.insert(candidate.text).inserted {
                candidate.headLength = length
                // The boost marker describes a candidate ranked first overall
                candidate.isBoosted = false
                result.append(candidate)
                if result.count >= limit { return result }
            }
        }
        return result
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
        let lowercasedCode = inputCode.lowercased()

        // Check for Protected Tier (jianma) using jianma table
        // Only full wubi matches with 1-2 char codes can be jianma
        if isFullMatch && isWubiCode && inputLength <= 2 {
            let text = match.entry.text
            if engine.isOfficialJianma(code: lowercasedCode, text: text) {
                // This is an official jianma from jianma.txt
                if inputLength == 1 {
                    return jianmaLevel1Bonus  // P0: 一级简码
                } else {
                    return jianmaLevel2Bonus  // P1: 二级简码
                }
            }
        }

        if isEnglishCode {
            // These only order English candidates among themselves: exact
            // word first, then completions. Position relative to Chinese
            // candidates is decided by placeEnglishAtPageEnds.
            return isFullMatch ? tier1Bonus : englishPrefixBonus
        }

        if isSecondaryWubi(match: match, inputCode: inputCode, engine: engine) {
            return secondaryWubiBonus
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

    /// A short-coded character matched at a full code it shares with phrases,
    /// e.g. 次 at `uqwy`. It stays typeable there but goes after the phrases.
    private static func isSecondaryWubi(
        match: DictionaryMatch,
        inputCode: String,
        engine: DictionaryEngine
    ) -> Bool {
        guard match.matchType == .full && match.codeType == .wubi else { return false }
        return engine.isSecondaryWubiCode(code: inputCode.lowercased(), text: match.entry.text)
    }

    // MARK: - Score Calculation

    /// Tier override boost after applying ranking exclusions.
    ///
    /// Returns 0 for secondary wubi codes, for Wubi prefix matches in short
    /// code mode (Tier 3), and for English prefix matches. The boost is keyed by entry id, not by the code it
    /// was picked with, so without this exclusion picking 交集 at `uqwy` would
    /// push it above the exact 3-key match 次 at `uqw` for ~2 hours.
    private static func effectiveTierOverrideBoost(
        match: DictionaryMatch,
        inputCode: String,
        lastAccessTimestamp: UInt32,
        ignoresLearning: Bool
    ) -> Double {
        if ignoresLearning { return 0 }
        let isWubiPrefix = match.matchType == .prefix && match.codeType == .wubi
        if isWubiPrefix && inputCode.count <= 4 { return 0 }
        // Same reasoning for English completions: picking "kubernetes" must
        // not lift it over everything else at every shorter prefix.
        if match.matchType == .prefix && match.codeType == .english { return 0 }
        return FrecencyScore.calculateTierOverrideBoost(lastAccessTimestamp: lastAccessTimestamp)
    }

    /// Calculate score for a single match
    ///
    /// With `ignoresLearning` (secondary wubi codes), only word-intrinsic scores are used:
    /// - TierBonus: tier level from match type (kept)
    /// - BaseScore: dictionary base frequency (kept)
    /// - ShortWordBonus: shorter word preference (kept)
    ///
    /// User behavior scores are then ignored:
    /// - TierOverrideBoost: recent selection boost
    /// - RecencyScore: time since last use
    /// - FrequencyScore: total usage count
    private static func calculateScore(
        match: DictionaryMatch,
        userData: UserEntryData?,
        inputCode: String,
        engine: DictionaryEngine,
        ignoresLearning: Bool = false
    ) -> Double {
        let inputLength = inputCode.count
        let isFullMatch = match.matchType == .full
        let isWubiCode = match.codeType == .wubi

        // 1. Tier bonus (absolute, determines tier)
        let tierBonus = getTierBonus(match: match, inputCode: inputCode, engine: engine)

        // 2. Base score from dictionary frequency
        let baseFrequency = match.entry.baseFrequency(for: match.codeType)
        let baseScore = FrecencyScore.calculateBaseScore(baseFrequency: baseFrequency)

        // 3. Short word bonus (prefer shorter words within tier)
        var shortWordBonus: Double = 0
        let textLength = match.entry.textLength
        if isFullMatch && isWubiCode && inputLength == 4 && textLength == 2 {
            // Wubi 4-char full match: 2-char words get higher bonus than 1-char words
            shortWordBonus = 50_000
        } else if textLength < 5 && match.codeType != .english {
            // Default: shorter words get higher bonus. Not for English, where
            // length counts letters and the frequency rank already orders words.
            shortWordBonus = Double(5 - textLength) * shortWordBonusPerChar
        }

        // 4. User behavior scores
        var tierOverrideBoost: Double = 0
        var recencyScore: Double = 0
        var frequencyScore: Double = 0

        if !ignoresLearning {
            let accessCount = userData?.accessCount ?? 0
            let timestamp = userData?.lastAccessTimestamp ?? 0
            tierOverrideBoost = effectiveTierOverrideBoost(
                match: match,
                inputCode: inputCode,
                lastAccessTimestamp: timestamp,
                ignoresLearning: ignoresLearning
            )
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
        } else if textLength < 5 && match.codeType != .english {
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
