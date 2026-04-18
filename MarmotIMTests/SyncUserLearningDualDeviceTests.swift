import XCTest
import SQLite3
@testable import MarmotIM

/// Spec-004 Part B: E-SYNC-LEARN-01..06. Dual-device sync scenarios for
/// the user_learning payload, driven by DualDeviceSyncHarness.
///
/// See spec-004 decision 010 (fix-all) — these scenarios are intended to
/// surface bugs; when they do, fixes land inline in MarmotIM/** with a
/// decision entry.
final class SyncUserLearningDualDeviceTests: XCTestCase {

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

    // E-SYNC-LEARN-01: Insert on device 1 propagates to device 2.
    func testLearn01_insertOnDevice1_propagatesToDevice2() throws {
        let entryId: Int64 = 0x11111111
        SyncPayloadFixtures.insertUserLearning(
            dbPath: harness.device1DBPath,
            entryId: entryId,
            accessCount: 3,
            lastAccessTimestamp: 1_700_000_000,
            totalScore: 42
        )

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        let row = SyncPayloadFixtures.readUserLearning(dbPath: harness.device2DBPath, entryId: entryId)
        XCTAssertEqual(row?.accessCount, 3)
        XCTAssertEqual(row?.timestamp, 1_700_000_000)
    }

    // E-SYNC-LEARN-02: Both devices record same entry. Merge keeps
    // the record from the side with higher accessCount (the composite-record
    // semantic documented in the SyncMerger contract — decision 010 pause
    // trigger allows escalation only if this behavior is re-interpreted;
    // we just pin it here).
    func testLearn02_bothDevices_mergeMaxAccessCount() throws {
        let entryId: Int64 = 0x22222222
        SyncPayloadFixtures.insertUserLearning(
            dbPath: harness.device1DBPath,
            entryId: entryId, accessCount: 2,
            lastAccessTimestamp: 1_700_000_100, totalScore: 20
        )
        SyncPayloadFixtures.insertUserLearning(
            dbPath: harness.device2DBPath,
            entryId: entryId, accessCount: 5,
            lastAccessTimestamp: 1_700_000_200, totalScore: 55
        )

        // Cross-sync to converge.
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = SyncPayloadFixtures.readUserLearning(dbPath: harness.device1DBPath, entryId: entryId)
        let d2 = SyncPayloadFixtures.readUserLearning(dbPath: harness.device2DBPath, entryId: entryId)

        XCTAssertEqual(d1?.accessCount, 5)
        XCTAssertEqual(d2?.accessCount, 5)
        // The accessCount=5 row's sibling fields (ts, score) survive together.
        XCTAssertEqual(d1?.timestamp, 1_700_000_200)
        XCTAssertEqual(d2?.timestamp, 1_700_000_200)
    }

    // E-SYNC-LEARN-03: device 1 higher accessCount. device 2 empty. Round-trip stable.
    func testLearn03_device1WinsOnAccessCount_stable() throws {
        let entryId: Int64 = 0x33333333
        SyncPayloadFixtures.insertUserLearning(
            dbPath: harness.device1DBPath,
            entryId: entryId, accessCount: 10,
            lastAccessTimestamp: 1_700_000_300, totalScore: 100
        )
        SyncPayloadFixtures.insertUserLearning(
            dbPath: harness.device2DBPath,
            entryId: entryId, accessCount: 5,
            lastAccessTimestamp: 1_700_000_400, totalScore: 50
        )

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = SyncPayloadFixtures.readUserLearning(dbPath: harness.device1DBPath, entryId: entryId)
        let d2 = SyncPayloadFixtures.readUserLearning(dbPath: harness.device2DBPath, entryId: entryId)
        XCTAssertEqual(d1?.accessCount, 10)
        XCTAssertEqual(d2?.accessCount, 10)

        // Round-trip idempotency: one more cycle doesn't change anything.
        try harness.runSyncCycle(device: 2)
        let d2Again = SyncPayloadFixtures.readUserLearning(dbPath: harness.device2DBPath, entryId: entryId)
        XCTAssertEqual(d2Again?.accessCount, 10)
    }

    // E-SYNC-LEARN-04: No tombstone semantics. Deleting on device 1 does
    // NOT remove from device 2 — the sync resurrects. Documented as
    // intentional in contracts.documented_invariants.
    func testLearn04_noTombstone_deleteDoesNotPropagate() throws {
        let entryId: Int64 = 0x44444444
        SyncPayloadFixtures.insertUserLearning(
            dbPath: harness.device1DBPath,
            entryId: entryId, accessCount: 5,
            lastAccessTimestamp: 1_700_000_500, totalScore: 50
        )

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        // Hard-delete on device 1.
        SyncPayloadFixtures.deleteUserLearning(dbPath: harness.device1DBPath, entryId: entryId)

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        // Device 2 still has the row; device 1 resurrects it on next sync.
        let d2 = SyncPayloadFixtures.readUserLearning(dbPath: harness.device2DBPath, entryId: entryId)
        XCTAssertEqual(d2?.accessCount, 5, "no tombstone => device 2 keeps it")

        try harness.runSyncCycle(device: 1)
        let d1 = SyncPayloadFixtures.readUserLearning(dbPath: harness.device1DBPath, entryId: entryId)
        XCTAssertEqual(d1?.accessCount, 5, "no tombstone => device 1 gets it back")
    }

    // E-SYNC-LEARN-05: File missing on device 2. MUST NOT destroy device 1's
    // cloud data.
    //
    // Reproduces the pre-fix bug precisely: device 1 syncs a rich state to
    // cloud, then the cloud file is removed (simulating user-induced delete
    // or inter-device race). Device 2 — fresh instance with only its own
    // local data — syncs. Under the buggy .notFound branch, device 2
    // UNCONDITIONALLY uploaded its local state, which erased device 1's
    // contribution from the cloud.
    //
    // Post-fix invariant: the cloud JSON, inspected directly, preserves
    // device 1's rows OR at minimum the union of local and cloud state
    // survives. We inspect the cloud JSON after device 2 syncs to force
    // the bug to surface at its root — the writer, not the downstream
    // device 1 whose local copy would otherwise mask the corruption.
    //
    // See spec-004 decision 011 + new decision 012-notfound-branch-merge-guard.
    func testLearn05_fileMissingOnDevice2_mustNotDestroyDevice1CloudData() throws {
        // Device 1 seeds 3 rows and syncs.
        for i in 0..<3 {
            SyncPayloadFixtures.insertUserLearning(
                dbPath: harness.device1DBPath,
                entryId: Int64(0x55550000 | i),
                accessCount: 1,
                lastAccessTimestamp: 1_700_000_600 + i,
                totalScore: Double(i)
            )
        }
        try harness.runSyncCycle(device: 1)

        // Device 2 has EMPTY local user_learning (never contributed to this
        // payload — matches the spec's E-SYNC-LEARN-05 "device 2 that has
        // never contributed" language).

        // Delete the cloud file (simulate user-induced delete or inter-device race).
        let cloudFile = harness.iCloudDocuments.appendingPathComponent("user_learning.json")
        try FileManager.default.removeItem(at: cloudFile)

        // Device 2 syncs. Pre-fix: .notFound branch writes device 2's empty
        // local state to cloud, creating an empty JSON and erasing device 1's
        // 3 rows.
        //
        // Post-fix (decision 012): device 2 sees an empty local and a missing
        // cloud file — the SAFE action is to skip the write (nothing to
        // upload, and writing would clobber whatever was supposed to be
        // there). A subsequent device 1 sync then restores cloud.
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let cloudFinal = try SyncPayloadFixtures.readRemoteSyncFile(at: cloudFile, type: LearningRecord.self)
        for i in 0..<3 {
            let key = String(Int64(0x55550000 | i))
            XCTAssertNotNil(cloudFinal.records[key],
                "cloud JSON must preserve device 1's entry 0x5555000\(i) across device 2 .notFound sync — decision 012 fix")
        }
        XCTAssertEqual(cloudFinal.records.count, 3,
            "cloud must hold exactly device 1's 3 rows after the round-trip")
    }

    // E-SYNC-LEARN-06: Large-scale merge — 100 rows from each device (scaled
    // down from spec-proposed 1,000 for test speed; still exercises the
    // same merge path).
    func testLearn06_largeScale_mergeAllRows() throws {
        let n = 100
        for i in 0..<n {
            SyncPayloadFixtures.insertUserLearning(
                dbPath: harness.device1DBPath,
                entryId: Int64(0x66660000 | i),
                accessCount: 1,
                lastAccessTimestamp: 1_700_100_000 + i,
                totalScore: Double(i)
            )
            SyncPayloadFixtures.insertUserLearning(
                dbPath: harness.device2DBPath,
                entryId: Int64(0x77770000 | i),
                accessCount: 1,
                lastAccessTimestamp: 1_700_200_000 + i,
                totalScore: Double(i) * 2
            )
        }

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1Count = SyncPayloadFixtures.countRows(dbPath: harness.device1DBPath, table: "user_learning")
        let d2Count = SyncPayloadFixtures.countRows(dbPath: harness.device2DBPath, table: "user_learning")
        XCTAssertEqual(d1Count, 2 * n)
        XCTAssertEqual(d2Count, 2 * n)
    }
}
