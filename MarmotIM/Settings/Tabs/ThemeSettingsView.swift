import SwiftUI

/// Theme settings view
struct ThemeSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Appearance mode
                SettingsSection(title: "外观模式") {
                    HStack(spacing: 20) {
                        ForEach(ThemeMode.allCases, id: \.self) { mode in
                            ThemeModeButton(
                                mode: mode,
                                isSelected: viewModel.config.themeMode == mode,
                                action: {
                                    viewModel.config.themeMode = mode
                                    viewModel.markDirty()
                                }
                            )
                        }
                    }
                }

                // Candidate window style
                SettingsSection(title: "候选窗口样式") {
                    // Preview
                    CandidateWindowPreview(style: viewModel.config.candidateWindowStyle)
                        .padding(.bottom, 8)

                    // Font size
                    HStack {
                        Text("字体大小：")
                            .frame(width: 100, alignment: .trailing)
                        Slider(
                            value: $viewModel.config.candidateWindowStyle.fontSize,
                            in: 10...24,
                            step: 1
                        )
                        .frame(width: 150)
                        .onChange(of: viewModel.config.candidateWindowStyle.fontSize) { _ in
                            viewModel.markDirty()
                        }
                        Text("\(Int(viewModel.config.candidateWindowStyle.fontSize))pt")
                            .frame(width: 40)
                            .monospacedDigit()
                    }

                    // Corner radius
                    HStack {
                        Text("圆角大小：")
                            .frame(width: 100, alignment: .trailing)
                        Slider(
                            value: $viewModel.config.candidateWindowStyle.cornerRadius,
                            in: 0...20,
                            step: 1
                        )
                        .frame(width: 150)
                        .onChange(of: viewModel.config.candidateWindowStyle.cornerRadius) { _ in
                            viewModel.markDirty()
                        }
                        Text("\(Int(viewModel.config.candidateWindowStyle.cornerRadius))px")
                            .frame(width: 40)
                            .monospacedDigit()
                    }

                    // Background opacity
                    HStack {
                        Text("背景透明度：")
                            .frame(width: 100, alignment: .trailing)
                        Slider(
                            value: $viewModel.config.candidateWindowStyle.backgroundOpacity,
                            in: 0.5...1.0,
                            step: 0.05
                        )
                        .frame(width: 150)
                        .onChange(of: viewModel.config.candidateWindowStyle.backgroundOpacity) { _ in
                            viewModel.markDirty()
                        }
                        Text("\(Int(viewModel.config.candidateWindowStyle.backgroundOpacity * 100))%")
                            .frame(width: 40)
                            .monospacedDigit()
                    }
                }

                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Theme Mode Button

struct ThemeModeButton: View {
    let mode: ThemeMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(backgroundColor)
                        .frame(width: 60, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                        )

                    iconView
                }

                // Label
                Text(mode.displayName)
                    .font(.caption)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var backgroundColor: Color {
        switch mode {
        case .system:
            return Color(NSColor.controlBackgroundColor)
        case .light:
            return Color.white
        case .dark:
            return Color(white: 0.2)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch mode {
        case .system:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 30, height: 40)
                Rectangle()
                    .fill(Color(white: 0.2))
                    .frame(width: 30, height: 40)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .light:
            Image(systemName: "sun.max.fill")
                .foregroundColor(.orange)
        case .dark:
            Image(systemName: "moon.fill")
                .foregroundColor(.yellow)
        }
    }
}

// MARK: - Candidate Window Preview

struct CandidateWindowPreview: View {
    let style: CandidateWindowStyle

    var body: some View {
        HStack(spacing: 12) {
            Text("1.测试")
            Text("2.测试词")
            Text("3.测试文字")
        }
        .font(.system(size: CGFloat(style.fontSize)))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: CGFloat(style.cornerRadius))
                .fill(Color(NSColor.windowBackgroundColor).opacity(style.backgroundOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat(style.cornerRadius))
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Preview

#if DEBUG
struct ThemeSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ThemeSettingsView(viewModel: SettingsViewModel())
            .frame(width: 600, height: 400)
    }
}
#endif
