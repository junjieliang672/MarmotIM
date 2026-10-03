import SwiftUI

/// Settings → iCloud: which Macs sync, when each last synced, and whether
/// they hold the same data as this one.
struct ICloudSettingsView: View {
    @State private var overview: SyncOverview?
    @State private var isLoading = false
    @State private var isSyncing = false
    @State private var showFiles = false

    private let overviewChanged = NotificationCenter.default.publisher(for: .syncOverviewDidChange)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                localSection
                devicesSection
                filesSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
        .onReceive(overviewChanged) { _ in
            isSyncing = false
            reload()
        }
    }

    // MARK: - This Mac

    private var localSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(overview?.localDevice?.name ?? Host.current().localizedName ?? "本机")
                        .font(.headline)
                    Text("本机")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                    Spacer()
                    if isLoading || isSyncing {
                        ProgressView().controlSize(.small)
                    }
                    Button("刷新", action: reload)
                        .disabled(isLoading)
                    Button("立即同步") {
                        isSyncing = true
                        iCloudSyncManager.shared.syncNow()
                    }
                    .disabled(isSyncing || overview?.iCloudAvailable == false)
                }

                if let overview = overview {
                    statusLine(for: overview)
                    if !overview.stuckFiles.isEmpty {
                        warning("\(overview.stuckFiles.count) 个文件写入后超过 5 分钟仍未上传完。"
                                + "iCloud 云盘可能卡住了，这台 Mac 的改动到不了其他设备。")
                    }
                } else {
                    Text("正在读取…").foregroundColor(.secondary)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func statusLine(for overview: SyncOverview) -> some View {
        if !overview.iCloudAvailable {
            warning("这台 Mac 没有登录 iCloud，或者没有打开 iCloud 云盘。")
        } else if !overview.containerFound {
            warning("拿不到 iCloud 存储位置。通常是安装包缺少 iCloud 权限，需要重新安装。")
        } else if let local = overview.localDevice {
            HStack(spacing: 6) {
                Image(systemName: local.lastSyncOK ? "checkmark.icloud" : "exclamationmark.icloud")
                    .foregroundColor(local.lastSyncOK ? .green : .orange)
                Text("上次同步：\(SyncStatusPresenter.timeAgo(Date(timeIntervalSince1970: local.lastSyncAt)))，"
                     + (local.lastSyncOK ? "成功" : "失败"))
                if let error = local.lastError, !local.lastSyncOK {
                    Text(error).foregroundColor(.secondary).lineLimit(1).help(error)
                }
            }
        } else {
            Text("这台 Mac 还没有同步过。点「立即同步」。").foregroundColor(.secondary)
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        GroupBox(label: Text("设备")) {
            VStack(alignment: .leading, spacing: 0) {
                if let overview = overview, !overview.devices.isEmpty {
                    deviceHeader
                    Divider()
                    if let local = overview.localDevice {
                        deviceRow(local, local: local, isLocal: true)
                    }
                    ForEach(overview.otherDevices) { device in
                        Divider()
                        deviceRow(device, local: overview.localDevice, isLocal: false)
                    }
                    if overview.otherDevices.isEmpty {
                        Divider()
                        Text("还没有其他设备。另一台 Mac 装上这个版本并同步一次后，会出现在这里。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                } else {
                    Text("还没有设备同步过。")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }
            .padding(6)
        }
    }

    private static let countWidth: CGFloat = 54

    private var deviceHeader: some View {
        HStack(spacing: 8) {
            Text("设备").frame(maxWidth: .infinity, alignment: .leading)
            Text("上次同步").frame(width: 84, alignment: .leading)
            ForEach(SyncPayloadKind.allCases, id: \.self) { kind in
                Text(kind.title).frame(width: Self.countWidth, alignment: .trailing)
            }
            Text("状态").frame(width: 150, alignment: .leading)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.vertical, 4)
    }

    private func deviceRow(_ device: DeviceSyncStatus, local: DeviceSyncStatus?, isLocal: Bool) -> some View {
        let differences = local.map { device.differences(from: $0) } ?? []
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name + (isLocal ? "（本机）" : "")).lineLimit(1)
                Text("版本 \(device.appVersion) · \(device.deviceId.prefix(8))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(SyncStatusPresenter.timeAgo(Date(timeIntervalSince1970: device.lastSyncAt)))
                .frame(width: 84, alignment: .leading)

            ForEach(SyncPayloadKind.allCases, id: \.self) { kind in
                Text(device.summary(kind).map { String($0.count) } ?? "–")
                    .monospacedDigit()
                    .foregroundColor(!isLocal && differences.contains(kind) ? .orange : .primary)
                    .frame(width: Self.countWidth, alignment: .trailing)
            }

            deviceState(device, differences: differences, isLocal: isLocal, hasLocal: local != nil)
                .frame(width: 150, alignment: .leading)
        }
        .padding(.vertical, 6)
    }

    /// A device that hasn't synced for this long is flagged even if its last
    /// published state matches
    private static let staleAfter: TimeInterval = 7 * 86400

    @ViewBuilder
    private func deviceState(_ device: DeviceSyncStatus, differences: [SyncPayloadKind],
                             isLocal: Bool, hasLocal: Bool) -> some View {
        let stale = Date().timeIntervalSince1970 - device.lastSyncAt > Self.staleAfter
        if isLocal {
            Text("—").foregroundColor(.secondary)
        } else if !hasLocal {
            Text("本机尚未同步").foregroundColor(.secondary)
        } else if !device.lastSyncOK {
            label("exclamationmark.icloud", .orange, "上次同步失败", help: device.lastError)
        } else if differences.isEmpty {
            label("checkmark.circle.fill", stale ? .secondary : .green, stale ? "已同步（长时间未同步）" : "已同步")
        } else {
            let names = differences.map(\.title).joined(separator: "、")
            label("exclamationmark.triangle.fill", .orange,
                  "有差异：\(names)" + (stale ? "（长时间未同步）" : ""),
                  help: "这些数据和本机不一样。对方下次同步后会更新。")
        }
    }

    private func label(_ icon: String, _ color: Color, _ text: String, help: String? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .help(help ?? text)
    }

    // MARK: - Files

    private var filesSection: some View {
        DisclosureGroup("本机文件上传状态", isExpanded: $showFiles) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(overview?.files ?? []) { file in
                    HStack(spacing: 8) {
                        Text(file.name)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(uploadText(file))
                            .font(.caption)
                            .foregroundColor(file.isUploaded ? .secondary : .orange)
                            .frame(width: 110, alignment: .leading)
                        Text(file.modified.map { SyncStatusPresenter.timeAgo($0) } ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 84, alignment: .leading)
                        Text(file.conflictCount > 0 ? "\(file.conflictCount) 个冲突副本" : "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 100, alignment: .leading)
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private func uploadText(_ file: SyncFileCloudState) -> String {
        if let error = file.uploadError { return "上传出错：\(error)" }
        if file.isUploaded { return "已上传" }
        if file.isStuck() { return "未上传完（卡住）" }
        return file.isUploading ? "上传中" : "等待上传"
    }

    // MARK: - Loading

    private func reload() {
        guard !isLoading else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = iCloudSyncManager.shared.loadOverview()
            DispatchQueue.main.async {
                overview = loaded
                isLoading = false
            }
        }
    }
}

#if DEBUG
struct ICloudSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ICloudSettingsView()
            .frame(width: 760, height: 560)
    }
}
#endif
