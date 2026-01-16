import XCTest
@testable import MarmotIM

final class UserTierIndexTests: XCTestCase {

    func testInsertAndSearch() {
        let index = UserTierIndex()

        index.insert(code: "test", entryId: 1, codeType: .pinyin)

        let results = index.search(prefix: "test", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].entryIds, [1])
    }

    func testRemove() {
        let index = UserTierIndex()

        index.insert(code: "test", entryId: 1, codeType: .pinyin)
        index.remove(code: "test", entryId: 1, codeType: .pinyin)

        let results = index.search(prefix: "test", limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testMultipleEntriesSameCode() {
        let index = UserTierIndex()

        index.insert(code: "test", entryId: 1, codeType: .pinyin)
        index.insert(code: "test", entryId: 2, codeType: .pinyin)

        let results = index.search(prefix: "test", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(Set(results[0].entryIds), Set([1, 2]))
    }

    func testPrefixSearch() {
        let index = UserTierIndex()

        index.insert(code: "hello", entryId: 1, codeType: .pinyin)
        index.insert(code: "help", entryId: 2, codeType: .pinyin)
        index.insert(code: "world", entryId: 3, codeType: .pinyin)

        let results = index.search(prefix: "hel", limit: 10)
        XCTAssertEqual(results.count, 2)
    }

    func testSeparatePinyinAndWubi() {
        let index = UserTierIndex()

        index.insert(code: "abc", entryId: 1, codeType: .pinyin)
        index.insert(code: "abc", entryId: 2, codeType: .wubi)

        let results = index.search(prefix: "abc", limit: 10)

        // Should have 2 results - one for each code type
        XCTAssertEqual(results.count, 2)

        let pinyinResult = results.first { $0.codeType == .pinyin }
        let wubiResult = results.first { $0.codeType == .wubi }

        XCTAssertNotNil(pinyinResult)
        XCTAssertNotNil(wubiResult)
        XCTAssertEqual(pinyinResult?.entryIds, [1])
        XCTAssertEqual(wubiResult?.entryIds, [2])
    }

    func testIsEmpty() {
        let index = UserTierIndex()
        XCTAssertTrue(index.isEmpty)

        index.insert(code: "test", entryId: 1, codeType: .pinyin)
        XCTAssertFalse(index.isEmpty)
    }
}
