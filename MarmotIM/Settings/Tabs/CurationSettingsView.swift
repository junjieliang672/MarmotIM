import SwiftUI

/// 词库管理 → 整理: the behaviour log that 整理词库 works from. Recording
/// switch, what has been recorded, excluded apps, and clearing the log.
/// Reviewing and accepting suggestions happens in the Claude conversation
/// (marmot-curate skill), not here.
struct CurationSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var summary: BehaviorLog.Summary?
    @State private var newApp: String = ""
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                recordingSection
                excludedAppsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reloadSummary)
    }

    // MARK: - Recording

    private var recordingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("记录打字和选词习惯", isOn: Binding(
                    get: { viewModel.config.curator.recordingEnabled },
                    set: { enabled in
                        viewModel.config.curator.recordingEnabled = enabled
                        viewModel.save()
                    }
                ))
                .toggleStyle(.switch)

                Text("记录每次选词时打的码、候选和选了哪一个，用来整理用户词库、降权词库和相对排序。"
                     + "记录只保存在这台 Mac 上，不会同步。"
                     + "让 Claude 整理词库时，汇总后的统计结果和少量前后文会发送给 Claude。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("不记录：英文模式下的按键、语音转写的文字、密码输入框，以及下面列出的 App。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack {
                    Text(summaryText)
                    Spacer()
                    Button("刷新", action: reloadSummary)
                    Button("清空记录…") { confirmClear = true }
                        .disabled((summary?.events ?? 0) == 0)
                }
                .font(.callout)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("清空全部打字记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) {
                DispatchQueue.global(qos: .userInitiated).async {
                    BehaviorLog.shared.clear()
                    reloadSummary()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除打字记录。用户词库、降权词库、相对排序和学习记录都不受影响。")
        }
    }

    private var summaryText: String {
        guard let summary = summary else { return "正在读取…" }
        if summary.events == 0 { return "还没有记录。" }
        let since = summary.firstTimestamp.map { SyncStatusPresenter.timeAgo(Date(timeIntervalSince1970: $0)) } ?? ""
        return "已记录 \(summary.events) 条，分布在 \(summary.days) 天（最早：\(since)）。"
            + "超过 \(viewModel.config.curator.retentionDays) 天的记录会自动删除。"
    }

    // MARK: - Excluded apps

    private var excludedAppsSection: some View {
        GroupBox(label: Text("不记录的 App")) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.config.curator.excludedApps, id: \.self) { app in
                    HStack {
                        Text(app).font(.system(.callout, design: .monospaced))
                        Spacer()
                        Button(action: { remove(app) }) {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("从列表中移除")
                    }
                }
                HStack {
                    TextField("App 的 Bundle ID，如 com.example.app", text: $newApp)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("添加", action: add)
                        .disabled(trimmedNewApp.isEmpty)
                }
                Text("Bundle ID 可以在终端用 osascript -e 'id of app \"App 名称\"' 查到。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trimmedNewApp: String {
        newApp.trimmingCharacters(in: .whitespaces)
    }

    private func add() {
        let app = trimmedNewApp
        guard !app.isEmpty, !viewModel.config.curator.excludedApps.contains(app) else { return }
        viewModel.config.curator.excludedApps.append(app)
        viewModel.save()
        newApp = ""
    }

    private func remove(_ app: String) {
        viewModel.config.curator.excludedApps.removeAll { $0 == app }
        viewModel.save()
    }

    private func reloadSummary() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = BehaviorLog.shared.summary()
            DispatchQueue.main.async { summary = loaded }
        }
    }
}
