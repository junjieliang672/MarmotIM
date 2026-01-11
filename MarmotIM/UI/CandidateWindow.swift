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

// MARK: - SwiftUI View

struct CandidateView: View {
    let candidates: [Candidate]
    let selectedIndex: Int
    let inputCode: String
    let currentPage: Int
    let totalPages: Int

    @Environment(\.colorScheme) var colorScheme

    /// Get style from config
    private var style: CandidateWindowStyle {
        AppDelegate.config.candidateWindowStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Input code and page info
            HStack {
                Text(inputCode)
                    .font(.system(size: style.fontSize, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                if totalPages > 1 {
                    Text("\(currentPage + 1)/\(totalPages)")
                        .font(.system(size: style.fontSize - 3))
                        .foregroundColor(.secondary)
                    Text("[,/.]")
                        .font(.system(size: style.fontSize - 4))
                        .foregroundColor(.gray)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // Candidates
            HStack(spacing: 12) {
                ForEach(Array(candidates.prefix(9).enumerated()), id: \.element.id) { index, candidate in
                    CandidateItemView(
                        candidate: candidate,
                        index: index + 1,
                        isSelected: index == selectedIndex,
                        fontSize: style.fontSize
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .background(
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill((colorScheme == .dark ? Color(white: 0.2) : Color.white).opacity(style.backgroundOpacity))
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
    }
}

struct CandidateItemView: View {
    let candidate: Candidate
    let index: Int
    let isSelected: Bool
    let fontSize: Double

    var body: some View {
        HStack(spacing: 2) {
            // Index number
            Text("\(index).")
                .font(.system(size: fontSize - 2))
                .foregroundColor(.secondary)

            // Candidate text
            Text(candidate.text)
                .font(.system(size: fontSize + 2))
                .foregroundColor(isSelected ? .white : .primary)

            // Code type indicator (optional)
            if AppDelegate.config.showCodeHint {
                Text(candidate.codeType == .pinyin ? "py" : "wb")
                    .font(.system(size: fontSize - 5))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }
}

// MARK: - Preview

#if DEBUG
struct CandidateView_Previews: PreviewProvider {
    static var previews: some View {
        CandidateView(
            candidates: [
                Candidate(
                    from: DictionaryMatch(
                        entry: DictionaryEntry(id: 1, text: "我国", pinyin: "woguo", wubi: "qklg", baseFrequency: 60000, source: 1, length: 2),
                        matchedCode: "woguo",
                        matchType: .full,
                        codeType: .pinyin
                    ),
                    score: 100
                ),
                Candidate(
                    from: DictionaryMatch(
                        entry: DictionaryEntry(id: 2, text: "我们", pinyin: "women", wubi: "qwu", baseFrequency: 59000, source: 1, length: 2),
                        matchedCode: "women",
                        matchType: .prefix,
                        codeType: .pinyin
                    ),
                    score: 90
                )
            ],
            selectedIndex: 0,
            inputCode: "wo",
            currentPage: 0,
            totalPages: 5
        )
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
