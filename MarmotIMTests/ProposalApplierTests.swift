import XCTest
import SQLite3
@testable import MarmotIM

/// Decisions recorded by tools/marmot_curate.py are applied by the input
/// method. The store calls are faked here; the table shape is the tool's
/// (PROPOSALS_DDL in marmot_curate.py).
final class ProposalApplierTests: XCTestCase {

    private var dir: URL!
    private var path: URL { dir.appendingPathComponent("behavior.db") }
    private var calls: [String] = []

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("marmotim-proposals-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        calls = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func exec(_ sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            XCTFail(err.map { String(cString: $0) } ?? "sql failed")
            sqlite3_free(err)
        }
    }

    private func createTable() {
        exec("""
            CREATE TABLE IF NOT EXISTS proposals (
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, key TEXT NOT NULL, payload TEXT NOT NULL,
                status TEXT NOT NULL, reason TEXT, stats TEXT, decided_at REAL NOT NULL, applied_at REAL, error TEXT)
        """)
    }

    private func add(kind: String, payload: String, status: String = "accepted") {
        exec("INSERT INTO proposals (kind, key, payload, status, decided_at) VALUES ('\(kind)', 'k', '\(payload)', '\(status)', 1)")
    }

    private func statuses() -> [[String?]] {
        var db: OpaquePointer?
        sqlite3_open(path.path, &db)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT status, error, applied_at IS NOT NULL FROM proposals ORDER BY id", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((0..<3).map { i in sqlite3_column_text(stmt, Int32(i)).map { String(cString: $0) } })
        }
        return rows
    }

    private func actions(ruleError: String? = nil) -> ProposalActions {
        ProposalActions(
            addWord: { [unowned self] text, wubi, pinyin in
                self.calls.append("add \(text) \(wubi ?? "-") \(pinyin ?? "-")")
                return nil
            },
            removeWord: { [unowned self] text in self.calls.append("remove \(text)"); return nil },
            suppress: { [unowned self] text in self.calls.append("suppress \(text)"); return nil },
            unsuppress: { [unowned self] text in self.calls.append("unsuppress \(text)"); return nil },
            addRule: { [unowned self] a, b in self.calls.append("rule \(a)>\(b)"); return ruleError },
            removeRule: { [unowned self] a, b in self.calls.append("unrule \(a)>\(b)"); return nil }
        )
    }

    func testAcceptedDecisionsAreAppliedThroughTheStoreCalls() {
        createTable()
        add(kind: "add_word", payload: #"{"text":"输入法","wubi":"ltif","pinyin":"shurufa"}"#)
        add(kind: "remove_word", payload: #"{"text":"旧词"}"#)
        add(kind: "suppress", payload: #"{"text":"效仿"}"#)
        add(kind: "unsuppress", payload: #"{"text":"将领"}"#)
        add(kind: "add_rule", payload: #"{"a":"交集","b":"效仿"}"#)
        add(kind: "remove_rule", payload: #"{"a":"次","b":"交集"}"#)

        let result = ProposalApplier(path: path, actions: actions()).applyPending()

        XCTAssertEqual(result.applied, 6)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(calls, ["add 输入法 ltif shurufa", "remove 旧词", "suppress 效仿", "unsuppress 将领",
                               "rule 交集>效仿", "unrule 次>交集"])
        XCTAssertTrue(statuses().allSatisfy { $0[0] == "applied" && $0[1] == nil && $0[2] == "1" })
    }

    func testEnglishWordIsStoredUnderItsOwnLowercasedLetters() {
        createTable()
        add(kind: "add_word", payload: #"{"text":"GitHub","english":true}"#)

        ProposalApplier(path: path, actions: actions()).applyPending()

        XCTAssertEqual(calls, ["add GitHub - github"])
    }

    func testFailureIsRecordedWithItsReasonAndOthersStillApply() {
        createTable()
        add(kind: "add_rule", payload: #"{"a":"丁","b":"丙"}"#)
        add(kind: "suppress", payload: #"{"text":"效仿"}"#)

        let result = ProposalApplier(path: path, actions: actions(ruleError: "会和现有规则形成环：丙 → 戊 → 丁 → 丙"))
            .applyPending()

        XCTAssertEqual(result.applied, 1)
        XCTAssertEqual(result.failed, 1)
        let rows = statuses()
        XCTAssertEqual(rows[0][0], "failed")
        XCTAssertEqual(rows[0][1], "会和现有规则形成环：丙 → 戊 → 丁 → 丙")
        XCTAssertEqual(rows[1][0], "applied")
    }

    func testRejectedAndAlreadyAppliedRowsAreLeftAlone() {
        createTable()
        add(kind: "suppress", payload: #"{"text":"效仿"}"#, status: "rejected")
        add(kind: "suppress", payload: #"{"text":"将领"}"#, status: "applied")

        let applier = ProposalApplier(path: path, actions: actions())
        XCTAssertEqual(applier.applyPending().applied, 0)
        XCTAssertEqual(calls, [])

        // Applying twice never repeats a decision
        add(kind: "suppress", payload: #"{"text":"资信"}"#)
        applier.applyPending()
        applier.applyPending()
        XCTAssertEqual(calls, ["suppress 资信"])
    }

    func testUnknownKindAndMissingFieldsFailWithoutCallingAnything() {
        createTable()
        add(kind: "explode", payload: #"{"text":"x"}"#)
        add(kind: "add_rule", payload: #"{"a":"只有一个"}"#)

        let result = ProposalApplier(path: path, actions: actions()).applyPending()

        XCTAssertEqual(result.failed, 2)
        XCTAssertEqual(calls, [])
    }

    func testNoDatabaseOrNoTableIsNotAnError() {
        XCTAssertEqual(ProposalApplier(path: path, actions: actions()).applyPending().applied, 0)
        exec("CREATE TABLE events (id INTEGER PRIMARY KEY)")  // Log exists, tool never ran
        XCTAssertEqual(ProposalApplier(path: path, actions: actions()).applyPending().applied, 0)
    }
}
