# MarmotIM Ranking Algorithm

## Overview

MarmotIM uses a **Tier-based Frecency** ranking algorithm that combines:

1. **Tier System** - Absolute priority based on match type (full/prefix) and code type (wubi/pinyin)
2. **Frecency Score** - Within-tier ranking based on recency + frequency + base frequency

```
TotalScore = TierBonus + TierOverrideBoost + RecencyScore + FrequencyScore + BaseScore + ShortWordBonus
```

---

## Tier System (Absolute Priority)

The tier system provides **absolute priority** - a higher tier candidate always ranks above lower tiers, regardless of frecency scores.

### Protected Tier (Tier 0) - 简码保护

Wubi 1-2级简码 (level 1-2 short codes) have a **protected tier** that **CANNOT be overridden** by user learning:

| Tier | Match Type | Code Length | Bonus | Override |
|------|------------|-------------|-------|----------|
| 0 | Full Wubi | 1-2 chars | +1T | ❌ Never |

**Rationale**: 一级简码 (25 single-key codes like `i`→我, `w`→人) and 二级简码 (625 two-key codes) are the core efficiency of Wubi input. These codes are deeply ingrained in muscle memory - users expect them to **always** produce the same result. Allowing frecency or user history to reorder these would destroy the deterministic nature that makes Wubi fast.

**Implementation**: The jianmaTierBonus (1T = 1,000,000,000,000) is intentionally set higher than:
- `tier1Bonus (100B) + tierOverrideBoost (500B) = 600B`

This ensures that even if a user repeatedly selects a different word, the 简码 will **always** rank first.

### Short Code Mode (input length <= 4)

When input is 4 characters or less, Wubi matches are prioritized. These are **regular tiers** that CAN be overridden by user selection:

| Tier | Match Type | Code Type | Bonus | Override |
|------|------------|-----------|-------|----------|
| 1 | Full Match | Wubi (3-4 chars) | +100B | ✅ Can override |
| 2 | Full Match | Pinyin | +10B | ✅ Can override |
| 3 | Prefix Match | Wubi | +1B | ✅ Can override |
| 4 | Prefix Match | Pinyin | 0 | ✅ Can override |

**Note**: Full Wubi matches with 1-2 char codes are Tier 0 (protected), not Tier 1.

**Rationale**: 3-4 character Wubi codes (三级简码, 全码) can be overridden because users may genuinely prefer alternative words. But 1-2级简码 are protected.

### Long Code Mode (input length > 4)

When input exceeds 4 characters, only match type matters:

| Tier | Match Type | Bonus |
|------|------------|-------|
| 1 | Full Match | +100B |
| 2 | Prefix Match | 0 |

**Rationale**: Long codes are typically pinyin. Full matches should rank above prefix matches.

---

## Frecency Algorithm

Within each tier, candidates are ranked by Frecency - a combination of **recency** and **frequency**.

### Recency Score (Exponential Decay)

```swift
RecencyScore = 1,000,000,000 × e^(-λ × timeSince)
```

Where:
- `λ = ln(2) / 86400` (half-life = 1 day = 86400 seconds)
- `timeSince` = seconds since last selection

**Decay Curve:**

| Time Since Selection | Recency Score | % of Initial |
|---------------------|---------------|--------------|
| Just now | 1,000,000,000 | 100% |
| 6 hours | 757,858,283 | 75.8% |
| 12 hours | 574,349,177 | 57.4% |
| 1 day | 500,000,000 | 50% |
| 2 days | 250,000,000 | 25% |
| 7 days | 7,812,500 | 0.78% |
| 14 days | 61,035 | 0.006% |

**Key Property**: Immediately after selection, recency score (~1B) dominates all other factors, guaranteeing the selected word ranks #1 within its tier.

### Frequency Score (Permanent)

```swift
FrequencyScore = accessCount × 10,000
```

- Each selection adds 10,000 points permanently
- Never decays
- After enough selections, frequency dominates over decayed recency

**Example:**
| Selections | Frequency Score |
|------------|-----------------|
| 1 | 10,000 |
| 10 | 100,000 |
| 100 | 1,000,000 |
| 1000 | 10,000,000 |

### Base Score (Dictionary Default)

```swift
BaseScore = baseFrequency  // 0-65535
```

The base frequency comes from the dictionary and reflects:
- **Wubi entries**: Code length priority (shorter codes = higher frequency)
  - 1-char code (一级简码): 65,000
  - 2-char code (二级简码): 55,000
  - 3-char code (三级简码): 45,000
  - 4-char code (全码): 35,000

- **Pinyin entries**: Word position priority (first word in dictionary = higher frequency)
  - Position 0: 65,000
  - Position 1: 64,500
  - Position 2: 64,000
  - ...decreasing by 500 per position

### Short Word Bonus

```swift
ShortWordBonus = (5 - textLength) × 10,000  // if textLength < 5
```

Prefer shorter words within the same tier:
- 1-char word: +40,000
- 2-char word: +30,000
- 3-char word: +20,000
- 4-char word: +10,000
- 5+ char word: 0

---

## Tier Override Boost (Cross-Tier Promotion)

A special high-value boost that can temporarily override **regular tier** boundaries:

```swift
TierOverrideBoost = 500,000,000,000 × e^(-λ × timeSince)
```

Where:
- `λ = ln(2) / 3600` (half-life = 1 hour)
- Initial boost = 500B (exceeds tier gap of 100B)

**Purpose**: When a user repeatedly selects a pinyin word over a wubi word, the tier-override boost allows the pinyin word to temporarily rank above the wubi word.

**Important**: This boost **CANNOT** override Tier 0 (1-2级简码). The protected tier bonus (1T) is intentionally set higher than the maximum possible regular score (tier1 100B + tierOverride 500B = 600B), ensuring 简码 always rank first.

**Decay:**
| Time Since | Boost | Effect |
|------------|-------|--------|
| Just now | 500B | Overrides tier |
| 30 min | 354B | Still overrides |
| 1 hour | 250B | Still overrides |
| 2 hours | 125B | Marginally overrides |
| 3 hours | 62.5B | No longer overrides |

**Cutoff**: Boost is set to 0 when it falls below 1B (no longer meaningful).

---

## Score Calculation Example

### Scenario 1: Just Selected Wubi Word

```
Input: "wo" (2 chars, short code mode)
Match: Full Wubi match, just selected, base=55000

TierBonus = 100,000,000,000 (Tier 1: Full Wubi)
TierOverrideBoost = 500,000,000,000
RecencyScore = 1,000,000,000
FrequencyScore = 10,000 (1 access)
BaseScore = 55,000
ShortWordBonus = 30,000 (2-char word)

Total = 600,001,095,000
```

### Scenario 2: Frequently Used Pinyin Word

```
Input: "wo" (2 chars)
Match: Full Pinyin match, 100 accesses, last access 2 days ago

TierBonus = 10,000,000,000 (Tier 2: Full Pinyin)
TierOverrideBoost = 0 (decayed past cutoff)
RecencyScore = 250,000,000 (2 days = 50% × 50%)
FrequencyScore = 1,000,000 (100 × 10,000)
BaseScore = 60,000
ShortWordBonus = 30,000

Total = 10,251,090,000
```

### Scenario 3: Never Selected Default

```
Input: "wo"
Match: Prefix Pinyin match, never selected, base=40000

TierBonus = 0 (Tier 4: Prefix Pinyin)
TierOverrideBoost = 0
RecencyScore = 0
FrequencyScore = 0
BaseScore = 40,000
ShortWordBonus = 20,000

Total = 60,000
```

---

## Data Storage

### Normal Mode

User learning data is stored in `user_learning` table:

```sql
CREATE TABLE user_learning (
    entry_id INTEGER PRIMARY KEY,
    access_count INTEGER NOT NULL DEFAULT 0,
    last_access_timestamp INTEGER NOT NULL DEFAULT 0,
    total_score REAL NOT NULL DEFAULT 0
);
```

### Filter Mode (Isolated)

Filter mode uses a separate table to avoid polluting normal mode rankings:

```sql
CREATE TABLE filter_user_freq (
    filter_type TEXT NOT NULL,  -- 'e' (emoji), 'p' (fuzzy pinyin), 's' (symbol)
    code TEXT NOT NULL,
    word TEXT NOT NULL,
    frequency INTEGER DEFAULT 1,
    last_used REAL,
    PRIMARY KEY (filter_type, code, word)
);
```

---

## Algorithm Properties

### Tier Override Summary

| Tier | Description | Can User Override? |
|------|-------------|-------------------|
| 0 | Wubi 1-2级简码 | ❌ Never - always ranks first |
| 1-4 | Regular tiers | ✅ Yes - via tierOverrideBoost |

### Convergence Behavior

1. **Short-term**: Recency dominates. Last selected word ranks #1 (within its tier).
2. **Medium-term** (1-7 days): Recency fades, frequency becomes important.
3. **Long-term** (>14 days): Frequency and base score dominate.

### User Experience

- **Immediate feedback**: Selected word immediately jumps to #1 (within its tier)
- **Learning**: Frequently used words gradually rise in ranking
- **Forgetting**: Rarely used words gradually fall back to base ranking
- **Stability**: High-frequency words maintain position even when not recently used
- **简码保护**: 1-2级简码 always produce the same result, preserving muscle memory

### Performance

- Score calculation is O(1) per candidate
- User data is cached in memory for fast lookup
- Only user-selected entries have user_learning records (sparse storage)

---

## Configuration (AppConfig)

Ranking weights can be customized in `AppConfig.swift`:

```swift
struct RankingWeights: Codable {
    var baseFrequencyWeight: Double = 1.0
    var fullMatchBonus: Double = 50000.0
    var lengthBonus: Double = 10000.0
    var wubiSourceBonus: Double = 5000.0
    var userLearningMultiplier: Double = 100000.0
    var recentSelectionBonus: Double = 500000.0
    var recentSelectionBoostTime: Double = 3600.0
    var recencyWeightWithinHour: Double = 4.0
    var recencyWeightWithinDay: Double = 2.0
    var recencyWeightWithinWeek: Double = 1.0
    var recencyWeightOlder: Double = 0.5
}
```

---

## Source Files

- `MarmotIM/Ranking/CandidateRanker.swift` - Tier-based ranking logic
- `MarmotIM/Ranking/FrecencyScore.swift` - Frecency score calculation
- `MarmotIM/Config/AppConfig.swift` - Configurable weights
- `MarmotIM/Dictionary/VocabularyDatabase.swift` - User learning data storage
