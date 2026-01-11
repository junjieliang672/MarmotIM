import XCTest
@testable import MarmotIM

final class PrefixTrieTests: XCTestCase {

    // MARK: - Insert and Search Tests

    func testInsertAndSearch() {
        let trie = PrefixTrie()

        // Insert entries
        trie.insert(code: "wo", entryId: 1)
        trie.insert(code: "woguo", entryId: 2)
        trie.insert(code: "wode", entryId: 3)

        // Search for exact match
        let results = trie.search(prefix: "wo", limit: 10)

        // Should find all three since "wo" is a prefix of all
        let allEntryIds = results.flatMap { $0.entryIds }
        XCTAssertTrue(allEntryIds.contains(1))
        XCTAssertTrue(allEntryIds.contains(2))
        XCTAssertTrue(allEntryIds.contains(3))
    }

    func testPrefixSearch() {
        let trie = PrefixTrie()

        trie.insert(code: "beijing", entryId: 10)
        trie.insert(code: "bei", entryId: 11)
        trie.insert(code: "beida", entryId: 12)
        trie.insert(code: "shanghai", entryId: 20)

        // Search for "bei" prefix
        let results = trie.search(prefix: "bei", limit: 10)
        let codes = results.map { $0.code }

        // Should find "bei", "beijing", "beida" but not "shanghai"
        XCTAssertTrue(codes.contains("bei"))
        XCTAssertTrue(codes.contains("beijing"))
        XCTAssertTrue(codes.contains("beida"))
        XCTAssertFalse(codes.contains("shanghai"))
    }

    func testEmptySearch() {
        let trie = PrefixTrie()

        trie.insert(code: "test", entryId: 1)

        // Empty prefix should return empty
        let results = trie.search(prefix: "", limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testNonExistentPrefix() {
        let trie = PrefixTrie()

        trie.insert(code: "hello", entryId: 1)

        // Search for non-existent prefix
        let results = trie.search(prefix: "xyz", limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Bulk Insert Tests

    func testBulkInsert() {
        let trie = PrefixTrie()

        let items: [(code: String, entryId: UInt32)] = [
            ("a", 1),
            ("ab", 2),
            ("abc", 3),
            ("abd", 4),
            ("b", 5)
        ]

        trie.bulkInsert(items)

        XCTAssertEqual(trie.codeCount, 5)
        XCTAssertEqual(trie.entryCount, 5)

        // Verify search works
        let results = trie.search(prefix: "ab", limit: 10)
        let entryIds = results.flatMap { $0.entryIds }
        XCTAssertTrue(entryIds.contains(2))
        XCTAssertTrue(entryIds.contains(3))
        XCTAssertTrue(entryIds.contains(4))
    }

    // MARK: - Remove Tests

    func testRemove() {
        let trie = PrefixTrie()

        trie.insert(code: "test", entryId: 1)
        trie.insert(code: "test", entryId: 2)

        // Remove one entry
        let removed = trie.remove(code: "test", entryId: 1)
        XCTAssertTrue(removed)

        // Search should still find entry 2
        let results = trie.search(prefix: "test", limit: 10)
        let entryIds = results.flatMap { $0.entryIds }
        XCTAssertFalse(entryIds.contains(1))
        XCTAssertTrue(entryIds.contains(2))
    }

    func testRemoveNonExistent() {
        let trie = PrefixTrie()

        trie.insert(code: "test", entryId: 1)

        // Try to remove non-existent entry
        let removed = trie.remove(code: "test", entryId: 999)
        XCTAssertFalse(removed)

        // Original entry should still be there
        let results = trie.search(prefix: "test", limit: 10)
        let entryIds = results.flatMap { $0.entryIds }
        XCTAssertTrue(entryIds.contains(1))
    }

    // MARK: - Multiple Entries Per Code Tests

    func testMultipleEntriesPerCode() {
        let trie = PrefixTrie()

        // Same code, multiple entries (like multiple words with same pinyin)
        trie.insert(code: "shi", entryId: 1)  // 是
        trie.insert(code: "shi", entryId: 2)  // 十
        trie.insert(code: "shi", entryId: 3)  // 时

        let results = trie.search(prefix: "shi", limit: 10)

        // Should find the code "shi" with all three entries
        guard let shiResult = results.first(where: { $0.code == "shi" }) else {
            XCTFail("Should find 'shi' code")
            return
        }

        XCTAssertEqual(shiResult.entryIds.count, 3)
        XCTAssertTrue(shiResult.entryIds.contains(1))
        XCTAssertTrue(shiResult.entryIds.contains(2))
        XCTAssertTrue(shiResult.entryIds.contains(3))
    }

    // MARK: - Limit Tests

    func testSearchLimit() {
        let trie = PrefixTrie()

        // Insert many entries
        for i in 1...100 {
            trie.insert(code: "test\(i)", entryId: UInt32(i))
        }

        // Search with limit
        let results = trie.search(prefix: "test", limit: 10)

        // Should respect the limit
        let totalEntries = results.flatMap { $0.entryIds }.count
        XCTAssertLessThanOrEqual(totalEntries, 10)
    }

    // MARK: - Statistics Tests

    func testCodeAndEntryCount() {
        let trie = PrefixTrie()

        XCTAssertEqual(trie.codeCount, 0)
        XCTAssertEqual(trie.entryCount, 0)

        trie.insert(code: "a", entryId: 1)
        trie.insert(code: "a", entryId: 2)
        trie.insert(code: "b", entryId: 3)

        XCTAssertEqual(trie.codeCount, 2)  // "a" and "b"
        XCTAssertEqual(trie.entryCount, 3)  // 3 total entries
    }
}
