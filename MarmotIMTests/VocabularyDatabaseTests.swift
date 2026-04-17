import XCTest
import SQLite3
@testable import MarmotIM

final class VocabularyDatabaseTests: XCTestCase {

    var testDbPath: String!
    var db: VocabularyDatabase!

    override func setUp() {
        super.setUp()
        // Create a temporary database for testing
        testDbPath = NSTemporaryDirectory() + "test_vocabulary_\(UUID().uuidString).db"
    }

    override func tearDown() {
        // Clean up test database
        if let path = testDbPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        super.tearDown()
    }

    // MARK: - Entry Tests

    func testInsertAndRetrieveEntry() {
        let db = VocabularyDatabase.shared

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

        // Cleanup
        _ = db.deleteEntry(id: 99999)
    }

    func testDeleteEntry() {
        let db = VocabularyDatabase.shared

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
        let db = VocabularyDatabase.shared

        // Insert pinyin index
        let inserted = db.insertPinyinIndex(code: "testpy", entryId: 88888)
        XCTAssertTrue(inserted)

        // Load all indexes and verify
        let indexes = db.loadAllPinyinIndexes()
        let found = indexes.contains { $0.code == "testpy" && $0.entryId == 88888 }
        XCTAssertTrue(found)

        // Cleanup - delete the index entry directly via SQL would be complex,
        // so we'll leave it (test DB is temporary anyway in real test setup)
    }

    func testWubiIndex() {
        let db = VocabularyDatabase.shared

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
        let db = VocabularyDatabase.shared

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
        let db = VocabularyDatabase.shared

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
    func testRecordSelection_roundTrip() {
        let db = VocabularyDatabase.shared

        // Use an id that is guaranteed NOT to exist in entries(id). If the
        // FK ever comes back, INSERT will fail with SQLITE_CONSTRAINT_FOREIGNKEY.
        let entryId = UInt32.random(in: 0xC0000000...0xCFFFFFFF)

        // Clean slate — defensively remove any prior row so this test can run
        // repeatedly without relying on tearDown wiping the singleton.
        _ = db.getConnection().map { conn -> Void in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(conn, "DELETE FROM user_learning WHERE entry_id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(entryId))
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

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

        // Cleanup.
        _ = db.getConnection().map { conn -> Void in
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(conn, "DELETE FROM user_learning WHERE entry_id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(entryId))
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Batch Operations

    func testBatchGetEntries() {
        let db = VocabularyDatabase.shared

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

        // Cleanup
        for entry in entries {
            _ = db.deleteEntry(id: entry.id)
        }
    }

    // MARK: - Entry Count

    func testGetEntryCount() {
        let db = VocabularyDatabase.shared

        // Use a random unique ID to avoid conflicts with existing entries
        let uniqueId = UInt32.random(in: 0x90000000...0xFFFFFFFF)

        // Clean up first in case this ID exists from a previous failed test
        _ = db.deleteEntry(id: uniqueId)

        let initialCount = db.getEntryCount()

        // Insert an entry
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

        // Cleanup
        _ = db.deleteEntry(id: uniqueId)
    }
}
