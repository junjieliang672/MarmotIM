import XCTest
@testable import MarmotIM

final class CompactIndexTests: XCTestCase {

    func testEmptyIndexReturnsNoResults() {
        let index = CompactIndex()
        let results = index.search(prefix: "test")
        XCTAssertTrue(results.isEmpty)
    }

    func testExactMatchReturnsEntryIds() {
        var index = CompactIndex()
        index.bulkLoad([
            ("hello", [1, 2]),
            ("world", [3])
        ])

        let results = index.search(prefix: "hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].code, "hello")
        XCTAssertEqual(Set(results[0].entryIds), Set([1, 2]))
    }

    func testPrefixMatchReturnsMultipleCodes() {
        var index = CompactIndex()
        index.bulkLoad([
            ("he", [1]),
            ("hello", [2]),
            ("help", [3]),
            ("world", [4])
        ])

        let results = index.search(prefix: "hel")
        XCTAssertEqual(results.count, 2)

        let codes = Set(results.map { $0.code })
        XCTAssertEqual(codes, Set(["hello", "help"]))
    }

    func testSearchRespectsLimit() {
        var index = CompactIndex()
        var items: [(String, [UInt32])] = []
        for i in 0..<100 {
            items.append(("test\(String(format: "%03d", i))", [UInt32(i)]))
        }
        index.bulkLoad(items)

        let results = index.search(prefix: "test", limit: 10)
        XCTAssertEqual(results.count, 10)
    }

    func testBinarySearchFindsFirstMatch() {
        var index = CompactIndex()
        index.bulkLoad([
            ("aaa", [1]),
            ("abc", [2]),
            ("abd", [3]),
            ("xyz", [4])
        ])

        let results = index.search(prefix: "ab")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.code == "abc" })
        XCTAssertTrue(results.contains { $0.code == "abd" })
    }

    func testNoMatchReturnsEmpty() {
        var index = CompactIndex()
        index.bulkLoad([
            ("hello", [1]),
            ("world", [2])
        ])

        let results = index.search(prefix: "xyz")
        XCTAssertTrue(results.isEmpty)
    }

    func testCodeCount() {
        var index = CompactIndex()
        index.bulkLoad([
            ("a", [1]),
            ("b", [2]),
            ("c", [3])
        ])

        XCTAssertEqual(index.codeCount, 3)
    }

    func testEntryCount() {
        var index = CompactIndex()
        index.bulkLoad([
            ("a", [1, 2]),
            ("b", [3]),
            ("c", [4, 5, 6])
        ])

        XCTAssertEqual(index.entryCount, 6)
    }
}
