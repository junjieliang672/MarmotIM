import SwiftUI

/// Parent view for 词库管理 (Dictionary Management). Wraps the three
/// existing dictionary-related tabs — 用户词库 / 降权词库 / 相对排序 —
/// behind a segmented `Picker` so the outer Settings window shrinks
/// to five top-level tabs (spec-003, T5).
///
/// Uses a segmented Picker rather than a SwiftUI TabView: on macOS,
/// TabView renders window-level chrome that would look out of place
/// inside an already-tabbed container. Matches the visual hierarchy
/// the outer SettingsWindowController already establishes.
struct DictionaryManagementView: View {
    @ObservedObject var viewModel: SettingsViewModel

    enum InnerTab: String, CaseIterable, Identifiable {
        case userDict      = "用户词库"
        case suppressed    = "降权词库"
        case relativeOrder = "相对排序"

        var id: String { rawValue }
    }

    @State private var innerTab: InnerTab = .userDict

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $innerTab) {
                ForEach(InnerTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Divider()

            Group {
                switch innerTab {
                case .userDict:
                    UserDictView(viewModel: viewModel)
                case .suppressed:
                    SuppressedWordsView(viewModel: viewModel)
                case .relativeOrder:
                    RelativeOrderingView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#if DEBUG
struct DictionaryManagementView_Previews: PreviewProvider {
    static var previews: some View {
        DictionaryManagementView(viewModel: SettingsViewModel())
            .frame(width: 700, height: 520)
    }
}
#endif
