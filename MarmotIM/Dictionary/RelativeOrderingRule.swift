import Foundation

// MARK: - Model

/// User-owned directed edge A→B meaning "A ranks above B whenever both
/// appear in the candidate list" (per spec-003 relative-ordering feature).
///
/// Persisted in the `user_relative_order` table in VocabularyDatabase
/// (schema v8). Synced via iCloud using ASCII Unit Separator (U+001F)
/// between `wordA` and `wordB` as the stable key (see decision 006).
struct RelativeOrderingRule: Equatable, Hashable {
    /// SQLite rowid; 0 for a not-yet-persisted rule.
    let id: Int64
    /// Normalized (NFC + trimmed) antecedent word.
    let wordA: String
    /// Normalized (NFC + trimmed) consequent word.
    let wordB: String
    /// Unix seconds at creation time.
    let createdAt: Int
    /// Unix seconds; bumped on tombstone flip or resurrection.
    let updatedAt: Int
    /// Tombstone flag for sync parity (matches user_favorites pattern).
    let isDeleted: Bool
}

// MARK: - Error

/// Errors surfaced from RelativeOrderingStore / VocabularyDatabase CRUD
/// for relative-ordering rules. Mapped to zh-Hans HUD strings by the
/// RelativeOrderingViewModel (dual-channel logging + toast per
/// `.knowledge/observability/error-boundaries.md`).
enum RelativeOrderingError: Error, Equatable, LocalizedError {
    /// `wordA` or `wordB` is empty after whitespace trim + NFC normalization.
    case emptyInput
    /// `wordA` == `wordB` after normalization.
    case identicalWords
    /// The exact (wordA, wordB) pair already exists (non-tombstoned).
    case duplicate
    /// Inserting the proposed edge would create a cycle in the rule graph.
    /// `path` is the detected cycle (e.g. ["B","A","B"]) for logging/debug.
    case cycle(path: [String])
    /// VocabularyDatabase is in degraded state (db handle is nil).
    case dbUnavailable

    /// zh-Hans description for HUD surface. The RelativeOrderingViewModel
    /// uses `mapError(_:)` but having LocalizedError makes surrogate log
    /// lines readable as well.
    var errorDescription: String? {
        switch self {
        case .emptyInput:     return "请填写两个词"
        case .identicalWords: return "两个词不能相同"
        case .duplicate:      return "该规则已存在"
        case .cycle:          return "该规则会造成循环（与已有规则冲突）"
        case .dbUnavailable:  return "词库未就绪"
        }
    }

    /// Stable English enum tag for structured logging (PII-safe — no word text).
    var loggingReason: String {
        switch self {
        case .emptyInput:     return "emptyInput"
        case .identicalWords: return "identicalWords"
        case .duplicate:      return "duplicate"
        case .cycle:          return "cycle"
        case .dbUnavailable:  return "dbUnavailable"
        }
    }
}

// MARK: - Input normalization

/// Centralized normalization used at the VocabularyDatabase boundary
/// before any rule INSERT/UPDATE. Applied to BOTH wordA and wordB.
///
/// Choice (decision 008):
/// 1. Whitespace trim (leading + trailing) — eliminates accidental copy-
///    paste padding that would otherwise produce phantom duplicates.
/// 2. Unicode NFC (`precomposedStringWithCanonicalMapping`) — aligns
///    composed/decomposed diacritic forms, critical because iCloud on
///    macOS stores filenames NFD and user text can arrive in either
///    form from the keyboard/OS.
///
/// NOT case-folded (Chinese has no case; mixing 'HTML' vs 'html' is the
/// user's responsibility).
enum RelativeOrderingNormalizer {
    static func normalize(_ raw: String) -> String {
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

// MARK: - In-memory store / cycle detection

/// Thin value type that holds the live (non-tombstoned) rule set as an
/// adjacency map, provides cycle-detection for proposed new edges, and
/// yields a pair-constraint comparator for use by the ranker's post-
/// processing pass (T3).
///
/// Rebuilt from VocabularyDatabase on startup and after sync merges via
/// NotificationCenter (.relativeOrderingDidChange). The DFS-based cycle
/// detection is O(V+E) over the rule graph, which remains small for a
/// personal IME.
struct RelativeOrderingStore {
    private let adjacency: [String: Set<String>]
    let rules: [RelativeOrderingRule]

    init(rules: [RelativeOrderingRule]) {
        // Only non-tombstoned rules affect the graph.
        let live = rules.filter { !$0.isDeleted }
        var adj: [String: Set<String>] = [:]
        for rule in live {
            adj[rule.wordA, default: Set<String>()].insert(rule.wordB)
        }
        self.adjacency = adj
        self.rules = rules
    }

    /// Lightweight pair view for the ranker hot path (no rule-id overhead).
    var pairs: [(wordA: String, wordB: String)] {
        return rules
            .filter { !$0.isDeleted }
            .map { ($0.wordA, $0.wordB) }
    }

    /// DFS from `b` following existing edges; if we can reach `a`, then
    /// adding edge a→b would close a cycle. Returns the cycle path when
    /// detected (a→…→b→a), else nil.
    ///
    /// Edge already present: returns nil (caller classifies as
    /// .duplicate — not a cycle).
    func wouldCreateCycle(adding a: String, b: String) -> [String]? {
        if a == b {
            // Guarded upstream by .identicalWords; defensive return.
            return [a, b]
        }
        if adjacency[a]?.contains(b) == true {
            // Edge already exists — caller resolves this as duplicate.
            return nil
        }

        // DFS from b; if we reach a, the proposed new edge a→b closes a
        // cycle. Track the path for debug logs.
        var stack: [(String, [String])] = [(b, [a, b])]
        var visited = Set<String>()
        while let (node, path) = stack.popLast() {
            if visited.contains(node) { continue }
            visited.insert(node)
            guard let neighbors = adjacency[node] else { continue }
            for next in neighbors {
                let newPath = path + [next]
                if next == a {
                    return newPath
                }
                stack.append((next, newPath))
            }
        }
        return nil
    }
}
