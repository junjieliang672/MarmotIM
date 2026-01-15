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

                // Candidate window style (Terminal Hybrid theme)
                SettingsSection(title: "候选窗口样式") {
                    // Preview
                    CandidateWindowPreview(style: viewModel.config.candidateWindowStyle)
                        .padding(.bottom, 12)

                    // Theme description
                    Text("Terminal Hybrid 主题：简约等宽字体 + 毛玻璃背景")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)

                    // Font size
                    HStack {
                        Text("字体大小：")
                            .frame(width: 100, alignment: .trailing)
                        Slider(
                            value: $viewModel.config.candidateWindowStyle.fontSize,
                            in: 12...20,
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

// MARK: - Candidate Window Preview (Terminal Hybrid Theme)

struct CandidateWindowPreview: View {
    let style: CandidateWindowStyle
    @Environment(\.colorScheme) var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private var backgroundColor: Color {
        isDark ? Color(white: 0.1) : Color(white: 0.96)
    }

    private var primaryTextColor: Color {
        isDark ? Color(white: 0.9) : Color(white: 0.1)
    }

    private var secondaryTextColor: Color {
        isDark ? Color(white: 0.53) : Color(white: 0.4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top bar with code, logo, page info
            HStack {
                Text("wo")
                    .font(.system(size: CGFloat(style.fontSize - 2), design: .monospaced))
                    .foregroundColor(secondaryTextColor)

                Spacer()

                MarmotLogoView()
                    .frame(width: 14, height: 14)
                    .foregroundColor(secondaryTextColor)

                Spacer()

                Text("1/3")
                    .font(.system(size: CGFloat(style.fontSize - 3), design: .monospaced))
                    .foregroundColor(secondaryTextColor)
                Text("[,/.]")
                    .font(.system(size: CGFloat(style.fontSize - 4), design: .monospaced))
                    .foregroundColor(secondaryTextColor.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            // Candidates
            HStack(spacing: 12) {
                PreviewCandidateItem(index: 1, text: "我", isSelected: true, fontSize: style.fontSize, isDark: isDark)
                PreviewCandidateItem(index: 2, text: "我们", isSelected: false, fontSize: style.fontSize, isDark: isDark)
                PreviewCandidateItem(index: 3, text: "我的", isSelected: false, fontSize: style.fontSize, isDark: isDark)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(
            ZStack {
                // Simulated vibrancy effect
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                backgroundColor.opacity(0.85)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        )
        .shadow(color: .black.opacity(isDark ? 0.4 : 0.15), radius: 8, x: 0, y: 4)
    }
}

struct PreviewCandidateItem: View {
    let index: Int
    let text: String
    let isSelected: Bool
    let fontSize: Double
    let isDark: Bool

    private var primaryTextColor: Color {
        isDark ? Color(white: 0.9) : Color(white: 0.1)
    }

    private var secondaryTextColor: Color {
        isDark ? Color(white: 0.53) : Color(white: 0.4)
    }

    private var selectionColor: Color {
        isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("\(index).")
                .font(.system(size: CGFloat(fontSize - 2), design: .monospaced))
                .foregroundColor(secondaryTextColor)

            Text(text)
                .font(.system(size: CGFloat(fontSize + 2), design: .monospaced))
                .foregroundColor(primaryTextColor)

            Text("py")
                .font(.system(size: CGFloat(fontSize - 5), design: .monospaced))
                .foregroundColor(secondaryTextColor.opacity(0.7))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(selectionColor)
                .cornerRadius(2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? selectionColor : Color.clear)
        )
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
