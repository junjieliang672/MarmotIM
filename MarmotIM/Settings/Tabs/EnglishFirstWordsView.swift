import SwiftUI

/// English-first word entry (from user_english_first_words table)
struct EnglishFirstWordEntry: Identifiable {
    let id: Int
    let text: String
    let timestamp: Int
}

/// English-first words management view
/// English words that take the first candidate slot when typed in full
struct EnglishFirstWordsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var englishFirstWords: [EnglishFirstWordEntry] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""
    @State private var selectedIds: Set<Int> = []
    @State private var statusMessage: String = ""
    @State private var showStatus: Bool = false
    @State private var newWord: String = ""

    private var filteredEntries: [EnglishFirstWordEntry] {
        if searchText.isEmpty {
            return englishFirstWords
        }
        let query = searchText.lowercased()
        return englishFirstWords.filter { entry in
            entry.text.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Description
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("名单里的英文词，在你完整打出它时排第一，不再固定在每页最后一位。")
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
                } else if englishFirstWords.isEmpty {
                    VStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.to.line")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("暂无英文置顶词")
                                .foregroundColor(.secondary)
                            Text("例如加入 agent 后，打 agent 按空格直接上屏 agent")
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
                        EnglishFirstWordRow(entry: entry)
                            .tag(entry.id)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(minHeight: 200)

            Divider()

            // Bottom toolbar - Add word input
            HStack(spacing: 8) {
                TextField("输入英文单词...", text: $newWord)
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

                Text("共 \(englishFirstWords.count) 个词条")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear {
            loadEnglishFirstWords()
        }
    }

    // MARK: - Actions

    private func loadEnglishFirstWords() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let words = VocabularyDatabase.shared.getEnglishFirstWordsWithDetails()
            let entries = words.map { EnglishFirstWordEntry(id: $0.id, text: $0.text, timestamp: $0.timestamp) }
            DispatchQueue.main.async {
                self.englishFirstWords = entries
                self.isLoading = false
            }
        }
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty else { return }

        // Check if already exists
        if englishFirstWords.contains(where: { $0.text == word }) {
            showStatusMessage("该词条已存在")
            return
        }

        // Without an English candidate the entry would never take effect
        if let engine = AppDelegate.shared?.dictionaryEngine, !engine.hasEnglishWord(word) {
            showStatusMessage("英文词表里没有这个词")
            return
        }

        let db = VocabularyDatabase.shared
        if db.addEnglishFirstWord(text: word) {
            showStatusMessage("已添加 \"\(word)\"")
            newWord = ""
            loadEnglishFirstWords()

            // Update engine cache if available
            if let engine = AppDelegate.shared?.dictionaryEngine {
                engine.updateEnglishFirstWordsCache()
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
            if db.removeEnglishFirstWordById(id) {
                deletedCount += 1
            }
        }

        selectedIds.removeAll()
        loadEnglishFirstWords()

        if deletedCount > 0 {
            showStatusMessage("已删除 \(deletedCount) 个词条")

            // Update engine cache if available
            if let engine = AppDelegate.shared?.dictionaryEngine {
                engine.updateEnglishFirstWordsCache()
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

// MARK: - English-First Word Row

struct EnglishFirstWordRow: View {
    let entry: EnglishFirstWordEntry

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
struct EnglishFirstWordsView_Previews: PreviewProvider {
    static var previews: some View {
        EnglishFirstWordsView(viewModel: SettingsViewModel())
            .frame(width: 500, height: 400)
    }
}
#endif
