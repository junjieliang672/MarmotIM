import Foundation
import SQLite3
@testable import MarmotIM

/// Low-level fixtures for spec-004 Part B dual-device sync tests.
///
/// These helpers write to / read from the *raw* sqlite file so tests can
/// set up arbitrary states (including edge cases that the public
/// VocabularyDatabase API would reject — empty text, negative
/// frequencies, arbitrary timestamps).
///
/// All helpers are namespaced under the `SyncPayloadFixtures` enum (no
/// instances) and take a `dbPath: URL` so they work with either
/// harness device's DB or with any isolated makeForTests(path:) DB.
///
/// Per spec-004 decision 005-dualDeviceSyncHarness-no-surface-change,
/// the DualDeviceSyncHarness itself stays unchanged — these fixtures
/// live alongside it as free functions.
enum SyncPayloadFixtures {

    // MARK: - user_learning

    /// Insert or replace a user_learning row. Returns true on SQLITE_DONE.
    @discardableResult
    static func insertUserLearning(dbPath: URL,
                                   entryId: Int64,
                                   accessCount: Int,
                                   lastAccessTimestamp: Int,
                                   totalScore: Double) -> Bool {
        return withOpenDB(dbPath, fallback: false) { db in
            let sql = """
                INSERT OR REPLACE INTO user_learning
                (entry_id, access_count, last_access_timestamp, total_score)
                VALUES (?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, entryId)
            sqlite3_bind_int(stmt, 2, Int32(accessCount))
            sqlite3_bind_int(stmt, 3, Int32(lastAccessTimestamp))
            sqlite3_bind_double(stmt, 4, totalScore)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    static func readUserLearning(dbPath: URL, entryId: Int64)
        -> (accessCount: Int, timestamp: Int, totalScore: Double)? {
        return withOpenDB(dbPath, fallback: nil) { db -> (accessCount: Int, timestamp: Int, totalScore: Double)? in
            let sql = "SELECT access_count, last_access_timestamp, total_score FROM user_learning WHERE entry_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, entryId)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return (Int(sqlite3_column_int(stmt, 0)),
                    Int(sqlite3_column_int(stmt, 1)),
                    sqlite3_column_double(stmt, 2))
        }
    }

    /// Hard-delete a user_learning row (used to probe "no tombstone"
    /// semantics — LEARN-04).
    @discardableResult
    static func deleteUserLearning(dbPath: URL, entryId: Int64) -> Bool {
        return withOpenDB(dbPath, fallback: false) { db in
            let sql = "DELETE FROM user_learning WHERE entry_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, entryId)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    // MARK: - user_favorites

    @discardableResult
    static func insertUserFavorite(dbPath: URL,
                                   text: String,
                                   wubiCode: String?,
                                   pinyinCode: String?,
                                   addedTimestamp: Int,
                                   isDeleted: Bool = false) -> Bool {
        return withOpenDB(dbPath, fallback: false) { db in
            let sql = """
                INSERT OR REPLACE INTO user_favorites
                (text, wubi_code, pinyin_code, added_timestamp, is_deleted)
                VALUES (?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            let textNS = text as NSString
            sqlite3_bind_text(stmt, 1, textNS.utf8String, -1, nil)
            if let w = wubiCode {
                let wNS = w as NSString
                sqlite3_bind_text(stmt, 2, wNS.utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let p = pinyinCode {
                let pNS = p as NSString
                sqlite3_bind_text(stmt, 3, pNS.utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int(stmt, 4, Int32(addedTimestamp))
            sqlite3_bind_int(stmt, 5, isDeleted ? 1 : 0)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    static func readUserFavorite(dbPath: URL, text: String)
        -> (exists: Bool, isDeleted: Bool, addedTimestamp: Int)? {
        return withOpenDB(dbPath, fallback: nil) { db -> (exists: Bool, isDeleted: Bool, addedTimestamp: Int)? in
            let sql = "SELECT added_timestamp, is_deleted FROM user_favorites WHERE text = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            let textNS = text as NSString
            sqlite3_bind_text(stmt, 1, textNS.utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return (false, false, 0)
            }
            let ts = Int(sqlite3_column_int(stmt, 0))
            let isDel = sqlite3_column_int(stmt, 1) != 0
            return (true, isDel, ts)
        }
    }

    // MARK: - filter_user_freq

    @discardableResult
    static func insertFilterFreq(dbPath: URL,
                                 filterType: String,
                                 code: String,
                                 word: String,
                                 frequency: Int,
                                 lastUsed: Double) -> Bool {
        return withOpenDB(dbPath, fallback: false) { db in
            let sql = """
                INSERT OR REPLACE INTO filter_user_freq
                (filter_type, code, word, frequency, last_used)
                VALUES (?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            let ftNS = filterType as NSString
            let cNS = code as NSString
            let wNS = word as NSString
            sqlite3_bind_text(stmt, 1, ftNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, cNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, wNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, Int32(frequency))
            sqlite3_bind_double(stmt, 5, lastUsed)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    static func readFilterFreq(dbPath: URL,
                               filterType: String,
                               code: String,
                               word: String)
        -> (frequency: Int, lastUsed: Double)? {
        return withOpenDB(dbPath, fallback: nil) { db -> (frequency: Int, lastUsed: Double)? in
            let sql = "SELECT frequency, last_used FROM filter_user_freq WHERE filter_type=? AND code=? AND word=?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            let ftNS = filterType as NSString
            let cNS = code as NSString
            let wNS = word as NSString
            sqlite3_bind_text(stmt, 1, ftNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, cNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, wNS.utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return (Int(sqlite3_column_int(stmt, 0)), sqlite3_column_double(stmt, 1))
        }
    }

    // MARK: - user_suppressed_words

    @discardableResult
    static func insertSuppressedWord(dbPath: URL,
                                     text: String,
                                     suppressedTimestamp: Int,
                                     isDeleted: Bool = false) -> Bool {
        return withOpenDB(dbPath, fallback: false) { db in
            let sql = """
                INSERT OR REPLACE INTO user_suppressed_words
                (text, suppressed_timestamp, is_deleted)
                VALUES (?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            let textNS = text as NSString
            sqlite3_bind_text(stmt, 1, textNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(suppressedTimestamp))
            sqlite3_bind_int(stmt, 3, isDeleted ? 1 : 0)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    static func readSuppressedWord(dbPath: URL, text: String)
        -> (exists: Bool, isDeleted: Bool, suppressedTimestamp: Int)? {
        return withOpenDB(dbPath, fallback: nil) { db -> (exists: Bool, isDeleted: Bool, suppressedTimestamp: Int)? in
            let sql = "SELECT suppressed_timestamp, is_deleted FROM user_suppressed_words WHERE text = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            let textNS = text as NSString
            sqlite3_bind_text(stmt, 1, textNS.utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return (false, false, 0)
            }
            return (true,
                    sqlite3_column_int(stmt, 1) != 0,
                    Int(sqlite3_column_int(stmt, 0)))
        }
    }

    // MARK: - user_relative_order

    @discardableResult
    static func insertRelativeOrder(dbPath: URL,
                                    wordA: String,
                                    wordB: String,
                                    createdAt: Int,
                                    updatedAt: Int,
                                    isDeleted: Bool = false) -> Bool {
        return withOpenDB(dbPath, fallback: false) { db in
            let sql = """
                INSERT OR REPLACE INTO user_relative_order
                (word_a, word_b, created_at, updated_at, is_deleted)
                VALUES (?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            let aNS = wordA as NSString
            let bNS = wordB as NSString
            sqlite3_bind_text(stmt, 1, aNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, bNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(createdAt))
            sqlite3_bind_int(stmt, 4, Int32(updatedAt))
            sqlite3_bind_int(stmt, 5, isDeleted ? 1 : 0)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    // MARK: - row counts

    /// Count rows in `table` at `dbPath`. Returns -1 on failure.
    static func countRows(dbPath: URL, table: String) -> Int {
        return withOpenDB(dbPath, fallback: -1) { db in
            let sql = "SELECT COUNT(*) FROM \(table)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - Corruption helpers

    /// Write random garbage bytes to `url`, simulating a corrupt JSON file
    /// that some other device pushed to iCloud. Used by F-SYNC-01.
    static func corruptJSONFile(at url: URL) throws {
        let garbage = "\u{FEFF}this is not json { not: valid, [ broken"
            .data(using: .utf8)!
        try garbage.write(to: url, options: .atomic)
    }

    /// Write the first `truncate` bytes of a valid `SyncFile<T>` encoding
    /// to `url`, simulating a half-written file left by a crashed writer.
    /// Used by F-SYNC-02.
    static func writePartialFavoritesFile(at url: URL, truncate: Int) throws {
        let full = try JSONEncoder().encode(
            SyncFile(records: ["测试": FavoriteRecord(wubiCode: "a", pinyinCode: "a", addedTimestamp: 1)])
        )
        let bytes = Data(full.prefix(truncate))
        try bytes.write(to: url, options: .atomic)
    }

    // MARK: - Remote JSON parsing

    /// Parse a remote sync JSON file and return a generic decoded SyncFile
    /// (caller supplies the record type via generics).
    static func readRemoteSyncFile<T: Codable>(at url: URL, type: T.Type)
        throws -> SyncFile<T> {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SyncFile<T>.self, from: data)
    }

    // MARK: - internal helpers

    /// Opens `path`, runs `body` with the connection, closes. Returns
    /// `body`'s result, or `fallback` if the open failed.
    private static func withOpenDB<T>(_ path: URL,
                                      fallback: T,
                                      _ body: (OpaquePointer) -> T) -> T {
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK, let conn = db else {
            if db != nil { sqlite3_close(db) }
            return fallback
        }
        defer { sqlite3_close(conn) }
        return body(conn)
    }
}
