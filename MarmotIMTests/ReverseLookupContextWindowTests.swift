import XCTest
@testable import MarmotIM

/// 多音字上下文窗口的边界。
///
/// 这些用例全部来自一次真实崩溃：用户词库里点「+」新建条目，敲第一个字就退出。
/// 栈顶是 `Swift runtime failure: Range requires lowerBound <= upperBound`
/// —— `2...min(4, charCount)` 在单字时是 `2...1`，而 Swift 的 `a...b` 在 `a > b`
/// 时不是空区间，是崩溃。
final class ReverseLookupContextWindowTests: XCTestCase {

    private func windows(_ charCount: Int, _ index: Int) -> [Range<Int>] {
        ReverseLookupTable.contextWindows(charCount: charCount, index: index)
    }

    // MARK: - 当初崩掉的那些入口

    /// 单字：`2...1`。这就是那次闪退。
    func testSingleCharacterHasNoWindows() {
        XCTAssertEqual(windows(1, 0), [], "单字没有上下文窗口，而且绝不能崩")
    }

    func testEmptyTextHasNoWindows() {
        XCTAssertEqual(windows(0, 0), [])
    }

    /// 下标越界、负数：调用方是 `chars.enumerated()`，正常不会给出这些，
    /// 但这个函数是公开的静态入口，不该靠调用方自律。
    func testOutOfRangeIndexHasNoWindows() {
        XCTAssertEqual(windows(2, 2), [])
        XCTAssertEqual(windows(2, 99), [])
        XCTAssertEqual(windows(2, -1), [])
    }

    // MARK: - 正常情况下窗口没有变

    func testTwoCharacters() {
        // 「银行」这种：唯一的窗口就是整词。
        XCTAssertEqual(windows(2, 0), [0..<2])
        XCTAssertEqual(windows(2, 1), [0..<2])
    }

    func testThreeCharacters() {
        // 先 2 字窗口再 3 字窗口，起点从左到右 —— 和修改前的循环顺序一致，
        // 因为命中顺序决定了多音字最终取哪个读音。
        XCTAssertEqual(windows(3, 0), [0..<2, 0..<3])
        XCTAssertEqual(windows(3, 1), [0..<2, 1..<3, 0..<3])
        XCTAssertEqual(windows(3, 2), [1..<3, 0..<3])
    }

    func testFourCharacters() {
        XCTAssertEqual(windows(4, 1), [0..<2, 1..<3, 0..<3, 1..<4, 0..<4])
    }

    /// 窗口最大 4 字，长词只在局部开窗。
    func testWindowSizeIsCappedAtFour() {
        for window in windows(10, 5) {
            XCTAssertLessThanOrEqual(window.count, 4)
            XCTAssertGreaterThanOrEqual(window.count, 2)
        }
        XCTAssertEqual(windows(10, 5).first, 4..<6)
    }

    // MARK: - 不变量

    /// 每个窗口都必须真的盖住那个多音字，并且落在串内 —— 否则
    /// `chars[window]` 或 `index - window.lowerBound` 会越界。
    func testEveryWindowCoversTheIndexAndStaysInBounds() {
        for charCount in 0...12 {
            for index in -1...(charCount + 1) {
                for window in windows(charCount, index) {
                    XCTAssertTrue(window.contains(index),
                                  "窗口 \(window) 没盖住 index \(index)")
                    XCTAssertGreaterThanOrEqual(window.lowerBound, 0)
                    XCTAssertLessThanOrEqual(window.upperBound, charCount)
                }
            }
        }
    }

    /// 真正的回归保护：任何 charCount/index 组合都不许 trap。
    /// 修改前，这个循环在第一次迭代就会让测试进程挂掉。
    func testNeverTrapsForAnyInput() {
        for charCount in 0...20 {
            for index in -3...(charCount + 3) {
                _ = windows(charCount, index)
            }
        }
    }

    func testNoDuplicateWindows() {
        let w = windows(5, 2)
        XCTAssertEqual(Set(w).count, w.count, "重复窗口只会让同一次查库白跑一遍")
    }
}
