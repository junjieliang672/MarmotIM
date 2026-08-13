//
//  TranscribeHotKey.swift
//  MarmotIM
//
//  语音转写：右 Command 长按热键监听（全局 + 本地 NSEvent flagsChanged）
//
//  两条不可动摇的性质：
//  1. 全局 NSEvent 监听是**只读**的 —— 它不能吞掉或改写事件，所以本文件无论怎么写，
//     都不可能让右 Command 的既有快捷键失效（右手拇指按的 ⌘C 照样复制）。
//     本地监听同理：回调原样返回 event，永不返回 nil。
//  2. 只监听 .flagsChanged。加 .keyDown 会把 Accessibility 授权重新拽回来
//     （spike Q3 实测：flagsChanged 在 AXIsProcessTrusted=NO 下照常收到事件），
//     所以不加，也不为听写申请 Accessibility。
//
//  由此产生的决策（brief 的"按下任意其他键则作废"无法按字面实现）：
//  .flagsChanged 只在修饰键跳变时触发，长按期间敲下的字母**根本没有事件可作废**。
//  取免费的那一档 —— 长按期间任何**其他修饰键**的跳变都作废本次长按。剩下的
//  "右拇指按住 Command 再敲字母" 只会多出一段近乎无声的录音，由下游的最短时长/
//  空转写文本兜底，不值得为它换一整个 Accessibility 授权。
//

import Cocoa

/// 一次长按结束的原因
enum TranscribeHoldEndReason: Equatable {
    /// 正常松开右 Command —— 这段录音有效
    case released
    /// 长按被打断：按了别的修饰键、监听被拆掉、或修饰键状态丢失 —— 这段录音应当丢弃
    case aborted
}

// MARK: - 事件监听安装点

/// flagsChanged 监听的安装点
///
/// 抽出来只为一件事：单测可以在没有 NSApplication 的进程里验证装/拆的幂等与不泄漏。
protocol TranscribeEventMonitoring: AnyObject {
    /// 装上监听。handler 参数是 (keyCode, modifierFlags.rawValue)。
    func install(handler: @escaping (UInt16, UInt) -> Void)
    /// 拆掉监听；重复调用安全。
    func uninstall()
}

/// 真实实现：全局 + 本地各一个 .flagsChanged 监听
///
/// 全局监听收不到发给 MarmotIM 自己的事件，本地监听只收发给自己的，两者互不重叠，
/// 所以同一次按键不会被计两次。
final class NSEventFlagsChangedMonitor: TranscribeEventMonitoring {

    private var globalMonitor: Any?
    private var localMonitor: Any?

    func install(handler: @escaping (UInt16, UInt) -> Void) {
        // 先拆再装：即使被重复调用也只会存在一组监听
        uninstall()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event.keyCode, event.modifierFlags.rawValue)
        }

        // 设置窗口在前台时 MarmotIM 自己是 key app，全局监听收不到，靠这个补上。
        // 原样返回 event —— 本地监听是唯一有能力吞事件的地方，我们绝不用这个能力。
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event.keyCode, event.modifierFlags.rawValue)
            return event
        }
    }

    func uninstall() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        uninstall()
    }
}

// MARK: - 长按状态机

/// 右 Command 长按的纯状态机
///
/// 不碰 NSEvent，也不碰计时器：把归一化后的 `Signal` 喂进来，拿回要执行的 `Action`。
/// 阈值本身由外部计时器决定，状态机只回答"到点时是否还该开始"。
struct TranscribeHoldStateMachine {

    enum Signal: Equatable {
        case rightCommandDown
        case rightCommandUp
        /// 长按期间其他修饰键（含左 Command）发生跳变 —— 作废本次长按
        case otherModifierChanged
        /// flagsChanged 显示右 Command 已经不在了：漏掉 UP 时的兜底
        case rightCommandLost
        /// 长按计时器到点
        case holdDeadline
        /// stop() / deinit
        case teardown
    }

    enum Action: Equatable {
        case none
        case scheduleHoldDeadline
        case cancelHoldDeadline
        case begin
        case end(TranscribeHoldEndReason)
    }

    enum State: Equatable {
        case idle
        /// 右 Command 已按下，还没到阈值
        case pending
        /// 已越过阈值，正在录音
        case recording
        /// 本次长按已作废，等右 Command 松开才回 idle
        case blocked
    }

    private(set) var state: State = .idle

    mutating func handle(_ signal: Signal) -> Action {
        switch (state, signal) {

        // idle：只有右 Command 按下才开始计时
        case (.idle, .rightCommandDown):
            state = .pending
            return .scheduleHoldDeadline
        case (.idle, _):
            return .none

        // pending：到点才开始；提前松开就是一次快按，什么都不发生
        case (.pending, .holdDeadline):
            state = .recording
            return .begin
        case (.pending, .rightCommandUp), (.pending, .rightCommandLost), (.pending, .teardown):
            state = .idle
            return .cancelHoldDeadline
        case (.pending, .otherModifierChanged):
            state = .blocked
            return .cancelHoldDeadline
        case (.pending, .rightCommandDown):
            return .none

        // recording：无论怎么结束，都必须发出 end —— 不存在录音停不下来的路径
        case (.recording, .rightCommandUp):
            state = .idle
            return .end(.released)
        case (.recording, .rightCommandLost), (.recording, .teardown):
            state = .idle
            return .end(.aborted)
        case (.recording, .otherModifierChanged):
            state = .blocked
            return .end(.aborted)
        case (.recording, .holdDeadline), (.recording, .rightCommandDown):
            return .none

        // blocked：本次已作废，等松手
        case (.blocked, .rightCommandUp), (.blocked, .rightCommandLost), (.blocked, .teardown):
            state = .idle
            return .none
        case (.blocked, .rightCommandDown):
            // 漏掉了上一次的 UP，按新的一次长按重新开始
            state = .pending
            return .scheduleHoldDeadline
        case (.blocked, _):
            return .none
        }
    }
}

// MARK: - 热键监听器

/// 转写热键监听器
///
/// 右 Command 的 keyCode 是 0x36，与左 Command 的 0x37 区分。
/// 只在主线程使用：NSEvent 监听回调与长按计时器都在主线程。
final class TranscribeHotKey {

    // MARK: - Key Codes

    /// 右 Command 虚拟键码
    static let rightCommandKeyCode: UInt16 = 0x36
    /// 左 Command 虚拟键码 —— 只用来说明"不是它"
    static let leftCommandKeyCode: UInt16 = 0x37
    /// 设备相关的右 Command 位（NX_DEVICERCMDKEYMASK），spike Q3 实测 rawFlags 带这一位
    static let rightCommandDeviceMask: UInt = 0x10
    /// 设备相关的左 Command 位（NX_DEVICELCMDKEYMASK）
    static let leftCommandDeviceMask: UInt = 0x08

    // MARK: - Callbacks

    /// 长按越过阈值：开始录音
    var onBegin: (() -> Void)?
    /// 长按结束：`.released` 才是有效录音，`.aborted` 应当丢弃
    var onEnd: ((TranscribeHoldEndReason) -> Void)?

    // MARK: - Properties

    private let monitor: TranscribeEventMonitoring
    private let config: () -> TranscribeConfig
    private var machine = TranscribeHoldStateMachine()
    private var holdWorkItem: DispatchWorkItem?

    private(set) var isMonitoring = false

    /// 长按阈值（秒）。来自配置，AppConfig.validate 已把它夹在 50–2000 ms。
    var holdThreshold: TimeInterval {
        Double(config().holdThresholdMilliseconds) / 1000.0
    }

    // MARK: - Initialization

    init(monitor: TranscribeEventMonitoring = NSEventFlagsChangedMonitor(),
         config: @escaping () -> TranscribeConfig = { AppDelegate.config.transcribe }) {
        self.monitor = monitor
        self.config = config
    }

    deinit {
        // 不能走 stop()：deinit 里发 onEnd 没有意义，直接把监听和计时器拆干净
        holdWorkItem?.cancel()
        monitor.uninstall()
    }

    // MARK: - Public Methods

    /// 开始监听。重复调用无副作用。
    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitor.install { [weak self] keyCode, rawFlags in
            self?.handle(keyCode: keyCode, rawFlags: rawFlags)
        }
        NSLog("MarmotIM: TranscribeHotKey - started (hold %.0f ms)", holdThreshold * 1000)
    }

    /// 停止监听。重复调用无副作用。
    ///
    /// 监听拆掉之后不可能再收到 UP 事件，所以这里必须把可能在录的那段收掉。
    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.uninstall()
        apply(machine.handle(.teardown))
        NSLog("MarmotIM: TranscribeHotKey - stopped")
    }

    // MARK: - Event Handling

    /// 处理一次 flagsChanged（监听回调的入口，单测直接调它）
    func handle(keyCode: UInt16, rawFlags: UInt) {
        apply(machine.handle(Self.signal(keyCode: keyCode, rawFlags: rawFlags)))
    }

    /// 长按计时器到点（单测直接调它，免得等真实的 250 ms）
    func handleHoldDeadline() {
        apply(machine.handle(.holdDeadline))
    }

    /// 把一次 flagsChanged 归一化成状态机信号
    ///
    /// 左右 Command 只看 keyCode；"右 Command 此刻是否按下"看设备相关位，
    /// 这样左手同时按着 Command 也不会把右手的 UP 误判成 DOWN。
    static func signal(keyCode: UInt16, rawFlags: UInt) -> TranscribeHoldStateMachine.Signal {
        let rightCommandHeld = (rawFlags & NSEvent.ModifierFlags.command.rawValue) != 0
            && (rawFlags & rightCommandDeviceMask) != 0

        guard keyCode == rightCommandKeyCode else {
            // 其他修饰键（含左 Command）：右 Command 还按着就是打断，否则只是状态丢失
            return rightCommandHeld ? .otherModifierChanged : .rightCommandLost
        }
        return rightCommandHeld ? .rightCommandDown : .rightCommandUp
    }

    // MARK: - Private Methods

    private func apply(_ action: TranscribeHoldStateMachine.Action) {
        switch action {
        case .none:
            break
        case .scheduleHoldDeadline:
            scheduleHoldDeadline()
        case .cancelHoldDeadline:
            cancelHoldDeadline()
        case .begin:
            cancelHoldDeadline()
            onBegin?()
        case .end(let reason):
            cancelHoldDeadline()
            onEnd?(reason)
        }
    }

    private func scheduleHoldDeadline() {
        cancelHoldDeadline()
        let item = DispatchWorkItem { [weak self] in
            self?.handleHoldDeadline()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: item)
    }

    private func cancelHoldDeadline() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
    }
}
