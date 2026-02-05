import Foundation
import SQLite3

/// Stores user interaction data using SQLite with WAL mode
class UserDataStore {

    // MARK: - Properties

    private var db: OpaquePointer?
    private let dbPath: URL
    private var cache: [UInt32: UserEntryData] = [:]
    private var isDirty = false

    /// Maximum total score before aging
    private let maxTotalScore: Double = 10000.0

    /// Aging factor (retain this percentage after aging)
    private let agingFactor: Double = 0.9

    // MARK: - Initialization

    init() throws {
        // Get Application Support directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MarmotIM/user")

        // Create directory if needed
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        dbPath = appDir.appendingPathComponent("frecency.db")

        // Open database
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            throw UserDataStoreError.databaseOpenFailed
        }

        // Enable WAL mode for better write performance
        executeSQL("PRAGMA journal_mode=WAL")
        executeSQL("PRAGMA synchronous=NORMAL")

        // Create table if not exists
        try createTable()

        // Load cache
        try loadCache()

        NSLog("MarmotIM: UserDataStore initialized at \(dbPath.path)")
    }

    deinit {
        save()
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func createTable() throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS user_data (
                entry_id INTEGER PRIMARY KEY,
                access_count INTEGER NOT NULL DEFAULT 0,
                last_access INTEGER NOT NULL DEFAULT 0,
                cached_score REAL NOT NULL DEFAULT 0
            )
        """
        if !executeSQL(sql) {
            throw UserDataStoreError.tableCreationFailed
        }
    }

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

    // MARK: - Cache Management

    private func loadCache() throws {
        let sql = "SELECT entry_id, access_count, last_access, cached_score FROM user_data"
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UserDataStoreError.queryFailed
        }

        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            let entryId = UInt32(sqlite3_column_int(statement, 0))
            let accessCount = UInt32(sqlite3_column_int(statement, 1))
            let lastAccess = UInt32(sqlite3_column_int(statement, 2))
            let cachedScore = Float(sqlite3_column_double(statement, 3))

            cache[entryId] = UserEntryData(
                entryId: entryId,
                accessCount: accessCount,
                lastAccessTimestamp: lastAccess,
                cachedScore: cachedScore
            )
        }

        NSLog("MarmotIM: Loaded \(cache.count) user data entries")
    }

    // MARK: - Data Access

    /// Get user data for an entry
    func getData(for entryId: UInt32) -> UserEntryData? {
        return cache[entryId]
    }

    /// Record a selection (user chose this candidate)
    func recordSelection(entryId: UInt32) {
        if var data = cache[entryId] {
            data.recordAccess()
            cache[entryId] = data
        } else {
            var newData = UserEntryData(
                entryId: entryId,
                accessCount: 0,
                lastAccessTimestamp: 0,
                cachedScore: 0
            )
            newData.recordAccess()
            cache[entryId] = newData
        }

        isDirty = true

        // Check if aging is needed
        checkAndAge()
    }

    // MARK: - Persistence

    /// Save all dirty data to database
    func save() {
        guard isDirty else { return }

        let sql = """
            INSERT OR REPLACE INTO user_data (entry_id, access_count, last_access, cached_score)
            VALUES (?, ?, ?, ?)
        """
        var statement: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("MarmotIM: Failed to prepare save statement")
            return
        }

        defer { sqlite3_finalize(statement) }

        // Begin transaction
        executeSQL("BEGIN TRANSACTION")

        for (_, data) in cache {
            sqlite3_bind_int64(statement, 1, Int64(data.entryId))
            sqlite3_bind_int(statement, 2, Int32(data.accessCount))
            sqlite3_bind_int(statement, 3, Int32(data.lastAccessTimestamp))
            sqlite3_bind_double(statement, 4, Double(data.cachedScore))

            if sqlite3_step(statement) != SQLITE_DONE {
                NSLog("MarmotIM: Failed to save entry \(data.entryId)")
            }

            sqlite3_reset(statement)
        }

        // Commit transaction
        executeSQL("COMMIT")

        isDirty = false
        NSLog("MarmotIM: Saved \(cache.count) user data entries")
    }

    // MARK: - Database Aging

    /// Check if aging is needed and perform it
    private func checkAndAge() {
        let totalScore = cache.values.reduce(0.0) { $0 + Double($1.cachedScore) }

        if totalScore > maxTotalScore {
            performAging()
        }
    }

    /// Perform database aging (reduce all scores)
    private func performAging() {
        let totalScore = cache.values.reduce(0.0) { $0 + Double($1.cachedScore) }
        let factor = (maxTotalScore * agingFactor) / totalScore

        var entriesToRemove: [UInt32] = []

        for (entryId, var data) in cache {
            data.cachedScore *= Float(factor)

            if data.cachedScore < 1.0 && data.accessCount == 0 {
                entriesToRemove.append(entryId)
            } else {
                cache[entryId] = data
            }
        }

        // Remove low-score entries
        for entryId in entriesToRemove {
            cache.removeValue(forKey: entryId)
        }

        isDirty = true
        NSLog("MarmotIM: Aged database, removed \(entriesToRemove.count) entries")
    }
}

// MARK: - Errors

enum UserDataStoreError: Error {
    case databaseOpenFailed
    case tableCreationFailed
    case queryFailed
}
