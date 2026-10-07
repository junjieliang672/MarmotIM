import SwiftUI

/// Basic settings tab view
struct BasicSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Encoding section
                SettingsSection(title: "编码") {
                    // Enter key behavior
                    HStack {
                        Text("Enter键：")
                            .frame(width: 80, alignment: .trailing)
                        Picker("", selection: $viewModel.config.enterKeyBehavior) {
                            ForEach(EnterKeyBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.displayName).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: viewModel.config.enterKeyBehavior) { _ in
                            viewModel.save()  // Save immediately for critical settings
                        }
                        Spacer()
                    }

                    Toggle(isOn: $viewModel.config.numberAsInputWhenCapital) {
                        Text("含大写字母时数字入码")
                    }
                    .onChange(of: viewModel.config.numberAsInputWhenCapital) { _ in
                        viewModel.save()
                    }
                }

                // Candidate section
                SettingsSection(title: "候选词") {
                    // Candidate count
                    HStack {
                        Text("候选词数量：")
                            .frame(width: 100, alignment: .trailing)
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.config.candidateCount) },
                                set: {
                                    viewModel.config.candidateCount = Int($0)
                                    viewModel.save()
                                }
                            ),
                            in: 3...9,
                            step: 1
                        )
                        .frame(width: 150)
                        Text("\(viewModel.config.candidateCount)")
                            .frame(width: 30)
                            .monospacedDigit()
                        Spacer()
                    }

                    Toggle(isOn: $viewModel.config.addSpaceAfterEnglish) {
                        Text("英文候选词上屏后自动添加空格（空格、Tab、数字键选中均生效）")
                    }
                    .onChange(of: viewModel.config.addSpaceAfterEnglish) { _ in
                        viewModel.save()
                    }

                    Toggle(isOn: $viewModel.config.englishCompletion) {
                        Text("英文单词补全（输入 5 个字母以上或含大写字母时）。含大写字母时只显示英文候选")
                    }
                    .onChange(of: viewModel.config.englishCompletion) { _ in
                        viewModel.save()
                    }

                    HStack {
                        Text("上屏当前页的第一个英文候选：")
                        Picker("", selection: $viewModel.config.selectEnglishCandidateKey) {
                            ForEach(EnglishCandidateKey.allCases, id: \.self) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .onChange(of: viewModel.config.selectEnglishCandidateKey) { _ in
                            viewModel.save()
                        }
                        Spacer()
                    }
                    Text("有五笔或拼音候选时，英文候选只排在每页最后一位。当前页没有英文候选时，这个键不起作用。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Icon section
                SettingsSection(title: "图标") {
                    Toggle(isOn: $viewModel.config.showStatusBarIcon) {
                        Text("在状态栏显示额外图标，以提示中英文状态")
                    }
                    .onChange(of: viewModel.config.showStatusBarIcon) { _ in
                        viewModel.save()
                    }

                    Toggle(isOn: $viewModel.config.showModeIndicator) {
                        Text("切换状态时，在光标处提示中英文状态")
                    }
                    .onChange(of: viewModel.config.showModeIndicator) { _ in
                        viewModel.save()
                    }
                }

                // 外部程序请求英文直通（ascii-hold）。见 ASCIIHoldMonitor。
                asciiHoldSection

                // Fuzzy Pinyin section
                SettingsSection(title: "模糊拼音") {
                    Toggle(isOn: $viewModel.config.fuzzyPinyin.enabled) {
                        Text("启用模糊拼音")
                    }
                    .onChange(of: viewModel.config.fuzzyPinyin.enabled) { _ in
                        viewModel.save()
                    }

                    if viewModel.config.fuzzyPinyin.enabled {
                        Divider()

                        Text("声母模糊")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        HStack {
                            Toggle("zh ↔ z", isOn: $viewModel.config.fuzzyPinyin.zh_z)
                                .onChange(of: viewModel.config.fuzzyPinyin.zh_z) { _ in
                                    viewModel.save()
                                }
                            Toggle("ch ↔ c", isOn: $viewModel.config.fuzzyPinyin.ch_c)
                                .onChange(of: viewModel.config.fuzzyPinyin.ch_c) { _ in
                                    viewModel.save()
                                }
                            Toggle("sh ↔ s", isOn: $viewModel.config.fuzzyPinyin.sh_s)
                                .onChange(of: viewModel.config.fuzzyPinyin.sh_s) { _ in
                                    viewModel.save()
                                }
                        }
                        HStack {
                            Toggle("n ↔ l", isOn: $viewModel.config.fuzzyPinyin.n_l)
                                .onChange(of: viewModel.config.fuzzyPinyin.n_l) { _ in
                                    viewModel.save()
                                }
                            Toggle("r ↔ l", isOn: $viewModel.config.fuzzyPinyin.r_l)
                                .onChange(of: viewModel.config.fuzzyPinyin.r_l) { _ in
                                    viewModel.save()
                                }
                            Toggle("f ↔ h", isOn: $viewModel.config.fuzzyPinyin.f_h)
                                .onChange(of: viewModel.config.fuzzyPinyin.f_h) { _ in
                                    viewModel.save()
                                }
                        }

                        Divider()

                        Text("韵母模糊")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        HStack {
                            Toggle("an ↔ ang", isOn: $viewModel.config.fuzzyPinyin.an_ang)
                                .onChange(of: viewModel.config.fuzzyPinyin.an_ang) { _ in
                                    viewModel.save()
                                }
                            Toggle("en ↔ eng", isOn: $viewModel.config.fuzzyPinyin.en_eng)
                                .onChange(of: viewModel.config.fuzzyPinyin.en_eng) { _ in
                                    viewModel.save()
                                }
                            Toggle("in ↔ ing", isOn: $viewModel.config.fuzzyPinyin.in_ing)
                                .onChange(of: viewModel.config.fuzzyPinyin.in_ing) { _ in
                                    viewModel.save()
                                }
                        }
                        HStack {
                            Toggle("ian ↔ iang", isOn: $viewModel.config.fuzzyPinyin.ian_iang)
                                .onChange(of: viewModel.config.fuzzyPinyin.ian_iang) { _ in
                                    viewModel.save()
                                }
                            Toggle("uan ↔ uang", isOn: $viewModel.config.fuzzyPinyin.uan_uang)
                                .onChange(of: viewModel.config.fuzzyPinyin.uan_uang) { _ in
                                    viewModel.save()
                                }
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - 外部控制

    @State private var holdStatus = ASCIIHoldMonitor.Status(holders: [], secondsSinceActive: nil)

    /// 一个开关加一行状态。
    ///
    /// 这里本来有五个控件（白名单、严格模式、提示开关……）。砍掉了：用户看着那一排
    /// 没法判断该不该勾，而「不确定就别动」对一个默认就该工作的功能来说是最差的结果。
    /// 剩下的那几个旋钮仍然在 config.json 里，默认值就是对的，真需要再手改。
    private var asciiHoldSection: some View {
        SettingsSection(title: "外部控制") {
            Toggle(isOn: $viewModel.config.asciiHold.enabled) {
                Text("终端程序等快捷键时，自动按英文输入")
            }
            .onChange(of: viewModel.config.asciiHold.enabled) { _ in
                viewModel.save()
                refreshHoldStatus()
            }

            Text("终端里的文件管理器（如 superfile）用单个字母当快捷键，中文模式下这些键会被输入法吃掉。"
                 + "开着这一项，它们在等快捷键时输入法自动走英文，光标进到搜索框、重命名框时自动放开，"
                 + "不用手动切。只有主动支持的程序才会用到，其它程序完全不受影响。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.config.asciiHold.enabled {
                HStack(spacing: 8) {
                    Circle()
                        .fill(holdStatus.isActive ? Color.orange : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(holdStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    // 只在真的有程序挂着时才出现。正常情况下，程序一离开终端就自己
                    // 撤销了 —— 所以能在这个窗口里看到它，基本就意味着它卡住了。
                    if holdStatus.isActive {
                        Button("强制解除") {
                            ASCIIHoldMonitor.shared.clearAllHolds()
                            refreshHoldStatus()
                        }
                    }
                }
            }
        }
        .onAppear(perform: refreshHoldStatus)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshHoldStatus()
        }
    }

    private var holdStatusText: String {
        if holdStatus.isActive {
            return "正在生效：" + holdStatus.holders.joined(separator: "、")
        }
        // 程序在终端失去焦点时就撤销了请求，而你为了看这个窗口必须离开终端，
        // 所以这里几乎总是「没有正在生效」。说一句「刚刚用过」才是有用的信息。
        if let seconds = holdStatus.secondsSinceActive, seconds < 120 {
            return "当前没有生效（\(Int(seconds)) 秒前用过，正常）"
        }
        return "当前没有程序在用"
    }

    private func refreshHoldStatus() {
        holdStatus = ASCIIHoldMonitor.shared.status
    }

}

// MARK: - Radio Button Component

/// A radio button style selector
struct RadioButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(title)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
    }
}

// MARK: - Preview

#if DEBUG
struct BasicSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        BasicSettingsView(viewModel: SettingsViewModel())
            .frame(width: 600, height: 400)
    }
}
#endif
