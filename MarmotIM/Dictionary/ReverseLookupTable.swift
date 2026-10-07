//
//  ReverseLookupTable.swift
//  MarmotIM
//
//  反查表：汉字/词组 → 编码
//  用于划词入库功能
//
//  Refactored to use SQLite database instead of in-memory dictionaries
//  to eliminate memory spikes from JSON loading.
//

import Foundation

/// 反查表管理器：提供汉字到五笔/拼音编码的转换
/// 使用 VocabularyDatabase 进行查询，无需加载到内存
final class ReverseLookupTable {

    // MARK: - Singleton

    static let shared = ReverseLookupTable()

    // MARK: - Properties

    /// Database reference
    private let database = VocabularyDatabase.shared

    // MARK: - Initialization

    private init() {}

    // MARK: - Lookup Methods

    /// 获取词组的五笔编码
    ///
    /// 五笔取码规则:
    /// - 1字: 取全码（最多4码）
    /// - 2字: 各取前2码
    /// - 3字: 前两字各取1码，末字取2码
    /// - 4+字: 前三字各取1码，末字取1码
    ///
    /// - Parameter text: 要查询的中文文本
    /// - Returns: 五笔编码，如果有任何字无法转换则返回 nil
    func getWubiCode(for text: String) -> String? {
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }

        // 获取每个字的五笔全码
        var codes: [String] = []
        for char in chars {
            guard let code = database.getWubiCode(for: char), !code.isEmpty else {
                NSLog("MarmotIM: No wubi code for character: %@", String(char))
                return nil
            }
            codes.append(code)
        }

        // 根据词长确定取码规则
        switch chars.count {
        case 1:
            // 单字: 取全码（最多4码）
            return String(codes[0].prefix(4))

        case 2:
            // 两字词: 各取前2码
            let c1 = String(codes[0].prefix(2))
            let c2 = String(codes[1].prefix(2))
            return c1 + c2

        case 3:
            // 三字词: 前两字各取1码，末字取2码
            let c1 = String(codes[0].prefix(1))
            let c2 = String(codes[1].prefix(1))
            let c3 = String(codes[2].prefix(2))
            return c1 + c2 + c3

        default:
            // 四字及以上: 前三字各取1码，末字取1码
            let c1 = String(codes[0].prefix(1))
            let c2 = String(codes[1].prefix(1))
            let c3 = String(codes[2].prefix(1))
            let c4 = String(codes[codes.count - 1].prefix(1))
            return c1 + c2 + c3 + c4
        }
    }

    /// 获取词组的拼音编码
    ///
    /// 智能处理多音字:
    /// 1. 优先查询 polyphone_words 表
    /// 2. 尝试匹配包含该字的子词组
    /// 3. 回退到最常用读音（第一个）
    ///
    /// - Parameter text: 要查询的中文文本
    /// - Returns: 拼音编码，如果有任何字无法转换则返回 nil
    func getPinyinCode(for text: String) -> String? {
        // 1. 先检查是否整词在 polyphone_words 中
        if let wordPinyin = database.getWordPinyin(for: text) {
            return wordPinyin
        }

        // 2. 逐字拼接，智能处理多音字
        let chars = Array(text)
        var result = ""

        for (index, char) in chars.enumerated() {
            let pinyins = database.getPinyinCodes(for: char)
            guard !pinyins.isEmpty else {
                NSLog("MarmotIM: No pinyin for character: %@", String(char))
                return nil
            }

            if pinyins.count == 1 {
                // 单音字，直接使用
                result += pinyins[0]
            } else {
                // 多音字，尝试通过上下文判断
                let pinyin = resolvePinyinByContext(
                    char: char,
                    pinyins: pinyins,
                    text: text,
                    chars: chars,
                    index: index
                )
                result += pinyin
            }
        }

        return result
    }

    /// 通过上下文判断多音字的正确读音
    private func resolvePinyinByContext(
        char: Character,
        pinyins: [String],
        text: String,
        chars: [Character],
        index: Int
    ) -> String {
        // 策略1: 查找包含该字的已知词组（2-4字窗口）
        for window in Self.contextWindows(charCount: chars.count, index: index) {
            let subWord = String(chars[window])
            guard let wordPinyin = database.getWordPinyin(for: subWord) else { continue }
            // 从词组拼音中提取该字位置的拼音
            if let extractedPinyin = extractPinyinAtPosition(
                wordPinyin: wordPinyin,
                subWord: subWord,
                position: index - window.lowerBound
            ) {
                return extractedPinyin
            }
        }

        // 策略2: 使用最常用读音（第一个）
        return pinyins[0]
    }

    /// 包含 `index` 那个字的所有 2–4 字窗口，按窗口从短到长、起点从左到右。
    ///
    /// **这里原来是两个会让进程当场 trap 的区间。** Swift 的 `a...b` 在 `a > b` 时
    /// 不是空区间，而是 `Range requires lowerBound <= upperBound` 崩溃：
    ///
    /// - `2...min(4, charCount)` 在单字时就是 `2...1`。用户词库里点「+」新建条目，
    ///   敲下第一个字（且它是多音字）就会走到这里 —— 输入法整个退出。
    /// - `max(0, index - windowSize + 1)...min(index, charCount - windowSize)` 的上界
    ///   可以小于下界。
    ///
    /// 抽成不碰数据库的静态函数，是为了这两种边界能被测试直接钉住：触发它要有一条
    /// 多音字记录和一次真实按键，靠手点是碰运气。
    static func contextWindows(charCount: Int, index: Int) -> [Range<Int>] {
        // 单字无所谓上下文，没有窗口可言。
        guard charCount >= 2, index >= 0, index < charCount else { return [] }

        var windows: [Range<Int>] = []
        for windowSize in 2...min(4, charCount) {
            let firstStart = max(0, index - windowSize + 1)
            let lastStart = min(index, charCount - windowSize)
            guard firstStart <= lastStart else { continue }
            for startIdx in firstStart...lastStart {
                windows.append(startIdx..<(startIdx + windowSize))
            }
        }
        return windows
    }

    /// 从词组拼音中提取指定位置字符的拼音
    ///
    /// 例如: wordPinyin="yinhang", subWord="银行", position=1
    /// 应返回 "hang"
    private func extractPinyinAtPosition(
        wordPinyin: String,
        subWord: String,
        position: Int
    ) -> String? {
        let subChars = Array(subWord)
        guard position >= 0, position < subChars.count else { return nil }

        // 获取子词中每个字的所有可能拼音
        var possiblePinyins: [[String]] = []
        for char in subChars {
            let pinyins = database.getPinyinCodes(for: char)
            guard !pinyins.isEmpty else { return nil }
            possiblePinyins.append(pinyins)
        }

        // 尝试找到与 wordPinyin 匹配的拼音组合
        // 使用递归回溯
        var result: String?
        findMatchingCombination(
            wordPinyin: wordPinyin,
            possiblePinyins: possiblePinyins,
            currentIndex: 0,
            currentPinyin: "",
            currentCombination: [],
            targetPosition: position,
            result: &result
        )

        return result
    }

    /// 递归查找匹配的拼音组合
    private func findMatchingCombination(
        wordPinyin: String,
        possiblePinyins: [[String]],
        currentIndex: Int,
        currentPinyin: String,
        currentCombination: [String],
        targetPosition: Int,
        result: inout String?
    ) {
        // 如果已经找到结果，停止搜索
        if result != nil { return }

        // 剪枝：如果当前拼音已经比目标长，停止
        if currentPinyin.count > wordPinyin.count { return }

        // 如果已处理所有字符
        if currentIndex == possiblePinyins.count {
            if currentPinyin == wordPinyin {
                result = currentCombination[targetPosition]
            }
            return
        }

        // 剪枝：检查前缀是否匹配
        if !wordPinyin.hasPrefix(currentPinyin) { return }

        // 尝试当前位置的每个可能拼音
        for pinyin in possiblePinyins[currentIndex] {
            var newCombination = currentCombination
            newCombination.append(pinyin)

            findMatchingCombination(
                wordPinyin: wordPinyin,
                possiblePinyins: possiblePinyins,
                currentIndex: currentIndex + 1,
                currentPinyin: currentPinyin + pinyin,
                currentCombination: newCombination,
                targetPosition: targetPosition,
                result: &result
            )

            if result != nil { return }
        }
    }

    // MARK: - Utility

    /// 检查单个字符是否有五笔编码
    func hasWubiCode(for char: Character) -> Bool {
        return database.getWubiCode(for: char) != nil
    }

    /// 检查单个字符是否有拼音编码
    func hasPinyinCode(for char: Character) -> Bool {
        return !database.getPinyinCodes(for: char).isEmpty
    }

    /// 获取单个字符的五笔编码
    func getWubiCode(for char: Character) -> String? {
        return database.getWubiCode(for: char)
    }

    /// 获取单个字符的所有拼音
    func getAllPinyins(for char: Character) -> [String]? {
        let pinyins = database.getPinyinCodes(for: char)
        return pinyins.isEmpty ? nil : pinyins
    }
}
