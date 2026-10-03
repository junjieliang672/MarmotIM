import XCTest
import SQLite3
@testable import MarmotIM

/// iCloud sync batch 1: user_favorites unique by text (v9), user-entry id
/// allocation helpers, and index cleanup on deleteEntry.
final class UserFavoritesDedupTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-fav-dedup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        super.tearDown()
    }

    private func exec(_ path: URL, _ sql: String) {
        var conn: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &conn), SQLITE_OK)
        defer { sqlite3_close(conn) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(conn, sql, nil, nil, &err) != SQLITE_OK {
            XCTFail("SQL failed: \(err.map { String(cString: $0) } ?? "?")")
            sqlite3_free(err)
        }
    }

    /// A v8 database where one word has an active row (pinyin NULL) and a
    /// newer tombstone row (wubi NULL) — the shape sync used to produce.
    func testV9MigrationCollapsesDuplicateRowsToNewest() {
        let path = tempDir.appendingPathComponent("v8.db")
        exec(path, """
            CREATE TABLE schema_version (version INTEGER PRIMARY KEY);
            INSERT INTO schema_version (version) VALUES (8);
            CREATE TABLE user_favorites (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL,
                wubi_code TEXT,
                pinyin_code TEXT,
                added_timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                is_deleted INTEGER NOT NULL DEFAULT 0,
                UNIQUE(text, wubi_code, pinyin_code)
            );
            INSERT INTO user_favorites (text, wubi_code, pinyin_code, added_timestamp, is_deleted)
                VALUES ('肓扫', 'yerv', NULL, 100, 0);
            INSERT INTO user_favorites (text, wubi_code, pinyin_code, added_timestamp, is_deleted)
                VALUES ('肓扫', NULL, 'huangsao', 200, 1);
            INSERT INTO user_favorites (text, wubi_code, pinyin_code, added_timestamp, is_deleted)
                VALUES ('涉政', 'ihgh', 'shezheng', 150, 0);
            """)

        let db = VocabularyDatabase.makeForTests(path: path)

        XCTAssertEqual(db.getUserFavorites().map { $0.text }, ["涉政"],
                       "the newer tombstone must win, so 肓扫 is no longer active")
        let deleted = db.getDeletedUserFavorites()
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?.text, "肓扫")
        XCTAssertEqual(deleted.first?.wubiCode, "yerv", "NULL code is filled from the other row")
        XCTAssertEqual(deleted.first?.pinyinCode, "huangsao")

        // Re-adding with one code NULL updates the single row instead of adding one
        XCTAssertTrue(db.addUserFavorite(text: "肓扫", wubiCode: "yerv", pinyinCode: nil))
        XCTAssertEqual(Set(db.getUserFavorites().map { $0.text }), ["涉政", "肓扫"])
        XCTAssertTrue(db.getDeletedUserFavorites().isEmpty)
    }

    func testUserEntryLookupSkipsSystemEntryAndDeleteClearsIndexes() {
        let db = VocabularyDatabase.makeForTests(path: tempDir.appendingPathComponent("t.db"))
        let userStart: UInt32 = 0x80000000

        let system = DictionaryEntry(id: 42, text: "豆包", pinyin: "doubao", wubi: "gkqn",
                                     wubiBaseFrequency: 35000, pinyinBaseFrequency: 50000, source: 1, length: 2)
        let user1 = DictionaryEntry(id: userStart, text: "豆包", pinyin: "", wubi: "gkqn",
                                    wubiBaseFrequency: 65000, pinyinBaseFrequency: 65000, source: 3, length: 2)
        let user2 = DictionaryEntry(id: userStart + 1, text: "豆包", pinyin: "doubao", wubi: nil,
                                    wubiBaseFrequency: 65000, pinyinBaseFrequency: 65000, source: 3, length: 2)
        for e in [system, user1, user2] { XCTAssertTrue(db.insertEntry(e)) }
        XCTAssertTrue(db.insertWubiIndex(code: "gkqn", entryId: user1.id))

        XCTAssertEqual(Set(db.getEntriesByText(text: "豆包", minId: userStart).map { $0.id }),
                       [user1.id, user2.id], "system entry 42 must not be returned")
        XCTAssertEqual(db.maxEntryId(atLeast: userStart), userStart + 1)

        XCTAssertTrue(db.deleteEntry(id: user1.id))
        XCTAssertNil(db.getEntry(id: user1.id))
        var conn: OpaquePointer?
        sqlite3_open(tempDir.appendingPathComponent("t.db").path, &conn)
        defer { sqlite3_close(conn) }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(conn, "SELECT COUNT(*) FROM wubi_index WHERE entry_id = \(user1.id)", -1, &stmt, nil)
        sqlite3_step(stmt)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0, "orphan index rows must be removed with the entry")
        sqlite3_finalize(stmt)

        XCTAssertNotNil(db.getEntry(id: 42), "system entry untouched")
    }

    func testMaxEntryIdNilWhenNoUserEntries() {
        let db = VocabularyDatabase.makeForTests(path: tempDir.appendingPathComponent("e.db"))
        XCTAssertNil(db.maxEntryId(atLeast: 0x80000000))
    }
}
