import XCTest
@testable import MarmotIM

final class EnglishWordIndexTests: XCTestCase {

    // MARK: - Exact Match Tests

    func testExactMatch_CaseSensitive_ReturnsExactCase() {
        var index = EnglishWordIndex()
        index.setTestData(["the": ["the", "The", "THE"]])

        XCTAssertEqual(index.exactMatch("the"), "the")
        XCTAssertEqual(index.exactMatch("The"), "The")
        XCTAssertEqual(index.exactMatch("THE"), "THE")
    }

    func testExactMatch_Fallback_ReturnsFirstVariant() {
        var index = EnglishWordIndex()
        index.setTestData(["hello": ["hello", "Hello"]])

        // "HELLO" 不在变体列表中，应该 fallback 到第一个变体 "hello"
        XCTAssertEqual(index.exactMatch("HELLO"), "hello")
    }

    func testExactMatch_NotFound_ReturnsNil() {
        var index = EnglishWordIndex()
        index.setTestData(["hello": ["hello"]])

        XCTAssertNil(index.exactMatch("world"))
    }

    func testExactMatch_EmptyInput_ReturnsNil() {
        var index = EnglishWordIndex()
        index.setTestData(["hello": ["hello"]])

        XCTAssertNil(index.exactMatch(""))
    }

    // MARK: - Contains Tests

    func testContains_CaseInsensitive() {
        var index = EnglishWordIndex()
        index.setTestData(["hello": ["hello", "Hello"]])

        XCTAssertTrue(index.contains("hello"))
        XCTAssertTrue(index.contains("Hello"))
        XCTAssertTrue(index.contains("HELLO"))  // 不区分大小写
        XCTAssertFalse(index.contains("world"))
    }

    // MARK: - Special Characters Tests

    func testExactMatch_NumberPrefix() {
        var index = EnglishWordIndex()
        index.setTestData(["3d": ["3D"]])

        XCTAssertEqual(index.exactMatch("3d"), "3D")  // fallback
        XCTAssertEqual(index.exactMatch("3D"), "3D")  // exact
    }

    func testExactMatch_DotPrefix() {
        var index = EnglishWordIndex()
        index.setTestData([".net": [".NET"]])

        XCTAssertEqual(index.exactMatch(".net"), ".NET")  // fallback
        XCTAssertEqual(index.exactMatch(".NET"), ".NET")  // exact
    }

    // MARK: - Loading Tests

    func testIsLoaded_InitiallyFalse() {
        let index = EnglishWordIndex()
        XCTAssertFalse(index.isLoaded)
    }

    func testIsLoaded_TrueAfterSetTestData() {
        var index = EnglishWordIndex()
        index.setTestData(["test": ["test"]])
        XCTAssertTrue(index.isLoaded)
    }

    func testCount_ReturnsCorrectCount() {
        var index = EnglishWordIndex()
        index.setTestData([
            "hello": ["hello"],
            "world": ["world"],
            "test": ["test"]
        ])
        XCTAssertEqual(index.count, 3)
    }

    func testClear_ResetsIndex() {
        var index = EnglishWordIndex()
        index.setTestData(["hello": ["hello"]])
        XCTAssertTrue(index.isLoaded)
        XCTAssertEqual(index.count, 1)

        index.clear()
        XCTAssertFalse(index.isLoaded)
        XCTAssertEqual(index.count, 0)
        XCTAssertNil(index.exactMatch("hello"))
    }
}
