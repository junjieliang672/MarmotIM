import Cocoa
import SwiftUI

/// Controller for the candidate window
class CandidateWindowController {

    // MARK: - Properties

    private var window: NSWindow?
    private var hostingView: NSHostingView<CandidateView>?
    private var candidates: [Candidate] = []
    private var selectedIndex: Int = 0
    private var inputCode: String = ""
    private var currentPage: Int = 0
    private var totalPages: Int = 1

    // MARK: - Window Management

    /// Show the candidate window near the cursor
    func show(candidates: [Candidate], nearRect: NSRect, inputCode: String, currentPage: Int = 0, totalPages: Int = 1) {
        // Ensure we're on the main thread for UI operations
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.show(candidates: candidates, nearRect: nearRect, inputCode: inputCode, currentPage: currentPage, totalPages: totalPages)
            }
            return
        }

        self.candidates = candidates
        self.inputCode = inputCode
        self.selectedIndex = 0
        self.currentPage = currentPage
        self.totalPages = totalPages

        // Create or update the view
        let view = CandidateView(
            candidates: candidates,
            selectedIndex: selectedIndex,
            inputCode: inputCode,
            currentPage: currentPage,
            totalPages: totalPages
        )

        if window == nil {
            createWindow()
        }

        // Update the hosting view
        if let hostingView = hostingView {
            hostingView.rootView = view
        }

        // Position the window
        positionWindow(nearRect: nearRect)

        // Show the window
        window?.orderFront(nil)
    }

    /// Hide the candidate window
    func hide() {
        // Ensure we're on the main thread for UI operations
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.hide()
            }
            return
        }
        window?.orderOut(nil)
    }

    /// Handle arrow key navigation
    func handleArrowKey(isDown: Bool) {
        if isDown {
            selectedIndex = min(selectedIndex + 1, candidates.count - 1)
        } else {
            selectedIndex = max(selectedIndex - 1, 0)
        }

        updateView()
    }

    /// Get the currently selected candidate
    func getSelectedCandidate() -> Candidate? {
        guard selectedIndex >= 0 && selectedIndex < candidates.count else { return nil }
        return candidates[selectedIndex]
    }

    // MARK: - Private Methods

    private func createWindow() {
        let view = CandidateView(
            candidates: candidates,
            selectedIndex: selectedIndex,
            inputCode: inputCode,
            currentPage: currentPage,
            totalPages: totalPages
        )

        hostingView = NSHostingView(rootView: view)
        hostingView?.frame = NSRect(x: 0, y: 0, width: 400, height: 60)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .popUpMenu
        window.hasShadow = true
        window.isReleasedWhenClosed = false  // Prevent double-release crash

        // Make it non-activating (doesn't steal focus)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        self.window = window
    }

    private func positionWindow(nearRect: NSRect) {
        guard let window = window, let screen = NSScreen.main else { return }

        // Calculate window size based on content
        let contentSize = hostingView?.fittingSize ?? CGSize(width: 400, height: 60)
        window.setContentSize(contentSize)

        // Position below the cursor
        var origin = nearRect.origin
        origin.y -= contentSize.height + 5

        // Make sure it's on screen
        let screenFrame = screen.visibleFrame
        if origin.x + contentSize.width > screenFrame.maxX {
            origin.x = screenFrame.maxX - contentSize.width
        }
        if origin.y < screenFrame.minY {
            // Position above cursor instead
            origin.y = nearRect.maxY + 5
        }

        window.setFrameOrigin(origin)
    }

    private func updateView() {
        let view = CandidateView(
            candidates: candidates,
            selectedIndex: selectedIndex,
            inputCode: inputCode,
            currentPage: currentPage,
            totalPages: totalPages
        )
        hostingView?.rootView = view
    }
}

// MARK: - Terminal Hybrid Theme Colors

/// Terminal Hybrid theme color definitions
struct TerminalHybridTheme {
    let colorScheme: ColorScheme

    init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    var isDark: Bool { colorScheme == .dark }

    // Background: semi-transparent with vibrancy
    var backgroundColor: Color {
        isDark ? Color(white: 0.1) : Color(white: 0.96)
    }

    var backgroundOpacity: Double { 0.85 }

    // Text colors
    var primaryTextColor: Color {
        isDark ? Color(white: 0.9) : Color(white: 0.1)
    }

    var secondaryTextColor: Color {
        isDark ? Color(white: 0.53) : Color(white: 0.4)
    }

    // Selection highlight (subtle)
    var selectionColor: Color {
        isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
    }

    // Shadow
    var shadowOpacity: Double {
        isDark ? 0.4 : 0.15
    }

    // Corner radius
    var cornerRadius: CGFloat { 4 }
}

// MARK: - SwiftUI View

struct CandidateView: View {
    let candidates: [Candidate]
    let selectedIndex: Int
    let inputCode: String
    let currentPage: Int
    let totalPages: Int

    @Environment(\.colorScheme) var systemColorScheme

    /// Get style from config
    private var style: CandidateWindowStyle {
        AppDelegate.config.candidateWindowStyle
    }

    /// Get candidate count from config
    private var candidateCount: Int {
        AppDelegate.config.candidateCount
    }

    /// Determine effective color scheme based on config
    private var effectiveColorScheme: ColorScheme {
        switch AppDelegate.config.themeMode {
        case .system:
            return systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    /// Terminal Hybrid theme colors
    private var theme: TerminalHybridTheme {
        TerminalHybridTheme(colorScheme: effectiveColorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top bar: input code, logo, page info
            HStack {
                // Input code (left)
                Text(inputCode)
                    .font(.system(size: style.fontSize - 2, design: .monospaced))
                    .foregroundColor(theme.secondaryTextColor)

                Spacer()

                // Marmot logo (center)
                MarmotLogoView()
                    .frame(width: 14, height: 14)
                    .foregroundColor(theme.secondaryTextColor)

                Spacer()

                // Page info (right)
                if totalPages > 1 {
                    Text("\(currentPage + 1)/\(totalPages)")
                        .font(.system(size: style.fontSize - 3, design: .monospaced))
                        .foregroundColor(theme.secondaryTextColor)
                    Text("[,/.]")
                        .font(.system(size: style.fontSize - 4, design: .monospaced))
                        .foregroundColor(theme.secondaryTextColor.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            // Candidates
            HStack(spacing: 12) {
                ForEach(Array(candidates.prefix(candidateCount).enumerated()), id: \.element.id) { index, candidate in
                    CandidateItemView(
                        candidate: candidate,
                        index: index + 1,
                        isSelected: index == selectedIndex,
                        fontSize: style.fontSize,
                        theme: theme
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .background(
            ZStack {
                // Vibrancy blur effect
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

                // Tinted overlay for color consistency
                theme.backgroundColor.opacity(theme.backgroundOpacity)
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius))
        )
        // Shadow only, no border
        .shadow(color: .black.opacity(theme.shadowOpacity), radius: 8, x: 0, y: 4)
    }
}

struct CandidateItemView: View {
    let candidate: Candidate
    let index: Int
    let isSelected: Bool
    let fontSize: Double
    let theme: TerminalHybridTheme

    /// Determine the indicator label based on candidate properties
    /// Priority: bo > jm > wb/py/en
    private var indicatorLabel: String {
        // "bo" only shows for #1 candidate that was boosted
        if candidate.isBoosted && index == 1 {
            return "bo"
        }
        // "jm" for protected wubi shortcodes (overrides "wb")
        if candidate.isJianma {
            return "jm"
        }
        // Default: show code type
        switch candidate.codeType {
        case .pinyin: return "py"
        case .wubi: return "wb"
        case .english: return "en"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            // Index number
            Text("\(index).")
                .font(.system(size: fontSize - 2, design: .monospaced))
                .foregroundColor(theme.secondaryTextColor)

            // Candidate text
            Text(candidate.text)
                .font(.system(size: fontSize + 2, design: .monospaced))
                .foregroundColor(theme.primaryTextColor)
                .lineLimit(1) // Ensure text doesn't wrap
                .layoutPriority(0) // Allow compression if needed

            // Code type indicator (optional)
            if AppDelegate.config.showCodeHint {
                Text(indicatorLabel)
                    .font(.system(size: fontSize - 5, design: .monospaced))
                    .foregroundColor(theme.secondaryTextColor.opacity(0.7))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(theme.selectionColor)
                    .cornerRadius(2)
                    .fixedSize() // Prevent truncation (shows as "...") when space is tight
                    .layoutPriority(1) // Prioritize showing the label over candidate text
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? theme.selectionColor : Color.clear)
        )
    }
}

// MARK: - Preview

#if DEBUG
struct CandidateView_Previews: PreviewProvider {
    static var sampleCandidates: [Candidate] {
        [
            Candidate(
                from: DictionaryMatch(
                    entry: DictionaryEntry(id: 1, text: "我", pinyin: "wo", wubi: "q", wubiBaseFrequency: 60000, pinyinBaseFrequency: 60000, source: 1, length: 1),
                    matchedCode: "wo",
                    matchType: .full,
                    codeType: .pinyin
                ),
                score: 100, isJianma: true
            ),
            Candidate(
                from: DictionaryMatch(
                    entry: DictionaryEntry(id: 2, text: "我们", pinyin: "women", wubi: "qwu", wubiBaseFrequency: 59000, pinyinBaseFrequency: 59000, source: 1, length: 2),
                    matchedCode: "women",
                    matchType: .prefix,
                    codeType: .pinyin
                ),
                score: 90
            ),
            Candidate(
                from: DictionaryMatch(
                    entry: DictionaryEntry(id: 3, text: "我的", pinyin: "wode", wubi: "qr", wubiBaseFrequency: 58000, pinyinBaseFrequency: 58000, source: 1, length: 2),
                    matchedCode: "wode",
                    matchType: .prefix,
                    codeType: .wubi
                ),
                score: 80
            ),
            Candidate(
                from: DictionaryMatch(
                    entry: DictionaryEntry(id: 4, text: "握", pinyin: "wo", wubi: "rkg", wubiBaseFrequency: 50000, pinyinBaseFrequency: 50000, source: 1, length: 1),
                    matchedCode: "wo",
                    matchType: .full,
                    codeType: .pinyin
                ),
                score: 70
            ),
            Candidate(
                from: DictionaryMatch(
                    entry: DictionaryEntry(id: 5, text: "窝", pinyin: "wo", wubi: "pwl", wubiBaseFrequency: 45000, pinyinBaseFrequency: 45000, source: 1, length: 1),
                    matchedCode: "wo",
                    matchType: .full,
                    codeType: .pinyin
                ),
                score: 60
            )
        ]
    }

    static var previews: some View {
        VStack(spacing: 40) {
            // Light mode
            CandidateView(
                candidates: sampleCandidates,
                selectedIndex: 1,
                inputCode: "wo",
                currentPage: 0,
                totalPages: 3
            )
            .environment(\.colorScheme, .light)

            // Dark mode
            CandidateView(
                candidates: sampleCandidates,
                selectedIndex: 1,
                inputCode: "wo",
                currentPage: 0,
                totalPages: 3
            )
            .environment(\.colorScheme, .dark)
        }
        .padding(40)
        .background(
            LinearGradient(
                colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .previewLayout(.sizeThatFits)
    }
}
#endif
