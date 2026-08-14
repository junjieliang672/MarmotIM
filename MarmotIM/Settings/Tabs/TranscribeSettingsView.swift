//
//  TranscribeSettingsView.swift
//  MarmotIM
//
//  语音转写设置页（「转写」标签页）
//

import SwiftUI
import AppKit
import AVFoundation

// MARK: - 麦克风权限

/// 界面侧的呈现。`MicrophonePermission` 本身由 `AudioRecorder.swift` 定义
/// （采集层查它、也由它决定要不要碰 AVAudioEngine）——本页只补中文标签和该给哪个按钮，
/// 不再自建一份同名三态枚举。
extension MicrophonePermission {

    var displayName: String {
        switch self {
        case .notDetermined: return "尚未授权"
        case .granted:       return "已授权"
        case .denied:        return "已拒绝"
        }
    }

    var iconName: String {
        switch self {
        case .notDetermined: return "questionmark.circle"
        case .granted:       return "checkmark.circle.fill"
        case .denied:        return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .notDetermined: return .secondary
        case .granted:       return .green
        case .denied:        return .red
        }
    }

    /// 首次使用时系统会自己弹窗询问，所以只有未决定态才值得给「请求授权」按钮。
    var canRequestInline: Bool { self == .notDetermined }

    /// 一旦拒绝，系统再也不会弹窗，只能到「系统设置」里改。
    var requiresSystemSettings: Bool { self == .denied }
}

/// 麦克风权限来源。抽成协议，测试可以注入固定状态而不碰 TCC。
protocol MicrophonePermissionProviding {
    func currentStatus() -> MicrophonePermission
    func requestAccess(_ completion: @escaping () -> Void)
}

/// 真实实现：直接用采集层那套查询/请求，不在设置页里再写一遍 TCC 映射。
struct SystemMicrophonePermission: MicrophonePermissionProviding {
    func currentStatus() -> MicrophonePermission {
        AudioRecorder.permission
    }

    func requestAccess(_ completion: @escaping () -> Void) {
        AudioRecorder.requestPermission { _ in completion() }
    }
}

// MARK: - 服务健康

/// 设置页的健康来源。
///
/// 抽成协议的理由与麦克风一致：测试注入固定快照，界面代码里不出现任何网络调用。
/// 快照类型用 `ASRHealthMonitor` 的 `ASRHealthSnapshot`，不另造一套 ——
/// 指示灯上的状态和输入路径读到的状态必须是同一个词汇表，否则排障时两边说的不是一回事。
///
/// 本页**不持有定时器**：只有窗口打开和用户点「检查」两个入口。
protocol TranscribeHealthProbing {
    func refresh(for config: TranscribeConfig, completion: @escaping (ASRHealthSnapshot) -> Void)
}

/// 真实实现：走 `ASRHealthMonitor` 已有的刷新入口，不自己发 `/health`。
///
/// 选哪个入口取决于探测目标变没变：改过 host / port 之后旧结论说的已经不是同一个服务，
/// 用 `configDidChange` 让监视器把缓存整份作废并取消在飞的旧探测；目标没变就是
/// `refreshForSettingsWindow`，那本来就是为这个指示灯准备的入口。
final class MonitorHealthProbe: TranscribeHealthProbing {

    private let monitor: ASRHealthMonitor
    /// 上一次**本页**探测所针对的目标。比的是 `ASRClientConfig` 而不是整份 `TranscribeConfig`：
    /// 改语言或热词不影响探谁，不该白白作废缓存。
    ///
    /// nil 表示本页还没探过，这要当作「目标没变」而不是「变了」——
    /// 监视器是应用共用的（integration 接管后就是输入路径手里那一份），
    /// 首次刷新若走 `configDidChange`，光是打开设置窗口就会把别人已经探出的结论抹回
    /// 未探测的 `.loading` 并取消在飞的探测。作废缓存的资格只属于「用户真的改了 host / port」。
    private var probedTarget: ASRClientConfig?

    /// 缺省用应用共用的那一份（`ASRHealthMonitor.shared`，装配在
    /// `TranscribeCoordinator.swift`），这样设置页指示灯和输入路径读的是同一份缓存，
    /// 不会出现两边结论不一致。`shared` 是惰性的 `static let`，启动路径上不构造。
    /// 参数仍留着，测试注入用。
    init(monitor: ASRHealthMonitor = .shared) {
        self.monitor = monitor
    }

    func refresh(for config: TranscribeConfig, completion: @escaping (ASRHealthSnapshot) -> Void) {
        let target = ASRClientConfig(config)
        let targetChanged = probedTarget != nil && probedTarget != target
        probedTarget = target
        let monitor = self.monitor
        Task {
            if targetChanged {
                await monitor.configDidChange(config)
            } else {
                await monitor.refreshForSettingsWindow()
            }
            let snapshot = monitor.snapshot
            DispatchQueue.main.async { completion(snapshot) }
        }
    }
}

/// 四态的中文呈现。名字带 `settings` 前缀，避免和 asr-client 日后自己加的展示扩展撞名 ——
/// 这一层纯粹是设置页的说法，输入路径读的是同一个枚举而不是这些字符串。
extension ASRHealthState {
    var settingsDisplayName: String {
        switch self {
        case .down:    return "未安装"
        case .loading: return "启动中"
        case .ready:   return "正常"
        case .error:   return "异常"
        }
    }

    var settingsIconName: String {
        switch self {
        case .down:    return "minus.circle"
        case .loading: return "clock"
        case .ready:   return "checkmark.circle.fill"
        case .error:   return "exclamationmark.triangle.fill"
        }
    }

    var settingsTint: Color {
        switch self {
        case .down:    return .secondary
        case .loading: return .orange
        case .ready:   return .green
        case .error:   return .red
        }
    }
}

// MARK: - 字段校验

/// 字段被退回的理由，直接就是给用户看的中文说明。
struct FieldError: Error, Equatable, CustomStringConvertible {
    let message: String

    init(_ message: String) { self.message = message }

    var description: String { message }
}

/// 一个数值设置项的取值范围与中文错误文案。
///
/// 纯逻辑，与 SwiftUI 无关：界面拿它决定「这次输入要不要写回配置」，测试直接对它断言。
/// 区间与 `AppConfig.validate()` 的钳制区间一一对应，但这里的语义是**拒绝**而不是钳制 ——
/// 输入 70000 会被当场退回并保留在框里，绝不会被悄悄改写成 65535。
struct NumericFieldSpec: Equatable {
    let unit: String
    let lowerBound: Double
    let upperBound: Double
    let isInteger: Bool

    /// 端口：1024 以下是特权端口，需要 root 才能监听。
    static let port = NumericFieldSpec(unit: "", lowerBound: 1024, upperBound: 65535, isInteger: true)
    static let requestTimeout = NumericFieldSpec(unit: "秒", lowerBound: 1, upperBound: 120, isInteger: false)
    static let maxRecording = NumericFieldSpec(unit: "秒", lowerBound: 5, upperBound: 600, isInteger: false)
    static let holdThreshold = NumericFieldSpec(unit: "毫秒", lowerBound: 50, upperBound: 2000, isInteger: true)
    // 服务端项目。区间与 AppConfig.validate() 的钳制、以及 server/config.py 的校验对齐。
    static let minAudio = NumericFieldSpec(unit: "秒", lowerBound: 0, upperBound: 10, isInteger: false)
    static let maxAudio = NumericFieldSpec(unit: "秒", lowerBound: 1, upperBound: 3600, isInteger: false)

    func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    var rangeMessage: String {
        let kind = isInteger ? "整数" : "数值"
        let suffix = unit.isEmpty ? "" : "（\(unit)）"
        return "请输入 \(format(lowerBound)) – \(format(upperBound)) 之间的\(kind)\(suffix)"
    }

    func parse(_ text: String) -> Result<Double, FieldError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(FieldError("不能为空")) }
        guard let value = Double(trimmed), value.isFinite else {
            return .failure(FieldError("请输入数字"))
        }
        if isInteger && value != value.rounded(.towardZero) {
            return .failure(FieldError("必须是整数"))
        }
        guard value >= lowerBound, value <= upperBound else {
            return .failure(FieldError(rangeMessage))
        }
        return .success(value)
    }
}

/// 主机名校验。非回环地址在 `ASRClientConfig.resolvedHost` 里会被强行拉回 127.0.0.1（决策 14）；
/// 与其让用户填了一个地址、界面却在背后换掉，不如在字段上就退回。
enum TranscribeHostRule {
    static func parse(_ text: String) -> Result<String, FieldError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(FieldError("不能为空")) }
        guard ASRClientConfig.loopbackHosts.contains(trimmed.lowercased()) else {
            return .failure(FieldError("只能填本机回环地址：127.0.0.1、localhost 或 ::1"))
        }
        return .success(trimmed)
    }
}

// MARK: - 服务安装状态

/// 「装没装 / 会不会开机自启 / 跑没跑」三件独立的事实，**任何状态下都显示**。
///
/// 起初这些只在 `.down` 分支出现，当作排障文案。那是个疏漏：服务好好跑着的时候，
/// 用户同样要能回答「重启之后它还会自己起来吗」—— 而那时页面只写着「正常」，
/// 什么都没说。状态不该只在出事时才可见。
///
/// 三件事来自两个互不相干的来源：前两件读 `~/Library/LaunchAgents` 里的 plist，
/// 第三件来自 HTTP 健康探测。分开显示是有意的 —— 「装了但没跑」和「跑着但不会自启」
/// 是两种完全不同的处境，合成一个词就把区别抹掉了。
struct ASRAgentStatusLine: View {
    let agent: ASRAgentStatus
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("服务：").foregroundColor(.secondary)
            if agent.isInstalled {
                fact(true, "已安装")
                dot
                // 装了却不自启，得靠人手动拉起来，这值得单独说一句。
                fact(agent.startsAtLogin, agent.startsAtLogin ? "开机自启" : "不会开机自启")
                dot
                fact(isRunning, isRunning ? "运行中" : "未运行")
            } else {
                // 没装的时候，后两件事无从谈起 —— 写「不会开机自启」只会让人以为有个开关没打开。
                fact(false, "未安装")
            }
        }
        .font(.caption)
    }

    private var dot: some View {
        Text("·").foregroundColor(.secondary)
    }

    private func fact(_ ok: Bool, _ label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ok ? .green : .secondary)
            Text(label).foregroundColor(ok ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 可复制的命令

/// 一条等宽显示、可一键复制的终端命令。
///
/// 设置页只能**告诉**用户跑什么，不能替他跑：决策 15 说输入法不做进程管理，
/// 所以这里没有「安装」「启动」按钮，只有一条命令和一个复制按钮。
/// 抄进终端这一步由人来做，是这条边界的实际代价，也是它的全部代价。
struct CommandToCopy: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
                copied = true
                // 复制成功没有别的可见结果，按钮自己变一下是唯一的回执。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(copied ? "已复制" : "复制命令")
            .accessibilityLabel(copied ? "已复制" : "复制命令")
        }
    }
}

// MARK: - View Model

/// 「转写」标签页自己的状态：麦克风权限，以及「改动后如何落盘并通知」这一动作。
///
/// 配置本身仍直接绑定在 `SettingsViewModel.config.transcribe` 上，与其他标签页一致；
/// 这里只承载不属于 `AppConfig` 的东西。
final class TranscribeSettingsModel: ObservableObject {

    @Published private(set) var microphone: MicrophonePermission

    /// 辅助功能授权。只有「不是当前输入源时也能听写」这一档需要它 ——
    /// 关着开关的人不该看见它，也不该被它引去开一个用不上的权限。
    @Published private(set) var accessibilityTrusted: Bool

    /// 最近一次健康探测的结果。nil ＝ 还没探出结论，界面显示「尚未检查」而不是猜一个状态
    /// （监视器的初始快照是 `.loading`，直接显示它等于把「还没问」说成「启动中」）。
    @Published private(set) var health: ASRHealthSnapshot?

    /// 探测进行中。按钮据此置灰，避免连点排出一串请求。
    @Published private(set) var isCheckingHealth = false

    /// LaunchAgent 的安装状态。读一个 plist 文件，不起进程（决策 15）——
    /// 它回答「装没装 / 会不会开机自启」，健康探测回答「跑没跑」，两者缺一不可：
    /// 只看健康探测，没装和装了没起来会给出同一句话，而这两种处境的补救完全不同。
    ///
    /// nil ＝ 还没读过，与 `health` 同一个约定：缺省值恰好是「未安装」，
    /// 没读就显示它等于把「还没看」说成「没装」。
    @Published private(set) var agent: ASRAgentStatus?

    /// 服务端说它正在重启。重启中的连接被拒绝与「没装」同形，靠猜会把前者显示成后者。
    /// 由 `.transcribeServerRestarting` 置位，健康探测再次成功时清除。
    @Published private(set) var isServerRestarting = false
    private var restartObserver: NSObjectProtocol?

    /// 辅助功能授权变化的两个观察点。
    ///
    /// 只在 `onAppear` 读一次是不够的：用户点「去授权」时设置窗口**是开着的**，
    /// 授权动作发生在另一个 app 里，回来时这一页仍在显示授权前的结论 ——
    /// 于是「我明明已经授权了，它还说未授权」。那是这一格最容易被当成 bug 的样子，
    /// 而它确实就是个 bug。
    ///
    /// · `com.apple.accessibility.api` 是系统在授权表变动时发的**分布式**通知
    ///   （跨进程，所以必须走 `DistributedNotificationCenter`）。它不带载荷，
    ///   收到就重读一次。
    /// · 应用重新激活时再读一次兜底：分布式通知的投递时机没有文档保证，而
    ///   「从系统设置切回来」是这条路径上必然发生的一步。
    private var accessibilityObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?

    private let permission: MicrophonePermissionProviding
    private let healthProbe: TranscribeHealthProbing
    private let accessibility: AccessibilityTrusting

    init(permission: MicrophonePermissionProviding = SystemMicrophonePermission(),
         healthProbe: TranscribeHealthProbing = MonitorHealthProbe(),
         accessibility: AccessibilityTrusting = SystemAccessibilityTrust()) {
        self.permission = permission
        self.healthProbe = healthProbe
        self.accessibility = accessibility
        self.microphone = permission.currentStatus()
        self.accessibilityTrusted = accessibility.isTrusted
        restartObserver = NotificationCenter.default.addObserver(
            forName: .transcribeServerRestarting, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isServerRestarting = true
        }
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // 通知到达与 AXIsProcessTrusted 开始改口之间有一小段窗口，立刻读会读到旧值。
            // 迟一点再读一次，两次都读 —— 读一次 AXIsProcessTrusted 是廉价的。
            self?.refreshAccessibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.refreshAccessibility() }
        }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshAccessibility()
        }
    }

    deinit {
        if let restartObserver { NotificationCenter.default.removeObserver(restartObserver) }
        if let appActivationObserver { NotificationCenter.default.removeObserver(appActivationObserver) }
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
    }

    /// 重新读取权限状态。窗口打开时调用 —— 用户可能刚在「系统设置」里改过。
    func refresh() {
        microphone = permission.currentStatus()
        refreshAccessibility()
    }

    /// 只重读辅助功能这一项。授权变化的通知与应用激活都只关心它，
    /// 顺带把麦克风也查一遍没有害处，但会让「谁触发了什么」在日志里糊成一片。
    func refreshAccessibility() {
        accessibilityTrusted = accessibility.isTrusted
    }

    /// 弹一次辅助功能授权引导窗。
    ///
    /// 系统这个弹窗只是把用户送到「系统设置」，**授权结果不会回调**，而且新授权通常
    /// 要重启进程才对本进程生效。所以这里不轮询、不假装能等到结果，只在下一次
    /// `refresh()`（重开设置窗口）时重新读一遍。界面上也是这么写给用户看的。
    func promptForAccessibility() {
        accessibility.promptForTrust()
    }

    /// 打开「系统设置 › 隐私与安全性 › 辅助功能」。
    func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// 触发系统授权弹窗（仅在未决定态有意义）。
    func requestMicrophoneAccess() {
        permission.requestAccess { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// 打开「系统设置 › 隐私与安全性 › 麦克风」。
    func openPrivacySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// 探测一次服务健康。**只在窗口打开和用户点「检查」时调用**，本页没有任何定时器。
    /// 结果异步到达，界面在它到达之前照常渲染。
    func checkHealth(_ config: TranscribeConfig) {
        guard !isCheckingHealth else { return }
        // 与健康探测同步刷新：读一个几百字节的 plist，同步做完不值得再排一次异步。
        agent = ASRAgentStatus.read()
        isCheckingHealth = true
        healthProbe.refresh(for: config) { [weak self] snapshot in
            guard let self else { return }
            // 探测被取消时监视器什么都没学到（probedAt 仍是 nil）——那不是一个可显示的结论。
            self.health = snapshot.hasProbed ? snapshot : nil
            // 探到了就说明它已经回来了；只有真正答话才清除，超时不算。
            if snapshot.hasProbed, snapshot.state == .ready || snapshot.state == .loading {
                self.isServerRestarting = false
            }
            self.isCheckingHealth = false
        }
    }

    /// 丢弃已有的健康结果。改了主机 / 端口之后，旧结果说的已经不是同一个服务了 ——
    /// 与其自动重探（那会在用户逐位输入端口时打出一串请求），不如显示「尚未检查」等用户点。
    func invalidateHealth() {
        health = nil
    }

    /// 保存并通知转写子系统。`save()` 会先 `validate()` 再写盘并发出
    /// `.configurationDidChange`；额外的 `.transcribeConfigDidChange` 让转写
    /// 子系统单独重配，而不必让整个应用重载配置。
    func persist(_ viewModel: SettingsViewModel) {
        viewModel.save()
        notifyTranscribeChanged()
    }

    func notifyTranscribeChanged() {
        NotificationCenter.default.post(name: .transcribeConfigDidChange, object: nil)
    }
}

// MARK: - View

/// 语音转写设置视图
struct TranscribeSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @StateObject private var model = TranscribeSettingsModel()

    /// 高级项默认折叠：绝大多数用户一辈子不需要改这里的任何一项。
    @State private var advancedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                mainSection
                healthSection
                microphoneSection
                recognitionSection
                advancedSection
                Spacer()
            }
            .padding()
        }
        .onAppear {
            model.refresh()
            model.checkHealth(viewModel.config.transcribe)
        }
        .onDisappear {
            if viewModel.isDirty { model.persist(viewModel) }
        }
    }

    // MARK: 总开关 + 手势

    private var mainSection: some View {
        SettingsSection(title: "语音转写") {
            Toggle(isOn: $viewModel.config.transcribe.enabled) {
                Text("启用语音转写")
            }
            .onChange(of: viewModel.config.transcribe.enabled) { _ in
                model.persist(viewModel)
            }

            Text("未启用时，转写功能完全不联网，也不会占用麦克风。")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            HStack {
                Text("快捷键：")
                    .frame(width: 80, alignment: .trailing)
                Text("按住右 Command 键")
                    .font(.system(size: 13, weight: .medium))
                Text("说话，松开后自动上屏")
                    .foregroundColor(.secondary)
                Spacer()
            }

            Text("该手势暂不支持自定义。")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            Toggle(isOn: $viewModel.config.transcribe.worksWhenInactive) {
                Text("不是当前输入源时也能听写")
            }
            .onChange(of: viewModel.config.transcribe.worksWhenInactive) { _ in
                model.persist(viewModel)
                // 刚打开时把授权状态重读一遍：用户可能上次开过又关了，
                // 下面那行提示必须说的是现在的实情。
                model.refresh()
            }

            Text("默认关闭。关闭时，只有土拨鼠是当前输入源、且光标停在能收字的地方，"
                 + "长按右 Command 才有反应 —— 其余情况整条无操作。")
                .font(.caption)
                .foregroundColor(.secondary)

            if viewModel.config.transcribe.worksWhenInactive {
                // 只在开着时展开。这一档的代价必须写在它自己旁边，而不是藏在文档里。
                VStack(alignment: .leading, spacing: 6) {
                    Text("打开后，土拨鼠不是当前输入源时改用合成键盘事件把文字送到当前焦点。"
                         + "土拨鼠自己能上屏时仍走原来那条路，行为不变。")

                    HStack {
                        Text("辅助功能：")
                            .frame(width: 80, alignment: .trailing)
                        Image(systemName: model.accessibilityTrusted
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(model.accessibilityTrusted ? .green : .orange)
                        Text(model.accessibilityTrusted ? "已授权" : "未授权")

                        if !model.accessibilityTrusted {
                            Button("去授权") { model.promptForAccessibility() }
                                .padding(.leading, 4)
                            Button("打开系统设置") { model.openAccessibilitySettings() }
                        }
                        Spacer()
                    }
                    .font(.body)

                    if !model.accessibilityTrusted {
                        // 说清楚「开关开着但仍然没用」不是坏了。这是最容易被当成 bug 的一格。
                        Text("没有这个授权，合成键盘事件会被系统丢弃，这个开关不起任何作用。"
                             + "授权后通常需要重新登录（或重启输入法）才对本进程生效。")
                            .foregroundColor(.orange)
                    }

                    Text("代价：文字会插进系统认定的当前焦点，土拨鼠无从核对那是不是你想要的输入框。"
                         + "密码框等安全输入场合系统会直接丢弃事件，这是刻意不去绕开的。")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 20)
            }
        }
    }

    // MARK: 服务状态

    private var healthSection: some View {
        SettingsSection(title: "服务状态") {
            HStack {
                Text("本地服务：")
                    .frame(width: 80, alignment: .trailing)

                if model.isServerRestarting {
                    // 优先于健康状态：重启期间探测必然失败，而 .down 会显示成「未安装」。
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.orange)
                    Text("重启中")
                        .foregroundColor(.orange)
                } else if let health = model.health {
                    Image(systemName: health.state.settingsIconName)
                        .foregroundColor(health.state.settingsTint)
                    Text(health.state.settingsDisplayName)
                } else {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(.secondary)
                    Text(model.isCheckingHealth ? "检查中…" : "尚未检查")
                        .foregroundColor(.secondary)
                }

                Button("检查") {
                    model.checkHealth(viewModel.config.transcribe)
                }
                .disabled(model.isCheckingHealth)
                .padding(.leading, 4)

                Spacer()
            }

            // 安装状态与健康状态分开显示：前者读 plist，后者靠探测，
            // 两者都拿到之前不猜（agent 为 nil 就是还没读过）。
            if let agent = model.agent {
                ASRAgentStatusLine(agent: agent,
                                   isRunning: model.health?.state == .ready)
            }

            if let health = model.health {
                switch health.state {
                case .ready:
                    if let loaded = health.model {
                        Text("当前模型：\(loaded)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    // 跑着，但重启之后不会自己回来 —— 这是唯一一种「一切正常」却仍需
                    // 用户动手的情形，所以在这里给出补救命令，而不是只标一个灰点。
                    if let agent = model.agent, agent.isInstalled, !agent.startsAtLogin {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("重启或重新登录后服务不会自动启动，需要手动运行一次。")
                            CommandToCopy(command: "bash scripts/install_asr.sh --reinstall")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                case .loading:
                    Text(health.detail ?? "模型正在加载，通常需要十几秒；加载完成前转写会失败。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .down where model.isServerRestarting:
                    Text("服务正在重启以应用新配置，通常十几秒；期间听写不可用。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .down:
                    // 「没装」和「装了但没跑」在这里是两句不同的话、两条不同的命令。
                    let advice = (model.agent ?? .notInstalled).advice(isRunning: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("没有服务在 \(viewModel.config.transcribe.host):\(String(viewModel.config.transcribe.port)) 监听。")
                        Text(advice.summary)
                        if let command = advice.command {
                            CommandToCopy(command: command)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                case .error:
                    // 服务自己给出的说明是排障时唯一有用的信息，原样呈现，不改写不吞掉。
                    Text("服务报告：\(health.detail ?? "模型加载失败，未提供详情。")")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: 麦克风权限

    private var microphoneSection: some View {
        SettingsSection(title: "麦克风") {
            HStack {
                Text("权限：")
                    .frame(width: 80, alignment: .trailing)
                Image(systemName: model.microphone.iconName)
                    .foregroundColor(model.microphone.tint)
                Text(model.microphone.displayName)

                if model.microphone.canRequestInline {
                    Button("请求授权") { model.requestMicrophoneAccess() }
                        .padding(.leading, 4)
                }
                if model.microphone.requiresSystemSettings {
                    Button("打开系统设置") { model.openPrivacySettings() }
                        .padding(.leading, 4)
                }
                Spacer()
            }

            if model.microphone.requiresSystemSettings {
                Text("已拒绝后系统不会再次询问，需在「隐私与安全性 › 麦克风」中手动勾选土拨鼠输入法。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: 识别

    private var recognitionSection: some View {
        SettingsSection(title: "识别") {
            HStack {
                Text("语言：")
                    .frame(width: 80, alignment: .trailing)
                Picker("", selection: $viewModel.config.transcribe.language) {
                    ForEach(TranscribeLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: viewModel.config.transcribe.language) { _ in
                    model.persist(viewModel)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("热词：")
                        .frame(width: 80, alignment: .trailing)
                    TextField("以空格分隔，例如：土拨鼠 五笔 仓颉",
                              text: $viewModel.config.transcribe.hotwords)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onChange(of: viewModel.config.transcribe.hotwords) { _ in
                            viewModel.markDirty()
                        }
                        .onSubmit { model.persist(viewModel) }
                    Spacer()
                }

                Text("热词只是引导，不能强制改写结果；填错的词反而会把本来正确的识别结果带偏，请只填确实常用的专有名词。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: 高级

    /// 折叠区。整体就是又一张 `SettingsSection`，只是标题可点：标题在卡片**外**、`.headline`、
    /// 与上面四节的标题左对齐，卡片沿用同一套 12pt 内边距 / 8pt 圆角 / `controlBackgroundColor`，
    /// 标题与卡片之间也是同样的 8pt。
    ///
    /// 不用 `DisclosureGroup`：它把标题画进卡片里、又把内容整体右缩一段，
    /// 于是这张卡片的左边缘和上面四张对不齐 —— 一列卡片里唯一缩进的那张最扎眼。
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { advancedExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("高级")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ValidatedField(label: "主机：",
                                   initialText: viewModel.config.transcribe.host,
                                   width: 140,
                                   parse: TranscribeHostRule.parse,
                                   onValid: { host in
                                       guard host != viewModel.config.transcribe.host else { return }
                                       viewModel.config.transcribe.host = host
                                       viewModel.markDirty()
                                       model.invalidateHealth()
                                   },
                                   onCommit: { model.persist(viewModel) })

                    ValidatedField(label: "端口：",
                                   initialText: NumericFieldSpec.port.format(Double(viewModel.config.transcribe.port)),
                                   width: 100,
                                   parse: NumericFieldSpec.port.parse,
                                   onValid: { port in
                                       let newPort = Int(port)
                                       guard newPort != viewModel.config.transcribe.port else { return }
                                       viewModel.config.transcribe.port = newPort
                                       viewModel.markDirty()
                                       model.invalidateHealth()
                                   },
                                   onCommit: { model.persist(viewModel) })

                    HStack {
                        Text("模型：")
                            .frame(width: 80, alignment: .trailing)
                        Picker("", selection: $viewModel.config.transcribe.modelVariant) {
                            ForEach(TranscribeModelVariant.allCases, id: \.self) { variant in
                                Text(variant.displayName).tag(variant)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .onChange(of: viewModel.config.transcribe.modelVariant) { _ in
                            model.persist(viewModel)
                        }
                        Spacer()
                    }

                    Text("切换模型后服务需要重新加载权重，期间状态会显示「启动中」。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    ValidatedField(label: "请求超时：",
                                   unit: "秒",
                                   initialText: NumericFieldSpec.requestTimeout.format(viewModel.config.transcribe.requestTimeoutSeconds),
                                   parse: NumericFieldSpec.requestTimeout.parse,
                                   onValid: { value in
                                       viewModel.config.transcribe.requestTimeoutSeconds = value
                                       viewModel.markDirty()
                                   },
                                   onCommit: { model.persist(viewModel) })

                    ValidatedField(label: "录音上限：",
                                   unit: "秒",
                                   initialText: NumericFieldSpec.maxRecording.format(viewModel.config.transcribe.maxRecordingSeconds),
                                   parse: NumericFieldSpec.maxRecording.parse,
                                   onValid: { value in
                                       viewModel.config.transcribe.maxRecordingSeconds = value
                                       viewModel.markDirty()
                                   },
                                   onCommit: { model.persist(viewModel) })

                    Text("这是修饰键卡住时的保险丝，不是给说话时长设的上限。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ValidatedField(label: "按住阈值：",
                                   unit: "毫秒",
                                   initialText: NumericFieldSpec.holdThreshold.format(Double(viewModel.config.transcribe.holdThresholdMilliseconds)),
                                   parse: NumericFieldSpec.holdThreshold.parse,
                                   onValid: { value in
                                       viewModel.config.transcribe.holdThresholdMilliseconds = Int(value)
                                       viewModel.markDirty()
                                   },
                                   onCommit: { model.persist(viewModel) })

                    Text("按住右 Command 键超过这个时长才开始录音，避免误触。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    // 服务端项目：改动通过 POST /reconfigure 下发。前两项服务端能原地生效，
                    // 日志级别要重开进程 —— 页面不判断，服务端在应答里告诉我们。
                    Text("以下三项作用于本机语音服务")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ValidatedField(label: "最短音频：",
                                   unit: "秒",
                                   initialText: NumericFieldSpec.minAudio.format(viewModel.config.transcribe.minAudioSeconds),
                                   parse: NumericFieldSpec.minAudio.parse,
                                   onValid: { value in
                                       viewModel.config.transcribe.minAudioSeconds = value
                                       viewModel.markDirty()
                                   },
                                   onCommit: { model.persist(viewModel) })

                    Text("短于此长度的录音会被静默丢弃，不会插字，也不报错。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ValidatedField(label: "最长音频：",
                                   unit: "秒",
                                   initialText: NumericFieldSpec.maxAudio.format(viewModel.config.transcribe.maxAudioSeconds),
                                   parse: NumericFieldSpec.maxAudio.parse,
                                   onValid: { value in
                                       viewModel.config.transcribe.maxAudioSeconds = value
                                       viewModel.markDirty()
                                   },
                                   onCommit: { model.persist(viewModel) })

                    Text("服务端的第二道上限。客户端本来就有录音上限，这一项通常不必动。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("日志级别：", selection: $viewModel.config.transcribe.logLevel) {
                        ForEach(TranscribeConfig.knownLogLevels, id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                    .onChange(of: viewModel.config.transcribe.logLevel) { _ in
                        model.persist(viewModel)
                    }

                    Text("改这一项服务会重启，期间听写短暂不可用。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    Toggle(isOn: $viewModel.config.transcribe.stripTrailingPunctuation) {
                        Text("去掉句尾标点")
                    }
                    .onChange(of: viewModel.config.transcribe.stripTrailingPunctuation) { _ in
                        model.persist(viewModel)
                    }

                    Text("只去掉结果末尾的一个「。」「，」或「.」，句中标点保持原样。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
            }
        }
    }
}

// MARK: - 带校验的输入框

/// 一个「输入非法就当场退回」的文本框。
///
/// 关键在于它**从不改写用户输入**：非法值原样留在框里，下面出现红色说明，
/// 配置一个字节都不会被写。合法值才写回内存中的配置并标脏，回车（或关窗）才落盘 ——
/// 逐字符落盘意味着每敲一个数字写一次配置文件。
private struct ValidatedField<Value>: View {
    let label: String
    var unit: String = ""
    var width: CGFloat = 100
    let parse: (String) -> Result<Value, FieldError>
    let onValid: (Value) -> Void
    let onCommit: () -> Void

    @State private var draft: String
    @State private var error: String?

    init(label: String,
         unit: String = "",
         initialText: String,
         width: CGFloat = 100,
         parse: @escaping (String) -> Result<Value, FieldError>,
         onValid: @escaping (Value) -> Void,
         onCommit: @escaping () -> Void) {
        self.label = label
        self.unit = unit
        self.width = width
        self.parse = parse
        self.onValid = onValid
        self.onCommit = onCommit
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 间距写死 8，是为了让下面的错误说明能精确对到输入框的左边缘（80 + 8）。
            HStack(spacing: 8) {
                Text(label)
                    .frame(width: 80, alignment: .trailing)
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .onChange(of: draft) { newValue in
                        switch parse(newValue) {
                        case .success(let value):
                            error = nil
                            onValid(value)
                        case .failure(let failure):
                            // 只记下理由 —— draft 保持用户敲的原样，配置一个字节都不写。
                            error = failure.message
                        }
                    }
                    .onSubmit {
                        if error == nil { onCommit() }
                    }
                if !unit.isEmpty {
                    Text(unit)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 88)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TranscribeSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        TranscribeSettingsView(viewModel: SettingsViewModel())
            .frame(width: 600, height: 450)
    }
}
#endif
