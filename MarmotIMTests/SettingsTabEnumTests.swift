import XCTest
@testable import MarmotIM

/// Spec-003 T1 + T5 regression guard: the top-level SettingsTab enum
/// shrinks from seven cases to five (Import/Export deleted in T1;
/// 用户词库 / 降权词库 folded under 词库管理 in T5).
final class SettingsTabEnumTests: XCTestCase {

    // I-IX-REMOVE-01: .importExport must not appear in allCases.
    func testNoImportExportCase() {
        let labels = Set(SettingsTab.allCases.map { $0.rawValue })
        XCTAssertFalse(labels.contains("导入导出"),
                       "导入导出 tab was removed in spec-003 T1")
    }

    // 用户词库 and 降权词库 are now inside DictionaryManagementView
    // and no longer top-level tabs.
    func testStandaloneUserDictAndSuppressedTabsRemoved() {
        let labels = Set(SettingsTab.allCases.map { $0.rawValue })
        XCTAssertFalse(labels.contains("用户词库"),
                       "用户词库 moved into DictionaryManagementView in spec-003 T5")
        XCTAssertFalse(labels.contains("降权词库"),
                       "降权词库 moved into DictionaryManagementView in spec-003 T5")
    }

    // Five top-level tabs: 基本, 词库管理, 标点符号, 主题, 关于.
    func testFiveTopLevelTabs() {
        XCTAssertEqual(SettingsTab.allCases.count, 5,
                       "spec-003 T5 consolidates to exactly 5 top-level tabs")
        let expected: [String] = ["基本", "词库管理", "标点符号", "主题", "关于"]
        XCTAssertEqual(SettingsTab.allCases.map { $0.rawValue }, expected)
    }

    // The 词库管理 tab's three inner tabs are the expected set.
    func testDictionaryManagementHasThreeInnerTabs() {
        let labels = Set(DictionaryManagementView.InnerTab.allCases.map { $0.rawValue })
        XCTAssertEqual(labels, ["用户词库", "降权词库", "相对排序"])
    }
}
