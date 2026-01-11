import Cocoa
import SwiftUI

/// A transient indicator window that shows the current input mode (Chinese/English)
/// Displays briefly at the cursor position when the user toggles input mode
class ModeIndicator {

    // MARK: - Singleton

    static let shared = ModeIndicator()

    // MARK: - Properties

    private var window: NSWindow?
    private var hideTimer: Timer?

    /// Duration to show the indicator (in seconds)
    private let displayDuration: TimeInterval = 0.8

    /// Size of the indicator window
    private let indicatorSize = NSSize(width: 36, height: 36)

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Show the mode indicator at the specified position
    /// - Parameters:
    ///   - isEnglishMode: Whether the current mode is English
    ///   - position: Screen position (typically cursor location)
    func show(isEnglishMode: Bool, at position: NSPoint) {
        // Ensure we're on the main thread for UI operations
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.show(isEnglishMode: isEnglishMode, at: position)
            }
            return
        }

        // Cancel any existing timer
        hideTimer?.invalidate()
        hideTimer = nil

        // Close existing window safely
        if let existingWindow = window {
            existingWindow.close()
            window = nil
        }

        // Create the indicator view
        let indicatorView = ModeIndicatorView(isEnglishMode: isEnglishMode)
        let hostingView = NSHostingView(rootView: indicatorView)

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: indicatorSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = hostingView
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false  // Prevent double-release crash

        // Position the window near the cursor
        // Offset slightly to not overlap with the cursor
        let adjustedPosition = NSPoint(
            x: position.x + 10,
            y: position.y - indicatorSize.height - 5
        )
        window.setFrameOrigin(adjustedPosition)

        // Show the window with fade-in animation
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }

        self.window = window

        // Schedule auto-hide
        hideTimer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    /// Show the mode indicator at the current cursor position
    /// - Parameter isEnglishMode: Whether the current mode is English
    func showAtCursor(isEnglishMode: Bool) {
        // Get cursor position from the system
        let mouseLocation = NSEvent.mouseLocation
        show(isEnglishMode: isEnglishMode, at: mouseLocation)
    }

    /// Show a message notification at the specified position
    /// - Parameters:
    ///   - message: The message to display
    ///   - position: Screen position (typically cursor location)
    ///   - duration: Duration to show the message (default: 1.5 seconds)
    func showMessage(_ message: String, at position: NSPoint, duration: TimeInterval = 1.5) {
        // Ensure we're on the main thread for UI operations
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showMessage(message, at: position, duration: duration)
            }
            return
        }

        // Cancel any existing timer
        hideTimer?.invalidate()
        hideTimer = nil

        // Close existing window safely
        if let existingWindow = window {
            existingWindow.close()
            window = nil
        }

        // Create the message view
        let messageView = MessageIndicatorView(message: message)
        let hostingView = NSHostingView(rootView: messageView)

        // Calculate dynamic size based on message length
        let width = min(max(CGFloat(message.count * 14 + 24), 80), 300)
        let messageSize = NSSize(width: width, height: 32)

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: messageSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = hostingView
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        // Position the window near the cursor
        let adjustedPosition = NSPoint(
            x: position.x + 10,
            y: position.y - messageSize.height - 5
        )
        window.setFrameOrigin(adjustedPosition)

        // Show the window with fade-in animation
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }

        self.window = window

        // Schedule auto-hide
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    /// Show a message notification at the current cursor position
    /// - Parameters:
    ///   - message: The message to display
    ///   - duration: Duration to show the message (default: 1.5 seconds)
    func showMessageAtCursor(_ message: String, duration: TimeInterval = 1.5) {
        let mouseLocation = NSEvent.mouseLocation
        showMessage(message, at: mouseLocation, duration: duration)
    }

    /// Hide the indicator with animation
    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil

        guard let windowToHide = window else { return }

        // Clear reference immediately to prevent race conditions
        self.window = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            windowToHide.animator().alphaValue = 0
        }, completionHandler: {
            // Close on main thread to ensure thread safety
            DispatchQueue.main.async {
                windowToHide.close()
            }
        })
    }
}

// MARK: - SwiftUI View

/// The visual content of the mode indicator
struct ModeIndicatorView: View {
    let isEnglishMode: Bool

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)

            // Mode text
            Text(isEnglishMode ? "A" : "中")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(textColor)
        }
        .frame(width: 36, height: 36)
    }

    private var backgroundColor: Color {
        if #available(macOS 12.0, *) {
            return Color(nsColor: .controlBackgroundColor)
        } else {
            return Color(NSColor.controlBackgroundColor)
        }
    }

    private var textColor: Color {
        if #available(macOS 12.0, *) {
            return Color(nsColor: .labelColor)
        } else {
            return Color(NSColor.labelColor)
        }
    }
}

/// The visual content of a message indicator
struct MessageIndicatorView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            )
    }

    private var backgroundColor: Color {
        if #available(macOS 12.0, *) {
            return Color(nsColor: .controlBackgroundColor)
        } else {
            return Color(NSColor.controlBackgroundColor)
        }
    }

    private var textColor: Color {
        if #available(macOS 12.0, *) {
            return Color(nsColor: .labelColor)
        } else {
            return Color(NSColor.labelColor)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ModeIndicatorView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ModeIndicatorView(isEnglishMode: false)
                .previewDisplayName("Chinese Mode")

            ModeIndicatorView(isEnglishMode: true)
                .previewDisplayName("English Mode")
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
