import Foundation
import SQLite3
@testable import MarmotIM

/// Test infrastructure for spec-003's Level-5 dual-device sync scenarios.
///
/// Creates two isolated `VocabularyDatabase.makeForTests` instances in
/// separate temp directories and a third temp directory that stands in
/// for the shared iCloud Documents container. Drives real sync merges
/// via `iCloudSyncManager.shared.syncOnce(documentsURL:dbPath:)` — no
/// iCloud entitlement required (decision 004).
///
/// Usage:
///
///     let harness = DualDeviceSyncHarness()
///     harness.device1.addRelativeOrderingRule(wordA: "A", wordB: "B")
///     harness.runSyncCycle(device: 1)
///     harness.runSyncCycle(device: 2)
///     XCTAssertEqual(harness.device2.listRelativeOrderingRules().count, 1)
///     harness.tearDown()
final class DualDeviceSyncHarness {

    /// Root temp dir; cleaned up by `tearDown()`.
    let root: URL
    /// Shared "iCloud" documents directory.
    let iCloudDocuments: URL
    /// Device 1's local DB.
    let device1: VocabularyDatabase
    /// Device 2's local DB.
    let device2: VocabularyDatabase
    /// On-disk paths (used by syncOnce).
    let device1DBPath: URL
    let device2DBPath: URL

    /// Ensures each harness instance has a unique tempdir so parallel tests
    /// don't collide. Named with UUID for safety.
    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-dualdevice-\(UUID().uuidString)")
        iCloudDocuments = root.appendingPathComponent("icloud")
        let d1Dir = root.appendingPathComponent("device1")
        let d2Dir = root.appendingPathComponent("device2")

        for dir in [iCloudDocuments, d1Dir, d2Dir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        device1DBPath = d1Dir.appendingPathComponent("dictionary.db")
        device2DBPath = d2Dir.appendingPathComponent("dictionary.db")
        device1 = VocabularyDatabase.makeForTests(path: device1DBPath)
        device2 = VocabularyDatabase.makeForTests(path: device2DBPath)
    }

    /// Drive one sync cycle for the given device (1 or 2). Uses the real
    /// SyncMerger code path via iCloudSyncManager.syncOnce, writing JSON
    /// files into the shared iCloudDocuments directory.
    ///
    /// Note: iCloudSyncManager is a singleton; serialize test execution
    /// by not running harness tests in parallel (default for XCTest).
    func runSyncCycle(device: Int) throws {
        let dbPath: URL
        switch device {
        case 1: dbPath = device1DBPath
        case 2: dbPath = device2DBPath
        default: fatalError("unknown device \(device) — expected 1 or 2")
        }
        // Checkpoint WAL on the in-process DB instance so the sqlite3_open
        // in syncOnce sees the latest user data.
        switch device {
        case 1: device1.checkpoint()
        case 2: device2.checkpoint()
        default: break
        }
        try iCloudSyncManager.shared.syncOnce(documentsURL: iCloudDocuments, dbPath: dbPath)
    }

    /// Remove all temp artifacts. Call in XCTestCase.tearDown.
    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
