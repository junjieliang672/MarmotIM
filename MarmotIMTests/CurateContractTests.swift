import XCTest
import SQLite3
@testable import MarmotIM

/// The input method and tools/marmot_curate.py share two tables in
/// behavior.db: Swift writes `events` and Python reads it; Python writes
/// `proposals` and Swift reads it. Each side's own tests use a hand-copied
/// schema, so a renamed column on either side would pass both suites. These
/// tests run the real tool against the real Swift code.
final class CurateContractTests: XCTestCase {

    private var dir: URL!
    private var behaviorDB: URL { dir.appendingPathComponent("behavior.db") }
    private var dictionaryDB: URL { dir.appendingPathComponent("dictionary.db") }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let tool = repoRoot.appendingPathComponent("tools/marmot_curate.py")
    private static let python = URL(fileURLWithPath: "/usr/bin/python3")

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.python.path), "python3 not available")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("marmotim-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir = dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    private func runTool(_ arguments: [String]) throws -> [String: Any] {
        let process = Process()
        process.executableURL = Self.python
        process.arguments = [Self.tool.path, "--behavior-db", behaviorDB.path,
                             "--dictionary-db", dictionaryDB.path] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(errorText, "", "tool wrote to stderr")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Events written by BehaviorLog are understood by the tool
    func testToolReadsEventsWrittenByTheInputMethod() throws {
        let log = BehaviorLog(path: behaviorDB, policy: { _ in true }, retentionDays: { 3650 })
        let now = Date().timeIntervalSince1970
        // 输入 then 法, three times a day on three days, each followed by punctuation
        for day in 0..<3 {
            for n in 0..<3 {
                let t = now - Double(day) * 86400 - Double(n) * 100
                log.record(BehaviorEvent(kind: .select, timestamp: t, app: "com.apple.TextEdit", code: "lwty",
                                         codeType: InputCodeType.wubi.behaviorLabel, text: "输入", rank: 0,
                                         trigger: "space", page: 0,
                                         candidates: [BehaviorCandidate(t: "输入", b: false, j: false)]))
                log.record(BehaviorEvent(kind: .select, timestamp: t + 1, app: "com.apple.TextEdit", code: "if",
                                         codeType: InputCodeType.wubi.behaviorLabel, text: "法", rank: 1,
                                         trigger: "number", page: 0,
                                         candidates: [BehaviorCandidate(t: "去", b: true, j: false),
                                                      BehaviorCandidate(t: "法", b: false, j: false)]))
                log.record(BehaviorEvent(kind: .boundary, timestamp: t + 2, app: "com.apple.TextEdit", trigger: "punct"))
            }
        }
        // After the last run: these kinds end a run of consecutive commits,
        // so placed between 输入 and 法 they would (correctly) split one
        log.record(BehaviorEvent(kind: .raw, timestamp: now + 10, text: "marmotctl", trigger: "shift", count: 0))
        log.record(BehaviorEvent(kind: .abandon, timestamp: now + 11, code: "xyzq", trigger: "backspace", count: 0))
        log.record(BehaviorEvent(kind: .delete, timestamp: now + 12, text: "法", count: 1))
        log.waitUntilIdle()

        let status = try runTool(["status"])
        XCTAssertEqual(status["events"] as? Int, 30)
        XCTAssertEqual(status["by_kind"] as? [String: Int],
                       ["select": 18, "break": 9, "raw": 1, "abandon": 1, "delete": 1])

        let userDict = try runTool(["candidates", "user-dict"])
        let phrases = try XCTUnwrap(userDict["phrases"] as? [[String: Any]])
        let phrase = try XCTUnwrap(phrases.first { $0["text"] as? String == "输入法" })
        XCTAssertEqual(phrase["count"] as? Int, 9)
        XCTAssertEqual(phrase["typed_as"] as? [String], ["输入", "法"])

        // 去 was ranked first by learning and skipped every time
        let suppress = try runTool(["candidates", "suppress"])
        let skipped = try XCTUnwrap((suppress["suppress"] as? [[String: Any]])?.first { $0["text"] as? String == "去" })
        XCTAssertEqual(skipped["skipped_when_first_by_learning"] as? Int, 9)

        let order = try runTool(["candidates", "order"])
        let pair = try XCTUnwrap((order["order"] as? [[String: Any]])?.first)
        XCTAssertEqual(pair["a"] as? String, "法")
        XCTAssertEqual(pair["b"] as? String, "去")
        XCTAssertEqual(pair["picked_a_past_b"] as? Int, 9)
    }

    /// Decisions written by the tool are applied by ProposalApplier, and the
    /// tool reads back the status the applier wrote
    func testInputMethodAppliesDecisionsWrittenByTheTool() throws {
        let decisions: [[String: Any]] = [
            ["kind": "add_word", "decision": "accept", "text": "输入法", "wubi": "ltif", "pinyin": "shurufa",
             "stats": ["count": 9]],
            ["kind": "add_word", "decision": "accept", "text": "GitHub", "english": true],
            ["kind": "suppress", "decision": "accept", "text": "去"],
            ["kind": "add_rule", "decision": "accept", "a": "法", "b": "去"],
            ["kind": "add_rule", "decision": "accept", "a": "丁", "b": "丙"],
            ["kind": "unsuppress", "decision": "reject", "text": "将领"],
        ]
        let file = dir.appendingPathComponent("decisions.json")
        try JSONSerialization.data(withJSONObject: decisions).write(to: file)

        let written = try runTool(["decide", "--file", file.path, "--no-notify"])
        XCTAssertEqual(written["written"] as? Int, 6)

        var calls: [String] = []
        let actions = ProposalActions(
            addWord: { text, wubi, pinyin in calls.append("add \(text) \(wubi ?? "-") \(pinyin ?? "-")"); return nil },
            removeWord: { text in calls.append("remove \(text)"); return nil },
            suppress: { text in calls.append("suppress \(text)"); return nil },
            unsuppress: { text in calls.append("unsuppress \(text)"); return nil },
            addRule: { a, b in
                calls.append("rule \(a)>\(b)")
                return a == "丁" ? "会和现有规则形成环" : nil
            },
            removeRule: { a, b in calls.append("unrule \(a)>\(b)"); return nil }
        )
        let result = ProposalApplier(path: behaviorDB, actions: actions).applyPending()

        XCTAssertEqual(result.applied, 4)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(calls, ["add 输入法 ltif shurufa", "add GitHub - github", "suppress 去", "rule 法>去", "rule 丁>丙"],
                       "the rejected decision is never applied")

        let history = try runTool(["history"])
        let proposals = try XCTUnwrap(history["proposals"] as? [[String: Any]])
        XCTAssertEqual(proposals.map { $0["status"] as? String },
                       ["applied", "applied", "applied", "applied", "failed", "rejected"])
        XCTAssertEqual(proposals[4]["error"] as? String, "会和现有规则形成环")
        XCTAssertNotNil(proposals[0]["applied_at"] as? Double)
    }
}
