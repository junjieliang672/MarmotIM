import SwiftUI
import Combine

// MARK: - View Model

/// View-model for the 相对排序 (relative-ordering) settings tab. Holds the
/// live rule list, the two input text fields, and the inline error message.
/// Interacts with VocabularyDatabase through a `VocabularyDatabase` handle
/// that defaults to the shared singleton but can be injected by tests.
///
/// Dual-channel per `.knowledge/observability/error-boundaries.md`: when
/// `add` or `remove` fail, the view-model BOTH sets `errorMessage` (HUD)
/// AND the VocabularyDatabase layer has already logged [W][dict].
final class RelativeOrderingViewModel: ObservableObject {

    /// The DB used for CRUD. Defaults to the app singleton in production;
    /// tests pass a `VocabularyDatabase.makeForTests` instance.
    private let db: VocabularyDatabase

    /// Optional closure called after any successful mutation so the ranker's
    /// in-memory cache can be refreshed. Defaults to notifying the app's
    /// DictionaryEngine, but tests can inject a no-op.
    private let onMutated: () -> Void

    /// The currently-loaded rule list (excludes tombstones).
    @Published private(set) var rules: [RelativeOrderingRule] = []

    /// Bound to the 词A text field.
    @Published var wordA: String = "" {
        didSet {
            if oldValue != wordA { errorMessage = nil }
        }
    }

    /// Bound to the 词B text field.
    @Published var wordB: String = "" {
        didSet {
            if oldValue != wordB { errorMessage = nil }
        }
    }

    /// Inline zh-Hans error message — nil when there's nothing to surface.
    @Published var errorMessage: String?

    init(
        db: VocabularyDatabase = .shared,
        onMutated: @escaping () -> Void = {
            AppDelegate.shared?.dictionaryEngine?.updateRelativeOrderingCache()
        }
    ) {
        self.db = db
        self.onMutated = onMutated
    }

    /// Load the rule list from the database.
    func load() {
        rules = db.listRelativeOrderingRules()
    }

    /// Attempt to add a new rule from the current text fields. On success
    /// the list reloads, text fields clear, and `errorMessage` is cleared.
    /// On failure, `errorMessage` is set to the zh-Hans HUD string.
    func add() {
        let a = wordA
        let b = wordB
        let result = db.addRelativeOrderingRule(wordA: a, wordB: b)
        switch result {
        case .success:
            wordA = ""
            wordB = ""
            errorMessage = nil
            load()
            onMutated()
        case .failure(let err):
            errorMessage = mapError(err)
        }
    }

    /// Remove a rule by id. Reloads the list on success.
    func remove(id: Int64) {
        let ok = db.removeRelativeOrderingRule(ruleId: id)
        if ok {
            load()
            onMutated()
        } else {
            errorMessage = mapError(.dbUnavailable)
        }
    }

    /// zh-Hans HUD string mapping for each error case. Mirrors the spec's
    /// error_to_hud_mapping table.
    func mapError(_ err: RelativeOrderingError) -> String {
        switch err {
        case .emptyInput:     return "请填写两个词"
        case .identicalWords: return "两个词不能相同"
        case .duplicate:      return "该规则已存在"
        case .cycle:          return "该规则会造成循环（与已有规则冲突）"
        case .dbUnavailable:  return "词库未就绪"
        }
    }

    /// Computed: can the Add button fire? False when either field is empty
    /// after trim.
    var canSubmit: Bool {
        let a = wordA.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = wordB.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && !b.isEmpty
    }
}

// MARK: - View

/// The 相对排序 settings tab. Displays the live rule list with
/// swipe-to-delete, a top-of-pane explanatory text, and a bottom
/// toolbar with two TextFields + Add button.
struct RelativeOrderingView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @StateObject private var model = RelativeOrderingViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Description
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("指定两个词的相对排序：词 A 永远优先 词 B。仅影响这两个词之间的相对顺序，不影响其他候选。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Rule list
            Group {
                if model.rules.isEmpty {
                    VStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("暂无相对排序规则")
                                .foregroundColor(.secondary)
                            Text("添加规则后，词 A 在候选列表中将总是排在词 B 之前")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(model.rules, id: \.id) { rule in
                            RelativeOrderingRow(rule: rule) {
                                model.remove(id: rule.id)
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(minHeight: 200)

            Divider()

            // Bottom toolbar: two inputs + Add button + error label
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("词 A", text: $model.wordA)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onSubmit { if model.canSubmit { model.add() } }

                    Text("→")
                        .foregroundColor(.secondary)

                    TextField("词 B", text: $model.wordB)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .onSubmit { if model.canSubmit { model.add() } }

                    Button("添加") { model.add() }
                        .disabled(!model.canSubmit)

                    Spacer()

                    Text("共 \(model.rules.count) 条规则")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let msg = model.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onAppear {
            model.load()
        }
    }
}

// MARK: - Row

private struct RelativeOrderingRow: View {
    let rule: RelativeOrderingRule
    let onDelete: () -> Void

    private var timestampString: String {
        let date = Date(timeIntervalSince1970: TimeInterval(rule.updatedAt))
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.wordA)
                        .font(.system(size: 13, weight: .medium))
                    Text("→")
                        .foregroundColor(.secondary)
                    Text(rule.wordB)
                        .font(.system(size: 13, weight: .medium))
                }
                Text(timestampString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("删除此规则")
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#if DEBUG
struct RelativeOrderingView_Previews: PreviewProvider {
    static var previews: some View {
        RelativeOrderingView(viewModel: SettingsViewModel())
            .frame(width: 600, height: 450)
    }
}
#endif
