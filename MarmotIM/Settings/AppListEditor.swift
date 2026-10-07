import Cocoa
import SwiftUI

/// A list of apps the user maintains by hand, picked by name rather than by
/// bundle identifier.
///
/// Two settings need this: the apps 整理词库 never records in, and the apps whose
/// ASCII-直通 requests are honoured. It was written for the first and factored
/// out for the second — the picking is the fiddly part (running apps, an open
/// panel, icons, apps that are no longer installed), and it has no business
/// being duplicated.
///
/// The config stores bundle identifiers, which is what the input method sees
/// and what survives an app being renamed or moved; the name and icon are
/// looked up for display through `AppIdentity`.
struct AppListEditor: View {

    /// Shown as the GroupBox label.
    let title: String

    /// Title of the "choose from /Applications" panel.
    let choosePanelTitle: String

    /// Shown in place of the list when it is empty, if given. Say what empty
    /// *means* — for an allowlist that is "everything", which is the opposite
    /// of what an empty list looks like.
    var emptyHint: String?

    @Binding var bundleIds: [String]

    /// Called after every change. Callers pass `viewModel.save()`.
    let onChange: () -> Void

    var body: some View {
        GroupBox(label: Text(title)) {
            VStack(alignment: .leading, spacing: 6) {
                if bundleIds.isEmpty, let emptyHint {
                    Text(emptyHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(bundleIds, id: \.self) { bundleId in
                    row(for: AppIdentity(bundleId: bundleId))
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

    private func row(for app: AppIdentity) -> some View {
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
            Button(action: { remove(app.bundleId) }) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("从列表中移除")
        }
        .help(app.bundleId)
    }

    /// Apps with a window that are not on the list yet, by name
    private var runningApps: [AppIdentity] {
        let listed = Set(bundleIds)
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier }
            .filter { !listed.contains($0) && seen.insert($0).inserted }
            .map { AppIdentity(bundleId: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.title = choosePanelTitle
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
        guard !bundleIds.contains(bundleId) else { return }
        bundleIds.append(bundleId)
        onChange()
    }

    private func remove(_ bundleId: String) {
        bundleIds.removeAll { $0 == bundleId }
        onChange()
    }
}
