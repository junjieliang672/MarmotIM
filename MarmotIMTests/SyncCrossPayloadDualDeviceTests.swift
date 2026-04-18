import XCTest
import SQLite3
@testable import MarmotIM

/// Spec-004 Part B: cross-payload scenarios ALL-01, ALL-02.
/// These exercise all 5 payloads within a single syncOnce cycle to
/// catch regressions where a future refactor accidentally drops one
/// of the per-payload try-calls in syncOnce.
final class SyncCrossPayloadDualDeviceTests: XCTestCase {

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

    // ALL-01: One row of every payload on device 1, one syncOnce cycle
    //         per device — all 5 payloads arrive on device 2.
    func testAll01_allFivePayloadsSyncInOneCycle() throws {
        // user_learning
        SyncPayloadFixtures.insertUserLearning(
            dbPath: harness.device1DBPath,
            entryId: 0xAAAA,
            accessCount: 1, lastAccessTimestamp: 1, totalScore: 1
        )
        // user_favorites
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "跨载荷A",
            wubiCode: "aa", pinyinCode: "kuazai",
            addedTimestamp: 1
        )
        // filter_user_freq
        SyncPayloadFixtures.insertFilterFreq(
            dbPath: harness.device1DBPath,
            filterType: "e", code: "all", word: "🤞",
            frequency: 1, lastUsed: 1
        )
        // user_suppressed_words
        XCTAssertTrue(harness.device1.suppressWord(text: "blacklistword"))
        // user_relative_order
        _ = harness.device1.addRelativeOrderingRule(wordA: "Top", wordB: "Bottom")

        try harness.runSyncCycle(device: 1)
        try harness.runSyncCycle(device: 2)

        // Verify each payload on device 2.
        XCTAssertNotNil(SyncPayloadFixtures.readUserLearning(dbPath: harness.device2DBPath, entryId: 0xAAAA))
        let fav = SyncPayloadFixtures.readUserFavorite(dbPath: harness.device2DBPath, text: "跨载荷A")
        XCTAssertTrue(fav?.exists ?? false)
        XCTAssertEqual(SyncPayloadFixtures.readFilterFreq(
            dbPath: harness.device2DBPath,
            filterType: "e", code: "all", word: "🤞"
        )?.frequency, 1)
        XCTAssertTrue(harness.device2.isWordSuppressed(text: "blacklistword"))
        let ruleCount = harness.device2.listRelativeOrderingRules().count
        XCTAssertEqual(ruleCount, 1)
    }

    // ALL-02: Determinism — running syncOnce twice in succession without
    // local changes produces the same cloud JSON (modulo the lastModified
    // timestamp which is allowed to change).
    func testAll02_determinism_acrossConsecutiveSyncs() throws {
        SyncPayloadFixtures.insertUserLearning(
            dbPath: harness.device1DBPath,
            entryId: 0xDEADBEEF,
            accessCount: 5, lastAccessTimestamp: 1_700_000_000, totalScore: 50
        )
        SyncPayloadFixtures.insertUserFavorite(
            dbPath: harness.device1DBPath,
            text: "确定性词",
            wubiCode: "aa", pinyinCode: "querdingxingci",
            addedTimestamp: 1_700_000_000
        )

        try harness.runSyncCycle(device: 1)

        let payloadNames = [
            "user_learning.json",
            "user_favorites.json",
            "filter_user_freq.json",
            "user_suppressed_words.json",
            "user_relative_ordering.json"
        ]

        // Snapshot records for each payload (ignore lastModified).
        func snapshot<T: Codable & Equatable>(file: URL, type: T.Type) throws -> [String: T] {
            let sf = try SyncPayloadFixtures.readRemoteSyncFile(at: file, type: type)
            return sf.records
        }

        // Read cloud state before the second sync.
        let learningBefore = try snapshot(
            file: harness.iCloudDocuments.appendingPathComponent(payloadNames[0]),
            type: LearningRecord.self
        )
        let favBefore = try snapshot(
            file: harness.iCloudDocuments.appendingPathComponent(payloadNames[1]),
            type: FavoriteRecord.self
        )

        try harness.runSyncCycle(device: 1)

        let learningAfter = try snapshot(
            file: harness.iCloudDocuments.appendingPathComponent(payloadNames[0]),
            type: LearningRecord.self
        )
        let favAfter = try snapshot(
            file: harness.iCloudDocuments.appendingPathComponent(payloadNames[1]),
            type: FavoriteRecord.self
        )

        XCTAssertEqual(learningBefore.keys.sorted(), learningAfter.keys.sorted())
        XCTAssertEqual(favBefore.keys.sorted(), favAfter.keys.sorted())
        XCTAssertEqual(learningAfter[String(0xDEADBEEF)]?.accessCount, 5)
        XCTAssertEqual(favAfter["确定性词"]?.addedTimestamp, 1_700_000_000)
    }
}

// Codable-conforming records so the Equatable requirement of the snapshot
// helper works with them. All 5 record types already conform to Codable;
// we just need Equatable synthesized via conformance extensions.
extension LearningRecord: Equatable {
    public static func == (lhs: LearningRecord, rhs: LearningRecord) -> Bool {
        lhs.accessCount == rhs.accessCount
            && lhs.lastAccessTimestamp == rhs.lastAccessTimestamp
            && lhs.totalScore == rhs.totalScore
    }
}

extension FavoriteRecord: Equatable {
    public static func == (lhs: FavoriteRecord, rhs: FavoriteRecord) -> Bool {
        lhs.wubiCode == rhs.wubiCode
            && lhs.pinyinCode == rhs.pinyinCode
            && lhs.addedTimestamp == rhs.addedTimestamp
            && lhs.isDeleted == rhs.isDeleted
    }
}
