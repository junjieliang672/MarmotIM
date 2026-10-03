import XCTest
@testable import MarmotIM

/// Settings → 词库管理 → 添加词条: codes are generated from the text and stay
/// editable. The generators are faked so these tests don't touch a database.
final class WordDraftBuilderTests: XCTestCase {

    private let wubi: [String: String] = ["交集": "uqwy", "百感交集": "dduw", "银行": "qvtf"]
    private let pinyin: [String: String] = ["交集": "jiaoji", "百感交集": "baiganjiaoji", "银行": "yinhang"]

    private func rebuild(_ input: String, previous: [WordDraft] = []) -> [WordDraft] {
        WordDraftBuilder.rebuild(input: input, previous: previous,
                                 generateWubi: { self.wubi[$0] }, generatePinyin: { self.pinyin[$0] })
    }

    func testCodesComeFromGenerators() {
        let drafts = rebuild("交集 百感交集")
        XCTAssertEqual(drafts.map(\.text), ["交集", "百感交集"])
        XCTAssertEqual(drafts.map(\.wubi), ["uqwy", "dduw"])
        XCTAssertEqual(drafts.map(\.pinyin), ["jiaoji", "baiganjiaoji"])
        XCTAssertTrue(drafts.allSatisfy { $0.canSubmit && !$0.wubiEdited && !$0.pinyinEdited })
    }

    func testEditedCodeSurvivesTypingAnotherWord() {
        var drafts = rebuild("交集")
        drafts[0].pinyin = "jiaojii"
        XCTAssertTrue(drafts[0].pinyinEdited)

        drafts = rebuild("交集 银行", previous: drafts)
        XCTAssertEqual(drafts[0].pinyin, "jiaojii", "the user's edit is kept")
        XCTAssertEqual(drafts[1].pinyin, "yinhang")
    }

    func testRemovedWordDropsItsDraft() {
        let drafts = rebuild("交集", previous: rebuild("交集 银行"))
        XCTAssertEqual(drafts.map(\.text), ["交集"])
    }

    func testUngeneratableWordNeedsManualCode() {
        let drafts = rebuild("MarmotIM")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertTrue(drafts[0].needsManualCode)
        XCTAssertEqual(drafts[0].wubi, "")
        XCTAssertFalse(drafts[0].canSubmit, "a word needs at least one code")

        var typed = drafts[0]
        typed.pinyin = "marmot"
        XCTAssertTrue(typed.canSubmit)
    }

    func testSplittingAndDuplicates() {
        XCTAssertEqual(WordDraftBuilder.words(in: "  交集\n\n银行   交集 "), ["交集", "银行"])
        XCTAssertEqual(WordDraftBuilder.words(in: "   "), [])
    }

    func testClearingOneCodeStillSubmits() {
        var draft = rebuild("交集")[0]
        draft.pinyin = ""
        XCTAssertTrue(draft.canSubmit, "only the wubi code is added")
        draft.wubi = ""
        XCTAssertFalse(draft.canSubmit)
    }

    func testValidation() {
        XCTAssertTrue(WordDraft.isValidWubi("uqwy"))
        XCTAssertTrue(WordDraft.isValidWubi("u"))
        XCTAssertFalse(WordDraft.isValidWubi("uqwyy"))
        XCTAssertFalse(WordDraft.isValidWubi("UQ1"))
        XCTAssertFalse(WordDraft.isValidWubi(""))
        XCTAssertTrue(WordDraft.isValidPinyin("jiaoji"))
        XCTAssertFalse(WordDraft.isValidPinyin("jiao ji"))
        XCTAssertFalse(WordDraft.isValidPinyin("jiāo"))
    }

    func testEditDraftStartsFromStoredCodes() {
        let draft = WordDraftBuilder.makeDraft(text: "交集", wubi: "uqw", pinyin: "",
                                               generateWubi: { self.wubi[$0] },
                                               generatePinyin: { self.pinyin[$0] })
        XCTAssertEqual(draft.wubi, "uqw")
        XCTAssertTrue(draft.wubiEdited, "differs from the generated uqwy, so ↺ is offered")
        XCTAssertEqual(draft.pinyin, "", "a cleared code stays cleared")
    }
}
