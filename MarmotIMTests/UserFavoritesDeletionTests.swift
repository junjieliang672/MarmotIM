import XCTest
@testable import MarmotIM

/// Tests for user favorites deletion behavior
/// These tests verify that deleted entries are properly handled and not resurrected by sync.
///
/// Note (spec-004 T2, I-MIG-UFD-01): the 2 tests that touch
/// VocabularyDatabase are migrated to `makeForTests(path:)`-backed
/// per-test DBs. The 5 pure-merger tests (testMergeFavorites_*) are
/// left untouched — they exercise `SyncMerger` directly and never
/// touched the shared DB. See spec-004 decision 001-scope-of-legacy-migration.
final class UserFavoritesDeletionTests: XCTestCase {

    private var tempDir: URL!
    private var db: VocabularyDatabase!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-ufd-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = VocabularyDatabase.makeForTests(path: tempDir.appendingPathComponent("test.db"))
    }

    override func tearDown() {
        db = nil
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Test 1: SyncMerger should not restore deleted entries from older remote

    func testMergeFavorites_shouldNotRestoreDeletedFromOlderRemote() {
        // Local has a deleted entry with newer timestamp
        let localDeleted = FavoriteRecord(
            wubiCode: "ccgk",
            pinyinCode: "ceshi",
            addedTimestamp: 200,  // Newer
            isDeleted: true
        )
        let local = ["测试": localDeleted]

        // Remote has an active entry with older timestamp
        let remoteActive = FavoriteRecord(
            wubiCode: "ccgk",
            pinyinCode: "ceshi",
            addedTimestamp: 100,  // Older
            isDeleted: false
        )
        let remote = ["测试": remoteActive]

        // Merge - should keep the local deleted version (newer timestamp wins)
        let merged = SyncMerger.mergeFavorites(local: local, remote: remote)

        XCTAssertTrue(merged["测试"]?.isDeleted ?? false,
            "Local deleted entry with newer timestamp should not be overwritten by older remote active entry")
        XCTAssertEqual(merged["测试"]?.addedTimestamp, 200,
            "Local timestamp should be preserved")
    }

    func testMergeFavorites_shouldAcceptNewerRemoteEvenIfDeleted() {
        // Local has an active entry with older timestamp
        let localActive = FavoriteRecord(
            wubiCode: "ccgk",
            pinyinCode: "ceshi",
            addedTimestamp: 100,  // Older
            isDeleted: false
        )
        let local = ["测试": localActive]

        // Remote has a deleted entry with newer timestamp
        let remoteDeleted = FavoriteRecord(
            wubiCode: "ccgk",
            pinyinCode: "ceshi",
            addedTimestamp: 200,  // Newer
            isDeleted: true
        )
        let remote = ["测试": remoteDeleted]

        // Merge - should accept remote deleted version (newer timestamp wins)
        let merged = SyncMerger.mergeFavorites(local: local, remote: remote)

        XCTAssertTrue(merged["测试"]?.isDeleted ?? false,
            "Remote deleted entry with newer timestamp should be accepted")
        XCTAssertEqual(merged["测试"]?.addedTimestamp, 200,
            "Remote timestamp should be used")
    }

    // MARK: - Test 2: SyncMerger should not add deleted remote entries

    func testMergeFavorites_shouldNotAddDeletedRemoteEntry() {
        // Local doesn't have this entry
        let local: [String: FavoriteRecord] = [:]

        // Remote has a deleted entry
        let remoteDeleted = FavoriteRecord(
            wubiCode: "ccgk",
            pinyinCode: "ceshi",
            addedTimestamp: 100,
            isDeleted: true
        )
        let remote = ["测试": remoteDeleted]

        // Merge - should NOT add the deleted remote entry
        let merged = SyncMerger.mergeFavorites(local: local, remote: remote)

        XCTAssertNil(merged["测试"],
            "Deleted remote entry should not be added to local")
    }

    func testMergeFavorites_shouldAddActiveRemoteEntry() {
        // Local doesn't have this entry
        let local: [String: FavoriteRecord] = [:]

        // Remote has an active entry
        let remoteActive = FavoriteRecord(
            wubiCode: "ccgk",
            pinyinCode: "ceshi",
            addedTimestamp: 100,
            isDeleted: false
        )
        let remote = ["测试": remoteActive]

        // Merge - SHOULD add the active remote entry
        let merged = SyncMerger.mergeFavorites(local: local, remote: remote)

        XCTAssertNotNil(merged["测试"],
            "Active remote entry should be added to local")
        XCTAssertFalse(merged["测试"]?.isDeleted ?? true,
            "Added entry should be active")
    }

    // MARK: - Test 3: User manual add should resurrect deleted entry

    func testAddUserFavorite_shouldResurrectDeletedEntry() {
        // Isolated DB per test — no need for UUID suffixes to dedupe against
        // other tests, but keep them for belt-and-suspenders so any accidental
        // test-order coupling would be obvious. Also they exercise the
        // "real-world" shape of user text.
        let uniqueText = "测试复活_\(UUID().uuidString.prefix(8))"

        // First, add an entry
        let added = db.addUserFavorite(text: uniqueText, wubiCode: "ccgk", pinyinCode: "ceshi")
        XCTAssertTrue(added, "Initial add should succeed")

        // Verify it exists
        var favorites = db.getUserFavorites()
        XCTAssertTrue(favorites.contains { $0.text == uniqueText },
            "Entry should appear in favorites after add")

        // Delete it (soft delete)
        let removed = db.removeUserFavorite(text: uniqueText)
        XCTAssertTrue(removed, "Remove should succeed")

        // Verify it's gone from active list
        favorites = db.getUserFavorites()
        XCTAssertFalse(favorites.contains { $0.text == uniqueText },
            "Entry should not appear in favorites after delete")

        // Verify it exists in deleted list
        let deleted = db.getDeletedUserFavorites()
        XCTAssertTrue(deleted.contains { $0.text == uniqueText },
            "Entry should appear in deleted list")

        // User manually re-adds the entry (should resurrect)
        let readded = db.addUserFavorite(text: uniqueText, wubiCode: "ccgk", pinyinCode: "ceshi")
        XCTAssertTrue(readded, "Re-add should succeed")

        // Verify it's resurrected
        favorites = db.getUserFavorites()
        XCTAssertTrue(favorites.contains { $0.text == uniqueText },
            "Entry should be resurrected after user manual re-add")
    }

    // MARK: - Test 4: getDeletedUserFavorites should return deleted entries

    func testGetDeletedUserFavorites() {
        let uniqueText = "测试删除列表_\(UUID().uuidString.prefix(8))"

        // Add and then delete an entry
        _ = db.addUserFavorite(text: uniqueText, wubiCode: "test", pinyinCode: nil)
        _ = db.removeUserFavorite(text: uniqueText)

        // Verify it appears in deleted list
        let deleted = db.getDeletedUserFavorites()
        let found = deleted.first { $0.text == uniqueText }

        XCTAssertNotNil(found, "Deleted entry should appear in getDeletedUserFavorites")
        XCTAssertEqual(found?.wubiCode, "test", "Wubi code should be preserved")
    }

    // MARK: - Test 5: Merge with multiple entries

    func testMergeFavorites_multipleEntries() {
        // Local: entry1 (active), entry2 (deleted newer), entry3 (active older)
        let local: [String: FavoriteRecord] = [
            "词条1": FavoriteRecord(wubiCode: "a", pinyinCode: "a", addedTimestamp: 100, isDeleted: false),
            "词条2": FavoriteRecord(wubiCode: "b", pinyinCode: "b", addedTimestamp: 300, isDeleted: true),
            "词条3": FavoriteRecord(wubiCode: "c", pinyinCode: "c", addedTimestamp: 100, isDeleted: false)
        ]

        // Remote: entry1 (deleted newer), entry2 (active older), entry4 (active), entry5 (deleted)
        let remote: [String: FavoriteRecord] = [
            "词条1": FavoriteRecord(wubiCode: "a", pinyinCode: "a", addedTimestamp: 200, isDeleted: true),
            "词条2": FavoriteRecord(wubiCode: "b", pinyinCode: "b", addedTimestamp: 100, isDeleted: false),
            "词条4": FavoriteRecord(wubiCode: "d", pinyinCode: "d", addedTimestamp: 100, isDeleted: false),
            "词条5": FavoriteRecord(wubiCode: "e", pinyinCode: "e", addedTimestamp: 100, isDeleted: true)
        ]

        let merged = SyncMerger.mergeFavorites(local: local, remote: remote)

        // Entry1: remote wins (newer), should be deleted
        XCTAssertTrue(merged["词条1"]?.isDeleted ?? false,
            "Entry1 should be deleted (remote newer)")
        XCTAssertEqual(merged["词条1"]?.addedTimestamp, 200)

        // Entry2: local wins (newer), should stay deleted
        XCTAssertTrue(merged["词条2"]?.isDeleted ?? false,
            "Entry2 should stay deleted (local newer)")
        XCTAssertEqual(merged["词条2"]?.addedTimestamp, 300)

        // Entry3: only in local, should remain
        XCTAssertNotNil(merged["词条3"])
        XCTAssertFalse(merged["词条3"]?.isDeleted ?? true)

        // Entry4: only in remote (active), should be added
        XCTAssertNotNil(merged["词条4"], "Active remote entry should be added")
        XCTAssertFalse(merged["词条4"]?.isDeleted ?? true)

        // Entry5: only in remote (deleted), should NOT be added
        XCTAssertNil(merged["词条5"], "Deleted remote entry should not be added")
    }
}
