import XCTest
import SQLite3
@testable import MarmotIM

/// VocabularyDatabase tests migrated to per-test isolated DBs via
/// `VocabularyDatabase.makeForTests(path:)` (spec-004 T1, I-MIG-VDB-01).
///
/// Prior to this migration every test poked the production singleton
/// which wrote to `~/Library/Application Support/MarmotIM/dictionary.db`
/// — polluting the user's real dictionary on every `swift test` run.
/// Each test now operates against a fresh tempDir DB; setUp creates it,
/// tearDown removes it. See spec-004 decision 001-scope-of-legacy-migration.
final class VocabularyDatabaseTests: XCTestCase {

    private var tempDir: URL!
    private var db: VocabularyDatabase!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-vdb-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = VocabularyDatabase.makeForTests(path: tempDir.appendingPathComponent("test.db"))
    }

    override func tearDown() {
        db = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Entry Tests

    func testInsertAndRetrieveEntry() {
        let entry = DictionaryEntry(
            id: 99999,
            text: "测试",
            pinyin: "ceshi",
            wubi: "aaaa",
            wubiBaseFrequency: 50000,
            pinyinBaseFrequency: 50000,
            source: EntrySource.user.rawValue,
            length: 2
        )

        // Insert
        let inserted = db.insertEntry(entry)
        XCTAssertTrue(inserted)

        // Retrieve
        let retrieved = db.getEntry(id: 99999)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.text, "测试")
        XCTAssertEqual(retrieved?.pinyin, "ceshi")
        XCTAssertEqual(retrieved?.wubi, "aaaa")
    }

    func testDeleteEntry() {
        let entry = DictionaryEntry(
            id: 99998,
            text: "删除测试",
            pinyin: "shanchueshi",
            wubi: nil,
            wubiBaseFrequency: 10000,
            pinyinBaseFrequency: 10000,
            source: EntrySource.user.rawValue,
            length: 4
        )

        // Insert
        _ = db.insertEntry(entry)

        // Delete
        let deleted = db.deleteEntry(id: 99998)
        XCTAssertTrue(deleted)

        // Verify deleted
        let retrieved = db.getEntry(id: 99998)
        XCTAssertNil(retrieved)
    }

    // MARK: - Index Tests

    func testPinyinIndex() {
        // pinyin_index has FK to entries(id) — insert the parent row first
        // (previously the shared DB happened to contain the id already).
        let parent = DictionaryEntry(
            id: 88888, text: "索引测试", pinyin: "suoyinceshi", wubi: nil,
            wubiBaseFrequency: 1, pinyinBaseFrequency: 1,
            source: EntrySource.user.rawValue, length: 4
        )
        _ = db.insertEntry(parent)

        // Insert pinyin index
        let inserted = db.insertPinyinIndex(code: "testpy", entryId: 88888)
        XCTAssertTrue(inserted)

        // Load all indexes and verify
        let indexes = db.loadAllPinyinIndexes()
        let found = indexes.contains { $0.code == "testpy" && $0.entryId == 88888 }
        XCTAssertTrue(found)
    }

    func testWubiIndex() {
        // wubi_index has FK to entries(id) — insert the parent row first.
        let parent = DictionaryEntry(
            id: 77777, text: "索引测试2", pinyin: "suoyinceshi2", wubi: "testwb",
            wubiBaseFrequency: 1, pinyinBaseFrequency: 1,
            source: EntrySource.user.rawValue, length: 5
        )
        _ = db.insertEntry(parent)

        // Insert wubi index
        let inserted = db.insertWubiIndex(code: "testwb", entryId: 77777)
        XCTAssertTrue(inserted)

        // Load all indexes and verify
        let indexes = db.loadAllWubiIndexes()
        let found = indexes.contains { $0.code == "testwb" && $0.entryId == 77777 }
        XCTAssertTrue(found)
    }

    // MARK: - User Learning Tests

    func testRecordSelection() {
        // Use unique entry ID to avoid conflicts
        let entryId = UInt32.random(in: 0xA0000000...0xAFFFFFFF)

        // Record a selection
        let recorded = db.recordSelection(entryId: entryId, totalScore: 12345.67)
        XCTAssertTrue(recorded)

        // Load and verify
        let learningData = db.loadAllUserLearning()
        if let data = learningData[entryId] {
            XCTAssertEqual(data.accessCount, 1)
            XCTAssertGreaterThan(data.lastAccessTimestamp, 0)
        }
    }

    func testRecordMultipleSelections() {
        // Use unique entry ID to avoid conflicts
        let entryId = UInt32.random(in: 0xB0000000...0xBFFFFFFF)

        // Record multiple selections
        _ = db.recordSelection(entryId: entryId, totalScore: 100)
        _ = db.recordSelection(entryId: entryId, totalScore: 200)
        _ = db.recordSelection(entryId: entryId, totalScore: 300)

        // Load and verify count incremented
        let learningData = db.loadAllUserLearning()
        if let data = learningData[entryId] {
            XCTAssertEqual(data.accessCount, 3)
        }
    }

    /// FI-001 (spec-001): full round-trip regression guard for recordSelection.
    ///
    /// Root cause recap: the bundled dictionary.db historically shipped
    /// user_learning with `FOREIGN KEY(entry_id) REFERENCES entries(id) ON
    /// DELETE CASCADE`, while the Swift source omitted the FK because user
    /// learning must survive dictionary rebuilds. That drift silently failed
    /// recordSelection whenever the id was not present in `entries` and lost
    /// user writes on every dictionary update. Schema v7 drops the FK.
    ///
    /// This test locks the invariant: a recordSelection for an arbitrary id
    /// must succeed, be retrievable, and the ON CONFLICT UPDATE path must
    /// actually increment access_count. If anyone re-adds the FK (e.g. by
    /// regenerating the bundled DB from tools/build_dictionary.py without
    /// also dropping it there), this test will fail immediately.
    ///
    /// Migration note (spec-004 T1): This test is preserved verbatim in
    /// intent but now runs against an isolated makeForTests DB. The FK
    /// regression would still trip here because makeForTests runs
    /// performMigrations() which applies v7 to the test DB.
    func testRecordSelection_roundTrip() {
        // Use an id that is guaranteed NOT to exist in entries(id). If the
        // FK ever comes back, INSERT will fail with SQLITE_CONSTRAINT_FOREIGNKEY.
        let entryId = UInt32.random(in: 0xC0000000...0xCFFFFFFF)

        // 1) First recordSelection must return true.
        let firstWrite = db.recordSelection(entryId: entryId, totalScore: 42.0)
        XCTAssertTrue(firstWrite, "recordSelection must succeed for an arbitrary entry id (FI-001)")

        // 2) The row must be visible via loadAllUserLearning() with accessCount=1.
        let after1 = db.loadAllUserLearning()
        guard let row1 = after1[entryId] else {
            XCTFail("loadAllUserLearning() missing the entry after a successful recordSelection")
            return
        }
        XCTAssertEqual(row1.accessCount, 1, "accessCount must be 1 after first selection")
        XCTAssertGreaterThan(row1.lastAccessTimestamp, 0, "timestamp must be populated")

        // 3) Second recordSelection must take the ON CONFLICT UPDATE path and
        //    bump accessCount to 2.
        let secondWrite = db.recordSelection(entryId: entryId, totalScore: 84.0)
        XCTAssertTrue(secondWrite, "second recordSelection (UPSERT path) must succeed")
        let after2 = db.loadAllUserLearning()
        guard let row2 = after2[entryId] else {
            XCTFail("row disappeared after second recordSelection")
            return
        }
        XCTAssertEqual(row2.accessCount, 2, "ON CONFLICT UPDATE must increment accessCount to 2")
    }

    // MARK: - Batch Operations

    func testBatchGetEntries() {
        // Insert test entries
        let entries = [
            DictionaryEntry(id: 44441, text: "批量1", pinyin: "piliang1", wubi: nil, wubiBaseFrequency: 1000, pinyinBaseFrequency: 1000, source: 3, length: 3),
            DictionaryEntry(id: 44442, text: "批量2", pinyin: "piliang2", wubi: nil, wubiBaseFrequency: 2000, pinyinBaseFrequency: 2000, source: 3, length: 3),
            DictionaryEntry(id: 44443, text: "批量3", pinyin: "piliang3", wubi: nil, wubiBaseFrequency: 3000, pinyinBaseFrequency: 3000, source: 3, length: 3)
        ]

        for entry in entries {
            _ = db.insertEntry(entry)
        }

        // Batch retrieve
        let ids: [UInt32] = [44441, 44442, 44443]
        let retrieved = db.getEntries(ids: ids)

        XCTAssertEqual(retrieved.count, 3)
        XCTAssertEqual(retrieved[44441]?.text, "批量1")
        XCTAssertEqual(retrieved[44442]?.text, "批量2")
        XCTAssertEqual(retrieved[44443]?.text, "批量3")
    }

    // MARK: - Entry Count

    func testGetEntryCount() {
        // Isolated DB starts at a known state; insertions add exactly N.
        let initialCount = db.getEntryCount()

        let uniqueId = UInt32.random(in: 0x90000000...0xFFFFFFFF)
        let entry = DictionaryEntry(
            id: uniqueId,
            text: "计数测试",
            pinyin: "jishuceshi",
            wubi: nil,
            wubiBaseFrequency: 1000,
            pinyinBaseFrequency: 1000,
            source: 3,
            length: 4
        )
        let inserted = db.insertEntry(entry)
        XCTAssertTrue(inserted, "Entry should be inserted successfully")

        let newCount = db.getEntryCount()
        XCTAssertEqual(newCount, initialCount + 1)
    }
}
