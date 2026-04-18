import XCTest
import Foundation
import SQLite3
@testable import MarmotIM

/// Structural lint enforced inside `swift test` — a regression guard for
/// the user-reported test-pollution incident that spawned spec-004.
///
/// Prior to spec-004 Part A, several test files used the production
/// `VocabularyDatabase` singleton directly. Every `swift test` run wrote
/// synthetic rows into `~/Library/Application Support/MarmotIM/dictionary.db`
/// — the user's real dictionary — polluting it with `测试复活_*` and
/// `测试删除列表_*` entries. Part A migrated the two offending files to
/// per-test isolated DBs via `VocabularyDatabase.makeForTests(path:)`.
///
/// This test IS the guard: it iterates every `.swift` file under
/// `MarmotIMTests/` and fails if any contains the literal forbidden
/// substring. The string is assembled at runtime via concatenation so
/// this file's own body does not contain the literal — no exemption list
/// needed.
///
/// Companion script: `scripts/kingjj-lint-no-shared-db-in-tests.sh` runs
/// the same check out-of-band (useful for CI / pre-commit hooks).
///
/// See spec-004 decisions:
///   001-scope-of-legacy-migration
///   003-structural-lint-via-LegacyTestShimGuard
///   006-where-legacy-test-file-exceptions-live (no exemptions)
final class LegacyTestShimGuard: XCTestCase {

    /// U-HYG-01: grep guard — no test file may reference the legacy shim.
    func test_legacyTestShimGuard_noProductionSingletonInTests() throws {
        // Split literal so this file itself passes the check.
        let forbidden = "VocabularyDatabase" + "." + "shared"

        let testsRoot = LegacyTestShimGuard.locateTestsRoot()
        guard let root = testsRoot else {
            throw XCTSkip("could not locate MarmotIMTests root on this runner — no-op")
        }

        var violations: [(file: String, occurrences: Int)] = []

        let enumerator = FileManager.default.enumerator(at: root,
                                                       includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles])
        while let next = enumerator?.nextObject() as? URL {
            guard next.pathExtension == "swift" else { continue }
            // Read file body; skip unreadable (shouldn't happen under `swift test`).
            guard let body = try? String(contentsOf: next, encoding: .utf8) else { continue }
            let count = body.components(separatedBy: forbidden).count - 1
            if count > 0 {
                violations.append((file: next.path, occurrences: count))
            }
        }

        if !violations.isEmpty {
            let lines = violations.map { "  \($0.file) (\($0.occurrences) occurrences)" }
                .joined(separator: "\n")
            XCTFail("""
                MarmotIM: [W][svc] legacy test shim still present action=fail. \
                Migrate the offending files to `VocabularyDatabase.makeForTests(path:)` \
                — see spec-004 Part A. Offenders:
                \(lines)
                """)
        }
    }

    /// U-HYG-02: makeForTests creates every table the legacy tests use.
    func test_makeForTests_createsAllRequiredTables() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-shimguard-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("test.db")
        let db = VocabularyDatabase.makeForTests(path: dbPath)
        defer { _ = db }

        // Query sqlite_master for every table name the tests touch.
        let expected: Set<String> = [
            "entries", "pinyin_index", "wubi_index",
            "user_learning", "user_favorites",
            "user_suppressed_words", "filter_user_freq",
            "user_relative_order"
        ]

        guard let conn = db.getConnection() else {
            XCTFail("makeForTests returned an instance with no open connection")
            return
        }

        var actual: Set<String> = []
        let sql = "SELECT name FROM sqlite_master WHERE type='table'"
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(conn, sql, -1, &stmt, nil), SQLITE_OK,
                       "sqlite_master query must prepare")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                actual.insert(String(cString: cstr))
            }
        }

        let missing = expected.subtracting(actual)
        XCTAssertTrue(missing.isEmpty,
                      "makeForTests DB missing expected tables: \(missing.sorted())")
    }

    // MARK: - Helpers

    /// Locate the MarmotIMTests/ directory on disk. Works when tests are
    /// run via `swift test` from the repo root. If the runner doesn't
    /// expose a useful CWD (CI sandbox, etc.), return nil and the test
    /// skips rather than false-fails.
    private static func locateTestsRoot() -> URL? {
        // #file expansion resolves to this file's absolute path — climb
        // two levels to reach MarmotIMTests/ (this file lives in
        // MarmotIMTests/Support/).
        let thisFile = URL(fileURLWithPath: #file)
        let supportDir = thisFile.deletingLastPathComponent()
        let testsRoot = supportDir.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: testsRoot.path) {
            return testsRoot
        }
        // Fallback: walk from CWD.
        let cwd = FileManager.default.currentDirectoryPath
        let cwdCandidate = URL(fileURLWithPath: cwd).appendingPathComponent("MarmotIMTests")
        if FileManager.default.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }
        return nil
    }
}
