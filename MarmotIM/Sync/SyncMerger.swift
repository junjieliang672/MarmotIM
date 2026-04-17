import Foundation

/// Handles record-level merging for sync operations
/// Uses "latest-write-wins" strategy based on numeric values
struct SyncMerger {

    // MARK: - User Learning Merge

    /// Merge user_learning records
    /// Conflict resolution: keep record with higher accessCount
    /// - Parameters:
    ///   - local: Local records (key: entry_id as string)
    ///   - remote: Remote records from iCloud
    /// - Returns: Merged records
    static func mergeLearning(
        local: [String: LearningRecord],
        remote: [String: LearningRecord]
    ) -> [String: LearningRecord] {
        var result = local

        for (key, remoteRecord) in remote {
            if let localRecord = result[key] {
                // Conflict: keep the one with higher accessCount
                if remoteRecord.accessCount > localRecord.accessCount {
                    result[key] = remoteRecord
                }
            } else {
                // Only exists in remote: add it
                result[key] = remoteRecord
            }
        }

        return result
    }

    // MARK: - User Favorites Merge

    /// Merge user_favorites records
    /// Conflict resolution: keep record with newer addedTimestamp
    /// IMPORTANT: Respects is_deleted flag to prevent resurrecting deleted entries
    /// - Parameters:
    ///   - local: Local records (key: text)
    ///   - remote: Remote records from iCloud
    /// - Returns: Merged records
    static func mergeFavorites(
        local: [String: FavoriteRecord],
        remote: [String: FavoriteRecord]
    ) -> [String: FavoriteRecord] {
        var result = local

        for (key, remoteRecord) in remote {
            if let localRecord = result[key] {
                // Conflict: keep the one with newer timestamp
                // The newer timestamp wins, regardless of is_deleted state
                // This ensures that a deletion with newer timestamp takes precedence
                if remoteRecord.addedTimestamp > localRecord.addedTimestamp {
                    result[key] = remoteRecord
                }
            } else {
                // Only exists in remote: only add if NOT deleted
                // This prevents resurrecting entries that were deleted locally
                // and the local deletion record was purged
                if !remoteRecord.isDeleted {
                    result[key] = remoteRecord
                }
            }
        }

        return result
    }

    // MARK: - Filter User Freq Merge

    /// Merge filter_user_freq records
    /// Conflict resolution: keep record with higher frequency
    /// - Parameters:
    ///   - local: Local records (key: "filter_type:code:word")
    ///   - remote: Remote records from iCloud
    /// - Returns: Merged records
    static func mergeFilterFreq(
        local: [String: FilterFreqRecord],
        remote: [String: FilterFreqRecord]
    ) -> [String: FilterFreqRecord] {
        var result = local

        for (key, remoteRecord) in remote {
            if let localRecord = result[key] {
                // Conflict: keep the one with higher frequency
                if remoteRecord.frequency > localRecord.frequency {
                    result[key] = remoteRecord
                }
            } else {
                // Only exists in remote: add it
                result[key] = remoteRecord
            }
        }

        return result
    }

    // MARK: - Diff Detection

    /// Find records that need to be updated in local database
    /// - Parameters:
    ///   - merged: Merged records
    ///   - original: Original local records
    /// - Returns: Records that are new or changed
    static func findChangedLearning(
        merged: [String: LearningRecord],
        original: [String: LearningRecord]
    ) -> [(String, LearningRecord)] {
        var changed: [(String, LearningRecord)] = []

        for (key, record) in merged {
            if let orig = original[key] {
                // Check if values differ
                if record.accessCount != orig.accessCount ||
                   record.lastAccessTimestamp != orig.lastAccessTimestamp ||
                   record.totalScore != orig.totalScore {
                    changed.append((key, record))
                }
            } else {
                // New record
                changed.append((key, record))
            }
        }

        return changed
    }

    static func findChangedFavorites(
        merged: [String: FavoriteRecord],
        original: [String: FavoriteRecord]
    ) -> [(String, FavoriteRecord)] {
        var changed: [(String, FavoriteRecord)] = []

        for (key, record) in merged {
            if let orig = original[key] {
                if record.addedTimestamp != orig.addedTimestamp ||
                   record.wubiCode != orig.wubiCode ||
                   record.pinyinCode != orig.pinyinCode ||
                   record.isDeleted != orig.isDeleted {
                    changed.append((key, record))
                }
            } else {
                changed.append((key, record))
            }
        }

        return changed
    }

    static func findChangedFilterFreq(
        merged: [String: FilterFreqRecord],
        original: [String: FilterFreqRecord]
    ) -> [(String, FilterFreqRecord)] {
        var changed: [(String, FilterFreqRecord)] = []

        for (key, record) in merged {
            if let orig = original[key] {
                if record.frequency != orig.frequency ||
                   record.lastUsed != orig.lastUsed {
                    changed.append((key, record))
                }
            } else {
                changed.append((key, record))
            }
        }

        return changed
    }

    // MARK: - User Suppressed Words Merge

    /// Merge user_suppressed_words records
    /// Conflict resolution: keep record with newer suppressedTimestamp
    /// IMPORTANT: Respects is_deleted flag to prevent resurrecting deleted entries
    /// - Parameters:
    ///   - local: Local records (key: text)
    ///   - remote: Remote records from iCloud
    /// - Returns: Merged records
    static func mergeSuppressedWords(
        local: [String: SuppressedWordRecord],
        remote: [String: SuppressedWordRecord]
    ) -> [String: SuppressedWordRecord] {
        var result = local

        for (key, remoteRecord) in remote {
            if let localRecord = result[key] {
                // Conflict: keep the one with newer timestamp
                // The newer timestamp wins, regardless of is_deleted state
                // This ensures that a deletion with newer timestamp takes precedence
                if remoteRecord.suppressedTimestamp > localRecord.suppressedTimestamp {
                    result[key] = remoteRecord
                }
            } else {
                // Only exists in remote: only add if NOT deleted
                // This prevents resurrecting entries that were deleted locally
                // and the local deletion record was purged
                if !remoteRecord.isDeleted {
                    result[key] = remoteRecord
                }
            }
        }

        return result
    }

    static func findChangedSuppressedWords(
        merged: [String: SuppressedWordRecord],
        original: [String: SuppressedWordRecord]
    ) -> [(String, SuppressedWordRecord)] {
        var changed: [(String, SuppressedWordRecord)] = []

        for (key, record) in merged {
            if let orig = original[key] {
                if record.suppressedTimestamp != orig.suppressedTimestamp ||
                   record.isDeleted != orig.isDeleted {
                    changed.append((key, record))
                }
            } else {
                changed.append((key, record))
            }
        }

        return changed
    }

    // MARK: - Relative Ordering Merge (spec-003)

    /// Merge two relative-ordering rule maps per spec-003 decision 002.
    ///
    /// Algorithm:
    /// 1. Set-union all keys. For overlapping keys, max-wins on `updatedAt`;
    ///    on exact timestamp tie, non-deleted beats deleted (resurrection
    ///    beats tombstone on a tie — matches the existing favorites /
    ///    suppressed-words tie policy).
    /// 2. Build a candidate DAG from the surviving non-tombstoned edges.
    /// 3. Detect cycles (DFS-based topo walk). On cycle, drop the edge
    ///    with the OLDER `updatedAt`; tie-break by lexicographic key DESC
    ///    (deterministic across devices). The dropped edge is converted
    ///    into a tombstone with `updatedAt = max(existing, now+1)` so the
    ///    drop propagates on the next sync cycle. Iterate until acyclic.
    ///
    /// - Returns: (merged: final map including tombstoned drops,
    ///            droppedForCycle: keys that were cycle-dropped).
    static func mergeRelativeOrdering(
        local: [String: RelativeOrderingRecord],
        remote: [String: RelativeOrderingRecord]
    ) -> (merged: [String: RelativeOrderingRecord], droppedForCycle: [String]) {
        // Step 1: set-union with LWW on updated_at.
        var merged = local
        for (key, remoteRec) in remote {
            if let localRec = merged[key] {
                if remoteRec.updatedAt > localRec.updatedAt {
                    merged[key] = remoteRec
                } else if remoteRec.updatedAt == localRec.updatedAt {
                    // Tie: non-deleted wins (resurrection beats tombstone
                    // on exact timestamp tie).
                    if localRec.isDeleted && !remoteRec.isDeleted {
                        merged[key] = remoteRec
                    }
                }
            } else {
                merged[key] = remoteRec
            }
        }

        // Step 2-3: cycle detection on non-tombstoned edges. Iterate until
        // acyclic, dropping the older-updatedAt edge each time.
        var dropped: [String] = []
        let now = Int(Date().timeIntervalSince1970)

        while true {
            // Build adjacency from non-tombstoned, parse-able keys only.
            var adjacency: [String: [(to: String, key: String, updatedAt: Int)]] = [:]
            for (key, rec) in merged {
                guard !rec.isDeleted,
                      let (a, b) = RelativeOrderingRecord.parseKey(key) else { continue }
                adjacency[a, default: []].append((to: b, key: key, updatedAt: rec.updatedAt))
            }

            // Find a cycle (if any). DFS-based detection returning a path of
            // keys (edge keys) participating in the cycle.
            guard let cycleEdgeKeys = _findRelativeOrderingCycle(adjacency: adjacency) else {
                break // acyclic — done
            }

            // Pick the edge to drop: smallest updatedAt, then lexicographic
            // DESC on key for stable cross-device determinism.
            let victim = cycleEdgeKeys.map { key -> (key: String, updatedAt: Int) in
                (key, merged[key]?.updatedAt ?? 0)
            }.sorted { a, b in
                if a.updatedAt != b.updatedAt {
                    return a.updatedAt < b.updatedAt
                }
                return a.key > b.key // lexicographic DESC on tie
            }.first!

            guard let victimRec = merged[victim.key],
                  let (va, vb) = RelativeOrderingRecord.parseKey(victim.key) else {
                // Defensive: bail out; this shouldn't happen.
                break
            }
            // Tombstone the victim, bumping updatedAt so the drop propagates.
            let newTs = max(victimRec.updatedAt + 1, now + 1)
            merged[victim.key] = RelativeOrderingRecord(
                createdAt: victimRec.createdAt,
                updatedAt: newTs,
                isDeleted: true
            )
            dropped.append(victim.key)
            NSLog("MarmotIM: [W][sync] relative order cycle dropped on merge action=drop_older_update resolution=lexicographic chars_a=\(va.count) chars_b=\(vb.count)")
        }

        return (merged, dropped)
    }

    /// Detect a cycle in the relative-ordering adjacency map. Returns the
    /// set of edge keys participating in the cycle, else nil. O(V+E) per
    /// detection; the outer merge loop calls this until acyclic.
    ///
    /// Implementation: recursive DFS with the classic white/gray/black
    /// coloring. When an edge reaches a gray node, we've found a back-
    /// edge — reconstruct the cycle from the recursion stack of parent
    /// edges.
    private static func _findRelativeOrderingCycle(
        adjacency: [String: [(to: String, key: String, updatedAt: Int)]]
    ) -> [String]? {
        // Collect every node that appears as source or target.
        var nodes = Set<String>(adjacency.keys)
        for edges in adjacency.values {
            for e in edges { nodes.insert(e.to) }
        }

        // Node color: 0 = white (unvisited), 1 = gray (on stack), 2 = black (done).
        var color: [String: Int] = [:]
        for n in nodes { color[n] = 0 }

        // Parent-edge trail: key of the edge that entered each gray node.
        var parentEdge: [String: String] = [:]
        var parentNode: [String: String] = [:]

        // Iterative DFS via explicit frame stack.
        struct Frame {
            let node: String
            let edges: [(to: String, key: String, updatedAt: Int)]
            var index: Int
        }

        for start in nodes where color[start] == 0 {
            var stack: [Frame] = [Frame(node: start, edges: adjacency[start] ?? [], index: 0)]
            color[start] = 1

            while !stack.isEmpty {
                var top = stack.removeLast()
                if top.index >= top.edges.count {
                    color[top.node] = 2
                    continue
                }
                let edge = top.edges[top.index]
                top.index += 1
                stack.append(top)

                switch color[edge.to] ?? 0 {
                case 1:
                    // Back-edge — cycle. Walk parentNode/parentEdge chains
                    // from top.node back to edge.to, collecting edge keys.
                    var cycleKeys: [String] = [edge.key]
                    var cur = top.node
                    while cur != edge.to {
                        if let pk = parentEdge[cur] {
                            cycleKeys.append(pk)
                        }
                        guard let pn = parentNode[cur] else { break }
                        cur = pn
                    }
                    return cycleKeys
                case 0:
                    color[edge.to] = 1
                    parentEdge[edge.to] = edge.key
                    parentNode[edge.to] = top.node
                    stack.append(Frame(node: edge.to,
                                       edges: adjacency[edge.to] ?? [],
                                       index: 0))
                default:
                    // black — already fully explored; skip.
                    break
                }
            }
        }
        return nil
    }

    /// Mirror of findChangedSuppressedWords for relative-ordering rules.
    static func findChangedRelativeOrdering(
        merged: [String: RelativeOrderingRecord],
        original: [String: RelativeOrderingRecord]
    ) -> [(String, RelativeOrderingRecord)] {
        var changed: [(String, RelativeOrderingRecord)] = []
        for (key, record) in merged {
            if let orig = original[key] {
                if record.createdAt != orig.createdAt ||
                   record.updatedAt != orig.updatedAt ||
                   record.isDeleted != orig.isDeleted {
                    changed.append((key, record))
                }
            } else {
                changed.append((key, record))
            }
        }
        return changed
    }
}
