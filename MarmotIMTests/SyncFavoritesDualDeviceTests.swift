import XCTest
import SQLite3
@testable import MarmotIM

/// Spec-004 Part B: E-SYNC-FAV-01..06. Dual-device sync scenarios for
/// the user_favorites payload.
final class SyncFavoritesDualDeviceTests: XCTestCase {

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

    // E-SYNC-FAV-01: Insert favorite on device 1 propagates to device 2.
    func testFav01_insertOnDevice1_propagatesToDevice2() throws {
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "收藏词条A",
            wubiCode: "scabcd",
            pinyinCode: "shoucangcitiaoa",
            addedTimestamp: 1_700_000_000
        )
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        let row = SyncPayloadFixtures.readUserFavorite(dbPath: harness.device2DBPath, text: "收藏词条A")
        XCTAssertTrue(row?.exists ?? false)
        XCTAssertFalse(row?.isDeleted ?? true)
    }

    // E-SYNC-FAV-02: Both devices add same favorite. Merge keeps newer addedTimestamp.
    func testFav02_bothDevicesAddSame_mergeKeepsNewer() throws {
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "共同词",
            wubiCode: "aa", pinyinCode: "gongtongci",
            addedTimestamp: 1_700_000_000
        )
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device2DBPath,
            text: "共同词",
            wubiCode: "aa", pinyinCode: "gongtongci",
            addedTimestamp: 1_700_000_100
        )

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = SyncPayloadFixtures.readUserFavorite(dbPath: harness.device1DBPath, text: "共同词")
        let d2 = SyncPayloadFixtures.readUserFavorite(dbPath: harness.device2DBPath, text: "共同词")
        XCTAssertEqual(d1?.addedTimestamp, 1_700_000_100)
        XCTAssertEqual(d2?.addedTimestamp, 1_700_000_100)
        XCTAssertFalse(d1?.isDeleted ?? true)
        XCTAssertFalse(d2?.isDeleted ?? true)
    }

    // E-SYNC-FAV-03: Tombstone propagation — device 1 deletes, device 2 follows.
    func testFav03_tombstonePropagation() throws {
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "待删词",
            wubiCode: "aa", pinyinCode: "daishanci",
            addedTimestamp: 1_700_000_000
        )

        // Seed on both devices.
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        let d2Before = SyncPayloadFixtures.readUserFavorite(dbPath: harness.device2DBPath, text: "待删词")
        XCTAssertTrue(d2Before?.exists ?? false)

        // Device 1 soft-deletes with a newer timestamp.
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "待删词",
            wubiCode: "aa", pinyinCode: "daishanci",
            addedTimestamp: 1_700_000_500,
            isDeleted: true
        )

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        let d2After = SyncPayloadFixtures.readUserFavorite(dbPath: harness.device2DBPath, text: "待删词")
        XCTAssertTrue(d2After?.isDeleted ?? false, "tombstone should propagate")
    }

    // E-SYNC-FAV-04: Resurrection beats stale remote tombstone.
    func testFav04_resurrectionBeatsStaleTombstone() throws {
        // Add → propagate → delete → propagate → re-add → propagate.
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "复活词",
            wubiCode: "aa", pinyinCode: "fuhuoci",
            addedTimestamp: 1_700_000_100
        )
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "复活词",
            wubiCode: "aa", pinyinCode: "fuhuoci",
            addedTimestamp: 1_700_000_200,
            isDeleted: true
        )
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        // Resurrect.
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "复活词",
            wubiCode: "aa", pinyinCode: "fuhuoci",
            addedTimestamp: 1_700_000_300,
            isDeleted: false
        )
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        let d2 = SyncPayloadFixtures.readUserFavorite(dbPath: harness.device2DBPath, text: "复活词")
        XCTAssertTrue(d2?.exists ?? false)
        XCTAssertFalse(d2?.isDeleted ?? true, "newest resurrection wins")
    }

    // E-SYNC-FAV-05: File missing — cloud data must be preserved.
    // See LEARN-05 commentary; same bug class across all 5 payloads.
    func testFav05_fileMissing_cloudDataPreserved() throws {
        // Device 1 seeds + syncs.
        for i in 0..<3 {
            SyncPayloadFixtures.insertUserFavorite(
                dbPath: harness.device1DBPath,
                text: "种子词\(i)",
                wubiCode: "aa", pinyinCode: "zhongzici\(i)",
                addedTimestamp: 1_700_000_000 + i
            )
        }
        try harness.runSyncCycle(device: 1)

        // Device 2 has EMPTY local user_favorites.

        // Delete cloud.
        let cloudFile = harness.iCloudDocuments.appendingPathComponent("user_favorites.json")
        try FileManager.default.removeItem(at: cloudFile)

        // Device 2 syncs — pre-fix uploads empty local and blasts cloud.
        // Post-fix (decision 012): skips the write; a later device 1 sync
        // restores the cloud state.
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let cloud = try SyncPayloadFixtures.readRemoteSyncFile(at: cloudFile, type: FavoriteRecord.self)
        for i in 0..<3 {
            XCTAssertNotNil(cloud.records["种子词\(i)"],
                "cloud JSON must preserve device 1's 种子词\(i) across device 2 .notFound sync — decision 012 fix")
        }
    }

    // E-SYNC-FAV-06: Large-scale — 100 favorites round-trip.
    func testFav06_largeScale() throws {
        let n = 100
        for i in 0..<n {
            SyncPayloadFixtures.insertUserFavorite(
                dbPath: harness.device1DBPath,
                text: "大规模A\(i)",
                wubiCode: nil, pinyinCode: "daguimoA\(i)",
                addedTimestamp: 1_700_100_000 + i
            )
            SyncPayloadFixtures.insertUserFavorite(
                dbPath: harness.device2DBPath,
                text: "大规模B\(i)",
                wubiCode: nil, pinyinCode: "daguimoB\(i)",
                addedTimestamp: 1_700_200_000 + i
            )
        }
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1Count = SyncPayloadFixtures.countRows(dbPath: harness.device1DBPath, table: "user_favorites")
        let d2Count = SyncPayloadFixtures.countRows(dbPath: harness.device2DBPath, table: "user_favorites")
        XCTAssertEqual(d1Count, 2 * n)
        XCTAssertEqual(d2Count, 2 * n)
    }
}
