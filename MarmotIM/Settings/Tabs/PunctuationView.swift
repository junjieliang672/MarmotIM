import SwiftUI

/// Punctuation settings view
struct PunctuationView: View {
    @ObservedObject var viewModel: SettingsViewModel

    /// Standard punctuation keys in order
    private let punctuationKeys = [
        " ", "`", "~", "!", "@", "#", "$", "%", "^", "&", "*",
        "(", ")", "-", "_", "=", "+", "[", "]", "{", "}", "\\",
        "|", ";", ":", "'", "\"", ",", ".", "<", ">", "/", "?"
    ]

    /// Display names for special keys
    private let keyDisplayNames: [String: String] = [
        " ": "空格",
        "\\": "\\\\",
        "\"": "\\\""
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // Left: Punctuation table
            VStack(alignment: .leading, spacing: 8) {
                // Table header
                HStack {
                    Text("按键")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 60, alignment: .center)
                    Text("输出标点")
                        .font(.caption)
                        .fontWeight(.medium)
                        .frame(width: 120, alignment: .center)
                }
                .padding(.horizontal, 8)

                Divider()

                // Table content
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(punctuationKeys, id: \.self) { key in
                            PunctuationRow(
                                key: key,
                                displayKey: keyDisplayNames[key] ?? key,
                                value: binding(for: key),
                                onChange: { viewModel.markDirty() }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            }
            .frame(minWidth: 280, maxWidth: 280, maxHeight: .infinity)
            .padding(.leading)
            .padding(.vertical)

            // Right: Mode selection and options
            VStack(alignment: .leading, spacing: 20) {
                // Mode selection
                SettingsSection(title: "方案设置") {
                    ForEach(PunctuationMode.allCases, id: \.self) { mode in
                        RadioButton(
                            title: mode.displayName,
                            isSelected: viewModel.config.punctuationMode == mode,
                            action: {
                                viewModel.config.punctuationMode = mode
                                viewModel.markDirty()
                                // Save immediately so changes take effect right away
                                viewModel.save()
                            }
                        )
                    }
                }

                // Help text
                VStack(alignment: .leading, spacing: 4) {
                    Text("提示：")
                        .fontWeight(.medium)
                    Text("切换快捷键：Ctrl+.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor))
                )

                // Other settings
                SettingsSection(title: "其它设置") {
                    Toggle(isOn: $viewModel.config.autoPairPunctuation) {
                        Text("成对标点配对输出")
                    }
                    .onChange(of: viewModel.config.autoPairPunctuation) { _ in
                        viewModel.markDirty()
                        // Save immediately so changes take effect right away
                        viewModel.save()
                    }
                }

                Spacer()
            }
            .padding(.trailing)
            .padding(.vertical)
        }
    }

    /// Create a binding for a specific punctuation key
    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: {
                viewModel.config.customPunctuation[key] ?? key
            },
            set: { newValue in
                viewModel.config.customPunctuation[key] = newValue
                viewModel.markDirty()
                // Save immediately so changes take effect right away
                viewModel.save()
            }
        )
    }
}

// MARK: - Punctuation Row

/// A single row in the punctuation table
struct PunctuationRow: View {
    let key: String
    let displayKey: String
    @Binding var value: String
    let onChange: () -> Void

    /// Common Chinese punctuation options
    private var options: [String] {
        // Provide relevant options based on the key
        switch key {
        case " ": return ["半角空格", "全角空格"]
        case "!": return ["!", "！"]
        case "?": return ["?", "？"]
        case ",": return [",", "，"]
        case ".": return [".", "。"]
        case ":": return [":", "："]
        case ";": return [";", "；"]
        case "'": return ["'", "'", "'"]
        case "\"": return ["\"", "\u{201C}", "\u{201D}"]
        case "(": return ["(", "（"]
        case ")": return [")", "）"]
        case "[": return ["[", "【", "［", "「"]
        case "]": return ["]", "】", "］", "」"]
        case "{": return ["{", "｛"]
        case "}": return ["}", "｝"]
        case "<": return ["<", "《", "〈"]
        case ">": return [">", "》", "〉"]
        case "\\": return ["\\", "、"]
        case "~": return ["~", "～"]
        case "^": return ["^", "……"]
        case "_": return ["_", "——"]
        case "-": return ["-", "－"]
        case "=": return ["=", "＝"]
        case "+": return ["+", "＋"]
        case "/": return ["/", "／"]
        default: return [key]
        }
    }

    var body: some View {
        HStack {
            Text(displayKey)
                .font(.system(.body, design: .monospaced))
                .frame(width: 60, alignment: .center)

            Picker("", selection: $value) {
                ForEach(options, id: \.self) { option in
                    Text(displayText(for: option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .onChange(of: value) { _ in
                onChange()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func displayText(for option: String) -> String {
        switch option {
        case "半角空格": return "半角空格"
        case "全角空格": return "全角空格"
        case " ": return "空格"
        default: return option
        }
    }
}

// MARK: - Preview

#if DEBUG
struct PunctuationView_Previews: PreviewProvider {
    static var previews: some View {
        PunctuationView(viewModel: SettingsViewModel())
            .frame(width: 600, height: 450)
    }
}
#endif
