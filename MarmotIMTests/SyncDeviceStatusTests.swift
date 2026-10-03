import XCTest
@testable import MarmotIM

/// Each device publishes devices/<id>.json after a sync; the settings iCloud
/// page compares the fingerprints in them to say whether two Macs hold the
/// same data.
final class SyncDeviceStatusTests: XCTestCase {

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

    private func statuses() -> [DeviceSyncStatus] {
        iCloudSyncManager.shared.readDeviceStatuses(documentsURL: harness.iCloudDocuments)
            .sorted { $0.deviceId < $1.deviceId }
    }

    private func seedBothDevices() {
        for path in [harness.device1DBPath, harness.device2DBPath] {
            SyncPayloadFixtures.insertEntry(dbPath: path, id: 0xABCD,
                                            text: SyncPayloadFixtures.fixtureText(forEntryId: 0xABCD))
        }
        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device1DBPath, text: "涉政", wubiCode: "ihgh",
                                               pinyinCode: "shezheng", addedTimestamp: 100)
        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device2DBPath, text: "肓扫", wubiCode: "yerv",
                                               pinyinCode: nil, addedTimestamp: 200, isDeleted: true)
        SyncPayloadFixtures.insertSuppressedWord(dbPath: harness.device2DBPath, text: "交集", suppressedTimestamp: 300)
        SyncPayloadFixtures.insertUserLearning(dbPath: harness.device1DBPath, entryId: 0xABCD, accessCount: 4,
                                               lastAccessTimestamp: 1_700_000_000, totalScore: 0)
    }

    func testBothDevicesPublishMatchingFingerprintsOnceConverged() throws {
        seedBothDevices()
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let all = statuses()
        XCTAssertEqual(all.count, 2, "one status file per device")
        XCTAssertNotEqual(all[0].deviceId, all[1].deviceId)
        XCTAssertEqual(all[0].differences(from: all[1]), [])
        XCTAssertTrue(all.allSatisfy { $0.lastSyncOK })
        // Tombstones are not counted as words
        XCTAssertEqual(all[0].summary(.favorites)?.count, 1)
        XCTAssertEqual(all[0].summary(.suppressed)?.count, 1)
        XCTAssertEqual(all[0].summary(.learning)?.count, 1)
    }

    func testUnsyncedChangeShowsAsDifferenceUntilTheOtherDeviceSyncs() throws {
        seedBothDevices()
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device1DBPath, text: "速览", wubiCode: "gkjt",
                                               pinyinCode: "sulan", addedTimestamp: 400)
        try harness.runSyncCycle(device: 1)

        var all = statuses()
        XCTAssertEqual(all[0].differences(from: all[1]), [.favorites],
                       "device 2 has not picked up the new word yet")

        try harness.runSyncCycle(device: 2)
        all = statuses()
        XCTAssertEqual(all[0].differences(from: all[1]), [])
    }

    func testStatusIsPublishedEvenWhenAPayloadFails() throws {
        SyncPayloadFixtures.insertUserFavorite(dbPath: harness.device1DBPath, text: "涉政", wubiCode: "ihgh",
                                               pinyinCode: "shezheng", addedTimestamp: 100)
        try harness.runSyncCycle(device: 1)
        try SyncPayloadFixtures.corruptJSONFile(
            at: harness.iCloudDocuments.appendingPathComponent("user_favorites.json"))

        XCTAssertThrowsError(try harness.runSyncCycle(device: 2))

        let failed = statuses().filter { !$0.lastSyncOK }
        XCTAssertEqual(failed.count, 1)
        XCTAssertNotNil(failed.first?.lastError)
    }

    func testStatusFilesAreNotMistakenForPayloads() throws {
        seedBothDevices()
        try harness.runSyncCycle(device: 1)
        let favorites = harness.iCloudDocuments.appendingPathComponent("user_favorites.json")
        let before = try Data(contentsOf: favorites)

        // Another round rewrites only the device status file
        try harness.runSyncCycle(device: 1)
        XCTAssertEqual(try Data(contentsOf: favorites), before)
    }

    func testDigestIgnoresOrder() {
        XCTAssertEqual(SyncDigest.digest(["a|1", "b|2"]), SyncDigest.digest(["b|2", "a|1"]))
        XCTAssertNotEqual(SyncDigest.digest(["a|1", "b|2"]), SyncDigest.digest(["a|1", "b|3"]))
    }

    func testMissingPayloadCountsAsDifference() {
        let full = DeviceSyncStatus(deviceId: "A", name: "A", appVersion: "1", lastSyncAt: 0, lastSyncOK: true,
                                    lastError: nil,
                                    payloads: Dictionary(uniqueKeysWithValues: SyncPayloadKind.allCases.map {
                                        ($0.rawValue, PayloadSummary(count: 0, digest: "x"))
                                    }))
        var partial = full
        partial.deviceId = "B"
        partial.payloads[SyncPayloadKind.learning.rawValue] = nil
        XCTAssertEqual(full.differences(from: partial), [.learning])
    }

    func testFileIsStuckOnlyWhenNotUploadedForLong() {
        let now = Date()
        func file(uploaded: Bool, age: TimeInterval) -> SyncFileCloudState {
            SyncFileCloudState(name: "f", modified: now.addingTimeInterval(-age), isUploaded: uploaded,
                               isUploading: !uploaded, conflictCount: 0, uploadError: nil)
        }
        XCTAssertTrue(file(uploaded: false, age: 900).isStuck(now: now), "machine 2's case: 15 minutes, still uploading")
        XCTAssertFalse(file(uploaded: false, age: 30).isStuck(now: now))
        XCTAssertFalse(file(uploaded: true, age: 900).isStuck(now: now))
    }

    func testTimeAgo() {
        let now = Date()
        XCTAssertEqual(SyncStatusPresenter.timeAgo(now.addingTimeInterval(-30), now: now), "刚刚")
        XCTAssertEqual(SyncStatusPresenter.timeAgo(now.addingTimeInterval(-120), now: now), "2分钟前")
        XCTAssertEqual(SyncStatusPresenter.timeAgo(now.addingTimeInterval(-3 * 86400), now: now), "3天前")
    }
}
