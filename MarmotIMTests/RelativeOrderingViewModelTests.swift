import XCTest
@testable import MarmotIM

/// Spec-003 Level-4 view-model tests for RelativeOrderingViewModel.
/// Exercises only the view-model layer (not SwiftUI rendering) against
/// an isolated VocabularyDatabase.makeForTests instance.
final class RelativeOrderingViewModelTests: XCTestCase {

    private var tempDir: URL!
    private var db: VocabularyDatabase!
    private var vm: RelativeOrderingViewModel!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-vm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = VocabularyDatabase.makeForTests(path: tempDir.appendingPathComponent("test.db"))
        vm = RelativeOrderingViewModel(db: db, onMutated: {})
    }

    override func tearDown() {
        vm = nil
        db = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // I-RO-UI-01: add success path
    func testAddSuccess_clearsInputsAndReloadsList() {
        vm.wordA = "你好"
        vm.wordB = "世界"
        vm.add()

        XCTAssertEqual(vm.rules.count, 1)
        XCTAssertEqual(vm.wordA, "")
        XCTAssertEqual(vm.wordB, "")
        XCTAssertNil(vm.errorMessage)
    }

    // I-RO-UI-02: empty input
    func testAddEmpty_setsHudMessage() {
        vm.wordA = ""
        vm.wordB = "x"
        vm.add()

        XCTAssertEqual(vm.errorMessage, "请填写两个词")
        XCTAssertEqual(vm.rules.count, 0)
    }

    // I-RO-UI-03: identical words
    func testAddIdentical_setsHudMessage() {
        vm.wordA = "同"
        vm.wordB = "同"
        vm.add()
        XCTAssertEqual(vm.errorMessage, "两个词不能相同")
    }

    // I-RO-UI-04: duplicate
    func testAddDuplicate_setsHudMessage() {
        vm.wordA = "A"
        vm.wordB = "B"
        vm.add()
        XCTAssertNil(vm.errorMessage, "first add should succeed")

        vm.wordA = "A"
        vm.wordB = "B"
        vm.add()
        XCTAssertEqual(vm.errorMessage, "该规则已存在")
    }

    // I-RO-UI-05: cycle
    func testAddCycle_setsHudMessage() {
        vm.wordA = "A"
        vm.wordB = "B"
        vm.add()
        XCTAssertNil(vm.errorMessage)

        vm.wordA = "B"
        vm.wordB = "A"
        vm.add()
        XCTAssertEqual(vm.errorMessage, "该规则会造成循环（与已有规则冲突）")
    }

    // I-RO-UI-06: delete removes row
    func testDelete_removesRow() {
        vm.wordA = "A"
        vm.wordB = "B"
        vm.add()
        guard let rule = vm.rules.first else {
            XCTFail("need an initial rule")
            return
        }

        vm.remove(id: rule.id)
        XCTAssertEqual(vm.rules.count, 0)
    }

    // Typing into a text field clears an existing error message.
    func testTyping_clearsErrorMessage() {
        vm.wordA = ""
        vm.wordB = "x"
        vm.add()
        XCTAssertNotNil(vm.errorMessage)

        vm.wordA = "y"
        XCTAssertNil(vm.errorMessage, "modifying wordA should clear the error")
    }

    // canSubmit is false when either side is empty after trim.
    func testCanSubmit_falseWhenEitherEmpty() {
        vm.wordA = ""
        vm.wordB = "x"
        XCTAssertFalse(vm.canSubmit)

        vm.wordA = "  "
        vm.wordB = "x"
        XCTAssertFalse(vm.canSubmit)

        vm.wordA = "a"
        vm.wordB = "b"
        XCTAssertTrue(vm.canSubmit)
    }

    // mapError returns a non-empty zh-Hans string for every case.
    func testMapError_allCasesCovered() {
        XCTAssertFalse(vm.mapError(.emptyInput).isEmpty)
        XCTAssertFalse(vm.mapError(.identicalWords).isEmpty)
        XCTAssertFalse(vm.mapError(.duplicate).isEmpty)
        XCTAssertFalse(vm.mapError(.cycle(path: ["A","B","A"])).isEmpty)
        XCTAssertFalse(vm.mapError(.dbUnavailable).isEmpty)
    }
}
