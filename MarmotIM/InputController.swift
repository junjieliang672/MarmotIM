import Cocoa
import InputMethodKit

/// Filter mode for specialized input (emoji, fuzzy pinyin, symbol)
enum FilterMode: String {
    case none = ""
    case emoji = "e"
    case fuzzyPinyin = "p"
    case symbol = "s"

    var displayLabel: String {
        switch self {
        case .none: return ""
        case .emoji: return "[🙂 emoji]"
        case .fuzzyPinyin: return "[拼 模糊拼音]"
        case .symbol: return "[※ 符号]"
        }
    }
}

/// Main input controller handling keyboard events and candidate selection
@objc(MarmotIMInputController)
class InputController: IMKInputController {

    // MARK: - Properties

    /// Current input buffer (the code being typed)
    private var inputBuffer: String = ""

    /// All candidates for current input
    private var allCandidates: [Candidate] = []

    /// Current page of candidates (displayed)
    private var currentCandidates: [Candidate] = []

    /// Current page index (0-based)
    private var currentPage: Int = 0

    /// Candidates per page
    private let pageSize: Int = 9

    /// Candidate window controller
    private var candidateWindowController: CandidateWindowController?

    /// Whether we're in composition mode
    private var isComposing: Bool = false

    /// Last committed text (for repeat function)
    private var lastCommittedText: String = ""

    /// Whether input is in English mode (pass-through)
    private var isEnglishMode: Bool = false

    /// Track when Shift was pressed (for quick-tap detection)
    private var shiftPressedTime: Date?

    /// Track if Shift was used as a modifier (with another key) rather than standalone
    private var shiftUsedAsModifier: Bool = false

    /// Pending shift toggle work item (used for delayed toggle to handle Electron app timing issues)
    private var pendingShiftToggle: DispatchWorkItem?

    /// Track when the last keyDown event occurred (for ZSA keyboard timing fix)
    private var lastKeyDownTime: Date?

    /// Track state for paired punctuation (true = next should be closing)
    private var pairedPunctuationState: [String: Bool] = [:]

    /// Current filter mode (none, emoji, fuzzyPinyin, symbol)
    private var filterMode: FilterMode = .none

    /// Input buffer for filter mode (separate from normal inputBuffer)
    private var filterBuffer: String = ""

    /// Chinese quote pairs: opening → closing
    /// Only quotes support open/close pairing, NOT brackets
    private let chineseQuotePairs: [String: String] = [
        "\u{201C}": "\u{201D}",  // " → "
        "\u{2018}": "\u{2019}",  // ' → '
    ]

    /// Total number of pages
    private var totalPages: Int {
        return max(1, (allCandidates.count + pageSize - 1) / pageSize)
    }

    // MARK: - Initialization

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let clientType = inputClient == nil ? "nil" : String(describing: type(of: inputClient!))
        let clientDesc = inputClient == nil ? "nil" : String(describing: inputClient!)
        NSLog("MarmotIM: InputController init - server: \(server != nil), clientType: \(clientType)")
        NSLog("MarmotIM: InputController init - clientDesc: \(clientDesc.prefix(200))")
        super.init(server: server, delegate: delegate, client: inputClient)
        NSLog("MarmotIM: InputController init complete")
    }

    // MARK: - IMKInputController Overrides

    override func recognizedEvents(_ sender: Any!) -> Int {
        // Request key down events and flags changed events (for Shift toggle)
        let clientType = sender == nil ? "nil" : String(describing: type(of: sender!))
        NSLog("MarmotIM: recognizedEvents() called - client: \(clientType)")
        return Int(NSEvent.EventTypeMask.keyDown.rawValue | NSEvent.EventTypeMask.flagsChanged.rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        let clientType = sender == nil ? "nil" : String(describing: type(of: sender!))
        let isIMKTextInput = sender is IMKTextInput
        NSLog("MarmotIM: activateServer() - client: \(clientType), isIMKTextInput: \(isIMKTextInput)")
        
        // Reset state
        reset()
        resetPairedPunctuationState()
        
        // Force Chinese mode on activation to prevent being stuck in English mode
        // This ensures the IME is ready to type Chinese when selected or app is switched
        isEnglishMode = false
        ModeIndicator.shared.hide() // Hide any lingering indicators
    }

    override func deactivateServer(_ sender: Any!) {
        NSLog("MarmotIM: deactivateServer()")
        super.deactivateServer(sender)
        hideCandidateWindow()
        reset()
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event else {
            NSLog("MarmotIM: handle() called with nil event")
            return false
        }

        // Log client type for debugging
        let clientType = sender == nil ? "nil" : String(describing: type(of: sender!))

        // Handle flags changed events (for Shift toggle)
        if event.type == .flagsChanged {
            return handleFlagsChanged(event, client: sender)
        }

        // Only handle key down events
        guard event.type == .keyDown else { return false }

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.characters ?? ""

        // Pass through other Command key shortcuts (Cmd+C, Cmd+V, Cmd+A, etc.)
        // These should be handled by the system, not the input method
        if modifiers.contains(.command) {
            return false
        }

        // Record keyDown timestamp for ZSA keyboard timing fix
        // ZSA keyboards may send events in order: Shift down → Shift up → keyDown
        // We need to detect this and prevent false mode toggles
        let now = Date()
        lastKeyDownTime = now
        NSLog("MarmotIM: keyDown at \(now.timeIntervalSince1970), shiftPressedTime: \(shiftPressedTime?.timeIntervalSince1970 ?? 0)")

        // If Shift is held while pressing another key, mark it as used as modifier (not for mode switching)
        if modifiers.contains(.shift) {
            shiftUsedAsModifier = true
        }

        // Cancel any pending shift toggle (handles race condition in Electron apps like Lark)
        // In Electron, keyDown may arrive AFTER shift release, so we cancel the pending toggle here
        if pendingShiftToggle != nil {
            pendingShiftToggle?.cancel()
            pendingShiftToggle = nil
            NSLog("MarmotIM: Cancelled pending shift toggle due to keyDown event")
        }

        // Debug log for troubleshooting app-specific issues
        NSLog("MarmotIM: handle() - keyCode: \(keyCode), chars: '\(characters)', isEnglish: \(isEnglishMode), filterMode: \(filterMode), filterBuffer: '\(filterBuffer)', client: \(clientType)")

        // Handle Ctrl shortcuts (works in both Chinese and English mode)
        if modifiers.contains(.control) {
            if handleControlShortcut(keyCode: keyCode, client: sender) {
                return true
            }
        }

        // English mode: pass through all input
        if isEnglishMode {
            return false
        }

        // Handle special keys
        switch keyCode {
        case 36: // Return/Enter
            return handleReturn(client: sender)
        case 53: // Escape
            return handleEscape(client: sender)
        case 51: // Backspace
            return handleBackspace(client: sender)
        case 49: // Space
            return handleSpace(client: sender)
        case 48: // Tab
            return handleTab(client: sender)
        case 125, 126: // Down/Up arrow
            return handleArrowKey(isDown: keyCode == 125, client: sender)
        case 33: // [ key - page up
            return handlePageUp(client: sender)
        case 30: // ] key - page down
            return handlePageDown(client: sender)
        case 43: // , key - page up
            if isComposing {
                return handlePageUp(client: sender)
            }
        case 47: // . key - page down
            if isComposing {
                return handlePageDown(client: sender)
            }
        case 41: // ; key
            if isComposing && filterMode == .none && inputBuffer.count == 1 {
                let prefix = inputBuffer.lowercased()
                if let mode = FilterMode(rawValue: prefix), mode != .none {
                    NSLog("MarmotIM: Entering filter mode via semicolon: \(mode.displayLabel)")
                    filterMode = mode
                    filterBuffer = ""
                    inputBuffer = ""
                    isComposing = true  // Ensure composing state is maintained
                    updateMarkedText(client: sender)
                    showFilterCandidates(client: sender)
                    NSLog("MarmotIM: Filter mode entered successfully, filterMode=\(filterMode), isComposing=\(isComposing)")
                    return true
                }
            }
        default:
            break
        }

        // Handle number keys for candidate selection (1-9)
        // Works in both normal mode (inputBuffer not empty) and filter mode
        if let char = characters.first, char.isNumber, (!inputBuffer.isEmpty || filterMode != .none) {
            let num = Int(String(char)) ?? 0
            if num >= 1 && num <= 9 {
                return selectCandidate(at: num - 1, client: sender)
            }
        }

        // Handle letter input
        if let char = characters.first, char.isLetter && char.isASCII {
            // Pass original character - handleLetterInput will handle uppercase detection
            return handleLetterInput(String(char), client: sender)
        }

        // Handle punctuation - convert based on config
        if let char = characters.first, !char.isLetter && !char.isNumber && !char.isWhitespace {
            // Only handle punctuation in Chinese mode and when not composing
            if !isComposing {
                if handlePunctuation(String(char), client: sender) {
                    return true
                }
            }
        }

        // Pass through other characters if not composing
        if !isComposing {
            return false
        }

        return false
    }

    // MARK: - Punctuation Handling

    /// Handle punctuation conversion based on config
    /// Logic:
    /// 1. First check explicit mapping (customPunctuation for custom mode, defaultChinesePunctuation for chinese mode)
    /// 2. If mapped output is English punctuation, output directly (no pairing)
    /// 3. If mapped output is Chinese quote AND autoPairPunctuation is enabled, apply open/close pairing
    /// 4. Otherwise output the mapped character directly
    private func handlePunctuation(_ char: String, client sender: Any!) -> Bool {
        let config = AppDelegate.config

        switch config.punctuationMode {
        case .english:
            // Pass through English punctuation unchanged
            return false

        case .chinese:
            // Use default Chinese punctuation mapping
            if let mapped = defaultChinesePunctuation[char] {
                let output = applyQuotePairing(input: char, mapped: mapped, config: config)
                commitText(output, client: sender)
                return true
            }
            return false

        case .custom:
            // Use custom mapping - strictly follow the explicit definition
            if let mapped = config.customPunctuation[char], mapped != char {
                let output = applyQuotePairing(input: char, mapped: mapped, config: config)
                commitText(output, client: sender)
                return true
            }
            return false
        }
    }

    /// Apply quote pairing if the mapped character is a Chinese opening quote
    /// Only Chinese quotes (" and ') support open/close alternation, NOT brackets
    private func applyQuotePairing(input: String, mapped: String, config: AppConfig) -> String {
        // Only apply pairing if autoPairPunctuation is enabled
        guard config.autoPairPunctuation else {
            return mapped
        }

        // Check if the mapped character is a Chinese opening quote
        if let closingQuote = chineseQuotePairs[mapped] {
            // This is a Chinese opening quote - alternate between open and close
            let isClosing = pairedPunctuationState[input] ?? false
            pairedPunctuationState[input] = !isClosing
            return isClosing ? closingQuote : mapped
        }

        // Not a Chinese quote - output the mapped character directly
        return mapped
    }

    /// Reset paired punctuation state (called when switching modes or apps)
    private func resetPairedPunctuationState() {
        pairedPunctuationState.removeAll()
    }

    // MARK: - Input Handling

    private func handleLetterInput(_ char: String, client sender: Any!) -> Bool {
        // Route to filter mode if active
        NSLog("MarmotIM: handleLetterInput called with char: '\(char)', filterMode: \(filterMode)")
        if filterMode != .none {
            NSLog("MarmotIM: Routing to handleFilterInput because filterMode is \(filterMode)")
            return handleFilterInput(char, client: sender)
        }

        // Add character to input buffer preserving original case
        // This allows users to type "This" and see "This" in the buffer
        inputBuffer.append(char)
        isComposing = true

        // Update marked text (shows original case)
        updateMarkedText(client: sender)

        // Search for candidates (uses lowercased input for matching)
        searchCandidates()

        // Show candidate window
        showCandidateWindow(client: sender)

        return true
    }

    /// Handle input in filter mode
    private func handleFilterInput(_ char: String, client sender: Any!) -> Bool {
        NSLog("MarmotIM: handleFilterInput called with char: '\(char)', filterMode: \(filterMode), filterBuffer before: '\(filterBuffer)'")
        filterBuffer.append(char.lowercased())
        isComposing = true
        NSLog("MarmotIM: filterBuffer after append: '\(filterBuffer)'")

        // Update marked text with filter prefix
        updateMarkedText(client: sender)

        // Search in filter-specific dictionary
        showFilterCandidates(client: sender)

        return true
    }

    /// Exit filter mode
    /// - Parameter commit: If true, commit selected candidate; if false, cancel
    private func exitFilterMode(commit: Bool, client sender: Any!) {
        NSLog("MarmotIM: Exiting filter mode (commit: \(commit))")

        if commit && !allCandidates.isEmpty {
            // Commit the first candidate
            let candidate = allCandidates[0]
            commitText(candidate.text, client: sender)

            // Record selection for filter ranking (isolated from normal mode)
            recordFilterSelection(code: filterBuffer, word: candidate.text)
        }

        // Reset filter state
        filterMode = .none
        filterBuffer = ""

        // Reset normal state
        reset()
        hideCandidateWindow()

        if let client = sender as? IMKTextInput {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private func handleSpace(client sender: Any!) -> Bool {
        // Handle filter mode space - commit first candidate
        if filterMode != .none && !allCandidates.isEmpty {
            exitFilterMode(commit: true, client: sender)
            return true
        }

        guard isComposing else { return false }

        // If we have candidates, select the first one
        if !currentCandidates.isEmpty {
            return selectCandidate(at: 0, client: sender)
        }

        // No candidates - clear input without committing (unlike Enter which respects settings)
        reset()
        hideCandidateWindow()
        if let client = sender as? IMKTextInput {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        return true
    }

    private func handleReturn(client sender: Any!) -> Bool {
        NSLog("MarmotIM: handleReturn - isComposing=%d, inputBuffer='%@', enterKeyBehavior=%@",
              isComposing ? 1 : 0, inputBuffer, AppDelegate.config.enterKeyBehavior.rawValue)

        // Handle filter mode return - commit first candidate
        if filterMode != .none && !allCandidates.isEmpty {
            exitFilterMode(commit: true, client: sender)
            return true
        }

        guard isComposing else { return false }

        // Check enter key behavior setting
        switch AppDelegate.config.enterKeyBehavior {
        case .clearCode:
            // Clear the input code without outputting
            NSLog("MarmotIM: handleReturn - clearing code")
            reset()
            hideCandidateWindow()
            if let client = sender as? IMKTextInput {
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case .outputCode:
            // Commit the raw input buffer (preserving original case)
            NSLog("MarmotIM: handleReturn - outputting code: '%@'", inputBuffer)
            commitText(inputBuffer, client: sender)
            reset()
        }
        return true
    }

    private func handleEscape(client sender: Any!) -> Bool {
        // Handle filter mode escape
        if filterMode != .none {
            exitFilterMode(commit: false, client: sender)
            return true
        }

        guard isComposing else { return false }

        reset()
        hideCandidateWindow()

        // Clear marked text
        if let client = sender as? IMKTextInput {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        return true
    }

    private func handleBackspace(client sender: Any!) -> Bool {
        guard isComposing else { return false }

        // Handle filter mode backspace
        if filterMode != .none {
            guard !filterBuffer.isEmpty else {
                // Exit filter mode when buffer is empty
                exitFilterMode(commit: false, client: sender)
                return true
            }

            filterBuffer.removeLast()

            if filterBuffer.isEmpty {
                // Show empty filter mode UI (no candidates)
                allCandidates = []
                currentCandidates = []
                hideCandidateWindow()
            } else {
                showFilterCandidates(client: sender)
            }
            updateMarkedText(client: sender)
            return true
        }

        // Normal mode backspace
        guard !inputBuffer.isEmpty else { return false }

        // Remove last character
        inputBuffer.removeLast()

        if inputBuffer.isEmpty {
            reset()
            hideCandidateWindow()
            if let client = sender as? IMKTextInput {
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        } else {
            updateMarkedText(client: sender)
            searchCandidates()
            showCandidateWindow(client: sender)
        }

        return true
    }

    /// Handle Tab key - no longer triggers filter mode
    private func handleTab(client sender: Any!) -> Bool {
        // Tab no longer triggers filter mode (use ; instead)
        // Return false to let Tab pass through
        return false
    }

    private func handleArrowKey(isDown: Bool, client sender: Any!) -> Bool {
        guard isComposing else { return false }
        // Arrow key navigation handled by candidate window
        candidateWindowController?.handleArrowKey(isDown: isDown)
        return true
    }

    private func handlePageUp(client sender: Any!) -> Bool {
        guard isComposing, !allCandidates.isEmpty else { return false }

        if currentPage > 0 {
            currentPage -= 1
            updateCurrentPageCandidates()
            showCandidateWindow(client: sender)
        }
        return true
    }

    private func handlePageDown(client sender: Any!) -> Bool {
        guard isComposing, !allCandidates.isEmpty else { return false }

        if currentPage < totalPages - 1 {
            currentPage += 1
            updateCurrentPageCandidates()
            showCandidateWindow(client: sender)
        }
        return true
    }

    private func updateCurrentPageCandidates() {
        let startIndex = currentPage * pageSize
        let endIndex = min(startIndex + pageSize, allCandidates.count)
        if startIndex < allCandidates.count {
            currentCandidates = Array(allCandidates[startIndex..<endIndex])
        } else {
            currentCandidates = []
        }
    }

    private func handleControlShortcut(keyCode: UInt16, client sender: Any!) -> Bool {
        // Control + = (keyCode 24) or numpad + (keyCode 69) - 划词入库
        if keyCode == 24 || keyCode == 69 {
            return handleAddSelectedTextToDict(client: sender)
        }

        // Control + - (keyCode 27) or numpad - (keyCode 78) - 划词删除
        if keyCode == 27 || keyCode == 78 {
            return handleRemoveSelectedTextFromDict(client: sender)
        }

        // Pass through other Ctrl shortcuts
        return false
    }

    // MARK: - 划词入库

    /// 划词入库：获取选中文本并添加到词库
    /// 使用 IMKTextInput 的 selectedRange 和 attributedSubstring 方法直接获取选中文本
    private func handleAddSelectedTextToDict(client sender: Any!) -> Bool {
        NSLog("MarmotIM: handleAddSelectedTextToDict triggered")

        // 1. 通过 IMKTextInput 协议获取选中文本
        guard let client = sender as? IMKTextInput else {
            NSLog("MarmotIM: Client is not IMKTextInput")
            ModeIndicator.shared.showMessageAtCursor("无法获取文本")
            return true
        }

        // 获取选中范围
        let selectedRange = client.selectedRange()
        NSLog("MarmotIM: selectedRange - location: %d, length: %d", selectedRange.location, selectedRange.length)

        // 检查是否有选中文本
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            NSLog("MarmotIM: No text selected (range invalid or length 0)")
            ModeIndicator.shared.showMessageAtCursor("未选中文本")
            return true
        }

        // 获取选中的文本内容
        // 使用 string(from:actualRange:) 方法 (Obj-C: stringFromRange:actualRange:)
        var actualRange = NSRange(location: NSNotFound, length: 0)
        guard let selectedText = client.string(from: selectedRange, actualRange: &actualRange),
              !selectedText.isEmpty else {
            NSLog("MarmotIM: Failed to get string from range")
            ModeIndicator.shared.showMessageAtCursor("无法获取选中内容")
            return true
        }
        NSLog("MarmotIM: Selected text: '%@'", selectedText)

        // 3. 验证文本
        let validationResult = SelectionCapture.shared.validateForDictionary(selectedText)
        guard validationResult.isValid, let chineseText = validationResult.text else {
            if case .invalid(let reason) = validationResult {
                NSLog("MarmotIM: Invalid text for dictionary: %@", reason)
                ModeIndicator.shared.showMessageAtCursor(reason)
            }
            return true
        }

        NSLog("MarmotIM: Filtered Chinese text: '%@'", chineseText)

        // 4. 生成编码 (queries database directly)
        let wubiCode = ReverseLookupTable.shared.getWubiCode(for: chineseText)
        let pinyinCode = ReverseLookupTable.shared.getPinyinCode(for: chineseText)

        NSLog("MarmotIM: Generated codes - wubi: %@, pinyin: %@",
              wubiCode ?? "nil", pinyinCode ?? "nil")

        guard wubiCode != nil || pinyinCode != nil else {
            NSLog("MarmotIM: Failed to generate codes for: '%@'", chineseText)
            ModeIndicator.shared.showMessageAtCursor("无法生成编码")
            return true
        }

        // 6. 入库
        guard let engine = AppDelegate.shared?.dictionaryEngine else {
            NSLog("MarmotIM: DictionaryEngine not available")
            ModeIndicator.shared.showMessageAtCursor("词库未就绪")
            return true
        }

        let result = engine.addDualEntry(
            text: chineseText,
            wubiCode: wubiCode,
            pinyinCode: pinyinCode
        )

        // 7. 显示结果
        if result.success {
            var message = "已入库: \(chineseText)"
            if result.wubiWasExisting && result.pinyinWasExisting {
                message = "已更新: \(chineseText)"
            } else if result.wubiWasExisting || result.pinyinWasExisting {
                message = "已入库: \(chineseText) (部分更新)"
            }
            ModeIndicator.shared.showMessageAtCursor(message, duration: 1.5)
            NSLog("MarmotIM: Successfully added '%@' to dictionary", chineseText)
        } else {
            ModeIndicator.shared.showMessageAtCursor("入库失败")
            NSLog("MarmotIM: Failed to add '%@' to dictionary", chineseText)
        }

        return true
    }

    // MARK: - 划词删除

    /// 划词删除：获取选中文本并从词库中删除
    /// 只能删除用户自己添加的词条，系统词库不可删除
    private func handleRemoveSelectedTextFromDict(client sender: Any!) -> Bool {
        NSLog("MarmotIM: handleRemoveSelectedTextFromDict triggered")

        // 1. 通过 IMKTextInput 协议获取选中文本
        guard let client = sender as? IMKTextInput else {
            NSLog("MarmotIM: Client is not IMKTextInput")
            ModeIndicator.shared.showMessageAtCursor("无法获取文本")
            return true
        }

        // 获取选中范围
        let selectedRange = client.selectedRange()
        NSLog("MarmotIM: selectedRange - location: %d, length: %d", selectedRange.location, selectedRange.length)

        // 检查是否有选中文本
        guard selectedRange.location != NSNotFound, selectedRange.length > 0 else {
            NSLog("MarmotIM: No text selected (range invalid or length 0)")
            ModeIndicator.shared.showMessageAtCursor("未选中文本")
            return true
        }

        // 获取选中的文本内容
        var actualRange = NSRange(location: NSNotFound, length: 0)
        guard let selectedText = client.string(from: selectedRange, actualRange: &actualRange),
              !selectedText.isEmpty else {
            NSLog("MarmotIM: Failed to get string from range")
            ModeIndicator.shared.showMessageAtCursor("无法获取选中内容")
            return true
        }
        NSLog("MarmotIM: Selected text for removal: '%@'", selectedText)

        // 2. 过滤中文字符
        let chineseText = SelectionCapture.shared.filterChineseCharacters(selectedText)
        guard !chineseText.isEmpty else {
            NSLog("MarmotIM: No Chinese characters in selection")
            ModeIndicator.shared.showMessageAtCursor("没有中文字符")
            return true
        }

        NSLog("MarmotIM: Filtered Chinese text: '%@'", chineseText)

        // 3. 生成编码 (queries database directly)
        let wubiCode = ReverseLookupTable.shared.getWubiCode(for: chineseText)
        let pinyinCode = ReverseLookupTable.shared.getPinyinCode(for: chineseText)

        NSLog("MarmotIM: Generated codes - wubi: %@, pinyin: %@",
              wubiCode ?? "nil", pinyinCode ?? "nil")

        guard wubiCode != nil || pinyinCode != nil else {
            NSLog("MarmotIM: Failed to generate codes for: '%@'", chineseText)
            ModeIndicator.shared.showMessageAtCursor("无法生成编码")
            return true
        }

        // 5. 删除词条
        guard let engine = AppDelegate.shared?.dictionaryEngine else {
            NSLog("MarmotIM: DictionaryEngine not available")
            ModeIndicator.shared.showMessageAtCursor("词库未就绪")
            return true
        }

        let result = engine.removeDualEntry(
            text: chineseText,
            wubiCode: wubiCode,
            pinyinCode: pinyinCode
        )

        // 6. 显示结果
        if result.success {
            ModeIndicator.shared.showMessageAtCursor("已删除: \(chineseText)", duration: 1.5)
            NSLog("MarmotIM: Successfully removed '%@' from dictionary", chineseText)
        } else if result.notFound {
            ModeIndicator.shared.showMessageAtCursor("词条不存在")
            NSLog("MarmotIM: '%@' not found in dictionary", chineseText)
        } else if result.foundButNotUserEntry {
            ModeIndicator.shared.showMessageAtCursor("非用户词条，无法删除")
            NSLog("MarmotIM: '%@' is a system entry, cannot remove", chineseText)
        } else {
            // Found as user entry but removal failed
            ModeIndicator.shared.showMessageAtCursor("删除失败")
            NSLog("MarmotIM: Failed to remove '%@' from dictionary", chineseText)
        }

        return true
    }

    private func handleFlagsChanged(_ event: NSEvent, client sender: Any!) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Check if Shift key state changed
        if event.keyCode == 56 || event.keyCode == 60 { // Left Shift or Right Shift
            let now = Date()
            if modifiers.contains(.shift) {
                // Shift pressed down - only record timestamp if not already pressed
                // This handles ZSA keyboards that send both Left and Right Shift events
                if shiftPressedTime == nil {
                    shiftPressedTime = now
                    shiftUsedAsModifier = false
                    pendingShiftToggle?.cancel()
                    pendingShiftToggle = nil
                    NSLog("MarmotIM: Shift DOWN (first) at \(now.timeIntervalSince1970)")
                } else {
                    NSLog("MarmotIM: Shift DOWN (ignored, already pressed) at \(now.timeIntervalSince1970)")
                }
            } else {
                // Shift released - only process once (shiftPressedTime will be nil after first processing)
                // This handles ZSA keyboards that send both Left and Right Shift UP events
                guard shiftPressedTime != nil else {
                    NSLog("MarmotIM: Shift UP (ignored, already processed) at \(now.timeIntervalSince1970)")
                    return false
                }
                NSLog("MarmotIM: Shift UP at \(now.timeIntervalSince1970), lastKeyDownTime: \(lastKeyDownTime?.timeIntervalSince1970 ?? 0)")
                // Shift released - check if it was a quick tap (< 150ms) AND not used as modifier
                if let pressedTime = shiftPressedTime {
                    let elapsed = Date().timeIntervalSince(pressedTime)
                    // Only toggle mode if:
                    // 1. Quick tap (< 150ms)
                    // 2. Shift was NOT used as a modifier (with another key)
                    if elapsed < 0.15 && !shiftUsedAsModifier {
                        // Use delayed toggle to handle race condition in Electron apps (Lark, etc.)
                        // and ZSA keyboards which may send events in order: Shift down → Shift up → keyDown
                        // By delaying the toggle by 50ms, we give the keyDown event time to arrive.
                        pendingShiftToggle?.cancel()
                        let shiftDownTime = pressedTime  // Capture for closure
                        let workItem = DispatchWorkItem { [weak self] in
                            guard let self = self else { return }
                            // Double-check conditions haven't changed
                            // Also check if a keyDown occurred after shift was pressed (ZSA keyboard fix)
                            let keyDownAfterShift = self.lastKeyDownTime.map { $0 > shiftDownTime } ?? false
                            if !self.shiftUsedAsModifier && !keyDownAfterShift {
                                NSLog("MarmotIM: Executing delayed shift toggle")
                                self.toggleInputMode(client: sender)
                            } else {
                                NSLog("MarmotIM: Cancelled shift toggle - shiftUsedAsModifier: \(self.shiftUsedAsModifier), keyDownAfterShift: \(keyDownAfterShift)")
                            }
                            self.pendingShiftToggle = nil
                        }
                        pendingShiftToggle = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
                    }
                }
                shiftPressedTime = nil
                shiftUsedAsModifier = false
            }
        }

        return false // Don't consume the event
    }

    private func toggleInputMode(client sender: Any!) {
        isEnglishMode = !isEnglishMode

        // If switching to English mode while composing, commit the input buffer as English text
        if isEnglishMode && isComposing {
            // Output the typed pinyin as English text instead of discarding it
            if !inputBuffer.isEmpty {
                commitText(inputBuffer, client: sender)
            }
            reset()
            hideCandidateWindow()
            // Clear marked text
            if let client = sender as? IMKTextInput {
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }

        // Show mode indicator if enabled
        if AppDelegate.config.showModeIndicator {
            // Try multiple methods to get cursor position
            var position = NSEvent.mouseLocation  // Default fallback

            if let client = sender as? IMKTextInput {
                var cursorRect = NSRect.zero
                client.attributes(forCharacterIndex: 0, lineHeightRectangle: &cursorRect)

                // Check if we got a valid cursor position (not at origin and reasonable values)
                if cursorRect.origin.x > 10 || cursorRect.origin.y > 50 {
                    position = cursorRect.origin
                }
            }

            ModeIndicator.shared.show(isEnglishMode: isEnglishMode, at: position)
        }
    }

    // MARK: - Candidate Search

    private func searchCandidates() {
        guard let engine = AppDelegate.shared?.dictionaryEngine else {
            allCandidates = []
            currentCandidates = []
            return
        }

        // Search using lowercased input (codes in database are lowercase)
        let searchCode = inputBuffer.lowercased()
        let matches = engine.search(code: searchCode, limit: 100)

        // Rank candidates using Frecency (new API with engine for user learning data)
        allCandidates = CandidateRanker.rank(
            matches: matches,
            inputCode: searchCode,
            engine: engine
        )

        // Reset to first page
        currentPage = 0
        updateCurrentPageCandidates()
    }

    // MARK: - Candidate Selection

    private func selectCandidate(at index: Int, client sender: Any!) -> Bool {
        // Index is relative to current page
        guard index >= 0 && index < currentCandidates.count else { return false }

        let candidate = currentCandidates[index]
        NSLog("MarmotIM: selectCandidate - text='%@', entryId=%u, baseFreq=%u, inputCode='%@'",
              candidate.text, candidate.entryId, candidate.baseFrequency, inputBuffer)
        commitText(candidate.text, client: sender)

        // If in filter mode, exit after selection
        if filterMode != .none {
            // Record selection for filter ranking (isolated from normal mode)
            recordFilterSelection(code: filterBuffer, word: candidate.text)
            filterMode = .none
            filterBuffer = ""
        }

        // Update user data (learning) - uses new DictionaryEngine API
        // CRITICAL: Use explicit guard to detect when engine is nil (bug detection)
        if let engine = AppDelegate.shared?.dictionaryEngine {
            engine.recordSelection(
                entryId: candidate.entryId,
                baseFrequency: candidate.baseFrequency
            )
        } else {
            // This would explain why selections don't affect ranking!
            NSLog("MarmotIM: ERROR - recordSelection skipped! AppDelegate.shared=%@, dictionaryEngine=%@",
                  AppDelegate.shared == nil ? "nil" : "exists",
                  AppDelegate.shared?.dictionaryEngine == nil ? "nil" : "exists")
        }

        reset()
        return true
    }

    // MARK: - Text Commit

    private func commitText(_ text: String, client sender: Any!) {
        if let client = sender as? IMKTextInput {
            NSLog("MarmotIM: commitText() - inserting '\(text)'")
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            NSLog("MarmotIM: commitText() - FAILED: client is not IMKTextInput, type: \(sender == nil ? "nil" : String(describing: type(of: sender!)))")
        }
        lastCommittedText = text
        hideCandidateWindow()
    }

    // MARK: - Marked Text

    private func updateMarkedText(client sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }

        let displayText: String
        if filterMode != .none {
            // Show filter mode label + buffer
            displayText = "\(filterMode.displayLabel) \(filterBuffer)"
        } else {
            // Set inputBuffer as marked text so the client knows there's composing text
            // This fixes backspace issues in Chrome/Electron where empty marked text
            // causes backspace to delete both the composing character and committed text
            displayText = inputBuffer
        }

        client.setMarkedText(
            displayText,
            selectionRange: NSRange(location: displayText.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    // MARK: - Candidate Window

    private func showCandidateWindow(client sender: Any!) {
        // Always show window when composing (even with no candidates)
        // This provides visual feedback for the input code
        guard isComposing else {
            hideCandidateWindow()
            return
        }

        if candidateWindowController == nil {
            candidateWindowController = CandidateWindowController()
        }

        // Get cursor position from client
        var cursorRect = NSRect.zero
        if let client = sender as? IMKTextInput {
            client.attributes(forCharacterIndex: 0, lineHeightRectangle: &cursorRect)
        }

        candidateWindowController?.show(
            candidates: currentCandidates,
            nearRect: cursorRect,
            inputCode: inputBuffer,
            currentPage: currentPage,
            totalPages: totalPages
        )
    }

    private func hideCandidateWindow() {
        candidateWindowController?.hide()
    }

    /// Show candidates for current filter mode
    private func showFilterCandidates(client sender: Any!) {
        NSLog("MarmotIM: showFilterCandidates called, filterMode: \(filterMode), filterBuffer: '\(filterBuffer)'")
        guard let engine = AppDelegate.shared?.dictionaryEngine else {
            NSLog("MarmotIM: showFilterCandidates - engine is nil!")
            return
        }

        var filterResults: [FilterCandidate] = []

        switch filterMode {
        case .emoji:
            filterResults = engine.searchEmoji(code: filterBuffer)
            NSLog("MarmotIM: searchEmoji returned \(filterResults.count) results for code '\(filterBuffer)'")
        case .fuzzyPinyin:
            filterResults = engine.searchFuzzyPinyin(code: filterBuffer)
            NSLog("MarmotIM: searchFuzzyPinyin returned \(filterResults.count) results for code '\(filterBuffer)'")
        case .symbol:
            filterResults = engine.searchSymbol(code: filterBuffer)
            NSLog("MarmotIM: searchSymbol returned \(filterResults.count) results for code '\(filterBuffer)'")
        case .none:
            NSLog("MarmotIM: showFilterCandidates - filterMode is none, returning")
            return
        }

        // Convert FilterCandidate to Candidate for display
        allCandidates = filterResults.enumerated().map { (index, fc) in
            let freq = UInt16(min(fc.frequency, Int(UInt16.max)))
            return Candidate(
                entryId: UInt32(index),
                text: fc.text,
                code: fc.code,
                codeType: .pinyin,  // Simplified for filter mode
                isFullMatch: true,
                wubiBaseFrequency: freq,
                pinyinBaseFrequency: freq,
                score: Double(fc.frequency)
            )
        }
        NSLog("MarmotIM: converted to \(allCandidates.count) candidates")

        // Apply filter user ranking (isolated from normal mode)
        rankFilterCandidates()

        currentPage = 0
        updateCurrentPageCandidates()
        NSLog("MarmotIM: currentCandidates count: \(currentCandidates.count), isComposing: \(isComposing)")
        showCandidateWindow(client: sender)
    }

    // MARK: - Filter Mode Ranking

    /// Record filter mode selection (delegates to database)
    private func recordFilterSelection(code: String, word: String) {
        VocabularyDatabase.shared.recordFilterSelection(
            filterType: filterMode.rawValue,
            code: code,
            word: word
        )
    }

    /// Rank filter candidates using isolated user data
    private func rankFilterCandidates() {
        let userFreqs = VocabularyDatabase.shared.getFilterUserFreq(
            filterType: filterMode.rawValue,
            code: filterBuffer
        )

        // Create lookup for user frequency
        var freqLookup: [String: (Int, Double)] = [:]
        for (word, freq, lastUsed) in userFreqs {
            freqLookup[word] = (freq, lastUsed)
        }

        // Apply user frequency to candidates
        for i in 0..<allCandidates.count {
            if let (freq, lastUsed) = freqLookup[allCandidates[i].text] {
                // Boost score based on user frequency
                let recencyBonus = calculateFilterRecencyBonus(lastUsed: lastUsed)
                allCandidates[i].score += Double(freq) * 10000 + recencyBonus
            }
        }

        // Re-sort by score
        allCandidates.sort { $0.score > $1.score }
    }

    private func calculateFilterRecencyBonus(lastUsed: Double) -> Double {
        let now = Date().timeIntervalSince1970
        let hoursSince = (now - lastUsed) / 3600

        if hoursSince < 1 {
            return 1_000_000  // Within last hour
        } else if hoursSince < 24 {
            return 100_000    // Within last day
        } else if hoursSince < 168 {
            return 10_000     // Within last week
        }
        return 0
    }

    // MARK: - Reset

    private func reset() {
        inputBuffer = ""
        allCandidates = []
        currentCandidates = []
        currentPage = 0
        isComposing = false
        // Reset filter mode state
        filterMode = .none
        filterBuffer = ""
    }

    // MARK: - IMKStateSetting Protocol

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        // Handle input mode changes if needed
        super.setValue(value, forTag: tag, client: sender)
    }

    // MARK: - Command Selectors (intercept Tab before IMK default handling)

    override func didCommand(by selector: Selector!, client sender: Any!) -> Bool {
        NSLog("MarmotIM: didCommand(by: \(selector?.description ?? "nil"))")

        // Intercept insertTab: which is sent when Tab is pressed
        if selector == #selector(insertTab(_:)) {
            NSLog("MarmotIM: Intercepted insertTab - passing through")
            return false  // Let Tab pass through
        }

        return super.didCommand(by: selector, client: sender)
    }

    @objc func insertTab(_ sender: Any?) {
        // Placeholder for selector
    }

    // MARK: - Menu

    /// Returns the menu for the input method (shown when clicking the menu bar icon)
    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "MarmotIM")

        // Settings section header
        let headerItem = NSMenuItem(title: "土拨鼠输入法", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // Settings
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings(_:)),
            keyEquivalent: "["
        )
        settingsItem.keyEquivalentModifierMask = [.control, .option, .command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        // User Dictionary
        let userDictItem = NSMenuItem(
            title: "用户词库…",
            action: #selector(openUserDictionary(_:)),
            keyEquivalent: "]"
        )
        userDictItem.keyEquivalentModifierMask = [.control, .option, .command]
        userDictItem.target = self
        menu.addItem(userDictItem)

        // iCloud Sync Status
        let syncItem = NSMenuItem(
            title: syncStatusText(),
            action: #selector(syncNow(_:)),
            keyEquivalent: ""
        )
        syncItem.target = self
        syncItem.image = syncStatusIcon()
        menu.addItem(syncItem)

        menu.addItem(NSMenuItem.separator())

        // Input mode section
        let modeHeaderItem = NSMenuItem(title: "输入模式", action: nil, keyEquivalent: "")
        modeHeaderItem.isEnabled = false
        menu.addItem(modeHeaderItem)

        // Chinese mode
        let chineseModeItem = NSMenuItem(
            title: "中文",
            action: #selector(switchToChineseMode(_:)),
            keyEquivalent: ""
        )
        chineseModeItem.target = self
        chineseModeItem.state = isEnglishMode ? .off : .on
        menu.addItem(chineseModeItem)

        // English mode
        let englishModeItem = NSMenuItem(
            title: "英文",
            action: #selector(switchToEnglishMode(_:)),
            keyEquivalent: ""
        )
        englishModeItem.target = self
        englishModeItem.state = isEnglishMode ? .on : .off
        menu.addItem(englishModeItem)

        return menu
    }

    // MARK: - Menu Actions

    @objc private func openSettings(_ sender: Any?) {
        NSLog("MarmotIM: Opening settings...")
        DispatchQueue.main.async {
            SettingsWindowController.shared.showSettings()
        }
    }

    @objc private func openUserDictionary(_ sender: Any?) {
        NSLog("MarmotIM: Opening user dictionary...")
        DispatchQueue.main.async {
            // Open settings and switch to user dictionary tab
            SettingsWindowController.shared.showSettings()
            // TODO: Add method to switch to specific tab
        }
    }

    @objc private func switchToChineseMode(_ sender: Any?) {
        if isEnglishMode {
            isEnglishMode = false
            NSLog("MarmotIM: Switched to Chinese mode via menu")
        }
    }

    @objc private func switchToEnglishMode(_ sender: Any?) {
        if !isEnglishMode {
            isEnglishMode = true
            NSLog("MarmotIM: Switched to English mode via menu")
        }
    }

    // MARK: - iCloud Sync Status

    private func syncStatusText() -> String {
        let sync = iCloudSyncManager.shared

        // iCloud not available
        guard sync.isICloudAvailable else {
            return "iCloud 未连接"
        }

        // Syncing
        if sync.isSyncing {
            return "同步中..."
        }

        // Never synced
        guard let lastTime = sync.lastSyncTime else {
            return "未同步"
        }

        // Sync failed
        if !sync.lastSyncSuccess {
            return "同步失败 · 点击重试"
        }

        // Sync success, show time ago
        let timeAgo = formatTimeAgo(lastTime)
        return "已同步 · \(timeAgo)"
    }

    private func syncStatusIcon() -> NSImage? {
        let sync = iCloudSyncManager.shared

        let iconName: String
        if !sync.isICloudAvailable {
            iconName = "icloud.slash"
        } else if sync.isSyncing {
            iconName = "arrow.triangle.2.circlepath"
        } else if !sync.lastSyncSuccess {
            iconName = "exclamationmark.icloud"
        } else {
            iconName = "checkmark.icloud"
        }

        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func formatTimeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)

        if seconds < 60 {
            return "刚刚"
        } else if seconds < 3600 {
            return "\(seconds / 60)分钟前"
        } else if seconds < 86400 {
            return "\(seconds / 3600)小时前"
        } else if seconds < 604800 {
            return "\(seconds / 86400)天前"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }

    @objc private func syncNow(_ sender: Any?) {
        NSLog("MarmotIM: Manual sync triggered")
        iCloudSyncManager.shared.syncNow()
    }
}
