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

// MARK: - Theme Colors

/// Candidate panel colors and metrics: black and white only
struct TerminalHybridTheme {
    let colorScheme: ColorScheme

    init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    var isDark: Bool { colorScheme == .dark }

    // Tint over the blur
    var backgroundColor: Color {
        isDark ? Color(red: 0.105, green: 0.11, blue: 0.125) : Color(white: 0.97)
    }

    var backgroundOpacity: Double { 0.78 }

    // Text colors
    var primaryTextColor: Color {
        isDark ? Color(white: 0.94) : Color(white: 0.11)
    }

    var secondaryTextColor: Color {
        isDark ? Color(white: 0.56) : Color(white: 0.43)
    }

    /// Faint backing behind the selected candidate and the logo badge. Text on it keeps its color.
    var selectionColor: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    var badgeColor: Color { selectionColor }

    var cornerRadius: CGFloat { 14 }

    /// Concentric with the panel's corner
    var innerCornerRadius: CGFloat { cornerRadius - inset }

    // Hairline around the panel, so it keeps an edge on backgrounds of its own color
    var borderColor: Color {
        isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
    }

    /// Gap between the panel edge and the shapes inside it
    var inset: CGFloat { 4 }

    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

// MARK: - SwiftUI View

struct CandidateView: View {
    let candidates: [Candidate]
    let selectedIndex: Int
    let inputCode: String
    let currentPage: Int
    let totalPages: Int
    /// Set by the settings preview to show edits that are not saved yet
    var styleOverride: CandidateWindowStyle? = nil
    var themeModeOverride: ThemeMode? = nil

    @Environment(\.colorScheme) var systemColorScheme

    /// Get style from config
    private var style: CandidateWindowStyle {
        styleOverride ?? AppDelegate.config.candidateWindowStyle
    }

    /// Get candidate count from config
    private var candidateCount: Int {
        AppDelegate.config.candidateCount
    }

    /// Determine effective color scheme based on config
    private var effectiveColorScheme: ColorScheme {
        switch themeModeOverride ?? AppDelegate.config.themeMode {
        case .system:
            return systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private var theme: TerminalHybridTheme {
        TerminalHybridTheme(colorScheme: effectiveColorScheme)
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 2) {
            // Marmot badge, as tall as a candidate
            MarmotSentinelLogoView()
                .foregroundColor(theme.primaryTextColor)
                .frame(width: style.fontSize + 7, height: style.fontSize + 7)
                .frame(width: style.fontSize + 14, height: style.fontSize + 14)
                .background(
                    RoundedRectangle(cornerRadius: theme.innerCornerRadius, style: .continuous)
                        .fill(theme.badgeColor)
                )

            // Input code
            Text(inputCode)
                .font(.system(size: style.fontSize - 2, design: .monospaced))
                .foregroundColor(theme.secondaryTextColor)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 6)
                .padding(.trailing, 4)

            // Candidates
            ForEach(Array(candidates.prefix(candidateCount).enumerated()), id: \.element.id) { index, candidate in
                CandidateItemView(
                    candidate: candidate,
                    index: index + 1,
                    isSelected: index == selectedIndex,
                    fontSize: style.fontSize,
                    theme: theme
                )
            }

            // Pager: an arrow dims when there is no page in that direction
            if totalPages > 1 {
                HStack(spacing: 5) {
                    Text("\(currentPage + 1)/\(totalPages)")
                        .font(.system(size: style.fontSize - 3, design: .monospaced))
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .opacity(currentPage > 0 ? 1 : 0.35)
                        Image(systemName: "chevron.right")
                            .opacity(currentPage < totalPages - 1 ? 1 : 0.35)
                    }
                    .font(.system(size: style.fontSize - 5, weight: .bold))
                }
                .foregroundColor(theme.secondaryTextColor)
                .fixedSize()
                .padding(.leading, 6)
                .padding(.trailing, 10)
            }
        }
        .padding(theme.inset)
        .background(
            ZStack {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow, appearance: theme.appearance)
                theme.backgroundColor.opacity(theme.backgroundOpacity)
            }
        )
        .clipShape(panelShape)
        .overlay(panelShape.strokeBorder(theme.borderColor, lineWidth: 0.5))
        // No SwiftUI shadow: the window is exactly content-sized, so it would be
        // clipped. The NSWindow shadow follows the panel's shape instead.
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
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            // Index number
            Text("\(index)")
                .font(.system(size: fontSize - 3, design: .monospaced))
                .foregroundColor(theme.secondaryTextColor)

            // Candidate text
            Text(candidate.text)
                .font(.system(size: fontSize + 2))
                .foregroundColor(theme.primaryTextColor)
                .lineLimit(1) // Ensure text doesn't wrap
                .layoutPriority(0) // Allow compression if needed

            // Code type indicator (optional)
            if AppDelegate.config.showCodeHint {
                Text(indicatorLabel)
                    .font(.system(size: fontSize - 4, design: .monospaced))
                    .foregroundColor(theme.secondaryTextColor)
                    .fixedSize() // Prevent truncation (shows as "...") when space is tight
                    .layoutPriority(1) // Prioritize showing the label over candidate text
            }
        }
        .padding(.horizontal, 9)
        .frame(height: fontSize + 14)
        .background(
            RoundedRectangle(cornerRadius: theme.innerCornerRadius, style: .continuous)
                .fill(isSelected ? theme.selectionColor : Color.clear)
        )
    }
}

// MARK: - Preview

extension Candidate {
    /// Fixed candidates for previews (settings page, Xcode previews, --ui-preview)
    static var previewSamples: [Candidate] {
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
        ] + extraSamples
    }

    private static var extraSamples: [Candidate] {
        let rows: [(UInt32, String, InputCodeType)] = [(6, "卧", .pinyin), (7, "沃", .pinyin), (8, "world", .english)]
        return rows.map { row -> Candidate in
            let entry = DictionaryEntry(id: row.0, text: row.1, pinyin: "wo", wubi: "wo", wubiBaseFrequency: 40000, pinyinBaseFrequency: 40000, source: 1, length: row.1.count)
            let match = DictionaryMatch(entry: entry, matchedCode: "wo", matchType: .full, codeType: row.2)
            return Candidate(from: match, score: 50)
        }
    }
}

#if DEBUG
struct CandidateView_Previews: PreviewProvider {
    static var sampleCandidates: [Candidate] { Candidate.previewSamples }

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

// MARK: - Preview Harness

#if DEBUG
/// `MarmotIM --ui-preview`: shows the real candidate panel over a light and a dark
/// fake editor, without registering as an input method. For iterating on the theme
/// without reinstalling into /Library/Input Methods.
enum CandidatePreviewHarness {
    private static var windows: [NSWindow] = []

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // --grab <dir> <seconds>: no windows of our own, just one screen capture per
        // second, to look at the installed input method's real candidate window
        if let index = CommandLine.arguments.firstIndex(of: "--grab"), CommandLine.arguments.count > index + 2 {
            let dir = CommandLine.arguments[index + 1]
            let seconds = Int(CommandLine.arguments[index + 2]) ?? 10
            for tick in 0..<seconds {
                for (number, screen) in NSScreen.screens.enumerated() {
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
                    capture(CGDisplayBounds(id), to: "\(dir)/grab-\(tick)-\(number).png")
                }
                Thread.sleep(forTimeInterval: 1)
            }
            exit(0)
        }
        // The user's saved settings (read only), so the preview shows what they will see
        if let saved = try? AppConfig.load() { AppDelegate.config = saved }
        AppDelegate.config.themeMode = .system
        if CommandLine.arguments.contains("--no-hint") { AppDelegate.config.showCodeHint = false }

        let size = CGSize(width: 780, height: 520)
        let screen = NSScreen.main!.frame
        let origin = CGPoint(x: 80, y: screen.maxY - 80 - size.height)

        let backdrop = NSWindow(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        // --settings: the theme tab alone, with an unsaved "dark" choice, to check its preview
        let showSettings = CommandLine.arguments.contains("--settings")
        if showSettings {
            let viewModel = SettingsViewModel()
            viewModel.config.themeMode = .dark
            backdrop.contentView = NSHostingView(rootView: ThemeSettingsView(viewModel: viewModel).frame(width: 700))
        } else {
            backdrop.contentView = NSHostingView(rootView: Backdrop())
        }
        backdrop.level = .floating
        backdrop.orderFrontRegardless()
        windows.append(backdrop)

        let samples = CandidateView_Previews.sampleCandidates
        for (column, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() where !showSettings {
            for (row, selected) in [0, 2].enumerated() {
                let view = CandidateView(candidates: samples, selectedIndex: selected,
                                         inputCode: "wo", currentPage: row, totalPages: 3)
                let hosting = NSHostingView(rootView: view)
                let panel = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
                panel.contentView = hosting
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.level = .popUpMenu
                panel.appearance = NSAppearance(named: appearance)
                panel.setFrameOrigin(CGPoint(x: origin.x + 30,
                                             y: origin.y + size.height - 110 - CGFloat(column) * 260 - CGFloat(row) * 90))
                panel.orderFrontRegardless()
                windows.append(panel)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--capture"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                capture(CGRect(x: 80, y: 80, width: size.width, height: size.height), to: path)
                exit(0)
            }
        }
        app.run()
        exit(0)
    }

    /// Composites this process's own on-screen windows (no Screen Recording permission
    /// needed for those). Looked up at runtime because the Swift SDK marks it unavailable.
    private static func capture(_ rect: CGRect, to path: String) {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(symbol, to: Fn.self)
        guard let image = create(rect, 1 /* onScreenOnly */, 0, 0)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private struct Backdrop: View {
        var body: some View {
            VStack(spacing: 0) {
                editor(background: .white, text: Color(white: 0.15), accent: .blue)
                editor(background: Color(red: 0.11, green: 0.12, blue: 0.15), text: Color(white: 0.8), accent: .orange)
            }
        }

        private func editor(background: Color, text: Color, accent: Color) -> some View {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<9, id: \.self) { line in
                    HStack(spacing: 6) {
                        Text("func").foregroundColor(accent)
                        Text("输入法候选窗口预览 line \(line) { return candidates }").foregroundColor(text)
                    }
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(background)
        }
    }
}
#endif
