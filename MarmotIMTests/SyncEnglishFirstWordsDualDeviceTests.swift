import XCTest
import SQLite3
@testable import MarmotIM

/// Spec-004 Part B: E-SYNC-SUPP-01..06. Dual-device sync scenarios for
/// the user_english_first_words payload.
///
/// One of the anticipated pre-committed fixes (decision 011b) is the
/// `removeEnglishFirstWord` hard-delete bug. The codebase actually uses
/// `removeEnglishFirstWord` which already performs a soft delete (UPDATE
/// is_deleted=1). SUPP-03 pins that invariant so future refactors can't
/// regress to hard-delete without an explicit decision entry.
final class SyncEnglishFirstWordsDualDeviceTests: XCTestCase {

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

    // SUPP-01: Insert an English-first word on device 1 → propagates to device 2.
    func testSupp01_insertPropagates() throws {
        XCTAssertTrue(harness.device1.addEnglishFirstWord(text: "usr"))

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        XCTAssertTrue(harness.device2.isEnglishFirstWord(text: "usr"))
    }

    // SUPP-02: Both devices add the same word → single row, LWW on timestamp.
    func testSupp02_bothDevicesSameWord_lww() throws {
        SyncPayloadFixtures.insertEnglishFirstWord(
            dbPath: harness.device1DBPath,
            text: "wget",
            addedTimestamp: 1_700_000_000
        )
        SyncPayloadFixtures.insertEnglishFirstWord(
            dbPath: harness.device2DBPath,
            text: "wget",
            addedTimestamp: 1_700_000_500  // newer
        )

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = SyncPayloadFixtures.readEnglishFirstWord(dbPath: harness.device1DBPath, text: "wget")
        let d2 = SyncPayloadFixtures.readEnglishFirstWord(dbPath: harness.device2DBPath, text: "wget")
        XCTAssertEqual(d1?.addedTimestamp, 1_700_000_500)
        XCTAssertEqual(d2?.addedTimestamp, 1_700_000_500)
    }

    // SUPP-03: Removal propagates. This is the anticipated bug
    // from decision 011b — pre-fix, removeEnglishFirstWord would hard-delete,
    // and the row would be resurrected by the next down-sync from another
    // device. The codebase's `removeEnglishFirstWord` actually already uses
    // soft-delete; this test pins that so a future refactor back to
    // hard-delete gets immediately caught.
    func testSupp03_removalPropagates_noResurrect() throws {
        // Seed + propagate.
        XCTAssertTrue(harness.device1.addEnglishFirstWord(text: "grep"))
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertTrue(harness.device2.isEnglishFirstWord(text: "grep"))

        // Device 1 removes the word.
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(harness.device1.removeEnglishFirstWord(text: "grep"))
        XCTAssertFalse(harness.device1.isEnglishFirstWord(text: "grep"))

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        XCTAssertFalse(harness.device2.isEnglishFirstWord(text: "grep"),
            "removal must propagate: is_deleted=1 with bumped timestamp (decision 011b)")

        // And another round-trip must NOT resurrect it.
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertFalse(harness.device2.isEnglishFirstWord(text: "grep"))
    }

    // SUPP-04: Resurrection (add → remove → add).
    func testSupp04_resurrectAfterRemoval() throws {
        XCTAssertTrue(harness.device1.addEnglishFirstWord(text: "sed"))
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(harness.device1.removeEnglishFirstWord(text: "sed"))
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertFalse(harness.device2.isEnglishFirstWord(text: "sed"))

        // Re-add (bump timestamp).
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(harness.device1.addEnglishFirstWord(text: "sed"))
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertTrue(harness.device2.isEnglishFirstWord(text: "sed"),
            "re-adding after removal must propagate")
    }

    // SUPP-05: File missing on device 2 with empty local — cloud preserved.
    func testSupp05_fileMissing_cloudPreserved() throws {
        XCTAssertTrue(harness.device1.addEnglishFirstWord(text: "awk"))
        XCTAssertTrue(harness.device1.addEnglishFirstWord(text: "cut"))
        try harness.runSyncCycle(device: 1)

        let cloud = harness.iCloudDocuments.appendingPathComponent("user_english_first_words.json")
        try FileManager.default.removeItem(at: cloud)

        // device 2 has empty local + no prior sync -> should skip write
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let data = try SyncPayloadFixtures.readRemoteSyncFile(at: cloud, type: EnglishFirstWordRecord.self)
        XCTAssertNotNil(data.records["awk"])
        XCTAssertNotNil(data.records["cut"])
    }

    // SUPP-06: Large-scale — 100 English-first words per device.
    func testSupp06_largeScale() throws {
        let n = 100
        for i in 0..<n {
            SyncPayloadFixtures.insertEnglishFirstWord(
                dbPath: harness.device1DBPath,
                text: "d1-sup-\(i)",
                addedTimestamp: 1_700_100_000 + i
            )
            SyncPayloadFixtures.insertEnglishFirstWord(
                dbPath: harness.device2DBPath,
                text: "d2-sup-\(i)",
                addedTimestamp: 1_700_200_000 + i
            )
        }
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = SyncPayloadFixtures.countRows(dbPath: harness.device1DBPath, table: "user_english_first_words")
        let d2 = SyncPayloadFixtures.countRows(dbPath: harness.device2DBPath, table: "user_english_first_words")
        XCTAssertEqual(d1, 2 * n)
        XCTAssertEqual(d2, 2 * n)
    }
}
