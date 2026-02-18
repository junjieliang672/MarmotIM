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
                        Text("选中英文候选词后自动添加空格")
                    }
                    .onChange(of: viewModel.config.addSpaceAfterEnglish) { _ in
                        viewModel.save()
                    }
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
