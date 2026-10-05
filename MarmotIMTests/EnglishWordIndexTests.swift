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

    func testExactMatch_AllCapsInput_UppercasesALowercaseWord() {
        var index = EnglishWordIndex()
        index.setTestData(["hello": ["hello"]])

        XCTAssertEqual(index.exactMatch("HELLO"), "HELLO")
        XCTAssertEqual(index.exactMatch("Hello"), "Hello")
    }

    func testExactMatch_TableCapitalsWinOverInputCase() {
        var index = EnglishWordIndex()
        index.setTestData(["iphone": ["iPhone"], "github": ["GitHub"]])

        XCTAssertEqual(index.exactMatch("iphone"), "iPhone")
        XCTAssertEqual(index.exactMatch("IPHONE"), "iPhone")
        XCTAssertEqual(index.exactMatch("Github"), "GitHub")
    }

    func testExactMatches_ReturnsEveryDisplayFormMostCommonFirst() {
        var index = EnglishWordIndex()
        index.setTestWords([("august", 900), ("August", 800), ("augustus", 5000)])

        XCTAssertEqual(index.exactMatches("august").map { $0.display }, ["August", "august"])
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

    // MARK: - Completion Tests

    func testCompletions_MostCommonFirst_UpToLimit() {
        var index = EnglishWordIndex()
        index.setTestWords([("world", 300), ("work", 100), ("worry", 2000), ("word", 400), ("wolf", 9000)])

        XCTAssertEqual(index.completions(prefix: "wor", limit: 3).map { $0.display }, ["work", "world", "word"])
        XCTAssertEqual(index.completions(prefix: "wor", limit: 10).map { $0.display }, ["work", "world", "word", "worry"])
    }

    func testCompletions_ExcludeTheExactWord() {
        var index = EnglishWordIndex()
        index.setTestWords([("work", 100), ("works", 900), ("worker", 1500)])

        XCTAssertEqual(index.completions(prefix: "work", limit: 3).map { $0.display }, ["works", "worker"])
    }

    func testCompletions_IgnoreInputCase_NoMatchIsEmpty() {
        var index = EnglishWordIndex()
        index.setTestWords([("kubernetes", 70000)])

        XCTAssertEqual(index.completions(prefix: "Kuber", limit: 3).map { $0.display }, ["kubernetes"])
        XCTAssertTrue(index.completions(prefix: "xyz", limit: 3).isEmpty)
        XCTAssertTrue(index.completions(prefix: "", limit: 3).isEmpty)
    }

    func testDisplay_FollowsInputCase() {
        let word = EnglishWord(key: "world", display: "world", rank: 1, id: 1)

        XCTAssertEqual(EnglishWordIndex.display(word, typedAs: "wor"), "world")
        XCTAssertEqual(EnglishWordIndex.display(word, typedAs: "Wor"), "World")
        XCTAssertEqual(EnglishWordIndex.display(word, typedAs: "WOR"), "WORLD")
        XCTAssertEqual(EnglishWordIndex.display(word, typedAs: "W"), "World", "a single capital is a leading capital, not all-caps")
    }

    // MARK: - Word Id Tests

    /// Ids key learning records and are also computed by tools/build_en_table.py;
    /// these values come from word_id() there.
    func testWordId_MatchesTheBuildTool() {
        XCTAssertEqual(EnglishWordIndex.wordId(key: "github", display: "GitHub"), 0x5e9c86f6)
        XCTAssertEqual(EnglishWordIndex.wordId(key: "cleaners", display: "cleaners", salt: "1"), 0x6d1f61ed)
    }

    func testWordId_StaysBetweenSystemAndUserEntryRanges() {
        let id = EnglishWordIndex.wordId(key: "the", display: "the")
        XCTAssertTrue(EnglishWordIndex.isEnglishId(id))
        XCTAssertLessThan(id, 0x8000_0000, "ids from 0x80000000 up are user entries")
        XCTAssertFalse(EnglishWordIndex.isEnglishId(0))
    }

    // MARK: - File Loading Tests

    func testLoad_ReadsKeyDisplayRankAndSalt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("en_table_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let table = [
            "github\tGitHub\t22985",
            "iphone11pro\tiPhone 11 Pro\t200000",
            "cleaners\tcleaners\t15777\t1",
            "not a table line",
            "",
        ].joined(separator: "\n")
        try table.write(to: url, atomically: true, encoding: .utf8)

        var index = EnglishWordIndex()
        try index.load(from: url)

        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(index.exactMatch("iphone11pro"), "iPhone 11 Pro")
        XCTAssertEqual(index.exactMatches("github").first?.rank, 22985)
        XCTAssertEqual(index.exactMatches("cleaners").first?.id,
                       EnglishWordIndex.wordId(key: "cleaners", display: "cleaners", salt: "1"))
    }

    // MARK: - Shipped Table

    /// The table in the repository, loaded the way the app loads it.
    private func shippedIndex() throws -> EnglishWordIndex {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MarmotIM/Resources/en_table.txt")
        var index = EnglishWordIndex()
        try index.load(from: url)
        return index
    }

    func testShippedTable_MultiWordNamesNoLongerBreakTheirFirstWord() throws {
        let index = try shippedIndex()

        // These used to come out as "8" and "98": names like "iPhone 8 Plus"
        // were written with tabs between their words and overwrote the key.
        XCTAssertEqual(index.exactMatch("iphone"), "iPhone")
        XCTAssertEqual(index.exactMatch("windows"), "Windows")
        XCTAssertEqual(index.exactMatch("iphone11pro"), "iPhone 11 Pro")
    }

    func testShippedTable_CompletesCommonAndTechnicalWords() throws {
        let index = try shippedIndex()

        XCTAssertGreaterThan(index.count, 60_000)
        XCTAssertEqual(index.completions(prefix: "kuber", limit: 3).first?.display, "Kubernetes")
        XCTAssertTrue(index.contains("async"))
        XCTAssertTrue(index.contains("refactoring"))
        XCTAssertEqual(index.completions(prefix: "wor", limit: 3).map { $0.display }, ["work", "world", "working"])
    }
}
