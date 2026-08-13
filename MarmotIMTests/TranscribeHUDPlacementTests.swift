import XCTest
import AppKit
@testable import MarmotIM

/// 转写提示窗的落位。
///
/// 起因是一个真实缺陷：光标靠近屏幕底部时，提示窗被摆在光标下方
/// （`anchor.y - height - 5`），算出来的 y 是负的，整个窗口跑到屏幕外，
/// 于是"正在录音"这件事没有任何可见反馈。
///
/// 这里只测 `fittedOrigin` 这个纯函数：它就是当初算错的那一段，而包着它的
/// NSWindow 在测试进程里不好造。
final class TranscribeHUDPlacementTests: XCTestCase {

    /// 一块 1440×900、顶部让出 25pt 菜单栏的屏幕，原点不在 (0,0) ——
    /// 副屏的 visibleFrame 通常带偏移，用 0 原点会让一整类坐标错误测不出来。
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = NSSize(width: 140, height: 32)

    // MARK: - 缺陷本身

    func testACaretAtTheBottomEdgeKeepsTheWholeWindowOnScreen() {
        // 光标离底边只有 8pt：下方绝对放不下 32pt 高的窗口。
        let origin = TranscribeHUDWindow.fittedOrigin(
            anchor: NSPoint(x: 400, y: 8), size: size, visibleFrame: screen)

        XCTAssertGreaterThanOrEqual(origin.y, screen.minY,
            "窗口顶到了屏幕下沿之外 —— 这正是用户报的那个缺陷")
        XCTAssertLessThanOrEqual(origin.y + size.height, screen.maxY)
    }

    func testTheBottomEdgeCaseFlipsAboveTheCaretRatherThanJustClamping() {
        // 夹到 minY 也能让窗口"在屏幕内"，但会盖住光标所在的那一行。
        // 正确做法是翻到光标上方，和 CandidateWindow 一致。
        let anchor = NSPoint(x: 400, y: 8)
        let origin = TranscribeHUDWindow.fittedOrigin(
            anchor: anchor, size: size, visibleFrame: screen)

        XCTAssertGreaterThan(origin.y, anchor.y,
            "应当翻到光标上方，而不是压在光标上")
    }

    // MARK: - 另外三条边

    func testACaretAtTheRightEdgeDoesNotPushTheWindowOffScreen() {
        let origin = TranscribeHUDWindow.fittedOrigin(
            anchor: NSPoint(x: screen.maxX - 4, y: 500), size: size, visibleFrame: screen)

        XCTAssertLessThanOrEqual(origin.x + size.width, screen.maxX)
        XCTAssertGreaterThanOrEqual(origin.x, screen.minX)
    }

    func testACaretAtTheTopEdgeStaysBelowTheMenuBar() {
        // 顶部：首选位置本来就在下方，不该被翻上去顶出可见区域。
        let origin = TranscribeHUDWindow.fittedOrigin(
            anchor: NSPoint(x: 400, y: screen.maxY - 2), size: size, visibleFrame: screen)

        XCTAssertLessThanOrEqual(origin.y + size.height, screen.maxY)
    }

    func testAScreenWithAnOffsetOriginIsRespected() {
        // 副屏：visibleFrame 不从 0 开始。夹的时候若拿 0 当左/下边界，这里就会漏。
        let secondary = NSRect(x: -1920, y: -300, width: 1920, height: 1080)
        let origin = TranscribeHUDWindow.fittedOrigin(
            anchor: NSPoint(x: -1918, y: -295), size: size, visibleFrame: secondary)

        XCTAssertGreaterThanOrEqual(origin.x, secondary.minX)
        XCTAssertGreaterThanOrEqual(origin.y, secondary.minY)
        XCTAssertLessThanOrEqual(origin.x + size.width, secondary.maxX)
        XCTAssertLessThanOrEqual(origin.y + size.height, secondary.maxY)
    }

    // MARK: - 不该改动的情形

    func testAnAnchorWithRoomBelowIsLeftWhereItIs() {
        // 绝大多数情况：屏幕中央，四边都放得下，落位必须与原来完全一致，
        // 否则这次修边界会顺手把常规情形也挪了。
        let anchor = NSPoint(x: 700, y: 500)
        let origin = TranscribeHUDWindow.fittedOrigin(
            anchor: anchor, size: size, visibleFrame: screen)

        XCTAssertEqual(origin.x, anchor.x + 10)
        XCTAssertEqual(origin.y, anchor.y - size.height - 5)
    }

    func testWithoutScreenInformationThePreferredOriginIsReturnedUnchanged() {
        // 拿不到屏幕就不猜：返回首选位置，行为与加这段之前一致。
        let anchor = NSPoint(x: 400, y: 8)
        let origin = TranscribeHUDWindow.fittedOrigin(
            anchor: anchor, size: size, visibleFrame: nil)

        XCTAssertEqual(origin.y, anchor.y - size.height - 5)
    }
}
