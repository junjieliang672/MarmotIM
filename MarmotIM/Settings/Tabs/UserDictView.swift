import SwiftUI

/// User favorite entry (from user_favorites table)
struct UserFavoriteEntry: Identifiable {
    let id: Int
    let text: String
    let wubiCode: String?
    let pinyinCode: String?
    let timestamp: Int
}

/// User dictionary management view
/// Shows entries added via control+= (user_favorites table)
struct UserDictView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var userFavorites: [UserFavoriteEntry] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""
    @State private var selectedIds: Set<Int> = []
    @State private var statusMessage: String = ""
    @State private var showStatus: Bool = false

    /// Add / edit sheet; nil when closed
    @State private var sheetMode: WordSheetMode?

    private var filteredEntries: [UserFavoriteEntry] {
        if searchText.isEmpty {
            return userFavorites
        }
        let query = searchText.lowercased()
        return userFavorites.filter { entry in
            entry.text.lowercased().contains(query) ||
            (entry.pinyinCode?.lowercased().contains(query) ?? false) ||
            (entry.wubiCode?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索词条、编码...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // List area
            Group {
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if userFavorites.isEmpty {
                    VStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("暂无用户词条")
                                .foregroundColor(.secondary)
                            Text("使用 Control+= 划词入库")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } else if filteredEntries.isEmpty {
                    VStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("未找到匹配的词条")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    List(filteredEntries, id: \.id, selection: $selectedIds) { entry in
                        UserFavoriteRow(entry: entry)
                            .tag(entry.id)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .contextMenu(forSelectionType: Int.self) { ids in
                        Button("编辑编码…") { editEntry(id: ids.first) }
                            .disabled(ids.count != 1)
                    } primaryAction: { ids in
                        // Double-click
                        if ids.count == 1 { editEntry(id: ids.first) }
                    }
                }
            }
            .frame(minHeight: 200)

            Divider()

            // Bottom toolbar
            HStack(spacing: 0) {
                Button(action: { sheetMode = .add }) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .help("添加词条")

                Divider()
                    .frame(height: 16)

                Button(action: deleteSelectedEntries) {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selectedIds.isEmpty)
                .help("删除选中的词条")

                Divider()
                    .frame(height: 16)

                Button(action: { editEntry(id: selectedIds.first) }) {
                    Image(systemName: "pencil")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selectedIds.count != 1)
                .help("编辑选中词条的编码（也可以双击）")

                Spacer()

                if showStatus {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                        .padding(.trailing, 8)
                }

                Text("Control+= 划词入库 | Control+- 划词删除")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear {
            loadUserFavorites()
        }
        .sheet(item: $sheetMode) { mode in
            WordSheet(
                mode: mode,
                onSubmit: { drafts in
                    switch mode {
                    case .add:
                        addWords(drafts)
                    case .edit(let entry):
                        if let draft = drafts.first { saveEdit(original: entry, draft: draft) }
                    }
                    sheetMode = nil
                },
                onCancel: { sheetMode = nil }
            )
        }
    }

    // MARK: - Actions

    private func loadUserFavorites() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let favorites = VocabularyDatabase.shared.getUserFavorites()
            let entries = favorites.map { UserFavoriteEntry(id: $0.id, text: $0.text, wubiCode: $0.wubiCode, pinyinCode: $0.pinyinCode, timestamp: $0.timestamp) }
            DispatchQueue.main.async {
                self.userFavorites = entries
                self.isLoading = false
            }
        }
    }

    private func addWords(_ drafts: [WordDraft]) {
        var addedCount = 0

        for draft in drafts where draft.canSubmit {
            let wubi = draft.wubi.isEmpty ? nil : draft.wubi
            let pinyin = draft.pinyin.isEmpty ? nil : draft.pinyin

            if let engine = AppDelegate.shared?.dictionaryEngine {
                // Same path as Control+= : indexes both codes and records the favorite
                if engine.addDualEntry(text: draft.text, wubiCode: wubi, pinyinCode: pinyin).success {
                    addedCount += 1
                }
            } else if VocabularyDatabase.shared.addUserFavorite(text: draft.text, wubiCode: wubi, pinyinCode: pinyin) {
                // Engine not available (settings window standalone): the favorite
                // is indexed by ensureUserFavoritesIndexed on the next launch
                addedCount += 1
            }
        }

        loadUserFavorites()
        showStatusMessage(addedCount > 0 ? "已添加 \(addedCount) 个词条" : "添加失败")
    }

    private func editEntry(id: Int?) {
        guard let id = id, let entry = userFavorites.first(where: { $0.id == id }) else { return }
        sheetMode = .edit(entry)
    }

    private func saveEdit(original: UserFavoriteEntry, draft: WordDraft) {
        let wubi = draft.wubi.isEmpty ? nil : draft.wubi
        let pinyin = draft.pinyin.isEmpty ? nil : draft.pinyin
        guard wubi != original.wubiCode || pinyin != original.pinyinCode else { return }

        if let engine = AppDelegate.shared?.dictionaryEngine {
            // Drop the old codes from the index, then index the new ones
            _ = engine.removeDualEntry(text: original.text, wubiCode: original.wubiCode, pinyinCode: original.pinyinCode)
            _ = engine.addDualEntry(text: original.text, wubiCode: wubi, pinyinCode: pinyin)
        }
        // addUserFavorite keeps an existing code when passed nil; an edit that
        // clears a code must clear it in the favorite row too
        let ok = VocabularyDatabase.shared.setUserFavoriteCodes(text: original.text, wubiCode: wubi, pinyinCode: pinyin)

        loadUserFavorites()
        showStatusMessage(ok ? "已更新 \(original.text)" : "更新失败")
    }

    private func deleteSelectedEntries() {
        guard !selectedIds.isEmpty else { return }

        var deletedCount = 0

        for id in selectedIds {
            // Find the entry in our list to get text/codes for complete deletion
            guard let entry = userFavorites.first(where: { $0.id == id }) else {
                continue
            }

            // Use DictionaryEngine for complete deletion (entries table + trie + user_favorites)
            // This ensures the entry won't reappear in search results
            if let engine = AppDelegate.shared?.dictionaryEngine {
                let result = engine.removeDualEntry(
                    text: entry.text,
                    wubiCode: entry.wubiCode,
                    pinyinCode: entry.pinyinCode
                )
                if result.success || !result.notFound {
                    // Even if it wasn't a user entry (system entry), mark as success
                    // because the soft delete in user_favorites was done
                    deletedCount += 1
                }
            } else {
                // Engine not available (e.g., settings window standalone)
                // Fall back to soft delete only
                if VocabularyDatabase.shared.removeUserFavoriteById(id) {
                    deletedCount += 1
                }
            }
        }

        selectedIds.removeAll()
        loadUserFavorites()

        if deletedCount > 0 {
            showStatusMessage("已删除 \(deletedCount) 个词条")
        }
    }

    private func showStatusMessage(_ message: String) {
        statusMessage = message
        withAnimation {
            showStatus = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showStatus = false
            }
        }
    }
}

// MARK: - User Favorite Row

struct UserFavoriteRow: View {
    let entry: UserFavoriteEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.text)
                .font(.body)

            Spacer()

            HStack(spacing: 8) {
                if let wubi = entry.wubiCode, !wubi.isEmpty {
                    Text(wubi)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                if let pinyin = entry.pinyinCode, !pinyin.isEmpty {
                    Text(pinyin)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Word Drafts

/// One word in the add / edit sheet, with its auto-generated codes and the
/// codes currently in the fields (which the user may have changed).
struct WordDraft: Identifiable, Equatable {
    var id: String { text }
    let text: String
    var wubi: String
    var pinyin: String
    /// What the generator produced; nil when it couldn't (rare character,
    /// non-Chinese text). The ↺ button restores these.
    let autoWubi: String?
    let autoPinyin: String?

    var wubiEdited: Bool { wubi != (autoWubi ?? "") }
    var pinyinEdited: Bool { pinyin != (autoPinyin ?? "") }
    var wubiIsValid: Bool { wubi.isEmpty || Self.isValidWubi(wubi) }
    var pinyinIsValid: Bool { pinyin.isEmpty || Self.isValidPinyin(pinyin) }
    /// Neither code could be generated, so the user has to type one
    var needsManualCode: Bool { autoWubi == nil && autoPinyin == nil }
    /// At least one code, and every non-empty code well-formed
    var canSubmit: Bool { wubiIsValid && pinyinIsValid && !(wubi.isEmpty && pinyin.isEmpty) }

    static func isValidWubi(_ code: String) -> Bool {
        (1...4).contains(code.count) && isLowercaseLetters(code)
    }

    static func isValidPinyin(_ code: String) -> Bool {
        !code.isEmpty && isLowercaseLetters(code)
    }

    private static func isLowercaseLetters(_ code: String) -> Bool {
        code.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
    }
}

enum WordDraftBuilder {

    /// Words in the input box: split on spaces and newlines, duplicates
    /// dropped, first occurrence's order kept.
    static func words(in input: String) -> [String] {
        var seen = Set<String>()
        return input
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Drafts for the current input. A word already in `previous` keeps its
    /// draft as is, so typing another word doesn't wipe codes the user edited.
    static func rebuild(
        input: String,
        previous: [WordDraft],
        generateWubi: (String) -> String?,
        generatePinyin: (String) -> String?
    ) -> [WordDraft] {
        words(in: input).map { word in
            if let existing = previous.first(where: { $0.text == word }) {
                return existing
            }
            return makeDraft(text: word, generateWubi: generateWubi, generatePinyin: generatePinyin)
        }
    }

    static func makeDraft(
        text: String,
        wubi: String? = nil,
        pinyin: String? = nil,
        generateWubi: (String) -> String?,
        generatePinyin: (String) -> String?
    ) -> WordDraft {
        let autoWubi = generateWubi(text)
        let autoPinyin = generatePinyin(text)
        return WordDraft(text: text,
                         wubi: wubi ?? autoWubi ?? "",
                         pinyin: pinyin ?? autoPinyin ?? "",
                         autoWubi: autoWubi,
                         autoPinyin: autoPinyin)
    }
}

// MARK: - Word Sheet

enum WordSheetMode: Identifiable {
    case add
    case edit(UserFavoriteEntry)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let entry): return "edit-\(entry.id)"
        }
    }
}

/// Add words (codes generated, editable) or edit one word's codes
struct WordSheet: View {
    let mode: WordSheetMode
    let onSubmit: ([WordDraft]) -> Void
    let onCancel: () -> Void

    @State private var input: String = ""
    @State private var drafts: [WordDraft] = []

    private static func generateWubi(_ text: String) -> String? {
        ReverseLookupTable.shared.getWubiCode(for: text)
    }

    private static func generatePinyin(_ text: String) -> String? {
        ReverseLookupTable.shared.getPinyinCode(for: text)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canSubmit: Bool {
        !drafts.isEmpty && drafts.allSatisfy { $0.canSubmit }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "编辑编码" : "添加词条")
                .font(.headline)

            if !isEditing {
                VStack(alignment: .leading, spacing: 4) {
                    Text("词条（空格或换行分隔多个）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("如: 交集 百感交集", text: $input, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .onChange(of: input) { newValue in
                            drafts = WordDraftBuilder.rebuild(
                                input: newValue, previous: drafts,
                                generateWubi: Self.generateWubi, generatePinyin: Self.generatePinyin)
                        }
                }
            }

            if !drafts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("词条").frame(width: 120, alignment: .leading)
                        Text("五笔").frame(width: 96, alignment: .leading)
                        Text("拼音").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)

                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach($drafts) { $draft in
                                WordDraftRow(draft: $draft)
                            }
                        }
                    }
                    .frame(maxHeight: 220)

                    Text("编码自动生成，可以直接修改；清空某个编码，就不加入那种输入方式。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Button("取消") { onCancel() }
                    .keyboardShortcut(.escape)

                Spacer()

                Button(isEditing ? "保存" : (drafts.count > 1 ? "添加 \(drafts.count) 个" : "添加")) {
                    onSubmit(drafts)
                }
                .keyboardShortcut(.return)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if case .edit(let entry) = mode {
                drafts = [WordDraftBuilder.makeDraft(
                    text: entry.text, wubi: entry.wubiCode ?? "", pinyin: entry.pinyinCode ?? "",
                    generateWubi: Self.generateWubi, generatePinyin: Self.generatePinyin)]
            }
        }
    }
}

struct WordDraftRow: View {
    @Binding var draft: WordDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(draft.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 120, alignment: .leading)
                    .help(draft.text)

                codeField("五笔", text: $draft.wubi, isValid: draft.wubiIsValid,
                          edited: draft.wubiEdited, reset: { draft.wubi = draft.autoWubi ?? "" })
                    .frame(width: 96)

                codeField("拼音", text: $draft.pinyin, isValid: draft.pinyinIsValid,
                          edited: draft.pinyinEdited, reset: { draft.pinyin = draft.autoPinyin ?? "" })
                    .frame(maxWidth: .infinity)

                Image(systemName: draft.canSubmit ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(draft.canSubmit ? .green : .red)
            }
            if draft.needsManualCode && draft.wubi.isEmpty && draft.pinyin.isEmpty {
                Text("无法自动生成编码，请手动输入")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 128)
            } else if !draft.wubiIsValid {
                Text("五笔编码是 1–4 个英文字母")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 128)
            } else if !draft.pinyinIsValid {
                Text("拼音只能包含英文字母，不要空格")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 128)
            }
        }
    }

    private func codeField(_ placeholder: String, text: Binding<String>, isValid: Bool,
                           edited: Bool, reset: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: Binding(
                get: { text.wrappedValue },
                set: { text.wrappedValue = $0.lowercased() }
            ))
            .textFieldStyle(.roundedBorder)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isValid ? Color.clear : Color.red, lineWidth: 1)
            )
            if edited {
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("恢复自动生成的编码")
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let userDictionaryDidChange = Notification.Name("MarmotIMUserDictionaryDidChange")
}

// MARK: - Preview

#if DEBUG
struct UserDictView_Previews: PreviewProvider {
    static var previews: some View {
        UserDictView(viewModel: SettingsViewModel())
            .frame(width: 500, height: 400)
    }
}
#endif
