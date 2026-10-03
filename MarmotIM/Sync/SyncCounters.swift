import Foundation

/// A synced usage counter (format v2) for user_learning and filter_user_freq.
///
/// Each device only ever increases its own slot in `counts`, and merging takes
/// the per-device maximum, so the total is the sum of every device's own
/// selections. Example: since the last sync Mac A picked 的 10 times and Mac B
/// 5 times; A's slot grows by 10, B's by 5, and both end up with +15. The v1
/// format kept one number and merged by max, which gave +10 and lost B's 5.
///
/// The `legacy` slot holds counts that existed before a device moved to v2.
/// Those totals were already shared between the Macs by v1 (both had 的 at
/// 13278), so they merge by max like v1 did instead of being added twice.
struct CounterRecord: Codable, Equatable {
    var counts: [String: Int]
    var lastUsed: Double

    var total: Int { counts.values.reduce(0, +) }
}

enum CounterSync {

    static let legacyDeviceId = "legacy-v1"

    /// Per-device max of counts, max of lastUsed. Commutative, associative
    /// and idempotent, so devices converge regardless of merge order and
    /// re-merging the same file never inflates a total.
    static func merge(_ a: [String: CounterRecord], _ b: [String: CounterRecord]) -> [String: CounterRecord] {
        var result = a
        for (key, rb) in b {
            guard var ra = result[key] else {
                result[key] = rb
                continue
            }
            for (device, count) in rb.counts {
                ra.counts[device] = max(ra.counts[device] ?? 0, count)
            }
            ra.lastUsed = max(ra.lastUsed, rb.lastUsed)
            result[key] = ra
        }
        return result
    }

    /// Build this device's view from the local table and the per-device
    /// counts recorded at the last sync.
    ///
    /// - totals: key -> (count, lastUsed) as the local table holds them now.
    /// - known: key -> device -> count, as of the last successful sync.
    /// - baselineDone: false until this device's first v2 sync completes;
    ///   before that, every local total is pre-v2 history and goes to `legacy`.
    ///
    /// This device's slot is whatever the local total holds beyond the other
    /// devices' known counts. It never shrinks, so a locally deleted row is
    /// restored by the next sync (learning has no tombstones).
    static func localRecords(
        totals: [String: (count: Int, lastUsed: Double)],
        known: [String: [String: Int]],
        deviceId: String,
        baselineDone: Bool
    ) -> [String: CounterRecord] {
        var result: [String: CounterRecord] = [:]
        for key in Set(totals.keys).union(known.keys) {
            let total = totals[key]?.count ?? 0
            var counts = known[key] ?? [:]

            if !baselineDone && counts.isEmpty {
                if total > 0 { counts[legacyDeviceId] = total }
            } else {
                let others = counts.filter { $0.key != deviceId }.values.reduce(0, +)
                let mine = max(counts[deviceId] ?? 0, total - others)
                if mine > 0 { counts[deviceId] = mine }
            }

            guard !counts.isEmpty else { continue }
            result[key] = CounterRecord(counts: counts, lastUsed: totals[key]?.lastUsed ?? 0)
        }
        return result
    }
}
