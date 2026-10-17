import XCTest
import SQLite3
@testable import MarmotIM

/// 英文置顶词: the user_english_first_words store that replaced
/// user_suppressed_words in schema v10. Placement is covered by
/// CandidateRankerTests (Part 10).
final class EnglishFirstWordsTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-english-first-\(UUID().uuidString)")
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

    private func tableExists(_ db: VocabularyDatabase, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)'"
        guard sqlite3_prepare_v2(db.getConnection(), sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// A v9 database still has the suppressed-words table. Its rows meant
    /// something else, so none of them become English-first words.
    func testV10MigrationDropsSuppressedWordsAndCarriesNothingOver() {
        let path = tempDir.appendingPathComponent("v9.db")
        exec(path, """
            CREATE TABLE schema_version (version INTEGER PRIMARY KEY);
            INSERT INTO schema_version (version) VALUES (9);
            CREATE TABLE user_suppressed_words (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL UNIQUE,
                suppressed_timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                is_deleted INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO user_suppressed_words (text, suppressed_timestamp, is_deleted) VALUES ('swim', 100, 0);
            """)

        let db = VocabularyDatabase.makeForTests(path: path)

        XCTAssertFalse(tableExists(db, "user_suppressed_words"))
        XCTAssertTrue(tableExists(db, "user_english_first_words"))
        XCTAssertEqual(db.getEnglishFirstWords(), [])
    }

    func testWordsAreStoredLowercasedAndRemovedByAnyCase() {
        let db = VocabularyDatabase.makeForTests(path: tempDir.appendingPathComponent("test.db"))

        XCTAssertTrue(db.addEnglishFirstWord(text: "Agent"))
        XCTAssertEqual(db.getEnglishFirstWords(), ["agent"])
        XCTAssertTrue(db.isEnglishFirstWord(text: "AGENT"))

        XCTAssertTrue(db.removeEnglishFirstWord(text: "AGENT"))
        XCTAssertEqual(db.getEnglishFirstWords(), [])

        // Adding again revives the same row
        XCTAssertTrue(db.addEnglishFirstWord(text: "agent"))
        XCTAssertEqual(db.getEnglishFirstWordsWithDetails().map { $0.text }, ["agent"])
    }
}
