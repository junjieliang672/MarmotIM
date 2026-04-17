import XCTest
@testable import MarmotIM

/// Tests for SyncMerger.mergeRelativeOrdering (spec-003, T6).
final class RelativeOrderingSyncMergerTests: XCTestCase {

    // Merge two disjoint rule sets → union.
    func testDisjointMerge_union() {
        let keyAB = RelativeOrderingRecord.makeKey(wordA: "A", wordB: "B")
        let keyCD = RelativeOrderingRecord.makeKey(wordA: "C", wordB: "D")
        let local  = [keyAB: RelativeOrderingRecord(createdAt: 100, updatedAt: 100)]
        let remote = [keyCD: RelativeOrderingRecord(createdAt: 200, updatedAt: 200)]

        let (merged, dropped) = SyncMerger.mergeRelativeOrdering(local: local, remote: remote)
        XCTAssertEqual(merged.count, 2)
        XCTAssertNotNil(merged[keyAB])
        XCTAssertNotNil(merged[keyCD])
        XCTAssertTrue(dropped.isEmpty)
    }

    // Same pair on both sides, max-updated_at wins.
    func testDuplicatePair_maxUpdatedAtWins() {
        let key = RelativeOrderingRecord.makeKey(wordA: "A", wordB: "B")
        let local  = [key: RelativeOrderingRecord(createdAt: 100, updatedAt: 100, isDeleted: false)]
        let remote = [key: RelativeOrderingRecord(createdAt: 100, updatedAt: 200, isDeleted: true)]

        let (merged, _) = SyncMerger.mergeRelativeOrdering(local: local, remote: remote)
        XCTAssertEqual(merged[key]?.updatedAt, 200)
        XCTAssertEqual(merged[key]?.isDeleted, true, "newer tombstone must win over older alive")
    }

    // Cycle detection on merge: newer edge survives, older tombstoned.
    func testCycleInMerge_olderUpdatedAtDropped() {
        let keyAB = RelativeOrderingRecord.makeKey(wordA: "A", wordB: "B")
        let keyBA = RelativeOrderingRecord.makeKey(wordA: "B", wordB: "A")
        let local  = [keyAB: RelativeOrderingRecord(createdAt: 100, updatedAt: 100)]
        let remote = [keyBA: RelativeOrderingRecord(createdAt: 200, updatedAt: 200)]

        let (merged, dropped) = SyncMerger.mergeRelativeOrdering(local: local, remote: remote)
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first, keyAB, "older edge (updatedAt=100) must be dropped")
        XCTAssertEqual(merged[keyAB]?.isDeleted, true)
        XCTAssertEqual(merged[keyBA]?.isDeleted, false)
    }

    // Tombstone propagation: older-side tombstone wins over newer active.
    func testTombstonePropagation() {
        let key = RelativeOrderingRecord.makeKey(wordA: "X", wordB: "Y")
        let local  = [key: RelativeOrderingRecord(createdAt: 100, updatedAt: 100, isDeleted: false)]
        let remote = [key: RelativeOrderingRecord(createdAt: 100, updatedAt: 300, isDeleted: true)]

        let (merged, _) = SyncMerger.mergeRelativeOrdering(local: local, remote: remote)
        XCTAssertEqual(merged[key]?.isDeleted, true)
    }

    // Exact tie on updatedAt: resurrection (non-deleted) beats tombstone.
    func testTimestampTie_resurrectionBeatsTombstone() {
        let key = RelativeOrderingRecord.makeKey(wordA: "A", wordB: "B")
        let local  = [key: RelativeOrderingRecord(createdAt: 100, updatedAt: 500, isDeleted: true)]
        let remote = [key: RelativeOrderingRecord(createdAt: 100, updatedAt: 500, isDeleted: false)]

        let (merged, _) = SyncMerger.mergeRelativeOrdering(local: local, remote: remote)
        XCTAssertEqual(merged[key]?.isDeleted, false,
                       "non-deleted record should win on exact timestamp tie")
    }

    // 3-node cycle on merge: oldest dropped, resulting graph acyclic.
    func testThreeNodeCycle_oldestDropped() {
        let keyAB = RelativeOrderingRecord.makeKey(wordA: "A", wordB: "B")
        let keyBC = RelativeOrderingRecord.makeKey(wordA: "B", wordB: "C")
        let keyCA = RelativeOrderingRecord.makeKey(wordA: "C", wordB: "A")
        let local = [
            keyAB: RelativeOrderingRecord(createdAt: 100, updatedAt: 100),
            keyBC: RelativeOrderingRecord(createdAt: 200, updatedAt: 200),
        ]
        let remote = [
            keyCA: RelativeOrderingRecord(createdAt: 300, updatedAt: 300),
        ]
        let (merged, dropped) = SyncMerger.mergeRelativeOrdering(local: local, remote: remote)
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first, keyAB, "oldest updatedAt (100) should be the cycle victim")
        // Survivors are acyclic.
        XCTAssertEqual(merged[keyAB]?.isDeleted, true)
        XCTAssertEqual(merged[keyBC]?.isDeleted, false)
        XCTAssertEqual(merged[keyCA]?.isDeleted, false)
    }

    // Key helpers round-trip.
    func testKeyRoundTrip() {
        let key = RelativeOrderingRecord.makeKey(wordA: "你好", wordB: "世界")
        let parsed = RelativeOrderingRecord.parseKey(key)
        XCTAssertEqual(parsed?.wordA, "你好")
        XCTAssertEqual(parsed?.wordB, "世界")
    }

    // Invalid key parsing returns nil.
    func testKeyParseRejectsInvalid() {
        XCTAssertNil(RelativeOrderingRecord.parseKey("noSeparator"))
        XCTAssertNil(RelativeOrderingRecord.parseKey("\u{001F}onlyB"))
        XCTAssertNil(RelativeOrderingRecord.parseKey("onlyA\u{001F}"))
    }

    // findChanged reports new + modified.
    func testFindChanged_newAndModified() {
        let keyAB = RelativeOrderingRecord.makeKey(wordA: "A", wordB: "B")
        let keyCD = RelativeOrderingRecord.makeKey(wordA: "C", wordB: "D")
        let original = [keyAB: RelativeOrderingRecord(createdAt: 100, updatedAt: 100)]
        let merged = [
            keyAB: RelativeOrderingRecord(createdAt: 100, updatedAt: 200), // modified
            keyCD: RelativeOrderingRecord(createdAt: 300, updatedAt: 300)  // new
        ]
        let changed = SyncMerger.findChangedRelativeOrdering(merged: merged, original: original)
        XCTAssertEqual(changed.count, 2)
    }
}
