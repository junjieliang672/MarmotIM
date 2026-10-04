import SwiftUI
import UniformTypeIdentifiers

/// 词库管理 → 整理: the behaviour log that 整理词库 works from. Recording
/// switch, what has been recorded, excluded apps, and clearing the log.
/// Reviewing and accepting suggestions happens in the Claude conversation
/// (marmot-curate skill), not here.
struct CurationSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var summary: BehaviorLog.Summary?
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
                ForEach(viewModel.config.curator.excludedApps, id: \.self) { bundleId in
                    let app = AppIdentity(bundleId: bundleId)
                    HStack(spacing: 8) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundColor(.secondary)
                        }
                        Text(app.name)
                        if !app.isInstalled {
                            Text("未安装").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: { remove(bundleId) }) {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("从列表中移除")
                    }
                    .help(bundleId)
                }

                Menu {
                    let running = runningApps
                    if !running.isEmpty {
                        Section("正在运行") {
                            ForEach(running, id: \.bundleId) { app in
                                Button(app.name) { add(app.bundleId) }
                            }
                        }
                    }
                    Button("从「应用程序」里选择…", action: chooseFromDisk)
                } label: {
                    Label("添加 App", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.top, 2)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Apps with a window that are not excluded yet, by name
    private var runningApps: [AppIdentity] {
        let excluded = Set(viewModel.config.curator.excludedApps)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier }
            .filter { !excluded.contains($0) && seen.insert($0).inserted }
            .map { AppIdentity(bundleId: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.title = "选择不记录的 App"
        panel.prompt = "添加"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleId = Bundle(url: url)?.bundleIdentifier {
                add(bundleId)
            }
        }
    }

    private func add(_ bundleId: String) {
        guard !viewModel.config.curator.excludedApps.contains(bundleId) else { return }
        viewModel.config.curator.excludedApps.append(bundleId)
        viewModel.save()
    }

    private func remove(_ bundleId: String) {
        viewModel.config.curator.excludedApps.removeAll { $0 == bundleId }
        viewModel.save()
    }

    private func reloadSummary() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = BehaviorLog.shared.summary()
            DispatchQueue.main.async { summary = loaded }
        }
    }
}

/// An excluded app as the user knows it. The config stores the bundle
/// identifier, which is what the input method sees and what stays the same
/// when an app is renamed or moved; the name and icon are looked up for display.
struct AppIdentity {
    let bundleId: String
    let name: String
    let icon: NSImage?
    let isInstalled: Bool

    init(bundleId: String) {
        self.bundleId = bundleId
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
            isInstalled = true
        } else {
            name = Self.knownNames[bundleId] ?? bundleId
            icon = nil
            isInstalled = false
        }
    }

    /// Names for the default exclusions when the app is not on this Mac
    private static let knownNames = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.bitwarden.desktop": "Bitwarden",
        "com.apple.keychainaccess": "钥匙串访问",
        "com.apple.Passwords": "密码",
    ]
}
