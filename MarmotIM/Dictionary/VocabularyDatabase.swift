import Foundation
import SQLite3

/// Unified SQLite database for vocabulary storage
/// Replaces both entries.json and frecency.db with a single database
final class VocabularyDatabase {

    // MARK: - Singleton

    static let shared = VocabularyDatabase()

    // MARK: - Properties

    private var db: OpaquePointer?
    private let dbPath: URL
    private let lock = NSLock()

    /// Database schema version for migrations
    /// Version 4: Add is_deleted column to user_favorites
    /// Version 5: Add reverse lookup tables (char_to_wubi, char_to_pinyin, polyphone_words)
    private static let schemaVersion = 5

    // MARK: - Initialization

    private init() {
        // Get Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MarmotIM")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        dbPath = appDir.appendingPathComponent("dictionary.db")

        // Auto-install dictionary from Bundle if not exists
        if !FileManager.default.fileExists(atPath: dbPath.path) {
            installFromBundle()
        }

        // Open database
        if openDatabase() != SQLITE_OK {
            // If failed to open, try to recover by deleting and re-installing
            NSLog("MarmotIM: Database corruption detected during open, attempting recovery...")
            closeDatabase()
            try? FileManager.default.removeItem(at: dbPath)
            installFromBundle()
            
            if openDatabase() != SQLITE_OK {
                NSLog("MarmotIM: Critical failure - could not recover database")
                return
            }
        }
        
        // Validate database integrity
        if !validateDatabase() {
            NSLog("MarmotIM: Database integrity check failed, rebuilding...")
            closeDatabase()
            try? FileManager.default.removeItem(at: dbPath)
            installFromBundle()
            _ = openDatabase()
        }

        // Configure database
        configureDatabase()
        
        // Create tables
        createTables()
        
        NSLog("MarmotIM: VocabularyDatabase initialized at \(dbPath.path)")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Public Database Management

    /// Get the database file path
    func getDatabasePath() -> URL {
        return dbPath
    }

    /// Get the database connection (for direct queries)
    func getConnection() -> OpaquePointer? {
        return db
    }

    /// Close the database connection (for import/export operations)
    func closeDatabase() {
        lock.lock()
        defer { lock.unlock() }

        if db != nil {
            sqlite3_close(db)
            db = nil
            NSLog("MarmotIM: Database connection closed")
        }
    }

    /// Reopen the database connection after import
    func reopenDatabase() {
        lock.lock()
        defer { lock.unlock() }

        // Close if already open
        if db != nil {
            sqlite3_close(db)
            db = nil
        }

        // Reopen
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            NSLog("MarmotIM: Failed to reopen vocabulary database at \(dbPath.path)")
            return
        }

        // Reconfigure
        configureDatabase()

        NSLog("MarmotIM: Database connection reopened")
    }

    // MARK: - Database Configuration

    private func installFromBundle() {
        if let bundleDbPath = Bundle.main.path(forResource: "dictionary", ofType: "db") {
            do {
                try FileManager.default.copyItem(atPath: bundleDbPath, toPath: dbPath.path)
                NSLog("MarmotIM: Installed initial dictionary from Bundle")
            } catch {
                NSLog("MarmotIM: Failed to install dictionary from Bundle: \(error)")
            }
        }
    }

    private func openDatabase() -> Int32 {
        return sqlite3_open(dbPath.path, &db)
    }

    private func validateDatabase() -> Bool {
        var stmt: OpaquePointer?
        // Simple query to check if database is readable
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_finalize(stmt)
            return true
        }
        sqlite3_finalize(stmt)
        return false
    }

    private func configureDatabase() {
        // Enable WAL mode for better concurrent read/write performance
        executeSQL("PRAGMA journal_mode=WAL")

        // Use FULL synchronous to ensure data survives process termination (pkill)
        // This is critical because quick_update.sh uses pkill to stop the app
        executeSQL("PRAGMA synchronous=FULL")

        // Enable memory-mapped I/O for the database
        // This allows the OS to manage page caching efficiently
        // 1GB mmap size covers the entire dictionary.db
        executeSQL("PRAGMA mmap_size=1073741824")

        // Reduce SQLite's internal page cache since mmap handles caching
        // 8MB is enough for write operations and non-mmap fallback
        executeSQL("PRAGMA cache_size=-8000")  // 8MB cache (reduced from 64MB)

        executeSQL("PRAGMA temp_store=MEMORY")

        // Enable foreign keys
        executeSQL("PRAGMA foreign_keys=ON")
    }

    /// Force checkpoint WAL file - call this before app termination
    func checkpoint() {
        lock.lock()
        defer { lock.unlock() }
        executeSQL("PRAGMA wal_checkpoint(TRUNCATE)")
        NSLog("MarmotIM: WAL checkpoint completed")
    }

    private func createTables() {
        // Main entries table
        // Schema version 3: Separate base frequencies for wubi and pinyin modes
        let entriesSQL = """
            CREATE TABLE IF NOT EXISTS entries (
                id INTEGER PRIMARY KEY,
                text TEXT NOT NULL,
                pinyin TEXT,
                wubi TEXT,
                wubi_base_frequency INTEGER NOT NULL DEFAULT 0,
                pinyin_base_frequency INTEGER NOT NULL DEFAULT 0,
                source INTEGER NOT NULL DEFAULT 1,
                length INTEGER NOT NULL,
                created_at INTEGER DEFAULT (strftime('%s', 'now'))
            )
        """

        // Pinyin index table
        let pinyinIndexSQL = """
            CREATE TABLE IF NOT EXISTS pinyin_index (
                code TEXT NOT NULL,
                entry_id INTEGER NOT NULL,
                PRIMARY KEY (code, entry_id),
                FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
            )
        """

        // Wubi index table
        let wubiIndexSQL = """
            CREATE TABLE IF NOT EXISTS wubi_index (
                code TEXT NOT NULL,
                entry_id INTEGER NOT NULL,
                PRIMARY KEY (code, entry_id),
                FOREIGN KEY (entry_id) REFERENCES entries(id) ON DELETE CASCADE
            )
        """

        // User learning table (replaces frecency.db)
        // NOTE: No CASCADE delete - user learning data must persist even if dictionary is updated
        // This ensures user preferences are NEVER lost during app updates or dictionary changes
        let userLearningSQL = """
            CREATE TABLE IF NOT EXISTS user_learning (
                entry_id INTEGER PRIMARY KEY,
                access_count INTEGER NOT NULL DEFAULT 0,
                last_access_timestamp INTEGER NOT NULL DEFAULT 0,
                total_score REAL NOT NULL DEFAULT 0
            )
        """

        // User favorites table - tracks entries added via control+=
        // This allows showing "user added" entries in settings even if they exist in system dict
        let userFavoritesSQL = """
            CREATE TABLE IF NOT EXISTS user_favorites (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                text TEXT NOT NULL,
                wubi_code TEXT,
                pinyin_code TEXT,
                added_timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
                is_deleted INTEGER NOT NULL DEFAULT 0,
                UNIQUE(text, wubi_code, pinyin_code)
            )
        """

        // Schema version table
        let schemaVersionSQL = """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            )
        """

        executeSQL(entriesSQL)
        executeSQL(pinyinIndexSQL)
        executeSQL(wubiIndexSQL)
        executeSQL(userLearningSQL)
        executeSQL(userFavoritesSQL)
        executeSQL(schemaVersionSQL)

        // Create indexes for fast prefix queries
        executeSQL("CREATE INDEX IF NOT EXISTS idx_pinyin_prefix ON pinyin_index(code)")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_wubi_prefix ON wubi_index(code)")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_user_learning_score ON user_learning(total_score DESC)")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_entries_source ON entries(source)")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_user_favorites_text ON user_favorites(text)")

        // Filter mode tables
        executeSQL("""
            CREATE TABLE IF NOT EXISTS emoji_index (
                id INTEGER PRIMARY KEY,
                code TEXT NOT NULL,
                code_type TEXT NOT NULL,
                emoji TEXT NOT NULL,
                frequency INTEGER DEFAULT 0
            )
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_emoji_code ON emoji_index(code)")

        executeSQL("""
            CREATE TABLE IF NOT EXISTS fuzzy_pinyin (
                id INTEGER PRIMARY KEY,
                fuzzy_code TEXT NOT NULL,
                original_code TEXT NOT NULL,
                word TEXT NOT NULL,
                fuzzy_type TEXT NOT NULL
            )
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_fuzzy_code ON fuzzy_pinyin(fuzzy_code)")

        executeSQL("""
            CREATE TABLE IF NOT EXISTS symbol_index (
                id INTEGER PRIMARY KEY,
                code TEXT NOT NULL,
                symbol TEXT NOT NULL,
                category TEXT,
                description TEXT
            )
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_symbol_code ON symbol_index(code)")

        // Filter mode user frequency (isolated from normal mode)
        executeSQL("""
            CREATE TABLE IF NOT EXISTS filter_user_freq (
                filter_type TEXT NOT NULL,
                code TEXT NOT NULL,
                word TEXT NOT NULL,
                frequency INTEGER DEFAULT 1,
                last_used REAL,
                PRIMARY KEY (filter_type, code, word)
            )
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_filter_freq ON filter_user_freq(filter_type, code)")
    }

    // MARK: - Entry Operations

    /// Insert a single entry
    func insertEntry(_ entry: DictionaryEntry) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            INSERT OR REPLACE INTO entries (id, text, pinyin, wubi, wubi_base_frequency, pinyin_base_frequency, source, length)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(entry.id))  // Use int64 for IDs > Int32.max
        sqlite3_bind_text(statement, 2, entry.text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, entry.pinyin, -1, SQLITE_TRANSIENT)
        if let wubi = entry.wubi {
            sqlite3_bind_text(statement, 4, wubi, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int(statement, 5, Int32(entry.wubiBaseFrequency))
        sqlite3_bind_int(statement, 6, Int32(entry.pinyinBaseFrequency))
        sqlite3_bind_int(statement, 7, Int32(entry.source ?? 1))
        sqlite3_bind_int(statement, 8, Int32(entry.length ?? entry.text.count))

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Bulk insert entries (much faster for large imports)
    func bulkInsertEntries(_ entries: [DictionaryEntry], progressCallback: ((Int, Int) -> Void)? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var insertedCount = 0
        let batchSize = 10000

        executeSQL("BEGIN TRANSACTION")

        let sql = """
            INSERT OR REPLACE INTO entries (id, text, pinyin, wubi, wubi_base_frequency, pinyin_base_frequency, source, length)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            executeSQL("ROLLBACK")
            return 0
        }
        defer { sqlite3_finalize(statement) }

        for (index, entry) in entries.enumerated() {
            sqlite3_bind_int64(statement, 1, Int64(entry.id))  // Use int64 for IDs > Int32.max
            sqlite3_bind_text(statement, 2, entry.text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, entry.pinyin, -1, SQLITE_TRANSIENT)
            if let wubi = entry.wubi {
                sqlite3_bind_text(statement, 4, wubi, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_int(statement, 5, Int32(entry.wubiBaseFrequency))
            sqlite3_bind_int(statement, 6, Int32(entry.pinyinBaseFrequency))
            sqlite3_bind_int(statement, 7, Int32(entry.source ?? 1))
            sqlite3_bind_int(statement, 8, Int32(entry.length ?? entry.text.count))

            if sqlite3_step(statement) == SQLITE_DONE {
                insertedCount += 1
            }

            sqlite3_reset(statement)

            // Report progress
            if (index + 1) % batchSize == 0 {
                progressCallback?(index + 1, entries.count)
            }
        }

        executeSQL("COMMIT")
        progressCallback?(entries.count, entries.count)

        return insertedCount
    }

    /// Get entry by ID
    func getEntry(id: UInt32) -> DictionaryEntry? {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT id, text, pinyin, wubi, wubi_base_frequency, pinyin_base_frequency, source, length FROM entries WHERE id = ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(id))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return extractEntry(from: statement)
    }

    /// Get entry by text (direct lookup ignoring index)
    /// Used when entry exists in database but may not be indexed for all codes
    func getEntryByText(text: String) -> DictionaryEntry? {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT id, text, pinyin, wubi, wubi_base_frequency, pinyin_base_frequency, source, length FROM entries WHERE text = ?"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return extractEntry(from: statement)
    }

    /// Get multiple entries by IDs (batch fetch)
    func getEntries(ids: [UInt32]) -> [UInt32: DictionaryEntry] {
        guard !ids.isEmpty else { return [:] }

        lock.lock()
        defer { lock.unlock() }

        var results: [UInt32: DictionaryEntry] = [:]

        // Build parameterized query
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT id, text, pinyin, wubi, wubi_base_frequency, pinyin_base_frequency, source, length FROM entries WHERE id IN (\(placeholders))"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), Int64(id))
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = extractEntry(from: statement) {
                results[entry.id] = entry
            }
        }

        return results
    }

    /// Delete an entry
    func deleteEntry(id: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return executeSQL("DELETE FROM entries WHERE id = \(id)")
    }

    /// Get all user dictionary entries (source = 3)
    func getUserEntries() -> [DictionaryEntry] {
        lock.lock()
        defer { lock.unlock() }

        var entries: [DictionaryEntry] = []
        let sql = "SELECT id, text, pinyin, wubi, wubi_base_frequency, pinyin_base_frequency, source, length FROM entries WHERE source = 3 ORDER BY id"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("MarmotIM: VocabularyDatabase.getUserEntries - failed to prepare statement")
            return []
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let entry = extractEntry(from: statement) {
                entries.append(entry)
            }
        }

        NSLog("MarmotIM: VocabularyDatabase.getUserEntries - found %d entries", entries.count)
        return entries
    }

    /// Add user entry directly to database (for settings window when DictionaryEngine is not available)
    func addUserEntryDirect(code: String, text: String, isWubi: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Generate a new ID starting from 0x80000000 (user dict range)
        let userDictStartId: UInt32 = 0x80000000

        // Find the max existing user entry ID
        var maxId: UInt32 = userDictStartId - 1
        let sql = "SELECT MAX(id) FROM entries WHERE id >= ?"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, Int64(userDictStartId))
            if sqlite3_step(statement) == SQLITE_ROW {
                let result = sqlite3_column_int64(statement, 0)
                if result > 0 {
                    maxId = UInt32(result)
                }
            }
            sqlite3_finalize(statement)
        }

        let newId = maxId + 1

        // Create and insert entry
        // User-added entries get high frequency in both modes
        let entry = DictionaryEntry(
            id: newId,
            text: text,
            pinyin: isWubi ? "" : code,
            wubi: isWubi ? code : nil,
            wubiBaseFrequency: 65000,
            pinyinBaseFrequency: 65000,
            source: 3,  // EntrySource.user
            length: text.count
        )

        guard insertEntryUnlocked(entry) else {
            NSLog("MarmotIM: addUserEntryDirect - failed to insert entry")
            return false
        }

        // Insert into index
        if isWubi {
            _ = insertWubiIndexUnlocked(code: code, entryId: newId)
        } else {
            _ = insertPinyinIndexUnlocked(code: code, entryId: newId)
        }

        NSLog("MarmotIM: addUserEntryDirect - added '%@' with code '%@' (id: %u)", text, code, newId)
        return true
    }

    /// Insert entry without locking (for internal use when already locked)
    private func insertEntryUnlocked(_ entry: DictionaryEntry) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO entries (id, text, pinyin, wubi, wubi_base_frequency, pinyin_base_frequency, source, length)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(entry.id))
        sqlite3_bind_text(statement, 2, entry.text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, entry.pinyin, -1, SQLITE_TRANSIENT)
        if let wubi = entry.wubi {
            sqlite3_bind_text(statement, 4, wubi, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_int(statement, 5, Int32(entry.wubiBaseFrequency))
        sqlite3_bind_int(statement, 6, Int32(entry.pinyinBaseFrequency))
        sqlite3_bind_int(statement, 7, Int32(entry.source ?? 1))
        sqlite3_bind_int(statement, 8, Int32(entry.length ?? entry.text.count))

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Insert pinyin index without locking
    private func insertPinyinIndexUnlocked(code: String, entryId: UInt32) -> Bool {
        let sql = "INSERT OR IGNORE INTO pinyin_index (code, entry_id) VALUES (?, ?)"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, code, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(entryId))

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Insert wubi index without locking
    private func insertWubiIndexUnlocked(code: String, entryId: UInt32) -> Bool {
        let sql = "INSERT OR IGNORE INTO wubi_index (code, entry_id) VALUES (?, ?)"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, code, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(entryId))

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Get total entry count
    func getEntryCount() -> Int {
        let sql = "SELECT COUNT(*) FROM entries"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Index Operations

    /// Insert pinyin index entry
    func insertPinyinIndex(code: String, entryId: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let sql = "INSERT OR IGNORE INTO pinyin_index (code, entry_id) VALUES (?, ?)"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, code, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(entryId))

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Insert wubi index entry
    func insertWubiIndex(code: String, entryId: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let sql = "INSERT OR IGNORE INTO wubi_index (code, entry_id) VALUES (?, ?)"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, code, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(entryId))

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Delete indexes for an entry
    func deleteIndexesForEntry(entryId: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let success1 = executeSQL("DELETE FROM pinyin_index WHERE entry_id = \(entryId)")
        let success2 = executeSQL("DELETE FROM wubi_index WHERE entry_id = \(entryId)")
        return success1 && success2
    }

    /// Bulk insert pinyin indexes
    func bulkInsertPinyinIndexes(_ indexes: [(code: String, entryId: UInt32)]) -> Int {
        return bulkInsertIndexes(tableName: "pinyin_index", indexes: indexes)
    }

    /// Bulk insert wubi indexes
    func bulkInsertWubiIndexes(_ indexes: [(code: String, entryId: UInt32)]) -> Int {
        return bulkInsertIndexes(tableName: "wubi_index", indexes: indexes)
    }

    private func bulkInsertIndexes(tableName: String, indexes: [(code: String, entryId: UInt32)]) -> Int {
        lock.lock()
        defer { lock.unlock() }

        var insertedCount = 0

        executeSQL("BEGIN TRANSACTION")

        let sql = "INSERT OR IGNORE INTO \(tableName) (code, entry_id) VALUES (?, ?)"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            executeSQL("ROLLBACK")
            return 0
        }
        defer { sqlite3_finalize(statement) }

        for (code, entryId) in indexes {
            sqlite3_bind_text(statement, 1, code, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 2, Int64(entryId))

            if sqlite3_step(statement) == SQLITE_DONE {
                insertedCount += 1
            }

            sqlite3_reset(statement)
        }

        executeSQL("COMMIT")
        return insertedCount
    }

    /// Load all pinyin indexes for Trie population
    func loadAllPinyinIndexes() -> [(code: String, entryId: UInt32)] {
        return loadAllIndexes(tableName: "pinyin_index")
    }

    /// Load all wubi indexes for Trie population
    func loadAllWubiIndexes() -> [(code: String, entryId: UInt32)] {
        return loadAllIndexes(tableName: "wubi_index")
    }

    private func loadAllIndexes(tableName: String) -> [(code: String, entryId: UInt32)] {
        lock.lock()
        defer { lock.unlock() }

        var results: [(code: String, entryId: UInt32)] = []

        let sql = "SELECT code, entry_id FROM \(tableName) ORDER BY code"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let codePtr = sqlite3_column_text(statement, 0) {
                let code = String(cString: codePtr)
                let entryId = UInt32(sqlite3_column_int64(statement, 1))
                results.append((code, entryId))
            }
        }

        return results
    }

    // MARK: - User Learning Operations

    /// Get user learning data for an entry
    func getUserLearning(entryId: UInt32) -> (accessCount: UInt32, lastAccessTimestamp: UInt32, totalScore: Double)? {
        let sql = "SELECT access_count, last_access_timestamp, total_score FROM user_learning WHERE entry_id = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(entryId))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let accessCount = UInt32(sqlite3_column_int(statement, 0))
        let lastAccess = UInt32(sqlite3_column_int(statement, 1))
        let totalScore = sqlite3_column_double(statement, 2)

        return (accessCount, lastAccess, totalScore)
    }

    /// Record a selection (increment access count, update timestamp)
    func recordSelection(entryId: UInt32, totalScore: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = UInt32(Date().timeIntervalSince1970)

        let sql = """
            INSERT INTO user_learning (entry_id, access_count, last_access_timestamp, total_score)
            VALUES (?, 1, ?, ?)
            ON CONFLICT(entry_id) DO UPDATE SET
                access_count = access_count + 1,
                last_access_timestamp = excluded.last_access_timestamp,
                total_score = excluded.total_score
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(entryId))
        sqlite3_bind_int(statement, 2, Int32(timestamp))
        sqlite3_bind_double(statement, 3, totalScore)

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Load all user learning data (for in-memory cache)
    func loadAllUserLearning() -> [UInt32: (accessCount: UInt32, lastAccessTimestamp: UInt32, totalScore: Double)] {
        lock.lock()
        defer { lock.unlock() }

        var results: [UInt32: (UInt32, UInt32, Double)] = [:]

        let sql = "SELECT entry_id, access_count, last_access_timestamp, total_score FROM user_learning"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let entryId = UInt32(sqlite3_column_int64(statement, 0))
            let accessCount = UInt32(sqlite3_column_int(statement, 1))
            let lastAccess = UInt32(sqlite3_column_int(statement, 2))
            let totalScore = sqlite3_column_double(statement, 3)
            results[entryId] = (accessCount, lastAccess, totalScore)
        }

        return results
    }

    // MARK: - User Learning Data Protection

    /// Backup user learning data before dictionary update
    /// Returns the backed up data that can be restored after update
    func backupUserLearningData() -> [UInt32: (accessCount: UInt32, lastAccessTimestamp: UInt32, totalScore: Double)] {
        NSLog("MarmotIM: Backing up user learning data...")
        let data = loadAllUserLearning()
        NSLog("MarmotIM: Backed up \(data.count) user learning records")
        return data
    }

    /// Restore user learning data after dictionary update
    /// This ensures user preferences are NEVER lost during updates
    func restoreUserLearningData(_ data: [UInt32: (accessCount: UInt32, lastAccessTimestamp: UInt32, totalScore: Double)]) {
        guard !data.isEmpty else { return }

        NSLog("MarmotIM: Restoring \(data.count) user learning records...")

        lock.lock()
        defer { lock.unlock() }

        executeSQL("BEGIN TRANSACTION")

        for (entryId, values) in data {
            let sql = """
                INSERT OR REPLACE INTO user_learning (entry_id, access_count, last_access_timestamp, total_score)
                VALUES (\(entryId), \(values.accessCount), \(values.lastAccessTimestamp), \(values.totalScore))
            """
            _ = executeSQL(sql)
        }

        executeSQL("COMMIT")
        NSLog("MarmotIM: User learning data restored successfully")
    }

    /// Clear only dictionary entries (preserves user learning data)
    /// Use this when updating the main dictionary
    func clearDictionaryEntriesOnly() {
        lock.lock()
        defer { lock.unlock() }

        // Important: Only clear entries and indexes, NOT user_learning
        executeSQL("DELETE FROM entries")
        executeSQL("DELETE FROM pinyin_index")
        executeSQL("DELETE FROM wubi_index")

        NSLog("MarmotIM: Dictionary entries cleared (user learning preserved)")
    }

    // MARK: - User Favorites (control+= added entries)

    /// Add a user favorite entry (called when user adds via control+=)
    func addUserFavorite(text: String, wubiCode: String?, pinyinCode: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let sql = """
            INSERT INTO user_favorites (text, wubi_code, pinyin_code, added_timestamp, is_deleted)
            VALUES (?, ?, ?, strftime('%s', 'now'), 0)
            ON CONFLICT(text, wubi_code, pinyin_code) DO UPDATE SET
                added_timestamp = excluded.added_timestamp,
                is_deleted = 0
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT)
        if let wubi = wubiCode {
            sqlite3_bind_text(statement, 2, wubi, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        if let pinyin = pinyinCode {
            sqlite3_bind_text(statement, 3, pinyin, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 3)
        }

        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Remove a user favorite entry (Soft Delete)
    func removeUserFavorite(text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Update is_deleted flag and timestamp instead of physical delete
        let sql = """
            UPDATE user_favorites
            SET is_deleted = 1, added_timestamp = strftime('%s', 'now')
            WHERE text = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT)
        
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Get all user favorites (active only)
    func getUserFavorites() -> [(id: Int, text: String, wubiCode: String?, pinyinCode: String?, timestamp: Int)] {
        lock.lock()
        defer { lock.unlock() }

        var results: [(Int, String, String?, String?, Int)] = []

        let sql = "SELECT id, text, wubi_code, pinyin_code, added_timestamp FROM user_favorites WHERE is_deleted = 0 ORDER BY added_timestamp DESC"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(statement, 0))
            let textPtr = sqlite3_column_text(statement, 1)
            let text = textPtr != nil ? String(cString: textPtr!) : ""

            let wubiCode: String?
            if let ptr = sqlite3_column_text(statement, 2) {
                wubiCode = String(cString: ptr)
            } else {
                wubiCode = nil
            }

            let pinyinCode: String?
            if let ptr = sqlite3_column_text(statement, 3) {
                pinyinCode = String(cString: ptr)
            } else {
                pinyinCode = nil
            }

            let timestamp = Int(sqlite3_column_int(statement, 4))
            results.append((id, text, wubiCode, pinyinCode, timestamp))
        }

        NSLog("MarmotIM: getUserFavorites - found %d entries", results.count)
        return results
    }

    /// Remove a user favorite by ID (Soft Delete)
    func removeUserFavoriteById(_ id: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Update is_deleted flag and timestamp instead of physical delete
        let sql = "UPDATE user_favorites SET is_deleted = 1, added_timestamp = strftime('%s', 'now') WHERE id = \(id)"
        return executeSQL(sql)
    }

    /// Get all deleted user favorites (for cleanup purposes)
    func getDeletedUserFavorites() -> [(id: Int, text: String, wubiCode: String?, pinyinCode: String?)] {
        lock.lock()
        defer { lock.unlock() }

        var results: [(Int, String, String?, String?)] = []

        let sql = "SELECT id, text, wubi_code, pinyin_code FROM user_favorites WHERE is_deleted = 1"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = Int(sqlite3_column_int(statement, 0))
            let textPtr = sqlite3_column_text(statement, 1)
            let text = textPtr != nil ? String(cString: textPtr!) : ""

            let wubiCode: String?
            if let ptr = sqlite3_column_text(statement, 2) {
                wubiCode = String(cString: ptr)
            } else {
                wubiCode = nil
            }

            let pinyinCode: String?
            if let ptr = sqlite3_column_text(statement, 3) {
                pinyinCode = String(cString: ptr)
            } else {
                pinyinCode = nil
            }

            results.append((id, text, wubiCode, pinyinCode))
        }

        return results
    }

    // MARK: - Migration

    /// Check if database needs migration from JSON
    func needsMigration() -> Bool {
        return getEntryCount() == 0
    }

    /// Get current schema version
    func getSchemaVersion() -> Int {
        let sql = "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }
        return 0
    }

    /// Update schema version
    func setSchemaVersion(_ version: Int) {
        executeSQL("INSERT OR REPLACE INTO schema_version (version) VALUES (\(version))")
    }

    /// Perform any necessary schema migrations
    func performMigrations() {
        let currentVersion = getSchemaVersion()
        let targetVersion = Self.schemaVersion

        if currentVersion >= targetVersion {
            return
        }

        NSLog("MarmotIM: Migrating schema from version \(currentVersion) to \(targetVersion)")

        // Migration logic for each version
        // Version 1: Initial schema (current)

        // Version 4: Add is_deleted to user_favorites
        if currentVersion < 4 {
            NSLog("MarmotIM: Migrating to version 4 (add is_deleted)...")
            executeSQL("ALTER TABLE user_favorites ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0")
        }

        // Version 5: Add reverse lookup tables (char_to_wubi, char_to_pinyin, polyphone_words)
        if currentVersion < 5 {
            NSLog("MarmotIM: Migrating to version 5 (add reverse lookup tables)...")
            executeSQL("""
                CREATE TABLE IF NOT EXISTS char_to_wubi (
                    char TEXT PRIMARY KEY,
                    wubi_code TEXT NOT NULL
                )
            """)
            executeSQL("CREATE INDEX IF NOT EXISTS idx_char_wubi ON char_to_wubi(char)")

            executeSQL("""
                CREATE TABLE IF NOT EXISTS char_to_pinyin (
                    char TEXT NOT NULL,
                    pinyin TEXT NOT NULL,
                    is_primary INTEGER DEFAULT 1,
                    PRIMARY KEY (char, pinyin)
                )
            """)
            executeSQL("CREATE INDEX IF NOT EXISTS idx_char_pinyin ON char_to_pinyin(char)")

            executeSQL("""
                CREATE TABLE IF NOT EXISTS polyphone_words (
                    word TEXT PRIMARY KEY,
                    pinyin TEXT NOT NULL
                )
            """)
        }

        setSchemaVersion(targetVersion)
        NSLog("MarmotIM: Schema migration complete")
    }

    /// Import entries from JSON file
    func importFromJSON(url: URL, progressCallback: ((Int, Int) -> Void)? = nil) throws {
        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)

        NSLog("MarmotIM: Importing \(entries.count) entries from JSON...")

        // Insert entries
        let insertedEntries = bulkInsertEntries(entries, progressCallback: progressCallback)
        NSLog("MarmotIM: Inserted \(insertedEntries) entries")

        // Build indexes
        var pinyinIndexes: [(String, UInt32)] = []
        var wubiIndexes: [(String, UInt32)] = []

        for entry in entries {
            pinyinIndexes.append((entry.pinyin, entry.id))
            if let wubi = entry.wubi {
                wubiIndexes.append((wubi, entry.id))
            }
        }

        let insertedPinyin = bulkInsertPinyinIndexes(pinyinIndexes)
        let insertedWubi = bulkInsertWubiIndexes(wubiIndexes)

        NSLog("MarmotIM: Created \(insertedPinyin) pinyin indexes, \(insertedWubi) wubi indexes")
    }

    /// Migrate user data from old frecency.db
    func migrateFromFrecencyDB() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let oldDbPath = appSupport.appendingPathComponent("MarmotIM/user/frecency.db")

        guard FileManager.default.fileExists(atPath: oldDbPath.path) else {
            NSLog("MarmotIM: No old frecency.db found, skipping migration")
            return
        }

        var oldDb: OpaquePointer?
        guard sqlite3_open(oldDbPath.path, &oldDb) == SQLITE_OK else {
            NSLog("MarmotIM: Failed to open old frecency.db")
            return
        }
        defer { sqlite3_close(oldDb) }

        let sql = "SELECT entry_id, access_count, last_access, cached_score FROM user_data"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(oldDb, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("MarmotIM: Failed to read old frecency.db")
            return
        }
        defer { sqlite3_finalize(statement) }

        lock.lock()
        defer { lock.unlock() }

        executeSQL("BEGIN TRANSACTION")

        var migratedCount = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let entryId = UInt32(sqlite3_column_int64(statement, 0))
            let accessCount = UInt32(sqlite3_column_int(statement, 1))
            let lastAccess = UInt32(sqlite3_column_int(statement, 2))
            let cachedScore = sqlite3_column_double(statement, 3)

            let insertSQL = """
                INSERT OR REPLACE INTO user_learning (entry_id, access_count, last_access_timestamp, total_score)
                VALUES (\(entryId), \(accessCount), \(lastAccess), \(cachedScore))
            """
            if executeSQL(insertSQL) {
                migratedCount += 1
            }
        }

        executeSQL("COMMIT")
        NSLog("MarmotIM: Migrated \(migratedCount) user learning records")
    }

    // MARK: - Filter Mode User Frequency

    /// Record user selection in filter mode (isolated from normal mode)
    func recordFilterSelection(filterType: String, code: String, word: String) {
        guard let db = db else { return }

        let now = Date().timeIntervalSince1970
        let sql = """
            INSERT INTO filter_user_freq (filter_type, code, word, frequency, last_used)
            VALUES (?, ?, ?, 1, ?)
            ON CONFLICT(filter_type, code, word) DO UPDATE SET
                frequency = frequency + 1,
                last_used = ?
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, filterType, -1, nil)
            sqlite3_bind_text(stmt, 2, code, -1, nil)
            sqlite3_bind_text(stmt, 3, word, -1, nil)
            sqlite3_bind_double(stmt, 4, now)
            sqlite3_bind_double(stmt, 5, now)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Get filter user frequency data
    func getFilterUserFreq(filterType: String, code: String) -> [(word: String, frequency: Int, lastUsed: Double)] {
        guard let db = db else { return [] }

        var results: [(String, Int, Double)] = []
        let sql = """
            SELECT word, frequency, last_used
            FROM filter_user_freq
            WHERE filter_type = ? AND code LIKE ? || '%'
            ORDER BY frequency DESC, last_used DESC
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, filterType, -1, nil)
            sqlite3_bind_text(stmt, 2, code, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let wordPtr = sqlite3_column_text(stmt, 0) else { continue }
                let word = String(cString: wordPtr)
                let freq = Int(sqlite3_column_int(stmt, 1))
                let lastUsed = sqlite3_column_double(stmt, 2)
                results.append((word, freq, lastUsed))
            }
        }
        sqlite3_finalize(stmt)

        return results
    }

    // MARK: - Reverse Lookup (for 划词入库 feature)

    /// Get wubi code for a single character
    func getWubiCode(for char: Character) -> String? {
        guard let db = db else { return nil }

        let sql = "SELECT wubi_code FROM char_to_wubi WHERE char = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let charStr = String(char)
        sqlite3_bind_text(statement, 1, charStr, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        guard let codePtr = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: codePtr)
    }

    /// Get all pinyin codes for a single character (supports polyphones)
    /// Returns pinyins sorted by is_primary (primary first)
    func getPinyinCodes(for char: Character) -> [String] {
        guard let db = db else { return [] }

        let sql = "SELECT pinyin FROM char_to_pinyin WHERE char = ? ORDER BY is_primary DESC"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let charStr = String(char)
        sqlite3_bind_text(statement, 1, charStr, -1, SQLITE_TRANSIENT)

        var pinyins: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let pinyinPtr = sqlite3_column_text(statement, 0) {
                pinyins.append(String(cString: pinyinPtr))
            }
        }

        return pinyins
    }

    /// Get pinyin for a word (polyphone disambiguation)
    func getWordPinyin(for word: String) -> String? {
        guard let db = db else { return nil }

        let sql = "SELECT pinyin FROM polyphone_words WHERE word = ?"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, word, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        guard let pinyinPtr = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: pinyinPtr)
    }

    // MARK: - Helpers

    @discardableResult
    private func executeSQL(_ sql: String) -> Bool {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)

        if result != SQLITE_OK {
            if let error = errorMessage {
                NSLog("MarmotIM: SQL error: \(String(cString: error))")
                sqlite3_free(error)
            }
            return false
        }
        return true
    }

    private func extractEntry(from statement: OpaquePointer?) -> DictionaryEntry? {
        guard let statement = statement else { return nil }

        let id = UInt32(sqlite3_column_int64(statement, 0))

        guard let textPtr = sqlite3_column_text(statement, 1) else { return nil }
        let text = String(cString: textPtr)

        let pinyin: String
        if let pinyinPtr = sqlite3_column_text(statement, 2) {
            pinyin = String(cString: pinyinPtr)
        } else {
            pinyin = ""
        }

        let wubi: String?
        if let wubiPtr = sqlite3_column_text(statement, 3) {
            wubi = String(cString: wubiPtr)
        } else {
            wubi = nil
        }

        let wubiBaseFrequency = UInt16(sqlite3_column_int(statement, 4))
        let pinyinBaseFrequency = UInt16(sqlite3_column_int(statement, 5))
        let source = Int(sqlite3_column_int(statement, 6))
        let length = Int(sqlite3_column_int(statement, 7))

        return DictionaryEntry(
            id: id,
            text: text,
            pinyin: pinyin,
            wubi: wubi,
            wubiBaseFrequency: wubiBaseFrequency,
            pinyinBaseFrequency: pinyinBaseFrequency,
            source: source,
            length: length
        )
    }
}

// MARK: - SQLITE_TRANSIENT Constant

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
