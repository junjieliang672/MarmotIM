import Foundation
import SQLite3
import Carbon.HIToolbox

private let SQLITE_TRANSIENT_BEHAVIOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One candidate as it was shown when the user picked
struct BehaviorCandidate: Codable, Equatable {
    /// Text
    var t: String
    /// Ranked first only because of learning boosts (Candidate.isBoosted)
    var b: Bool
    /// Protected level-1/2 short code (Candidate.isJianma)
    var j: Bool
}

/// What the user did. Raw values are the `kind` column in behavior.db and are
/// read by tools/marmot_curate.py; changing one is a format change.
enum BehaviorEventKind: String {
    /// Picked a candidate
    case select
    /// Committed the typed letters as they are (Enter, or Shift to English)
    case raw
    /// Gave up on a code: Escape, Space with no candidates, Enter set to
    /// clear, or deleting the whole code with Backspace
    case abandon
    /// Backspaces right after a commit: the commit was probably wrong
    case delete
    /// The run of consecutive commits ends here (punctuation, app switch)
    case boundary = "break"
}

struct BehaviorEvent: Equatable {
    var kind: BehaviorEventKind
    var timestamp: TimeInterval = Date().timeIntervalSince1970
    /// Bundle identifier of the app being typed into
    var app: String?
    /// The code typed (lowercased), when there was one
    var code: String?
    /// "wubi" / "pinyin" / "english" for a selection
    var codeType: String?
    /// Selected text, raw committed text, or the text that was deleted
    var text: String?
    /// 0-based position in the full candidate list
    var rank: Int?
    /// select: "space" / "number". raw: "enter" / "shift". abandon: "escape" /
    /// "empty" / "enter" / "backspace". break: "punct" / "app" / "dictation".
    var trigger: String?
    /// Page the candidate was picked from (0 = first page)
    var page: Int?
    /// select: the candidates shown, in order, up to and including the picked
    /// one's page. raw / abandon: how many candidates there were.
    var candidates: [BehaviorCandidate]?
    /// delete: number of backspaces. raw / abandon: candidate count.
    var count: Int?
}

/// Per-commit record of what was typed and picked, for 整理词库.
///
/// Everything else the input method keeps (user_learning) is a per-word total:
/// it cannot say which code was typed, which candidates were skipped, or which
/// word came next. This log can. It lives in its own database, next to
/// dictionary.db but separate from it, so a dictionary rebuild never touches
/// it, and it is never synced.
///
/// Recording is off unless the user turns it on (CuratorConfig), and nothing
/// is recorded while secure input is on or in an excluded app.
final class BehaviorLog {

    static let shared = BehaviorLog(
        path: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MarmotIM/behavior.db"),
        policy: { app in
            let config = AppDelegate.config.curator
            return BehaviorLog.shouldRecord(enabled: config.recordingEnabled,
                                            secureInput: IsSecureEventInputEnabled(),
                                            app: app,
                                            excludedApps: config.excludedApps)
        },
        retentionDays: { AppDelegate.config.curator.retentionDays }
    )

    /// The single rule for whether an event may be written
    static func shouldRecord(enabled: Bool, secureInput: Bool, app: String?, excludedApps: [String]) -> Bool {
        guard enabled, !secureInput else { return false }
        if let app = app, excludedApps.contains(app) { return false }
        return true
    }

    private let path: URL
    private let policy: (String?) -> Bool
    private let retentionDays: () -> Int
    /// Same pattern as DictionaryEngine.recordSelection: the typing thread
    /// never waits on SQLite
    private let queue = DispatchQueue(label: "com.marmotim.behavior", qos: .utility)
    private var db: OpaquePointer?
    private var lastPurge: TimeInterval = 0

    init(path: URL, policy: @escaping (String?) -> Bool, retentionDays: @escaping () -> Int = { 60 }) {
        self.path = path
        self.policy = policy
        self.retentionDays = retentionDays
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Recording

    func record(_ event: BehaviorEvent) {
        // Checked on the caller's thread: secure-input state is about now
        guard policy(event.app) else { return }
        queue.async { [weak self] in
            self?.insert(event)
        }
    }

    // MARK: - Maintenance (settings page)

    struct Summary: Equatable {
        var events: Int
        var days: Int
        var firstTimestamp: TimeInterval?
    }

    func summary() -> Summary {
        queue.sync {
            guard open() else { return Summary(events: 0, days: 0, firstTimestamp: nil) }
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*), COUNT(DISTINCT CAST(ts / 86400 AS INTEGER)), MIN(ts) FROM events"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return Summary(events: 0, days: 0, firstTimestamp: nil)
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return Summary(events: 0, days: 0, firstTimestamp: nil) }
            let first: TimeInterval? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            return Summary(events: Int(sqlite3_column_int64(stmt, 0)),
                           days: Int(sqlite3_column_int64(stmt, 1)),
                           firstTimestamp: first)
        }
    }

    /// Delete every recorded event
    func clear() {
        queue.sync {
            guard open() else { return }
            sqlite3_exec(db, "DELETE FROM events", nil, nil, nil)
        }
    }

    /// Delete events older than the retention period
    func purgeExpired(now: TimeInterval = Date().timeIntervalSince1970) {
        queue.sync { purge(now: now) }
    }

    /// Block until queued events are written (tests)
    func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - Storage (on `queue`)

    private func open() -> Bool {
        if db != nil { return true }
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            NSLog("MarmotIM: [E][behavior] cannot open behavior.db")
            sqlite3_close(db)
            db = nil
            return false
        }
        sqlite3_busy_timeout(db, 2000)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        // Columns are read by tools/marmot_curate.py
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                app TEXT,
                code TEXT,
                code_type TEXT,
                text TEXT,
                rank INTEGER,
                trigger TEXT,
                page INTEGER,
                candidates TEXT,
                n INTEGER
            )
        """, nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)", nil, nil, nil)
        return true
    }

    private func insert(_ event: BehaviorEvent) {
        guard open() else { return }

        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO events (ts, kind, app, code, code_type, text, rank, trigger, page, candidates, n)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        func bind(_ index: Int32, _ value: String?) {
            if let value = value {
                sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT_BEHAVIOR)
            } else {
                sqlite3_bind_null(stmt, index)
            }
        }
        func bind(_ index: Int32, _ value: Int?) {
            if let value = value {
                sqlite3_bind_int64(stmt, index, Int64(value))
            } else {
                sqlite3_bind_null(stmt, index)
            }
        }

        sqlite3_bind_double(stmt, 1, event.timestamp)
        bind(2, event.kind.rawValue)
        bind(3, event.app)
        bind(4, event.code)
        bind(5, event.codeType)
        bind(6, event.text)
        bind(7, event.rank)
        bind(8, event.trigger)
        bind(9, event.page)
        let candidatesJSON = event.candidates
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        bind(10, candidatesJSON)
        bind(11, event.count)

        if sqlite3_step(stmt) != SQLITE_DONE {
            NSLog("MarmotIM: [E][behavior] insert failed msg=\(String(cString: sqlite3_errmsg(db)))")
        }

        // Retention: at most once a day, piggybacked on a write
        if event.timestamp - lastPurge > 86400 {
            purge(now: event.timestamp)
        }
    }

    private func purge(now: TimeInterval) {
        guard open() else { return }
        lastPurge = now
        let cutoff = now - TimeInterval(retentionDays()) * 86400
        sqlite3_exec(db, "DELETE FROM events WHERE ts < \(cutoff)", nil, nil, nil)
    }
}

/// Counts backspaces typed straight after a commit, so that "picked 交集,
/// deleted it, typed again" is visible as a correction.
///
/// The input method cannot see what a backspace deleted, only that the key was
/// pressed while nothing was being composed. Backspaces that follow a commit
/// within `window` seconds, with no other key in between, are attributed to
/// that commit.
struct CommitCorrectionTracker {
    static let window: TimeInterval = 5

    private var text: String?
    private var committedAt: TimeInterval = 0
    private var backspaces = 0

    /// A commit happened. Returns the correction to record for the previous
    /// commit, if it was followed by backspaces.
    mutating func didCommit(_ text: String, at time: TimeInterval) -> (text: String, backspaces: Int)? {
        let pending = flush()
        self.text = text
        self.committedAt = time
        return pending
    }

    /// A backspace was pressed while not composing
    mutating func didBackspace(at time: TimeInterval) {
        guard text != nil, time - committedAt <= Self.window else {
            text = nil
            return
        }
        backspaces += 1
        committedAt = time  // A run of backspaces keeps the window open
    }

    /// Any other key, or a change of app. Returns the correction to record.
    mutating func flush() -> (text: String, backspaces: Int)? {
        defer {
            text = nil
            backspaces = 0
        }
        guard let text = text, backspaces > 0 else { return nil }
        return (text, backspaces)
    }
}

extension InputCodeType {
    /// `code_type` column in behavior.db
    var behaviorLabel: String {
        switch self {
        case .wubi: return "wubi"
        case .pinyin: return "pinyin"
        case .english: return "english"
        }
    }
}
