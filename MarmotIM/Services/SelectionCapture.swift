//
//  SelectionCapture.swift
//  MarmotIM
//
//  获取其他应用中选中的文本
//  用于划词入库功能
//

import Cocoa
import ApplicationServices

/// 选中文本获取服务
final class SelectionCapture {

    // MARK: - Singleton

    static let shared = SelectionCapture()

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// 获取当前焦点应用中的选中文本
    ///
    /// 优先使用 Accessibility API，如果失败则使用剪贴板方式
    ///
    /// - Returns: 选中的文本，如果无法获取则返回 nil
    func getSelectedText() -> String? {
        // 方法1: 尝试使用 Accessibility API
        if let text = getSelectedTextViaAccessibility() {
            return text
        }

        // 方法2: 使用剪贴板方式（模拟 Cmd+C）
        NSLog("MarmotIM: SelectionCapture - Falling back to clipboard method")
        return getSelectedTextViaClipboard()
    }

    /// 通过 Accessibility API 获取选中文本
    private func getSelectedTextViaAccessibility() -> String? {
        // 1. 获取系统级辅助功能元素
        let systemWide = AXUIElementCreateSystemWide()

        // 2. 获取当前焦点元素
        var focusedElement: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success,
              let element = focusedElement else {
            NSLog("MarmotIM: SelectionCapture - Failed to get focused element (error: %d)", focusResult.rawValue)
            return nil
        }

        // 3. 尝试获取选中文本
        var selectedText: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        )

        if textResult == .success,
           let text = selectedText as? String,
           !text.isEmpty {
            NSLog("MarmotIM: SelectionCapture - Got selected text via AX: '%@'", text)
            return text
        }

        NSLog("MarmotIM: SelectionCapture - AX method failed (error: %d)", textResult.rawValue)
        return nil
    }

    /// 通过剪贴板获取选中文本（模拟 Cmd+C）
    private func getSelectedTextViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general

        // 1. 保存当前剪贴板内容
        let previousChangeCount = pasteboard.changeCount
        let previousContents = pasteboard.string(forType: .string)

        // 2. 模拟 Cmd+C
        simulateCopy()

        // 3. 等待一小段时间让系统处理按键事件
        Thread.sleep(forTimeInterval: 0.05)

        // 4. 等待剪贴板更新（最多等待 200ms）
        var attempts = 0
        while pasteboard.changeCount == previousChangeCount && attempts < 20 {
            Thread.sleep(forTimeInterval: 0.01)
            attempts += 1
        }

        // 5. 读取新的剪贴板内容
        guard pasteboard.changeCount != previousChangeCount,
              let newText = pasteboard.string(forType: .string),
              !newText.isEmpty else {
            NSLog("MarmotIM: SelectionCapture - Clipboard method failed, no new content (attempts: %d)", attempts)
            return nil
        }

        NSLog("MarmotIM: SelectionCapture - Got selected text via clipboard: '%@'", newText)

        // 6. 恢复之前的剪贴板内容（可选，避免覆盖用户的剪贴板）
        // 注意：这会导致用户无法使用 Cmd+V 粘贴刚复制的内容
        // 暂时不恢复，让用户可以直接粘贴
        // if let previous = previousContents {
        //     pasteboard.clearContents()
        //     pasteboard.setString(previous, forType: .string)
        // }

        return newText
    }

    /// 模拟 Cmd+C 复制操作
    private func simulateCopy() {
        // 创建 Cmd+C 按键事件
        let source = CGEventSource(stateID: .hidSystemState)

        // 按下 Cmd
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        cmdDown?.flags = .maskCommand

        // 按下 C
        let cDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        cDown?.flags = .maskCommand

        // 释放 C
        let cUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        cUp?.flags = .maskCommand

        // 释放 Cmd
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        // 发送事件
        let location = CGEventTapLocation.cghidEventTap
        cmdDown?.post(tap: location)
        cDown?.post(tap: location)
        cUp?.post(tap: location)
        cmdUp?.post(tap: location)
    }

    /// 检查是否有辅助功能权限
    ///
    /// 如果没有权限且 prompt 为 true，会弹出系统权限请求对话框
    ///
    /// - Parameter prompt: 是否在无权限时弹出权限请求对话框
    /// - Returns: 是否有权限
    func checkAccessibilityPermission(prompt: Bool = true) -> Bool {
        // 先检查是否已有权限（不弹窗）
        let alreadyTrusted = AXIsProcessTrusted()

        if alreadyTrusted {
            return true
        }

        // 没有权限，根据 prompt 参数决定是否弹窗
        if prompt {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
            _ = AXIsProcessTrustedWithOptions(options)
            NSLog("MarmotIM: SelectionCapture - Accessibility permission not granted, prompting user")
        } else {
            NSLog("MarmotIM: SelectionCapture - Accessibility permission not granted")
        }

        return false
    }

    /// 过滤文本，只保留中文字符
    ///
    /// - Parameter text: 原始文本
    /// - Returns: 只包含中文字符的文本
    func filterChineseCharacters(_ text: String) -> String {
        return text.filter { $0.isChineseCharacter }
    }

    /// 验证文本是否适合入库
    ///
    /// - Parameter text: 要验证的文本
    /// - Returns: 验证结果
    func validateForDictionary(_ text: String) -> ValidationResult {
        // 过滤中文字符
        let chineseText = filterChineseCharacters(text)

        if chineseText.isEmpty {
            return .invalid(reason: "没有中文字符")
        }

        if chineseText.count > 20 {
            return .invalid(reason: "文本过长（最多20字）")
        }

        if chineseText.count == 1 {
            return .warning(text: chineseText, reason: "单字入库")
        }

        return .valid(text: chineseText)
    }

    /// 验证结果
    enum ValidationResult {
        case valid(text: String)
        case warning(text: String, reason: String)
        case invalid(reason: String)

        var isValid: Bool {
            switch self {
            case .valid, .warning:
                return true
            case .invalid:
                return false
            }
        }

        var text: String? {
            switch self {
            case .valid(let text), .warning(let text, _):
                return text
            case .invalid:
                return nil
            }
        }
    }
}

// MARK: - Character Extension

extension Character {
    /// 判断字符是否是中文字符
    var isChineseCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }

        // CJK Unified Ideographs (基本汉字)
        if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF {
            return true
        }

        // CJK Unified Ideographs Extension A (扩展A)
        if scalar.value >= 0x3400 && scalar.value <= 0x4DBF {
            return true
        }

        // CJK Unified Ideographs Extension B (扩展B)
        if scalar.value >= 0x20000 && scalar.value <= 0x2A6DF {
            return true
        }

        // CJK Unified Ideographs Extension C (扩展C)
        if scalar.value >= 0x2A700 && scalar.value <= 0x2B73F {
            return true
        }

        // CJK Unified Ideographs Extension D (扩展D)
        if scalar.value >= 0x2B740 && scalar.value <= 0x2B81F {
            return true
        }

        // CJK Unified Ideographs Extension E (扩展E)
        if scalar.value >= 0x2B820 && scalar.value <= 0x2CEAF {
            return true
        }

        // CJK Unified Ideographs Extension F (扩展F)
        if scalar.value >= 0x2CEB0 && scalar.value <= 0x2EBEF {
            return true
        }

        // CJK Compatibility Ideographs (兼容汉字)
        if scalar.value >= 0xF900 && scalar.value <= 0xFAFF {
            return true
        }

        return false
    }
}
