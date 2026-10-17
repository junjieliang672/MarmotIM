import XCTest
@testable import MarmotIM

/// 连续输入: candidates for the start of the buffer
/// (CandidateRanker.headCandidates) and the picked segments
/// (CompositionSegments). The key handling itself lives in InputController,
/// which cannot be created in a test.
final class ContinuousInputTests: XCTestCase {

    private func entry(_ id: UInt32, _ text: String, pinyin: String = "", wubi: String? = nil,
                       frequency: UInt16 = 50000) -> DictionaryEntry {
        DictionaryEntry(id: id, text: text, pinyin: pinyin, wubi: wubi,
                        wubiBaseFrequency: frequency, pinyinBaseFrequency: frequency,
                        source: 1, length: text.count)
    }

    private func makeEngine() throws -> DictionaryEngine {
        try DictionaryEngine(entries: [
            entry(1, "这个", pinyin: "zhege"),
            entry(2, "这", pinyin: "zhe", frequency: 60000),
            entry(3, "就是", wubi: "yijg"),
            entry(4, "就", wubi: "yi"),
            entry(5, "会", wubi: "wf"),
            entry(6, "人", wubi: "w"),
            entry(7, "这歌", pinyin: "zhege", frequency: 30000),
        ])
    }

    private func heads(_ buffer: String, _ engine: DictionaryEngine) -> [String] {
        CandidateRanker.headCandidates(buffer: buffer, engine: engine).map { $0.text }
    }

    // MARK: - Head candidates

    func testLongerHeadComesFirst() throws {
        let engine = try makeEngine()
        let candidates = CandidateRanker.headCandidates(buffer: "zhegeyijg", engine: engine)

        XCTAssertEqual(candidates.map { $0.text }, ["这个", "这歌", "这"],
                       "zhege before zhe, though 这 has the higher frequency")
        XCTAssertEqual(candidates.map { $0.headLength }, [5, 5, 3])
    }

    func testRemainderMatchesOnItsOwn() throws {
        let engine = try makeEngine()
        // After 这个: yijg is 4 letters, an ordinary search, and its own heads
        // only appear once more letters follow
        XCTAssertEqual(heads("yijg", engine), [])
        XCTAssertEqual(heads("yijgwf", engine), ["就是", "就"])
    }

    func testUpToFourLettersNothingChanges() throws {
        let engine = try makeEngine()
        XCTAssertEqual(heads("wfyi", engine), [], "4 letters: whole-buffer search only")
        XCTAssertEqual(heads("zhege", engine), ["这"],
                       "the whole buffer is the ordinary search, so only shorter heads are added")
    }

    func testDelimiterSplitsAtAnyLength() throws {
        let engine = try makeEngine()
        XCTAssertEqual(heads("wf'yi", engine), ["会", "人"])
        XCTAssertEqual(heads("zhege'yijg", engine), ["这个", "这歌", "这"],
                       "only the letters before the delimiter")
        XCTAssertEqual(CandidateRanker.headCandidates(buffer: "zhege'yijg", engine: engine).first?.headLength, 5)
    }

    /// A trailing delimiter changes nothing: the segment still gets its
    /// completions (拆成 is `chaicheng`; no word is exactly `chaichen`)
    func testTrailingDelimiterListsWhatTheSegmentAloneDoes() throws {
        let engine = try DictionaryEngine(entries: [
            entry(1, "拆成", pinyin: "chaicheng"),
            entry(2, "柴车", pinyin: "chaiche"),
            entry(3, "柴", pinyin: "chai"),
        ])
        let alone = CandidateRanker.rank(matches: engine.search(code: "chaichen", limit: 100),
                                         inputCode: "chaichen", engine: engine).map { $0.text }
            + heads("chaichen", engine)
        XCTAssertEqual(alone, ["拆成", "柴车", "柴"])

        let delimited = CandidateRanker.headCandidates(buffer: "chaichen'", engine: engine)
        XCTAssertEqual(delimited.map { $0.text }, alone)
        XCTAssertEqual(delimited.first?.headLength, 8, "拆成 uses up the whole segment, and the delimiter with it")
        XCTAssertEqual(CompositionSegments.split("chaichen'", afterHead: 8).rest, "")
    }

    func testUppercaseGetsNoHeads() throws {
        let engine = try makeEngine()
        XCTAssertEqual(heads("Zhegeyijg", engine), [])
    }

    func testSameTextListedOnce() throws {
        let engine = try DictionaryEngine(entries: [
            entry(1, "这", pinyin: "zhe"),
            entry(2, "这", wubi: "yp"),
        ])
        XCTAssertEqual(heads("zhexyz", engine), ["这"])
    }

    func testHeadRankedAsIfTypedAlone() throws {
        let engine = try DictionaryEngine(entries: [
            entry(1, "就是", wubi: "yijg", frequency: 30000),
            entry(2, "京师", wubi: "yijg", frequency: 40000),
        ])
        let alone = CandidateRanker.rank(matches: engine.searchHead(code: "yijg"), inputCode: "yijg", engine: engine)
        XCTAssertEqual(heads("yijgxx", engine), alone.map { $0.text })
    }

    func testSearchHeadIsExactOnly() throws {
        let engine = try makeEngine()
        XCTAssertEqual(Set(engine.searchHead(code: "zhege").map { $0.entry.text }), ["这个", "这歌"])
        XCTAssertTrue(engine.searchHead(code: "zheg").isEmpty, "no code is exactly zheg")
        XCTAssertTrue(engine.searchHead(code: "zhege").allSatisfy { $0.matchType == .full })
    }

    // MARK: - Picked segments

    private func segment(_ text: String, _ consumed: String) throws -> CompositionSegments.Segment {
        let engine = try makeEngine()
        let candidate = try XCTUnwrap(CandidateRanker.headCandidates(buffer: "zhegeyijg", engine: engine).first)
        return CompositionSegments.Segment(text: text, consumed: consumed, candidate: candidate, event: nil)
    }

    func testSplitTakesTheDelimiterWithTheHead() {
        XCTAssertEqual(CompositionSegments.split("zhegeyijg", afterHead: 5).consumed, "zhege")
        XCTAssertEqual(CompositionSegments.split("zhegeyijg", afterHead: 5).rest, "yijg")
        XCTAssertEqual(CompositionSegments.split("zhege'yijg", afterHead: 5).consumed, "zhege'")
        XCTAssertEqual(CompositionSegments.split("zhege'yijg", afterHead: 5).rest, "yijg")
        XCTAssertEqual(CompositionSegments.split("zhege'yijg", afterHead: 3).rest, "ge'yijg",
                       "a shorter head leaves the delimiter in place")
        XCTAssertEqual(CompositionSegments.split("zhege'", afterHead: 5).rest, "")
    }

    func testPickThenTakeBack() throws {
        var composition = CompositionSegments()
        composition.pick(try segment("这个", "zhege"))
        XCTAssertEqual(composition.text, "这个")
        XCTAssertTrue(composition.justPicked)

        XCTAssertEqual(composition.reopenLast(buffer: "yijg"), "zhegeyijg")
        XCTAssertTrue(composition.isEmpty)
        XCTAssertNil(composition.reopenLast(buffer: "zhegeyijg"))
    }

    func testTwoPicksTakenBackOneByOne() throws {
        var composition = CompositionSegments()
        composition.pick(try segment("这个", "zhege'"))
        composition.pick(try segment("就是", "yijg"))
        XCTAssertEqual(composition.text, "这个就是")

        let once = try XCTUnwrap(composition.reopenLast(buffer: "wf"))
        XCTAssertEqual(once, "yijgwf")
        XCTAssertTrue(composition.justPicked, "the next Backspace takes back 这个 as well")
        XCTAssertEqual(composition.reopenLast(buffer: once), "zhege'yijgwf")
        XCTAssertFalse(composition.justPicked)
    }

    func testRemoveLastDropsTheWordWithoutItsLetters() throws {
        var composition = CompositionSegments()
        composition.pick(try segment("这个", "zhege"))
        composition.pick(try segment("就是", "yijg"))

        composition.removeLast()
        XCTAssertEqual(composition.text, "这个")
        XCTAssertFalse(composition.justPicked)
        composition.removeLast()
        XCTAssertTrue(composition.isEmpty)
    }

    func testTypingClosesTheTakeBackWindow() throws {
        var composition = CompositionSegments()
        composition.pick(try segment("这个", "zhege"))
        composition.edited()
        XCTAssertFalse(composition.justPicked)
        XCTAssertEqual(composition.text, "这个", "the pick itself stays")
    }

    // MARK: - Setting

    func testOnByDefaultAndForOlderConfigFiles() throws {
        XCTAssertTrue(AppConfig.default.continuousInput)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"candidateCount":7}"#.utf8))
        XCTAssertTrue(decoded.continuousInput)
    }
}
