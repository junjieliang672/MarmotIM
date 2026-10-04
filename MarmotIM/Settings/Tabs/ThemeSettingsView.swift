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
                                    // Save right away: the window's onDisappear save is not
                                    // reliable, and the choice should show on the next keystroke
                                    viewModel.save()
                                }
                            )
                        }
                    }
                }

                // Candidate window style (Terminal Hybrid theme)
                SettingsSection(title: "候选窗口样式") {
                    // Preview
                    // The same view the input method shows, fed the unsaved settings
                    CandidateView(
                        candidates: Candidate.previewSamples,
                        selectedIndex: 0,
                        inputCode: "wo",
                        currentPage: 0,
                        totalPages: 3,
                        styleOverride: viewModel.config.candidateWindowStyle,
                        themeModeOverride: viewModel.config.themeMode
                    )
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)
                    .padding(.bottom, 12)

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
                            viewModel.save()
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

// MARK: - Preview

#if DEBUG
struct ThemeSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ThemeSettingsView(viewModel: SettingsViewModel())
            .frame(width: 600, height: 400)
    }
}
#endif
