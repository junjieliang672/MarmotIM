import XCTest
import SQLite3
@testable import MarmotIM

/// Spec-004 Part B: E-SYNC-SUPP-01..06. Dual-device sync scenarios for
/// the user_suppressed_words payload.
///
/// One of the anticipated pre-committed fixes (decision 011b) is the
/// `removeSuppressedWord` hard-delete bug. The codebase actually uses
/// `unsuppressWord` which already performs a soft delete (UPDATE
/// is_deleted=1). SUPP-03 pins that invariant so future refactors can't
/// regress to hard-delete without an explicit decision entry.
final class SyncSuppressedWordsDualDeviceTests: XCTestCase {

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

    // SUPP-01: Insert a suppressed word on device 1 → propagates to device 2.
    func testSupp01_insertPropagates() throws {
        XCTAssertTrue(harness.device1.suppressWord(text: "usr"))

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        XCTAssertTrue(harness.device2.isWordSuppressed(text: "usr"))
    }

    // SUPP-02: Both devices suppress same word → single row, LWW on timestamp.
    func testSupp02_bothDevicesSameWord_lww() throws {
        SyncPayloadFixtures.insertSuppressedWord(
            dbPath: harness.device1DBPath,
            text: "wget",
            suppressedTimestamp: 1_700_000_000
        )
        SyncPayloadFixtures.insertSuppressedWord(
            dbPath: harness.device2DBPath,
            text: "wget",
            suppressedTimestamp: 1_700_000_500  // newer
        )

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = SyncPayloadFixtures.readSuppressedWord(dbPath: harness.device1DBPath, text: "wget")
        let d2 = SyncPayloadFixtures.readSuppressedWord(dbPath: harness.device2DBPath, text: "wget")
        XCTAssertEqual(d1?.suppressedTimestamp, 1_700_000_500)
        XCTAssertEqual(d2?.suppressedTimestamp, 1_700_000_500)
    }

    // SUPP-03: Un-suppression propagates. This is the anticipated bug
    // from decision 011b — pre-fix, removeSuppressedWord would hard-delete,
    // and the row would be resurrected by the next down-sync from another
    // device. The codebase's `unsuppressWord` actually already uses
    // soft-delete; this test pins that so a future refactor back to
    // hard-delete gets immediately caught.
    func testSupp03_unsuppressPropagates_noResurrect() throws {
        // Seed + propagate.
        XCTAssertTrue(harness.device1.suppressWord(text: "grep"))
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertTrue(harness.device2.isWordSuppressed(text: "grep"))

        // Device 1 un-suppresses.
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(harness.device1.unsuppressWord(text: "grep"))
        XCTAssertFalse(harness.device1.isWordSuppressed(text: "grep"))

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        XCTAssertFalse(harness.device2.isWordSuppressed(text: "grep"),
            "un-suppression must propagate: is_deleted=1 with bumped timestamp (decision 011b)")

        // And another round-trip must NOT resurrect it.
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertFalse(harness.device2.isWordSuppressed(text: "grep"))
    }

    // SUPP-04: Resurrection (suppress → unsuppress → suppress).
    func testSupp04_resurrectAfterUnsuppress() throws {
        XCTAssertTrue(harness.device1.suppressWord(text: "sed"))
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(harness.device1.unsuppressWord(text: "sed"))
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertFalse(harness.device2.isWordSuppressed(text: "sed"))

        // Re-suppress (bump timestamp).
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertTrue(harness.device1.suppressWord(text: "sed"))
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertTrue(harness.device2.isWordSuppressed(text: "sed"),
            "re-suppression after un-suppression must propagate")
    }

    // SUPP-05: File missing on device 2 with empty local — cloud preserved.
    func testSupp05_fileMissing_cloudPreserved() throws {
        XCTAssertTrue(harness.device1.suppressWord(text: "awk"))
        XCTAssertTrue(harness.device1.suppressWord(text: "cut"))
        try harness.runSyncCycle(device: 1)

        let cloud = harness.iCloudDocuments.appendingPathComponent("user_suppressed_words.json")
        try FileManager.default.removeItem(at: cloud)

        // device 2 has empty local + no prior sync -> should skip write
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let data = try SyncPayloadFixtures.readRemoteSyncFile(at: cloud, type: SuppressedWordRecord.self)
        XCTAssertNotNil(data.records["awk"])
        XCTAssertNotNil(data.records["cut"])
    }

    // SUPP-06: Large-scale — 100 suppressed words per device.
    func testSupp06_largeScale() throws {
        let n = 100
        for i in 0..<n {
            SyncPayloadFixtures.insertSuppressedWord(
                dbPath: harness.device1DBPath,
                text: "d1-sup-\(i)",
                suppressedTimestamp: 1_700_100_000 + i
            )
            SyncPayloadFixtures.insertSuppressedWord(
                dbPath: harness.device2DBPath,
                text: "d2-sup-\(i)",
                suppressedTimestamp: 1_700_200_000 + i
            )
        }
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = SyncPayloadFixtures.countRows(dbPath: harness.device1DBPath, table: "user_suppressed_words")
        let d2 = SyncPayloadFixtures.countRows(dbPath: harness.device2DBPath, table: "user_suppressed_words")
        XCTAssertEqual(d1, 2 * n)
        XCTAssertEqual(d2, 2 * n)
    }
}
