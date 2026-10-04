import XCTest
import SQLite3
@testable import MarmotIM

/// The behaviour log behind 整理词库: what is written, and when nothing is.
final class BehaviorLogTests: XCTestCase {

    private var dir: URL!
    private var path: URL { dir.appendingPathComponent("behavior.db") }

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("marmotim-behavior-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func rows(_ sql: String) -> [[String?]] {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(stmt)).map { i in
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            })
        }
        return result
    }

    // MARK: - What is written

    func testSelectionIsWrittenWithCandidatesAndRank() throws {
        let log = BehaviorLog(path: path, policy: { _ in true })
        log.record(BehaviorEvent(
            kind: .select, timestamp: 1_790_000_000, app: "com.apple.TextEdit",
            code: "uqwy", codeType: "wubi", text: "交集", rank: 2, trigger: "number", page: 0,
            candidates: [BehaviorCandidate(t: "效仿", b: true, j: false),
                         BehaviorCandidate(t: "将领", b: false, j: false),
                         BehaviorCandidate(t: "交集", b: false, j: false)]))
        log.waitUntilIdle()

        let row = try XCTUnwrap(rows("SELECT kind, app, code, code_type, text, rank, trigger, page, candidates FROM events").first)
        XCTAssertEqual(Array(row.prefix(8)), ["select", "com.apple.TextEdit", "uqwy", "wubi", "交集", "2", "number", "0"])
        let candidates = try JSONDecoder().decode([BehaviorCandidate].self, from: Data(try XCTUnwrap(row[8]).utf8))
        XCTAssertEqual(candidates.map(\.t), ["效仿", "将领", "交集"])
        XCTAssertEqual(candidates.map(\.b), [true, false, false], "which candidate led only through learning boosts")
    }

    func testRawAbandonDeleteAndBreakEvents() {
        let log = BehaviorLog(path: path, policy: { _ in true })
        log.record(BehaviorEvent(kind: .raw, text: "kubectl", trigger: "shift", count: 0))
        log.record(BehaviorEvent(kind: .abandon, code: "xyzq", trigger: "escape", count: 0))
        log.record(BehaviorEvent(kind: .delete, text: "交集", count: 2))
        log.record(BehaviorEvent(kind: .boundary, trigger: "punct"))
        log.waitUntilIdle()

        XCTAssertEqual(rows("SELECT kind, text, code, trigger, n FROM events ORDER BY id"), [
            ["raw", "kubectl", nil, "shift", "0"],
            ["abandon", nil, "xyzq", "escape", "0"],
            ["delete", "交集", nil, nil, "2"],
            ["break", nil, nil, "punct", nil],
        ])
    }

    // MARK: - When nothing is written

    func testPolicyRule() {
        let excluded = ["com.1password.1password"]
        XCTAssertTrue(BehaviorLog.shouldRecord(enabled: true, secureInput: false, app: "com.apple.TextEdit", excludedApps: excluded))
        XCTAssertFalse(BehaviorLog.shouldRecord(enabled: false, secureInput: false, app: "com.apple.TextEdit", excludedApps: excluded),
                       "off until the user turns recording on")
        XCTAssertFalse(BehaviorLog.shouldRecord(enabled: true, secureInput: true, app: "com.apple.TextEdit", excludedApps: excluded),
                       "password fields")
        XCTAssertFalse(BehaviorLog.shouldRecord(enabled: true, secureInput: false, app: "com.1password.1password", excludedApps: excluded))
        XCTAssertTrue(BehaviorLog.shouldRecord(enabled: true, secureInput: false, app: nil, excludedApps: excluded),
                      "an unknown app is not an excluded app")
    }

    func testNothingIsWrittenWhenPolicyRefuses() {
        let log = BehaviorLog(path: path, policy: { app in app != "com.1password.1password" })
        log.record(BehaviorEvent(kind: .raw, app: "com.1password.1password", text: "hunter2", trigger: "enter"))
        log.waitUntilIdle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "not even the database file is created")
        XCTAssertEqual(log.summary().events, 0)
    }

    func testDefaultConfigDoesNotRecord() {
        XCTAssertFalse(CuratorConfig.default.recordingEnabled)
        XCTAssertFalse(AppConfig.default.curator.recordingEnabled)
    }

    func testCuratorConfigSurvivesMissingFields() throws {
        let decoded = try JSONDecoder().decode(CuratorConfig.self, from: Data(#"{"recordingEnabled":true}"#.utf8))
        XCTAssertTrue(decoded.recordingEnabled)
        XCTAssertEqual(decoded.excludedApps, CuratorConfig.defaultExcludedApps)
        XCTAssertEqual(decoded.retentionDays, 60)
    }

    // MARK: - Retention and clearing

    func testPurgeRemovesOnlyExpiredEvents() {
        let now: TimeInterval = 1_790_000_000
        let log = BehaviorLog(path: path, policy: { _ in true }, retentionDays: { 60 })
        log.record(BehaviorEvent(kind: .raw, timestamp: now - 61 * 86400, text: "old"))
        log.record(BehaviorEvent(kind: .raw, timestamp: now - 59 * 86400, text: "kept"))
        log.waitUntilIdle()

        log.purgeExpired(now: now)

        XCTAssertEqual(rows("SELECT text FROM events"), [["kept"]])
    }

    func testSummaryAndClear() {
        let log = BehaviorLog(path: path, policy: { _ in true }, retentionDays: { 3650 })
        let day: TimeInterval = 86400
        log.record(BehaviorEvent(kind: .raw, timestamp: 1_790_000_000, text: "a"))
        log.record(BehaviorEvent(kind: .raw, timestamp: 1_790_000_100, text: "b"))
        log.record(BehaviorEvent(kind: .raw, timestamp: 1_790_000_000 + 3 * day, text: "c"))
        log.waitUntilIdle()

        XCTAssertEqual(log.summary(), BehaviorLog.Summary(events: 3, days: 2, firstTimestamp: 1_790_000_000))

        log.clear()
        XCTAssertEqual(log.summary().events, 0)
    }

    // MARK: - Backspaces after a commit

    func testBackspacesRightAfterCommitCountAgainstIt() {
        var tracker = CommitCorrectionTracker()
        XCTAssertNil(tracker.didCommit("交集", at: 100))
        tracker.didBackspace(at: 101)
        tracker.didBackspace(at: 101.5)

        let correction = tracker.flush()
        XCTAssertEqual(correction?.text, "交集")
        XCTAssertEqual(correction?.backspaces, 2)
        XCTAssertNil(tracker.flush(), "reported once")
    }

    func testNoCorrectionWithoutBackspace() {
        var tracker = CommitCorrectionTracker()
        _ = tracker.didCommit("交集", at: 100)
        XCTAssertNil(tracker.flush(), "the next key was not a backspace")
        tracker.didBackspace(at: 101)
        XCTAssertNil(tracker.flush(), "another key came in between, so this backspace is unrelated")
    }

    func testBackspaceLongAfterCommitIsUnrelated() {
        var tracker = CommitCorrectionTracker()
        _ = tracker.didCommit("交集", at: 100)
        tracker.didBackspace(at: 100 + CommitCorrectionTracker.window + 1)
        XCTAssertNil(tracker.flush())
    }

    func testNextCommitReportsThePreviousCorrection() {
        var tracker = CommitCorrectionTracker()
        _ = tracker.didCommit("将领", at: 100)
        tracker.didBackspace(at: 101)
        tracker.didBackspace(at: 101.2)
        let correction = tracker.didCommit("交集", at: 103)
        XCTAssertEqual(correction?.text, "将领")
        XCTAssertEqual(correction?.backspaces, 2)
    }
}
