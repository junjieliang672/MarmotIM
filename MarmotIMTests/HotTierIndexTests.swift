import XCTest
@testable import MarmotIM

final class HotTierIndexTests: XCTestCase {

    func testSearchReturnsBothPinyinAndWubiMatches() {
        var index = HotTierIndex()

        // Load some test data
        index.loadPinyinIndexes([
            ("wo", 1),
            ("woguo", 2)
        ])
        index.loadWubiIndexes([
            ("q", 1),
            ("qklg", 2)
        ])

        index.finalizePreload()

        // Search should find both
        let results = index.search(prefix: "q", limit: 10)

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.contains { $0.code == "q" && $0.codeType == .wubi })
    }

    func testSearchReturnsCorrectCodeType() {
        var index = HotTierIndex()

        index.loadPinyinIndexes([("hello", 1)])
        index.loadWubiIndexes([("qqq", 2)])
        index.finalizePreload()

        let pinyinResults = index.search(prefix: "hel", limit: 10)
        XCTAssertEqual(pinyinResults.first?.codeType, .pinyin)

        let wubiResults = index.search(prefix: "qq", limit: 10)
        XCTAssertEqual(wubiResults.first?.codeType, .wubi)
    }

    func testIsPreloadedInitiallyFalse() {
        let index = HotTierIndex()
        XCTAssertFalse(index.isPreloaded)
    }

    func testFinalizePreloadSetsFlag() {
        var index = HotTierIndex()
        index.finalizePreload()
        XCTAssertTrue(index.isPreloaded)
    }

    func testSearchReturnsEmptyWhenNotPreloaded() {
        var index = HotTierIndex()
        index.loadPinyinIndexes([("test", 1)])
        // Don't call finalizePreload

        let results = index.search(prefix: "test", limit: 10)
        XCTAssertTrue(results.isEmpty, "Should return empty when not preloaded")
    }

    func testStatistics() {
        var index = HotTierIndex()
        index.loadPinyinIndexes([
            ("a", 1),
            ("b", 2),
            ("c", 3)
        ])
        index.loadWubiIndexes([
            ("x", 4),
            ("y", 5)
        ])
        index.finalizePreload()

        let stats = index.statistics
        XCTAssertEqual(stats.pinyinCodes, 3)
        XCTAssertEqual(stats.wubiCodes, 2)
    }

    func testContainsCodeForPinyin() {
        var index = HotTierIndex()
        index.loadPinyinIndexes([("hello", 1)])
        index.loadWubiIndexes([("qqq", 2)])
        index.finalizePreload()

        XCTAssertTrue(index.contains(code: "hello", codeType: .pinyin))
        XCTAssertFalse(index.contains(code: "hello", codeType: .wubi))
    }

    func testContainsCodeForWubi() {
        var index = HotTierIndex()
        index.loadPinyinIndexes([("hello", 1)])
        index.loadWubiIndexes([("qqq", 2)])
        index.finalizePreload()

        XCTAssertTrue(index.contains(code: "qqq", codeType: .wubi))
        XCTAssertFalse(index.contains(code: "qqq", codeType: .pinyin))
    }

    func testSearchWithEmptyPrefixReturnsEmpty() {
        var index = HotTierIndex()
        index.loadPinyinIndexes([("test", 1)])
        index.finalizePreload()

        let results = index.search(prefix: "", limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchResultContainsEntryIds() {
        var index = HotTierIndex()
        index.loadPinyinIndexes([
            ("wo", 1),
            ("wo", 2),
            ("wo", 3)
        ])
        index.finalizePreload()

        let results = index.search(prefix: "wo", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(Set(results[0].entryIds), Set([1, 2, 3]))
    }
}
