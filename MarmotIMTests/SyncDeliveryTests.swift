import XCTest
import SQLite3
@testable import MarmotIM

/// Sync fixes for "the other Mac never gets it" and "deleted words come back":
/// tombstones survive devices that never had the row, one bad payload doesn't
/// block the rest, unchanged merges don't rewrite the cloud file, and merged
/// learning rows announce themselves so the ranker cache can reload.
final class SyncDeliveryTests: XCTestCase {

    private var harness: DualDeviceSyncHarness!
    private var device3DBPath: URL!
    private var device3: VocabularyDatabase!

    override func setUp() {
        super.setUp()
        harness = DualDeviceSyncHarness()
        let dir = harness.root.appendingPathComponent("device3")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        device3DBPath = dir.appendingPathComponent("dictionary.db")
        device3 = VocabularyDatabase.makeForTests(path: device3DBPath)
    }

    override func tearDown() {
        device3 = nil
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    private func syncDevice3() throws {
        device3.checkpoint()
        try iCloudSyncManager.shared.syncOnce(documentsURL: harness.iCloudDocuments, dbPath: device3DBPath)
    }

    private var favoritesCloudURL: URL {
        harness.iCloudDocuments.appendingPathComponent("user_favorites.json")
    }

    /// Device 1 deletes X. Device 3 (fresh DB, never had X) syncs. Device 2,
    /// which was offline with X still active, syncs last. Before the fix,
    /// device 3's merge dropped the tombstone from the cloud file and device 2
    /// re-uploaded X as active.
    func testTombstoneSurvivesFreshDeviceThenStaleDevice() throws {
        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device2DBPath, text: "肓扫",
                                               wubiCode: "yerv", pinyinCode: nil, addedTimestamp: 100)
        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device1DBPath, text: "肓扫",
                                               wubiCode: "yerv", pinyinCode: nil, addedTimestamp: 200,
                                               isDeleted: true)

        try harness.runSyncCycle(device: 1)
        try syncDevice3()

        let cloudAfterFresh = try SyncPayloadFixtures.readRemoteSyncFile(at: favoritesCloudURL,
                                                                         type: FavoriteRecord.self)
        XCTAssertEqual(cloudAfterFresh.records["肓扫"]?.isDeleted, true,
                       "a device without the row must not erase the cloud tombstone")
        XCTAssertEqual(SyncPayloadFixtures.readUserFavorite(dbPath: device3DBPath, text: "肓扫")?.isDeleted, true)

        try harness.runSyncCycle(device: 2)

        XCTAssertEqual(SyncPayloadFixtures.readUserFavorite(dbPath: harness.device2DBPath, text: "肓扫")?.isDeleted,
                       true, "stale active copy loses to the newer tombstone")
        let cloudFinal = try SyncPayloadFixtures.readRemoteSyncFile(at: favoritesCloudURL, type: FavoriteRecord.self)
        XCTAssertEqual(cloudFinal.records["肓扫"]?.isDeleted, true)
    }

    /// A corrupt user_learning_v2.json used to abort syncOnce before favorites,
    /// filter freq, suppressed words and ordering ran.
    func testCorruptPayloadDoesNotBlockOtherPayloads() throws {
        SyncPayloadFixtures.insertUserLearning(dbPath: harness.device1DBPath, entryId: 0xBEEF,
                                               accessCount: 1, lastAccessTimestamp: 1, totalScore: 1)
        try harness.runSyncCycle(device: 1)
        try SyncPayloadFixtures.corruptJSONFile(
            at: harness.iCloudDocuments.appendingPathComponent("user_learning_v2.json"))

        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device2DBPath, text: "涉政",
                                               wubiCode: "ihgh", pinyinCode: "shezheng", addedTimestamp: 300)
        SyncPayloadFixtures.insertSuppressedWord(dbPath: harness.device2DBPath, text: "交集",
                                                 suppressedTimestamp: 300)

        XCTAssertThrowsError(try harness.runSyncCycle(device: 2), "the failure is still reported")

        let favorites = try SyncPayloadFixtures.readRemoteSyncFile(at: favoritesCloudURL, type: FavoriteRecord.self)
        XCTAssertNotNil(favorites.records["涉政"], "favorites synced despite the learning failure")
        let suppressed = try SyncPayloadFixtures.readRemoteSyncFile(
            at: harness.iCloudDocuments.appendingPathComponent("user_suppressed_words.json"),
            type: SuppressedWordRecord.self)
        XCTAssertNotNil(suppressed.records["交集"])
    }

    /// Every rewrite fires NSMetadataQuery on both Macs and starts another
    /// round; a merge that changes nothing must leave the file alone.
    func testUnchangedMergeDoesNotRewriteCloudFile() throws {
        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device1DBPath, text: "涉政",
                                               wubiCode: "ihgh", pinyinCode: "shezheng", addedTimestamp: 300)
        try harness.runSyncCycle(device: 1)
        let before = try Data(contentsOf: favoritesCloudURL)

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        // SyncFile embeds lastModified, so identical bytes mean no rewrite
        XCTAssertEqual(try Data(contentsOf: favoritesCloudURL), before)
    }

    func testMergedLearningPostsReloadNotification() throws {
        SyncPayloadFixtures.insertEntry(dbPath: harness.device2DBPath, id: 0xBEEF,
                                        text: SyncPayloadFixtures.fixtureText(forEntryId: 0xBEEF))
        SyncPayloadFixtures.insertUserLearning(dbPath: harness.device1DBPath, entryId: 0xBEEF,
                                               accessCount: 5, lastAccessTimestamp: 1_790_000_000, totalScore: 1)
        try harness.runSyncCycle(device: 1)

        let posted = expectation(forNotification: .userLearningDidChange, object: nil)
        try harness.runSyncCycle(device: 2)
        wait(for: [posted], timeout: 2)

        XCTAssertEqual(SyncPayloadFixtures.readUserLearning(dbPath: harness.device2DBPath, entryId: 0xBEEF)?.accessCount, 5)
    }
}
