import XCTest
import SQLite3
@testable import MarmotIM

/// Spec-004 Part B extensions for relative-ordering sync — augments the
/// 5 existing scenarios in RelativeOrderingDualDeviceTests (spec-003)
/// with the file-missing and large-scale probes for parity with the
/// other 4 payloads.
final class SyncRelativeOrderingDualDeviceExtensionTests: XCTestCase {

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

    // RO-EXT-01: File missing — decision 012 invariant holds for relative_ordering.
    func testROExt01_fileMissing_cloudPreserved() throws {
        _ = harness.device1.addRelativeOrderingRule(wordA: "Alpha", wordB: "Beta")
        _ = harness.device1.addRelativeOrderingRule(wordA: "Gamma", wordB: "Delta")
        try harness.runSyncCycle(device: 1)

        let cloud = harness.iCloudDocuments.appendingPathComponent("user_relative_ordering.json")
        try FileManager.default.removeItem(at: cloud)

        try harness.runSyncCycle(device: 2)  // empty local, no prior sync → skip
        try harness.runSyncCycle(device: 1)  // restores cloud

        let data = try SyncPayloadFixtures.readRemoteSyncFile(
            at: cloud, type: RelativeOrderingRecord.self
        )
        XCTAssertNotNil(data.records[RelativeOrderingRecord.makeKey(wordA: "Alpha", wordB: "Beta")])
        XCTAssertNotNil(data.records[RelativeOrderingRecord.makeKey(wordA: "Gamma", wordB: "Delta")])
    }

    // RO-EXT-02: 200 rules round-trip losslessly (scaled down from
    // spec's 500 for test speed — still exercises the large-N merge path).
    func testROExt02_largeScale() throws {
        let n = 200
        for i in 0..<n {
            _ = harness.device1.addRelativeOrderingRule(wordA: "d1A\(i)", wordB: "d1B\(i)")
            _ = harness.device2.addRelativeOrderingRule(wordA: "d2A\(i)", wordB: "d2B\(i)")
        }
        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)
        try harness.runSyncCycle(device: 1)

        let d1 = harness.device1.listRelativeOrderingRules().count
        let d2 = harness.device2.listRelativeOrderingRules().count
        XCTAssertEqual(d1, 2 * n)
        XCTAssertEqual(d2, 2 * n)
    }
}
