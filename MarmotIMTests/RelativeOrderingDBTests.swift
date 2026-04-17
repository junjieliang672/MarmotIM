import XCTest
@testable import MarmotIM

/// Integration tests for VocabularyDatabase's relative-ordering CRUD.
/// Uses `VocabularyDatabase.makeForTests(path:)` (decision 005 testability
/// hook) to get an isolated on-disk DB per test.
final class RelativeOrderingDBTests: XCTestCase {

    private var tempDir: URL!
    private var db: VocabularyDatabase!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-relorder-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("test.db")
        db = VocabularyDatabase.makeForTests(path: dbPath)
    }

    override func tearDown() {
        db = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // I-RO-DB-01: add → list → remove round trip
    func testAddListRemoveRoundTrip() {
        let result = db.addRelativeOrderingRule(wordA: "你好", wordB: "世界")
        guard case .success(let rule) = result else {
            XCTFail("expected .success, got \(result)")
            return
        }
        XCTAssertGreaterThan(rule.id, 0)
        XCTAssertEqual(rule.wordA, "你好")
        XCTAssertEqual(rule.wordB, "世界")
        XCTAssertFalse(rule.isDeleted)

        let listed = db.listRelativeOrderingRules()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, rule.id)

        XCTAssertTrue(db.removeRelativeOrderingRule(ruleId: rule.id))

        XCTAssertTrue(db.listRelativeOrderingRules().isEmpty,
                      "active list should be empty after remove")

        let all = db.listRelativeOrderingRulesIncludingDeleted()
        XCTAssertEqual(all.count, 1,
                       "tombstone must be preserved for sync parity")
        XCTAssertTrue(all.first!.isDeleted)
    }

    // I-RO-DB-02: duplicate returns .duplicate
    func testDuplicateReturnsDuplicate() {
        let firstAdd = db.addRelativeOrderingRule(wordA: "apple", wordB: "banana")
        guard case .success = firstAdd else {
            XCTFail("first add must succeed")
            return
        }

        let secondAdd = db.addRelativeOrderingRule(wordA: "apple", wordB: "banana")
        guard case .failure(let err) = secondAdd else {
            XCTFail("second add must fail with .duplicate")
            return
        }
        XCTAssertEqual(err, .duplicate)
        XCTAssertEqual(db.listRelativeOrderingRules().count, 1,
                       "exactly one active row after duplicate attempt")
    }

    // I-RO-DB-03: direct cycle returns .cycle
    func testDirectCycleReturnsCycle() {
        _ = db.addRelativeOrderingRule(wordA: "A", wordB: "B")
        let result = db.addRelativeOrderingRule(wordA: "B", wordB: "A")
        guard case .failure(let err) = result else {
            XCTFail("expected .cycle failure")
            return
        }
        switch err {
        case .cycle(let path):
            XCTAssertFalse(path.isEmpty)
        default:
            XCTFail("expected .cycle, got \(err)")
        }

        // The rejected rule must NOT be persisted (neither active nor tombstoned).
        let all = db.listRelativeOrderingRulesIncludingDeleted()
        XCTAssertEqual(all.count, 1, "cycle-rejected insert must not persist")
    }

    // 3-hop cycle returns .cycle
    func testThreeHopCycleReturnsCycle() {
        _ = db.addRelativeOrderingRule(wordA: "A", wordB: "B")
        _ = db.addRelativeOrderingRule(wordA: "B", wordB: "C")
        let result = db.addRelativeOrderingRule(wordA: "C", wordB: "A")
        guard case .failure(.cycle) = result else {
            XCTFail("expected .cycle, got \(result)")
            return
        }
        XCTAssertEqual(db.listRelativeOrderingRules().count, 2,
                       "only the two pre-cycle rules should remain")
    }

    // I-RO-DB-04: revive a tombstone
    func testReviveTombstone() {
        let first = db.addRelativeOrderingRule(wordA: "X", wordB: "Y")
        guard case .success(let firstRule) = first else {
            XCTFail("first add must succeed")
            return
        }
        XCTAssertTrue(db.removeRelativeOrderingRule(ruleId: firstRule.id))

        let second = db.addRelativeOrderingRule(wordA: "X", wordB: "Y")
        guard case .success(let secondRule) = second else {
            XCTFail("re-add must succeed post-tombstone")
            return
        }
        XCTAssertEqual(secondRule.id, firstRule.id,
                       "UNIQUE(word_a, word_b) keeps the same row id on revival")
        XCTAssertFalse(secondRule.isDeleted)
        XCTAssertEqual(db.listRelativeOrderingRules().count, 1)
    }

    // I-RO-DB-06: normalization at the DB boundary
    func testInputNormalization() {
        let result = db.addRelativeOrderingRule(wordA: "  你好  ", wordB: "世界")
        guard case .success(let rule) = result else {
            XCTFail("expected success after normalization")
            return
        }
        XCTAssertEqual(rule.wordA, "你好")
        XCTAssertEqual(rule.wordB, "世界")

        // A second add with un-normalized input but matching after norm must be
        // rejected as duplicate.
        let dup = db.addRelativeOrderingRule(wordA: "你好", wordB: "  世界 ")
        XCTAssertEqual(Self.failureError(dup), .duplicate)
    }

    // I-RO-DB-07: empty input rejected (before SQL)
    func testEmptyInputRejected() {
        let emptyA = db.addRelativeOrderingRule(wordA: "", wordB: "x")
        XCTAssertEqual(Self.failureError(emptyA), .emptyInput)

        let emptyB = db.addRelativeOrderingRule(wordA: "y", wordB: "   ")
        XCTAssertEqual(Self.failureError(emptyB), .emptyInput)

        XCTAssertTrue(db.listRelativeOrderingRules().isEmpty)
    }

    // Identical words rejected before SQL
    func testIdenticalWordsRejected() {
        let identical = db.addRelativeOrderingRule(wordA: "同", wordB: "同")
        XCTAssertEqual(Self.failureError(identical), .identicalWords)
    }

    // Helper: extract the error from a Result<_, RelativeOrderingError> or nil.
    private static func failureError(_ result: Result<RelativeOrderingRule, RelativeOrderingError>) -> RelativeOrderingError? {
        if case .failure(let e) = result { return e }
        return nil
    }

    // I-RO-DB-05: schema v8 idempotent — reopening an existing v8 DB does nothing
    func testSchemaMigrationIdempotent() {
        XCTAssertEqual(db.getSchemaVersion(), 8, "fresh makeForTests DB must be at v8")

        // Re-open a second instance on the same path: version stays 8.
        let dbPath = tempDir.appendingPathComponent("test.db")
        let db2 = VocabularyDatabase.makeForTests(path: dbPath)
        XCTAssertEqual(db2.getSchemaVersion(), 8)
    }

    // loadRelativeOrderingCache returns lightweight pairs
    func testLoadRelativeOrderingCache() {
        _ = db.addRelativeOrderingRule(wordA: "A", wordB: "B")
        _ = db.addRelativeOrderingRule(wordA: "C", wordB: "D")

        let cache = db.loadRelativeOrderingCache()
        XCTAssertEqual(cache.count, 2)
        let pairs = Set(cache.map { "\($0.wordA)|\($0.wordB)" })
        XCTAssertEqual(pairs, ["A|B", "C|D"])
    }

    // Sync upsert bypasses cycle detection (docs: SyncMerger already pruned)
    func testUpsertForSync_bypassesCycleCheck() {
        // Normal path would reject B→A after A→B; sync path accepts it because
        // the SyncMerger owns cycle-breaking during merges.
        _ = db.addRelativeOrderingRule(wordA: "A", wordB: "B")
        let ok = db.upsertRelativeOrderingRuleForSync(
            wordA: "B", wordB: "A",
            createdAt: 100, updatedAt: 200, isDeleted: false
        )
        XCTAssertTrue(ok, "sync upsert must bypass cycle check")
        XCTAssertEqual(db.listRelativeOrderingRules().count, 2)
    }
}
