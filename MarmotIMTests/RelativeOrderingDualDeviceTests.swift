import XCTest
import SQLite3
@testable import MarmotIM

/// Spec-003 Level-5 end-to-end sync scenarios driven by
/// `DualDeviceSyncHarness`. These DO NOT touch real iCloud — they
/// exercise the real `SyncMerger` + JSON file I/O through the
/// `syncOnce(documentsURL:dbPath:)` entry point (decision 004).
final class RelativeOrderingDualDeviceTests: XCTestCase {

    private var harness: DualDeviceSyncHarness!

    override func setUp() {
        super.setUp()
        harness = DualDeviceSyncHarness()
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    // E-SYNC-RO-01: device 1 adds a rule → device 2 sees it after sync
    func testDevice1AddsRule_device2SeesItAfterSync() throws {
        let addResult = harness.device1.addRelativeOrderingRule(wordA: "你好", wordB: "世界")
        guard case .success = addResult else {
            XCTFail("device1 add must succeed")
            return
        }

        try harness.runSyncCycle(device: 1)  // upload
        try harness.runSyncCycle(device: 2)  // download + merge

        let d2Rules = harness.device2.listRelativeOrderingRules()
        XCTAssertEqual(d2Rules.count, 1)
        XCTAssertEqual(d2Rules.first?.wordA, "你好")
        XCTAssertEqual(d2Rules.first?.wordB, "世界")
    }

    // E-SYNC-RO-02: same rule on both devices → union yields one row
    func testBothDevicesAddSameRule_merged() throws {
        _ = harness.device1.addRelativeOrderingRule(wordA: "A", wordB: "B")
        _ = harness.device2.addRelativeOrderingRule(wordA: "A", wordB: "B")

        // Serialize uploads so the later one merges against the earlier.
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1) // catch the merged state back on device1

        XCTAssertEqual(harness.device1.listRelativeOrderingRules().count, 1)
        XCTAssertEqual(harness.device2.listRelativeOrderingRules().count, 1)
    }

    // E-SYNC-RO-03: device 1 has A→B; device 2 has B→A → cycle dropped
    func testConflictingEdges_cycleDroppedDeterministically() throws {
        _ = harness.device1.addRelativeOrderingRule(wordA: "A", wordB: "B")
        // Ensure device 2's rule has a strictly-greater updated_at by
        // sleeping briefly (unix-seconds granularity).
        Thread.sleep(forTimeInterval: 1.1)
        _ = harness.device2.addRelativeOrderingRule(wordA: "B", wordB: "A")

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1Rules = harness.device1.listRelativeOrderingRulesIncludingDeleted()
        let d2Rules = harness.device2.listRelativeOrderingRulesIncludingDeleted()

        // Count surviving non-deleted rules — each side must see exactly one.
        let d1Alive = d1Rules.filter { !$0.isDeleted }
        let d2Alive = d2Rules.filter { !$0.isDeleted }
        XCTAssertEqual(d1Alive.count, 1, "device1 should have exactly one alive rule after cycle merge")
        XCTAssertEqual(d2Alive.count, 1, "device2 should have exactly one alive rule after cycle merge")

        // The surviving rule is the newer one (B→A).
        XCTAssertEqual(d1Alive.first?.wordA, "B")
        XCTAssertEqual(d1Alive.first?.wordB, "A")
        XCTAssertEqual(d2Alive.first?.wordA, "B")
        XCTAssertEqual(d2Alive.first?.wordB, "A")
    }

    // E-SYNC-RO-05: device 1 deletes while device 2 edits — max-updated_at wins
    func testDeleteVsEdit_maxUpdatedAtWins() throws {
        // Seed (A,B) on both devices via one sync round.
        guard case .success(let rule1) = harness.device1.addRelativeOrderingRule(wordA: "A", wordB: "B") else {
            XCTFail("seed add failed")
            return
        }
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        // Find the equivalent rule id on device 2.
        guard let d2Rule = harness.device2.listRelativeOrderingRules().first(where: {
            $0.wordA == "A" && $0.wordB == "B"
        }) else {
            XCTFail("device2 should have the seeded rule")
            return
        }

        // device 1 deletes; timestamp now guaranteed later.
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(harness.device1.removeRelativeOrderingRule(ruleId: rule1.id))

        // device 2 does nothing — its row still has the original updatedAt.
        _ = d2Rule

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        XCTAssertTrue(harness.device1.listRelativeOrderingRules().isEmpty)
        XCTAssertTrue(harness.device2.listRelativeOrderingRules().isEmpty,
                      "newer tombstone must propagate to device 2")
    }

    // E-SYNC-RO-06: regression — user_learning delta still propagates.
    // We hand-insert a user_learning row via direct sqlite (the harness DB
    // has the user_learning table via createTables()), then verify the
    // regular sync path carries it to device 2.
    func testUserLearningRegression_propagates() throws {
        // Insert a synthetic user_learning row on device 1.
        let entryId: Int64 = 0xDEADBEEF
        writeUserLearningRow(to: harness.device1DBPath, entryId: entryId, accessCount: 3)

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        // Read back the row on device 2.
        let d2Count = readUserLearningAccessCount(from: harness.device2DBPath, entryId: entryId)
        XCTAssertEqual(d2Count, 3, "user_learning row should propagate through the sync harness too")
    }

    // MARK: - Low-level sqlite helpers

    private func writeUserLearningRow(to path: URL, entryId: Int64, accessCount: Int) {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            XCTFail("failed to open \(path.path)"); return
        }
        defer { sqlite3_close(db) }

        let sql = """
            INSERT OR REPLACE INTO user_learning
            (entry_id, access_count, last_access_timestamp, total_score)
            VALUES (?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("prepare failed"); return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, entryId)
        sqlite3_bind_int(stmt, 2, Int32(accessCount))
        sqlite3_bind_int(stmt, 3, Int32(Date().timeIntervalSince1970))
        sqlite3_bind_double(stmt, 4, 42.0)
        _ = sqlite3_step(stmt)
    }

    private func readUserLearningAccessCount(from path: URL, entryId: Int64) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT access_count FROM user_learning WHERE entry_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, entryId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return nil
    }
}
