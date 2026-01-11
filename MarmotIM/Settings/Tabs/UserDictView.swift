import SwiftUI

/// User dictionary management view
/// macOS native style with +/- buttons and search
struct UserDictView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var userEntries: [DictionaryEntry] = []
    @State private var isLoading: Bool = true
    @State private var showingAddSheet: Bool = false
    @State private var searchText: String = ""
    @State private var selectedEntryIds: Set<UInt32> = []
    @State private var statusMessage: String = ""
    @State private var showStatus: Bool = false

    // Add sheet state
    @State private var newCode: String = ""
    @State private var newWords: String = ""
    @State private var isWubiCode: Bool = false

    private var filteredEntries: [DictionaryEntry] {
        if searchText.isEmpty {
            return userEntries
        }
        let query = searchText.lowercased()
        return userEntries.filter { entry in
            entry.text.lowercased().contains(query) ||
            entry.pinyin.lowercased().contains(query) ||
            (entry.wubi?.lowercased().contains(query) ?? false)
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
                } else if userEntries.isEmpty {
                    VStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "book.closed")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("暂无用户词条")
                                .foregroundColor(.secondary)
                            Text("点击下方 + 添加词条")
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
                    List(filteredEntries, id: \.id, selection: $selectedEntryIds) { entry in
                        UserEntryRow(entry: entry)
                            .tag(entry.id)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(minHeight: 200)

            Divider()

            // Bottom toolbar with +/- buttons
            HStack(spacing: 0) {
                Button(action: { showingAddSheet = true }) {
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
                .disabled(selectedEntryIds.isEmpty)
                .help("删除选中的词条")

                Spacer()

                if showStatus {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                        .padding(.trailing, 8)
                }

                Text("添加后立即生效")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear {
            loadUserEntries()
        }
        .sheet(isPresented: $showingAddSheet) {
            AddWordSheet(
                code: $newCode,
                words: $newWords,
                isWubi: $isWubiCode,
                onAdd: { addWord() },
                onCancel: {
                    showingAddSheet = false
                    clearInputs()
                }
            )
        }
    }

    // MARK: - Actions

    private func loadUserEntries() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Query directly from database
            let entries = VocabularyDatabase.shared.getUserEntries()
            NSLog("MarmotIM: UserDictView loaded %d user entries", entries.count)
            DispatchQueue.main.async {
                self.userEntries = entries
                self.isLoading = false
            }
        }
    }

    private func addWord() {
        guard !newCode.isEmpty, !newWords.isEmpty else { return }

        let code = newCode.lowercased()
        let codePattern = "^[a-z]{1,4}$"
        guard code.range(of: codePattern, options: .regularExpression) != nil else {
            showStatusMessage("编码格式错误")
            return
        }

        // Try to use DictionaryEngine first, fall back to direct DB access
        let words = newWords.split(separator: " ")
        var addedCount = 0

        if let engine = AppDelegate.shared?.dictionaryEngine {
            for word in words {
                let text = String(word).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if engine.addUserEntry(code: code, text: text, isWubi: isWubiCode) != nil {
                    addedCount += 1
                }
            }
        } else {
            // Direct database access when engine is not available
            let db = VocabularyDatabase.shared
            for word in words {
                let text = String(word).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if db.addUserEntryDirect(code: code, text: text, isWubi: isWubiCode) {
                    addedCount += 1
                }
            }
        }

        if addedCount > 0 {
            showStatusMessage("已添加 \(addedCount) 个词条")
            loadUserEntries()
            clearInputs()
            showingAddSheet = false
        } else {
            showStatusMessage("添加失败")
        }
    }

    private func deleteSelectedEntries() {
        guard !selectedEntryIds.isEmpty else { return }

        var deletedCount = 0
        let db = VocabularyDatabase.shared

        for id in selectedEntryIds {
            if db.deleteIndexesForEntry(entryId: id) && db.deleteEntry(id: id) {
                deletedCount += 1
            }
        }

        selectedEntryIds.removeAll()
        loadUserEntries()

        if deletedCount > 0 {
            showStatusMessage("已删除 \(deletedCount) 个词条")
        }
    }

    private func clearInputs() {
        newCode = ""
        newWords = ""
        isWubiCode = false
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

// MARK: - User Entry Row

struct UserEntryRow: View {
    let entry: DictionaryEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.text)
                .font(.body)

            Spacer()

            HStack(spacing: 8) {
                if let wubi = entry.wubi, !wubi.isEmpty {
                    Text(wubi)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }
                if !entry.pinyin.isEmpty {
                    Text(entry.pinyin)
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

// MARK: - Add Word Sheet

struct AddWordSheet: View {
    @Binding var code: String
    @Binding var words: String
    @Binding var isWubi: Bool
    let onAdd: () -> Void
    let onCancel: () -> Void

    @State private var codeError: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("添加词条")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                Picker("编码类型", selection: $isWubi) {
                    Text("拼音").tag(false)
                    Text("五笔").tag(true)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text("编码 (1-4位字母)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("如: addr", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: code) { newValue in
                            validateCode(newValue)
                        }
                    if !codeError.isEmpty {
                        Text(codeError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("词条 (空格分隔多个)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("如: 北京市海淀区", text: $words)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("取消") { onCancel() }
                    .keyboardShortcut(.escape)

                Spacer()

                Button("添加") { onAdd() }
                    .keyboardShortcut(.return)
                    .disabled(code.isEmpty || words.isEmpty || !codeError.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func validateCode(_ value: String) {
        let lowercased = value.lowercased()
        if value != lowercased {
            code = lowercased
        }

        if value.isEmpty {
            codeError = ""
        } else if value.count > 4 {
            codeError = "编码最多4位"
        } else if !value.allSatisfy({ $0.isLetter && $0.isASCII }) {
            codeError = "只能包含英文字母"
        } else {
            codeError = ""
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
