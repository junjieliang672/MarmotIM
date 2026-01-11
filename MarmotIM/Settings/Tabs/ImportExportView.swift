//
//  ImportExportView.swift
//  MarmotIM
//
//  数据库导入导出设置页面
//

import SwiftUI
import UniformTypeIdentifiers

/// 导入导出设置视图
struct ImportExportView: View {
    @State private var statusMessage: String = ""
    @State private var isShowingStatus: Bool = false
    @State private var isSuccess: Bool = true
    @State private var isShowingImportConfirm: Bool = false
    @State private var selectedImportURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 数据库位置信息
                SettingsSection(title: "数据库信息") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("数据库位置:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text(getDatabasePathDisplay())
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)

                        Button("在 Finder 中显示") {
                            showInFinder()
                        }
                        .padding(.top, 4)
                    }
                }

                // 导出功能
                SettingsSection(title: "导出数据库") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("将当前数据库导出为文件，可用于备份或迁移到其他设备。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button(action: exportDatabase) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("导出数据库...")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                // 导入功能
                SettingsSection(title: "导入数据库") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("警告：导入将完全覆盖当前数据库，包括所有用户词条和学习数据。此操作不可撤销。")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Button(action: selectImportFile) {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                Text("导入数据库...")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // 状态消息
                if isShowingStatus {
                    HStack {
                        Image(systemName: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(isSuccess ? .green : .red)
                        Text(statusMessage)
                            .foregroundColor(isSuccess ? .green : .red)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSuccess ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                    )
                }

                Spacer()
            }
            .padding()
        }
        .alert("确认导入", isPresented: $isShowingImportConfirm) {
            Button("取消", role: .cancel) {
                selectedImportURL = nil
            }
            Button("确认导入", role: .destructive) {
                if let url = selectedImportURL {
                    performImport(from: url)
                }
            }
        } message: {
            Text("此操作将完全覆盖当前数据库。所有用户词条和学习数据都将被替换。是否继续？")
        }
    }

    // MARK: - Helper Methods

    private func getDatabasePathDisplay() -> String {
        let path = VocabularyDatabase.shared.getDatabasePath().path
        // 将完整路径转换为 ~ 开头的形式
        if let homeDir = FileManager.default.homeDirectoryForCurrentUser.path as String? {
            if path.hasPrefix(homeDir) {
                return "~" + path.dropFirst(homeDir.count)
            }
        }
        return path
    }

    private func showInFinder() {
        let url = VocabularyDatabase.shared.getDatabasePath()
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    private func exportDatabase() {
        let savePanel = NSSavePanel()
        savePanel.title = "导出数据库"
        savePanel.nameFieldStringValue = "MarmotIM-backup.db"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                performExport(to: url)
            }
        }
    }

    private func performExport(to destinationURL: URL) {
        let sourceURL = VocabularyDatabase.shared.getDatabasePath()

        do {
            // 如果目标文件已存在，先删除
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            // 复制数据库文件
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            // 同时复制 WAL 和 SHM 文件（如果存在）
            let walURL = sourceURL.appendingPathExtension("wal")
            let shmURL = sourceURL.appendingPathExtension("shm")

            if FileManager.default.fileExists(atPath: walURL.path) {
                let destWal = destinationURL.appendingPathExtension("wal")
                try? FileManager.default.removeItem(at: destWal)
                try? FileManager.default.copyItem(at: walURL, to: destWal)
            }

            if FileManager.default.fileExists(atPath: shmURL.path) {
                let destShm = destinationURL.appendingPathExtension("shm")
                try? FileManager.default.removeItem(at: destShm)
                try? FileManager.default.copyItem(at: shmURL, to: destShm)
            }

            showStatus("导出成功", success: true)
            NSLog("MarmotIM: Database exported to \(destinationURL.path)")
        } catch {
            showStatus("导出失败: \(error.localizedDescription)", success: false)
            NSLog("MarmotIM: Failed to export database: \(error)")
        }
    }

    private func selectImportFile() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择要导入的数据库"
        openPanel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false

        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                selectedImportURL = url
                isShowingImportConfirm = true
            }
        }
    }

    private func performImport(from sourceURL: URL) {
        let destinationURL = VocabularyDatabase.shared.getDatabasePath()

        do {
            // 关闭当前数据库连接
            VocabularyDatabase.shared.closeDatabase()

            // 备份当前数据库（以防万一）
            let backupURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent("dictionary-backup-\(Int(Date().timeIntervalSince1970)).db")
            try? FileManager.default.copyItem(at: destinationURL, to: backupURL)

            // 删除当前数据库文件
            try FileManager.default.removeItem(at: destinationURL)

            // 删除 WAL 和 SHM 文件
            let walURL = destinationURL.appendingPathExtension("wal")
            let shmURL = destinationURL.appendingPathExtension("shm")
            try? FileManager.default.removeItem(at: walURL)
            try? FileManager.default.removeItem(at: shmURL)

            // 复制新数据库
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            // 复制相关的 WAL/SHM 文件（如果存在）
            let sourceWal = sourceURL.appendingPathExtension("wal")
            let sourceShm = sourceURL.appendingPathExtension("shm")
            if FileManager.default.fileExists(atPath: sourceWal.path) {
                try? FileManager.default.copyItem(at: sourceWal, to: walURL)
            }
            if FileManager.default.fileExists(atPath: sourceShm.path) {
                try? FileManager.default.copyItem(at: sourceShm, to: shmURL)
            }

            // 重新打开数据库
            VocabularyDatabase.shared.reopenDatabase()

            // 重新初始化字典引擎
            if let appDelegate = AppDelegate.shared {
                appDelegate.dictionaryEngine = try? DictionaryEngine()
                DictionaryPreloadService.shared.startPreloading(engine: appDelegate.dictionaryEngine!) {
                    NSLog("MarmotIM: Dictionary reloaded after import")
                }
            }

            showStatus("导入成功，请重启输入法以确保所有更改生效", success: true)
            NSLog("MarmotIM: Database imported from \(sourceURL.path)")

            // 删除备份（导入成功后）
            try? FileManager.default.removeItem(at: backupURL)

        } catch {
            // 尝试恢复
            VocabularyDatabase.shared.reopenDatabase()

            showStatus("导入失败: \(error.localizedDescription)", success: false)
            NSLog("MarmotIM: Failed to import database: \(error)")
        }

        selectedImportURL = nil
    }

    private func showStatus(_ message: String, success: Bool) {
        statusMessage = message
        isSuccess = success
        isShowingStatus = true

        // 5秒后自动隐藏成功消息
        if success {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if statusMessage == message {
                    isShowingStatus = false
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ImportExportView_Previews: PreviewProvider {
    static var previews: some View {
        ImportExportView()
            .frame(width: 600, height: 450)
    }
}
#endif
