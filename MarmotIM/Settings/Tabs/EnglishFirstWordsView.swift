import SwiftUI

/// Suppressed word entry (from user_suppressed_words table)
struct SuppressedWordEntry: Identifiable {
    let id: Int
    let text: String
    let timestamp: Int
}

/// Suppressed words management view
/// Shows words that have their user behavior scores suppressed during ranking
struct SuppressedWordsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var suppressedWords: [SuppressedWordEntry] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""
    @State private var selectedIds: Set<Int> = []
    @State private var statusMessage: String = ""
    @State private var showStatus: Bool = false
    @State private var newWord: String = ""

    private var filteredEntries: [SuppressedWordEntry] {
        if searchText.isEmpty {
            return suppressedWords
        }
        let query = searchText.lowercased()
        return suppressedWords.filter { entry in
            entry.text.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Description
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("降权词在候选列表中只使用基础词频排序，不受使用频率、最近选择等因素影响。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索词条...", text: $searchText)
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
            .padding(.bottom, 8)

            // List area
            Group {
                if isLoading {
                    VStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if suppressedWords.isEmpty {
                    VStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("暂无降权词")
                                .foregroundColor(.secondary)
                            Text("添加词条后，该词将只使用基础词频排序")
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
                        SuppressedWordRow(entry: entry)
                            .tag(entry.id)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(minHeight: 200)

            Divider()

            // Bottom toolbar - Add word input
            HStack(spacing: 8) {
                TextField("输入要降权的词...", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit {
                        addWord()
                    }

                Button(action: addWord) {
                    Text("添加")
                }
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)

                Divider()
                    .frame(height: 16)

                Button(action: deleteSelectedEntries) {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(selectedIds.isEmpty)
                .help("删除选中的词条")

                Spacer()

                if showStatus {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                        .padding(.trailing, 8)
                }

                Text("共 \(suppressedWords.count) 个词条")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear {
            loadSuppressedWords()
        }
    }

    // MARK: - Actions

    private func loadSuppressedWords() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let words = VocabularyDatabase.shared.getSuppressedWordsWithDetails()
            let entries = words.map { SuppressedWordEntry(id: $0.id, text: $0.text, timestamp: $0.timestamp) }
            DispatchQueue.main.async {
                self.suppressedWords = entries
                self.isLoading = false
            }
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }

        // Check if already exists
        if suppressedWords.contains(where: { $0.text == word }) {
            showStatusMessage("该词条已存在")
            return
        }

        let db = VocabularyDatabase.shared
        if db.suppressWord(text: word) {
            showStatusMessage("已添加 \"\(word)\"")
            newWord = ""
            loadSuppressedWords()

            // Update engine cache if available
            if let engine = AppDelegate.shared?.dictionaryEngine {
                engine.updateSuppressedWordsCache()
            }
        } else {
            showStatusMessage("添加失败")
        }
    }

    private func deleteSelectedEntries() {
        guard !selectedIds.isEmpty else { return }

        var deletedCount = 0
        let db = VocabularyDatabase.shared

        for id in selectedIds {
            if db.unsuppressWordById(id) {
                deletedCount += 1
            }
        }

        selectedIds.removeAll()
        loadSuppressedWords()

        if deletedCount > 0 {
            showStatusMessage("已删除 \(deletedCount) 个词条")

            // Update engine cache if available
            if let engine = AppDelegate.shared?.dictionaryEngine {
                engine.updateSuppressedWordsCache()
            }
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

// MARK: - Suppressed Word Row

struct SuppressedWordRow: View {
    let entry: SuppressedWordEntry

    var body: some View {
        HStack(spacing: 12) {
            Text(entry.text)
                .font(.body)

            Spacer()

            Text(formatDate(entry.timestamp))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDate(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#if DEBUG
struct SuppressedWordsView_Previews: PreviewProvider {
    static var previews: some View {
        SuppressedWordsView(viewModel: SettingsViewModel())
            .frame(width: 500, height: 400)
    }
}
#endif
