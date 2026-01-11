import XCTest
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
            baseFrequency: 50000,
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
            baseFrequency: 10000,
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

    // MARK: - Batch Operations

    func testBatchGetEntries() {
        let db = VocabularyDatabase.shared

        // Insert test entries
        let entries = [
            DictionaryEntry(id: 44441, text: "批量1", pinyin: "piliang1", wubi: nil, baseFrequency: 1000, source: 3, length: 3),
            DictionaryEntry(id: 44442, text: "批量2", pinyin: "piliang2", wubi: nil, baseFrequency: 2000, source: 3, length: 3),
            DictionaryEntry(id: 44443, text: "批量3", pinyin: "piliang3", wubi: nil, baseFrequency: 3000, source: 3, length: 3)
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
            baseFrequency: 1000,
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
