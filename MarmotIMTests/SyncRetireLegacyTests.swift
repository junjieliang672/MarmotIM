import XCTest
@testable import MarmotIM

/// Retiring the v1 payload files (settings → iCloud → 清理) and the per-Mac
/// sync switch.
final class SyncRetireLegacyTests: XCTestCase {

    private var harness: DualDeviceSyncHarness!
    private let wordId: Int64 = 0x0B0B0B0B

    private var docs: URL { harness.iCloudDocuments }
    private var v1Learning: URL { docs.appendingPathComponent("user_learning.json") }
    private var v1Filter: URL { docs.appendingPathComponent("filter_user_freq.json") }
    private var backup: URL { docs.appendingPathComponent("user_favorites.json.bak-pre-purge") }

    override func setUp() {
        super.setUp()
        harness = DualDeviceSyncHarness()
        for path in [harness.device1DBPath, harness.device2DBPath] {
            SyncPayloadFixtures.insertEntry(dbPath: path, id: wordId,
                                            text: SyncPayloadFixtures.fixtureText(forEntryId: wordId))
        }
    }

    override func tearDown() {
        harness?.tearDown()
        harness = nil
        super.tearDown()
    }

    private func writeV1Learning(count: Int) throws {
        let file = SyncFile(records: [String(wordId): LearningRecord(accessCount: count,
                                                                     lastAccessTimestamp: 1_700_000_000 + count,
                                                                     totalScore: 0)])
        try JSONEncoder().encode(file).write(to: v1Learning)
    }

    private func writeObsoleteFiles() throws {
        try writeV1Learning(count: 12)
        let filter = SyncFile(records: ["e:foo:🐸": FilterFreqRecord(frequency: 3, lastUsed: 1_700_000_000)])
        try JSONEncoder().encode(filter).write(to: v1Filter)
        try Data("old backup".utf8).write(to: backup)
    }

    private func retire(device: Int) throws -> [String] {
        let dbPath = device == 1 ? harness.device1DBPath : harness.device2DBPath
        (device == 1 ? harness.device1 : harness.device2).checkpoint()
        return try iCloudSyncManager.shared.retireLegacyFiles(documentsURL: docs, dbPath: dbPath)
    }

    private func learningCount(device: Int) -> Int? {
        let dbPath = device == 1 ? harness.device1DBPath : harness.device2DBPath
        return SyncPayloadFixtures.readUserLearning(dbPath: dbPath, entryId: wordId)?.accessCount
    }

    /// The v1 files hold a count the v2 data has never seen. Retiring must
    /// carry it over before deleting anything.
    func testRetireMergesFirstThenDeletes() throws {
        try writeObsoleteFiles()

        let removed = try retire(device: 1)

        XCTAssertEqual(Set(removed), ["user_learning.json", "filter_user_freq.json", "user_favorites.json.bak-pre-purge"])
        for url in [v1Learning, v1Filter, backup] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
        XCTAssertEqual(learningCount(device: 1), 12, "the v1 count is in the local database")
        let v2 = try SyncPayloadFixtures.readRemoteSyncFile(
            at: docs.appendingPathComponent("user_learning_v2.json"), type: CounterRecord.self)
        XCTAssertEqual(v2.records[SyncPayloadFixtures.fixtureText(forEntryId: wordId)]?.total, 12)
        XCTAssertEqual(SyncPayloadFixtures.readFilterFreq(dbPath: harness.device1DBPath,
                                                          filterType: "e", code: "foo", word: "🐸")?.frequency, 3)
    }

    /// If any payload fails to sync, nothing is deleted and nothing is retired.
    func testRetireDeletesNothingWhenSyncFails() throws {
        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device1DBPath, text: "涉政", wubiCode: "ihgh",
                                               pinyinCode: "shezheng", addedTimestamp: 100)
        try harness.runSyncCycle(device: 1)
        try writeObsoleteFiles()
        try SyncPayloadFixtures.corruptJSONFile(at: docs.appendingPathComponent("user_favorites.json"))

        XCTAssertThrowsError(try retire(device: 2))

        for url in [v1Learning, v1Filter, backup] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
        let statuses = iCloudSyncManager.shared.readDeviceStatuses(documentsURL: docs)
        XCTAssertFalse(statuses.contains { $0.legacyRetired == true })
    }

    /// Device 2 learns of the retirement from device 1's status file. A v1
    /// file that shows up again afterwards (an old build re-uploading it,
    /// e.g. the work Mac) is ignored instead of merged.
    func testOtherDeviceAdoptsRetirementAndIgnoresReappearingV1File() throws {
        try writeObsoleteFiles()
        _ = try retire(device: 1)
        try harness.runSyncCycle(device: 2)
        XCTAssertEqual(learningCount(device: 2), 12)

        try writeV1Learning(count: 900)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        XCTAssertEqual(learningCount(device: 2), 12, "device 2 adopted the retirement and ignores the file")
        XCTAssertEqual(learningCount(device: 1), 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v1Learning.path),
                      "ignored, not silently deleted: the settings page offers to clean it again")
        XCTAssertEqual(iCloudSyncManager.shared.obsoleteFiles(documentsURL: docs).map(\.lastPathComponent),
                       ["user_learning.json"])
    }

    func testStatusWithoutLegacyRetiredFieldStillDecodes() throws {
        let json = """
        {"deviceId":"A","name":"Mac","appVersion":"1.0.0 (1)","lastSyncAt":1,"lastSyncOK":true,
         "payloads":{"favorites":{"count":1,"digest":"ab"}}}
        """
        let status = try JSONDecoder().decode(DeviceSyncStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.legacyRetired)
        XCTAssertEqual(status.summary(.favorites)?.count, 1)
    }

    // MARK: - Per-Mac sync switch

    func testSyncIsEnabledUnlessMarkerFileExists() throws {
        let dir = harness.root.appendingPathComponent("switch")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(iCloudSyncManager.isSyncEnabled(inDirectory: dir), "a fresh install syncs")

        FileManager.default.createFile(atPath: iCloudSyncManager.syncDisabledMarkerURL(inDirectory: dir).path,
                                       contents: nil)
        XCTAssertFalse(iCloudSyncManager.isSyncEnabled(inDirectory: dir))
    }

    func testMenuTextAndIconWhenSyncIsSwitchedOff() {
        // Off is the user's choice, not a failure: it wins over every failure text
        XCTAssertEqual(SyncStatusPresenter.text(isEnabled: false, isAvailable: false, isSyncing: false,
                                                lastSyncTime: nil, lastSyncSuccess: false,
                                                lastSyncError: SyncError.containerNotFound,
                                                timeAgo: { _ in "" }),
                       "同步已关闭")
        XCTAssertEqual(SyncStatusPresenter.iconName(isEnabled: false, isAvailable: true, isSyncing: false,
                                                    lastSyncSuccess: true, lastSyncError: nil),
                       "icloud.slash")
    }
}
