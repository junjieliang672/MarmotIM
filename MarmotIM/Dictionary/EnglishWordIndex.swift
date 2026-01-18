import Foundation

/// 英文单词索引，支持大小写敏感的完全匹配
struct EnglishWordIndex {
    /// 小写形式 -> 所有变体（保持原始大小写）
    /// 例如: "the" -> ["the", "The", "THE"]
    private var variants: [String: [String]] = [:]

    /// 是否已加载
    private(set) var isLoaded = false

    /// 词条数量
    var count: Int { variants.count }

    /// 从文件加载英文词典
    /// 格式: "小写形式 变体1 变体2 ..."
    mutating func load(from url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            let key = parts[0].lowercased()
            let values = Array(parts.dropFirst())
            variants[key] = values
        }
        isLoaded = true
    }

    /// 完全匹配查找（大小写敏感，带 fallback）
    /// 1. 先精确匹配输入的大小写
    /// 2. 如果没有，fallback 到第一个变体（通常是小写）
    func exactMatch(_ code: String) -> String? {
        let key = code.lowercased()
        guard let values = variants[key] else { return nil }

        // 先找精确匹配
        if values.contains(code) {
            return code
        }

        // Fallback 到第一个变体（通常是小写）
        return values.first
    }

    /// 检查是否包含某个词（不区分大小写）
    func contains(_ code: String) -> Bool {
        return variants[code.lowercased()] != nil
    }
}

// MARK: - Test Helpers

extension EnglishWordIndex {
    /// 用于测试：直接设置数据
    mutating func setTestData(_ data: [String: [String]]) {
        variants = data
        isLoaded = true
    }

    /// 用于测试：清空数据
    mutating func clear() {
        variants.removeAll()
        isLoaded = false
    }
}
