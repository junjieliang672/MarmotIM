import Foundation
import SQLite3
import notify

private let SQLITE_TRANSIENT_PROPOSAL = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// What applying a decision does to the three stores. Each returns nil on
/// success or a message saying why it could not be applied.
struct ProposalActions {
    var addWord: (_ text: String, _ wubi: String?, _ pinyin: String?) -> String?
    var removeWord: (_ text: String) -> String?
    var suppress: (_ text: String) -> String?
    var unsuppress: (_ text: String) -> String?
    var addRule: (_ a: String, _ b: String) -> String?
    var removeRule: (_ a: String, _ b: String) -> String?
}

/// Applies the decisions `tools/marmot_curate.py decide` recorded.
///
/// The tool only writes rows to the `proposals` table in behavior.db. The
/// stores themselves are changed here, inside the input method, because only
/// this process can keep the database, the in-memory indexes and iCloud sync
/// consistent: it goes through the same calls the settings pages use.
///
/// Rows with status `accepted` are applied and become `applied`, or `failed`
/// with the reason in `error`. Runs when the tool posts the Darwin
/// notification, and once at launch for anything decided while the input
/// method was not running.
final class ProposalApplier {

    /// Posted by marmot_curate.py (DECIDED_NOTIFICATION)
    static let decidedNotification = "com.marmotim.curate.decided"

    private let path: URL
    private let actions: ProposalActions
    private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID

    init(path: URL, actions: ProposalActions) {
        self.path = path
        self.actions = actions
    }

    deinit {
        if notifyToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(notifyToken)
        }
    }

    /// Apply what is pending now, and again whenever the tool records decisions.
    /// The store calls are the ones the settings pages make on the main thread.
    func start() {
        notify_register_dispatch(Self.decidedNotification, &notifyToken, .main) { [weak self] _ in
            self?.applyPending()
        }
        DispatchQueue.main.async { [weak self] in
            self?.applyPending()
        }
    }

    /// Apply every `accepted` row. Returns how many were applied and failed.
    @discardableResult
    func applyPending() -> (applied: Int, failed: Int) {
        guard FileManager.default.fileExists(atPath: path.path) else { return (0, 0) }
        var db: OpaquePointer?
        guard sqlite3_open(path.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return (0, 0)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var pending: [(id: Int64, kind: String, payload: [String: Any])] = []
        var stmt: OpaquePointer?
        // The table is created by the tool; absent until the first `decide`
        guard sqlite3_prepare_v2(db, "SELECT id, kind, payload FROM proposals WHERE status = 'accepted' ORDER BY id",
                                 -1, &stmt, nil) == SQLITE_OK else {
            return (0, 0)
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let payloadText = String(cString: sqlite3_column_text(stmt, 2))
            let payload = (try? JSONSerialization.jsonObject(with: Data(payloadText.utf8))) as? [String: Any] ?? [:]
            pending.append((sqlite3_column_int64(stmt, 0), String(cString: sqlite3_column_text(stmt, 1)), payload))
        }
        sqlite3_finalize(stmt)

        var applied = 0
        var failed = 0
        for item in pending {
            let error = apply(kind: item.kind, payload: item.payload)
            mark(db, id: item.id, error: error)
            if error == nil { applied += 1 } else { failed += 1 }
            NSLog("MarmotIM: [I][curate] proposal id=\(item.id) kind=\(item.kind) result=\(error ?? "applied")")
        }
        return (applied, failed)
    }

    private func apply(kind: String, payload: [String: Any]) -> String? {
        let text = payload["text"] as? String
        let a = payload["a"] as? String
        let b = payload["b"] as? String

        switch kind {
        case "add_word":
            guard let text = text else { return "缺少词条" }
            var wubi = payload["wubi"] as? String
            var pinyin = payload["pinyin"] as? String
            if payload["english"] as? Bool == true {
                // An English word is typed by its own letters. Stored as an
                // entry whose code is the lowercased word, it comes up as a
                // candidate when those letters are typed in Chinese mode.
                wubi = nil
                pinyin = text.lowercased()
            }
            return actions.addWord(text, wubi, pinyin)
        case "remove_word":
            guard let text = text else { return "缺少词条" }
            return actions.removeWord(text)
        case "suppress":
            guard let text = text else { return "缺少词条" }
            return actions.suppress(text)
        case "unsuppress":
            guard let text = text else { return "缺少词条" }
            return actions.unsuppress(text)
        case "add_rule":
            guard let a = a, let b = b else { return "规则缺少两个词" }
            return actions.addRule(a, b)
        case "remove_rule":
            guard let a = a, let b = b else { return "规则缺少两个词" }
            return actions.removeRule(a, b)
        default:
            return "不认识的类型：\(kind)"
        }
    }

    private func mark(_ db: OpaquePointer?, id: Int64, error: String?) {
        var stmt: OpaquePointer?
        let sql = "UPDATE proposals SET status = ?, applied_at = ?, error = ? WHERE id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, error == nil ? "applied" : "failed", -1, SQLITE_TRANSIENT_PROPOSAL)
        sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
        if let error = error {
            sqlite3_bind_text(stmt, 3, error, -1, SQLITE_TRANSIENT_PROPOSAL)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_int64(stmt, 4, id)
        sqlite3_step(stmt)
    }
}

extension ProposalActions {

    /// The real stores, through the calls the settings pages make
    static func live(engine: DictionaryEngine) -> ProposalActions {
        let db = VocabularyDatabase.shared
        return ProposalActions(
            addWord: { text, wubi, pinyin in
                guard wubi != nil || pinyin != nil else { return "没有编码" }
                return engine.addDualEntry(text: text, wubiCode: wubi, pinyinCode: pinyin).success ? nil : "入库失败"
            },
            removeWord: { text in
                guard let favorite = db.getUserFavorites().first(where: { $0.text == text }) else {
                    return "用户词库里没有这个词"
                }
                _ = engine.removeDualEntry(text: text, wubiCode: favorite.wubiCode, pinyinCode: favorite.pinyinCode)
                return nil
            },
            suppress: { text in
                guard db.suppressWord(text: text) else { return "降权失败" }
                engine.updateSuppressedWordsCache()
                return nil
            },
            unsuppress: { text in
                guard db.unsuppressWord(text: text) else { return "解除降权失败" }
                engine.updateSuppressedWordsCache()
                return nil
            },
            addRule: { a, b in
                switch db.addRelativeOrderingRule(wordA: a, wordB: b) {
                case .success:
                    engine.updateRelativeOrderingCache()
                    return nil
                case .failure(.duplicate):
                    return nil  // Already there: the outcome the user asked for
                case .failure(.cycle(let path)):
                    return "会和现有规则形成环：\(path.joined(separator: " → "))"
                case .failure(let error):
                    return error.localizedDescription
                }
            },
            removeRule: { a, b in
                guard let rule = db.listRelativeOrderingRules().first(where: { $0.wordA == a && $0.wordB == b }) else {
                    return "没有这条规则"
                }
                guard db.removeRelativeOrderingRule(ruleId: rule.id) else { return "移除规则失败" }
                engine.updateRelativeOrderingCache()
                return nil
            }
        )
    }
}
