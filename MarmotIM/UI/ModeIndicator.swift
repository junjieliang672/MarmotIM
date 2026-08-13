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

// MARK: - 听写 HUD 的窗口

/// 听写 HUD 的绘制端：复用 `MessageIndicatorView` 的视觉语言，但**自己持有一个窗口**。
///
/// 为什么不走 `ModeIndicator.shared.showMessage`：那个单例只有一个 `window`，
/// `show` / `showMessage` / `hide` 三个方法都会先把现存的窗口 close 掉再换上自己的。
/// 听写 HUD 要在屏幕上待好几秒（按住说话 + 等转写），其间用户敲一下 Shift 切中英，
/// 中英提示就会把录音提示顶掉；更糟的是随后中英提示 0.8 s 到点自动 `hide()`，
/// 会把 `window` 置 nil，于是我们再调 `dismiss` 也没有窗口可关 —— 但我们的窗口
/// 其实早就被 close 了，屏幕上没有残留，坏的是"两条提示不能共存"这件事本身。
/// 各自持有一个窗口就没有这个问题，代价只是多一个 NSWindow。
///
/// 不做任何策略判断（何时显示、何时消失、代次）—— 那些在 `TranscribeHUD` 里，
/// 因为它们要被单测驱动，而这里的 NSWindow 不好在测试进程里造。
/// **完全不碰 `CandidateWindow`。**
final class TranscribeHUDWindow: TranscribeHUDRendering {

    private var window: NSWindow?

    /// 把提示窗摆在光标附近，并保证它整个留在屏幕里。
    ///
    /// 纯函数、静态、不碰 NSWindow —— 本文件里真正的窗口代码在测试进程里不好造，
    /// 而"摆在哪"恰恰是唯一会算错的部分，所以把它单独摘出来直接对着断言。
    ///
    /// 默认摆在光标**下方**（阅读时提示不挡住正在打的那一行）。光标贴着屏幕底部时
    /// 下方放不下，就翻到上方 —— 与 `CandidateWindow.positionWindow` 同一套办法，
    /// 那边早就这么干了，这里当初漏了。
    ///
    /// - Parameter visibleFrame: 光标所在屏幕的可见区域（已排除菜单栏与程序坞）。
    ///   nil 表示拿不到屏幕信息，此时原样返回首选位置而不是瞎猜一个。
    static func fittedOrigin(anchor: NSPoint, size: NSSize, visibleFrame: NSRect?) -> NSPoint {
        var origin = NSPoint(x: anchor.x + 10, y: anchor.y - size.height - 5)
        guard let frame = visibleFrame else { return origin }

        // 先横向：右边放不下就贴右边缘；贴完再兜一次左边缘，屏幕比窗口还窄时以左为准，
        // 否则窗口会从左边溢出去。
        if origin.x + size.width > frame.maxX { origin.x = frame.maxX - size.width }
        if origin.x < frame.minX { origin.x = frame.minX }

        // 再纵向：下方放不下就翻到光标上方。翻完仍可能顶出屏幕上沿（屏幕很矮、
        // 或光标本来就贴着顶部），所以最后再夹一次，顺序不能反。
        if origin.y < frame.minY { origin.y = anchor.y + 5 }
        if origin.y + size.height > frame.maxY { origin.y = frame.maxY - size.height }
        if origin.y < frame.minY { origin.y = frame.minY }

        return origin
    }

    func render(_ text: String, at position: NSPoint?, icon: TranscribeHUDIcon) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.render(text, at: position, icon: icon) }
            return
        }

        // 有图标就多留出图标宽度 + 间距，否则长文案会把土拨鼠挤出窗口。
        let iconWidth: CGFloat = (icon == .none) ? 0 : 27
        let size = NSSize(width: min(max(CGFloat(text.count * 16 + 28) + iconWidth, 96), 320), height: 32)
        // 拿不到光标就退回鼠标位置 —— 与 ModeIndicator.showMessageAtCursor 同一个兜底。
        let anchor = position ?? NSEvent.mouseLocation
        // 用光标所在的那块屏幕，而不是 NSScreen.main：多显示器下 main 是「有 key window 的
        // 那块」，而输入法弹提示时 key window 往往在另一块屏上。
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let origin = Self.fittedOrigin(anchor: anchor, size: size,
                                       visibleFrame: screen?.visibleFrame)

        // 已经有窗口就只换内容和位置：录音中 → 转写中 之间不该闪一下。
        if let window {
            window.setContentSize(size)
            window.contentView = NSHostingView(rootView: MessageIndicatorView(message: text, icon: icon))
            window.setFrameOrigin(origin)
            window.orderFrontRegardless()
            return
        }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: MessageIndicatorView(message: text, icon: icon))
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false   // 与 ModeIndicator 同理，避免二次释放崩溃
        window.setFrameOrigin(origin)

        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }
        self.window = window
    }

    func clear() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.clear() }
            return
        }
        guard let closing = window else { return }
        // 先断引用：淡出期间又来一次 render 会新建窗口，而不是复用一个正在消失的。
        window = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            closing.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async { closing.close() }
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
    /// 缺省无图标 —— 中英切换等既有提示的调用点一行都不用改。
    var icon: TranscribeHUDIcon = .none

    var body: some View {
        HStack(spacing: 7) {
            if icon == .recording {
                // 20×14：与 13pt 文字等高，宽一点是因为左右两侧各有声波。
                MarmotRecordingView().frame(width: 20, height: 14)
            }
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)
        }
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
