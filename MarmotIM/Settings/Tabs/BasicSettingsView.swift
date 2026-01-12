import SwiftUI

/// Basic settings tab view
struct BasicSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Encoding section
                SettingsSection(title: "编码") {
                    // Empty code behavior
                    HStack {
                        Text("空码时：")
                            .frame(width: 80, alignment: .trailing)
                        Picker("", selection: $viewModel.config.emptyCodeBehavior) {
                            ForEach(EmptyCodeBehavior.allCases, id: \.self) { behavior in
                                Text(behavior.displayName).tag(behavior)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .onChange(of: viewModel.config.emptyCodeBehavior) { _ in
                            viewModel.save()
                        }
                        Spacer()
                    }

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

                    // Page keys
                    HStack {
                        Text("翻页：")
                            .frame(width: 100, alignment: .trailing)
                        ForEach(PageKeyOption.allCases, id: \.self) { option in
                            RadioButton(
                                title: option.displayName,
                                isSelected: viewModel.config.pageKeys == option,
                                action: {
                                    viewModel.config.pageKeys = option
                                    viewModel.save()
                                }
                            )
                        }
                        Spacer()
                    }

                    // Mode switch key
                    HStack {
                        Text("状态切换：")
                            .frame(width: 100, alignment: .trailing)
                        ForEach(ModeSwitchKey.allCases, id: \.self) { key in
                            RadioButton(
                                title: key.displayName,
                                isSelected: viewModel.config.modeSwitchKey == key,
                                action: {
                                    viewModel.config.modeSwitchKey = key
                                    viewModel.save()
                                }
                            )
                        }
                        Spacer()
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
