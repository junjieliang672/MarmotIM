import XCTest
import SQLite3
@testable import MarmotIM

/// Spec-004 Part B: E-SYNC-FILT-01..06. Dual-device sync scenarios for
/// the filter_user_freq payload.
///
/// FILT-06 is the colon-in-word probe — `FilterFreqRecord.makeKey` joins
/// filter_type, code, and word with `:` and parseKey uses
/// `split(maxSplits: 2)`, so an embedded `:` in the word should survive
/// the round-trip. This test pins the invariant.
final class SyncFilterFreqDualDeviceTests: XCTestCase {

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

    // FILT-01: Insert on device 1 propagates.
    func testFilt01_emojiFreqPropagates() throws {
        SyncPayloadFixtures.insertFilterFreq(
            dbPath: harness.device1DBPath,
            filterType: "e", code: "cat", word: "🐱",
            frequency: 3, lastUsed: 1_700_000_000
        )
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        let row = SyncPayloadFixtures.readFilterFreq(
            dbPath: harness.device2DBPath, filterType: "e", code: "cat", word: "🐱"
        )
        XCTAssertEqual(row?.frequency, 3)
    }

    // FILT-02: Both devices same key, device 2 higher freq wins.
    func testFilt02_maxFreqWins() throws {
        SyncPayloadFixtures.insertFilterFreq(
            dbPath: harness.device1DBPath,
            filterType: "e", code: "dog", word: "🐶",
            frequency: 2, lastUsed: 1_700_000_000
        )
        SyncPayloadFixtures.insertFilterFreq(
            dbPath: harness.device2DBPath,
            filterType: "e", code: "dog", word: "🐶",
            frequency: 9, lastUsed: 1_700_000_100
        )
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = SyncPayloadFixtures.readFilterFreq(
            dbPath: harness.device1DBPath, filterType: "e", code: "dog", word: "🐶"
        )
        let d2 = SyncPayloadFixtures.readFilterFreq(
            dbPath: harness.device2DBPath, filterType: "e", code: "dog", word: "🐶"
        )
        XCTAssertEqual(d1?.frequency, 9)
        XCTAssertEqual(d2?.frequency, 9)
    }

    // FILT-03: Different word, same code — both survive.
    func testFilt03_differentWordsSameCode() throws {
        SyncPayloadFixtures.insertFilterFreq(
            dbPath: harness.device1DBPath,
            filterType: "e", code: "cat", word: "🐱",
            frequency: 1, lastUsed: 1_700_000_000
        )
        SyncPayloadFixtures.insertFilterFreq(
            dbPath: harness.device2DBPath,
            filterType: "e", code: "cat", word: "🐶",
            frequency: 1, lastUsed: 1_700_000_100
        )
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        XCTAssertEqual(
            SyncPayloadFixtures.readFilterFreq(
                dbPath: harness.device1DBPath, filterType: "e", code: "cat", word: "🐱"
            )?.frequency, 1)
        XCTAssertEqual(
            SyncPayloadFixtures.readFilterFreq(
                dbPath: harness.device1DBPath, filterType: "e", code: "cat", word: "🐶"
            )?.frequency, 1)
    }

    // FILT-04: .notFound behavior — same decision 012 invariant.
    func testFilt04_fileMissing_cloudPreserved() throws {
        SyncPayloadFixtures.insertFilterFreq(
            dbPath: harness.device1DBPath,
            filterType: "e", code: "foo", word: "🐸",
            frequency: 1, lastUsed: 1_700_000_000
        )
        try harness.runSyncCycle(device: 1)
        let cloud = harness.iCloudDocuments.appendingPathComponent("filter_user_freq.json")
        try FileManager.default.removeItem(at: cloud)
        try harness.runSyncCycle(device: 2)   // empty local → skip
        try harness.runSyncCycle(device: 1)   // restores cloud

        let data = try SyncPayloadFixtures.readRemoteSyncFile(at: cloud, type: FilterFreqRecord.self)
        XCTAssertNotNil(data.records["e:foo:🐸"])
    }

    // FILT-05: Large-scale — 100 rows per device.
    func testFilt05_largeScale() throws {
        let n = 100
        for i in 0..<n {
            SyncPayloadFixtures.insertFilterFreq(
                dbPath: harness.device1DBPath,
                filterType: "e", code: "d1-\(i)", word: "🐱\(i)",
                frequency: 1, lastUsed: 1_700_000_000
            )
            SyncPayloadFixtures.insertFilterFreq(
                dbPath: harness.device2DBPath,
                filterType: "e", code: "d2-\(i)", word: "🐶\(i)",
                frequency: 1, lastUsed: 1_700_000_000
            )
        }
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        XCTAssertEqual(
            SyncPayloadFixtures.countRows(dbPath: harness.device1DBPath, table: "filter_user_freq"),
            2 * n
        )
    }

    // FILT-06: Colon-in-word probe. key format is "type:code:word";
    // parseKey uses maxSplits:2 so only the first two `:`s are separators
    // and the word field can contain additional `:`s.
    func testFilt06_colonInWord_roundTripsLosslessly() throws {
        SyncPayloadFixtures.insertFilterFreq(
            dbPath: harness.device1DBPath,
            filterType: "e",
            code: "cat",
            word: ":colon:🐱",  // embedded colons
            frequency: 5, lastUsed: 1_700_000_000
        )
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        let row = SyncPayloadFixtures.readFilterFreq(
            dbPath: harness.device2DBPath,
            filterType: "e", code: "cat", word: ":colon:🐱"
        )
        XCTAssertNotNil(row, "colon-in-word must survive sync round-trip (spec-004 FILT-06 probe)")
        XCTAssertEqual(row?.frequency, 5)
    }
}
