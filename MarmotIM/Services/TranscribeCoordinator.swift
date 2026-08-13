//
//  TranscribeCoordinator.swift
//  MarmotIM
//
//  语音转写：热键 → 录音 → 转写 → 上屏 的编排
//
//  分两层，照抄 TranscribeHotKey 的分法，理由也一样：
//  · `TranscribeSessionMachine` 是纯状态机 —— 不碰 NSEvent、不碰计时器、不做 I/O，
//    因此每一条转移（含每一条失败边）都能在单测里同步驱动。
//  · `TranscribeCoordinator` 是外壳 —— 它把动作翻译成对 AudioRecorder / ASRClient /
//    HUD / 上屏接缝的真实调用，所有依赖都可注入。
//
//  三条不变量，是"永不影响打字"（决策 20）在本层的落点：
//
//  1. **输入路径上一行代码都不跑。** 本文件不被 InputController 调用，也不注册任何
//     每次按键都会触发的东西。唯一的入口是 TranscribeHotKey 的两个回调。
//  2. **每一次 `finishCapture` / `takeCeilingCapture` 都恰好被一次 `conclude(token:)` 应答。**
//     这条不变量就是"HUD 不会卡住"的全部证明：太短、nil、服务不在、超时、推理失败、
//     文本为空 —— 每一条都在同一个漏斗里收口，没有哪条路能不经过 `present`。
//  3. **迟到的结果按代次丢弃。** 服务端对并发请求是排队而非拒绝（见 ASRClient 头注），
//     所以"松手后又按了一次"和"超时后服务端仍在解码"都会产生一个我们已经不要的答案。
//     代次不匹配就丢，绝不让它插到光标处。
//
//  几个刻意做出的取舍，写在这里免得被当成疏漏：
//
//  · **重叠长按 = 取代 + 丢弃前一次**，不是排队。排队能保住数据，但两段文本的先后
//    完全取决于服务端，插反了就是在用户光标处制造错乱；丢掉一次可以重说，插错不能撤。
//  · **503 model_not_ready 不自动重试。** 它是契约里唯一可重试的状态，但用户此刻正站着
//    等结果，静默重试等于把等待翻倍；给一句"模型加载中"，他自己再按一次更快。
//  · **`.loading` 不短路。** 它同时是"从没探测过"的初始值（见 ASRHealthSnapshot），
//    把它当"服务没准备好"会让首次转写永远失败。只有 `.down`（唯一由连接被拒绝写入的
//    状态）才短路，因为那次请求必然白跑一趟。
//  · **太短 / 服务端 audio_too_short / 文本为空 是静默丢弃**，不报错也不插字。
//    AudioRecorder 头注点名的那条缝（按住 1.5 s 的 ⌘C）只有最后一条挡得住。
//

import Foundation
import Cocoa
import Carbon   // TISCopyCurrentKeyboardInputSource —— 决策 3 的判据只在按下时读一次

// MARK: - 外部接缝

/// 上屏接缝。真实实现走 IME 提交路径（InputController），测试注入假的。
///
/// `isActiveInputSource` 是决策 3 的判据：MarmotIM 不是当前输入源时整条长按无操作 ——
/// 不录音、不发请求、不显示任何东西，也**没有**剪贴板兜底。
protocol TranscriptInserting: AnyObject {
    var isActiveInputSource: Bool { get }
    /// 返回是否真的插进去了。
    @discardableResult
    func insertTranscript(_ text: String) -> Bool
}

/// 录音 HUD 接缝。实现复用 ModeIndicator 的视觉语言，绝不碰 CandidateWindow。
protocol TranscribeHUDPresenting: AnyObject {
    func showRecording()
    func showTranscribing()
    /// 一句话提示，自行在短暂延时后消失
    func showMessage(_ text: String)
    func dismiss()
}

/// 转写请求发起方。抽出来只为让单测不必碰 URLSession。
///
/// `reload` 也在这里，因为它与转写共用同一个目标服务：设置页换了模型变体之后，
/// 服务端不会自己知道 —— 有人得告诉它，否则变体选择器就是个摆设（见 ASRClient.reload 的头注）。
protocol TranscribeRequesting: AnyObject {
    func transcribe(_ request: TranscribeRequest) async throws -> TranscribeResponse
    @discardableResult
    func reload(model: String) async throws -> HealthResponse
    /// 设置页改动服务端项目的唯一出口。哪些能原地生效、哪些要重启由服务端判断。
    @discardableResult
    func reconfigure(_ request: ReconfigureRequest) async throws -> ReconfigureResponse
}

extension ASRClient: TranscribeRequesting {}

/// 健康状态读取方。读 `state` / `snapshot` 不做 I/O；`refreshIfStale` 只在长按开始时踢，
/// 绝不在松手后等。`configDidChange` 只在探测目标真的变了时才调 —— 它会把整份缓存作废。
protocol ASRHealthReading: AnyObject {
    var state: ASRHealthState { get }
    var snapshot: ASRHealthSnapshot { get }
    @discardableResult
    func refreshIfStale(maxAge: TimeInterval) async -> ASRHealthState
    func configDidChange(_ config: TranscribeConfig) async
}

extension ASRHealthMonitor: ASRHealthReading {}

// MARK: - 一次会话的结局

/// 出错时同时需要的两样东西：给用户看的一句话，和给日志的一行。
struct TranscribeFailure: Equatable {
    /// HUD 上的一句话。短，不带错误码 —— 用户看不懂也帮不上忙。
    let message: String
    /// 日志行。诊断信息全在这里。
    let reason: String
}

/// 一次转写会话的结局。三选一，没有第四种。
enum TranscribeSessionResult: Equatable {
    /// 服务端返回的原样文本（尚未 polish）
    case transcript(String)
    /// 静默丢弃：不插字、不报错，只留一行日志
    case discarded(String)
    /// 失败：一句 HUD + 一行日志
    case failure(TranscribeFailure)
}

// MARK: - 会话状态机

/// 转写会话的纯状态机
///
/// idle → recording → transcribing → idle，外加每一条失败边。
/// 与 `TranscribeHoldStateMachine` 的关系：那个管"这次长按算不算数"，这个管
/// "算数的那次长按后面发生了什么"。两个都不做 I/O。
struct TranscribeSessionMachine {

    enum Signal: Equatable {
        /// 长按越过阈值，且已通过按下时的前置检查（当前输入源是 MarmotIM）
        case begin
        /// 长按结束
        case end(TranscribeHoldEndReason)
        /// 采集起不来：授权被拒 / 没有输入设备 / 引擎启动失败
        case captureFailed
        /// 卡键兜底到点：录音被自动停掉，已采到的那段交了出来
        case ceilingReached
        /// 某一代转写有了结局（成功或失败都算）
        case settled(token: UInt64)
        /// stop() / deinit
        case teardown
    }

    enum Action: Equatable {
        case none
        /// 起录音机
        case startCapture
        /// 作废本次采集：cancel()，什么都不交出去
        case discardCapture
        /// 停录音机，可用就以这一代发起转写
        case finishCapture(token: UInt64)
        /// 卡键兜底已经把音频交出来了，直接以这一代发起转写
        case takeCeilingCapture(token: UInt64)
        /// 新的长按取代了在飞的那一代：撤回旧的，同时起新录音
        case supersedeAndStartCapture(abandoning: UInt64)
        /// 主动放弃在飞的那一代（teardown）
        case abandon(token: UInt64)
        /// 这一代的结果作数：呈现它，回 idle
        case settle(token: UInt64)
        /// 迟到的结果：我们早就不要了
        case dropLate(token: UInt64)
    }

    enum State: Equatable {
        case idle
        /// 正在采集
        case recording
        /// 请求在飞，`token` 是这一代
        case transcribing(token: UInt64)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    mutating func handle(_ signal: Signal) -> Action {
        switch (state, signal) {

        // idle：只有 begin 能启动一次会话
        case (.idle, .begin):
            state = .recording
            return .startCapture
        case (.idle, .settled(let token)):
            // teardown / 取代之后才回来的答案
            return .dropLate(token: token)
        case (.idle, _):
            return .none

        // recording：无论怎么结束都必须离开这个状态，不存在停不下来的录音
        case (.recording, .end(.released)):
            let token = nextToken()
            state = .transcribing(token: token)
            return .finishCapture(token: token)
        case (.recording, .end(.aborted)):
            // 长按被打断（按了别的修饰键 / 监听被拆掉）—— 这段音频作废，绝不转写。
            // 把 onEnd 直接接到"停并转写"上，会让每一次被打断的组合键都插一段字。
            state = .idle
            return .discardCapture
        case (.recording, .ceilingReached):
            let token = nextToken()
            state = .transcribing(token: token)
            return .takeCeilingCapture(token: token)
        case (.recording, .captureFailed):
            state = .idle
            return .none
        case (.recording, .teardown):
            state = .idle
            return .discardCapture
        case (.recording, .settled(let token)):
            return .dropLate(token: token)
        case (.recording, .begin):
            return .none

        // transcribing：请求在飞
        case (.transcribing(let current), .settled(let token)):
            guard token == current else { return .dropLate(token: token) }
            state = .idle
            return .settle(token: token)
        case (.transcribing(let current), .begin):
            // 上一段还在转，用户已经开始说下一段：取代它。
            state = .recording
            return .supersedeAndStartCapture(abandoning: current)
        case (.transcribing(let current), .teardown):
            state = .idle
            return .abandon(token: current)
        case (.transcribing, .end):
            // 卡键兜底已经收走了音频，用户随后才松手；或者重复的 end。都无事发生。
            return .none
        case (.transcribing, .ceilingReached), (.transcribing, .captureFailed):
            return .none
        }
    }

    private mutating func nextToken() -> UInt64 {
        lastToken &+= 1
        return lastToken
    }
}

// MARK: - 协调器

/// 转写流程协调器
///
/// 只在主线程使用：热键回调、录音机、HUD 都在主线程；网络在 Task 里，结果经 `onMain` 回来。
final class TranscribeCoordinator {

    // MARK: - Dependencies

    private let hotKey: TranscribeHotKey
    private let recorder: AudioRecorder
    private let health: ASRHealthReading
    private let makeClient: (TranscribeConfig) -> TranscribeRequesting
    private let config: () -> TranscribeConfig
    private let inserter: TranscriptInserting
    private let hud: TranscribeHUDPresenting
    private let onMain: (@escaping () -> Void) -> Void
    private let log: (String) -> Void

    /// frecency 热词供给方。真实实现由 AppDelegate 注入（词表层只读）。
    var hotwords: HotwordSupplying?

    // MARK: - State

    private var machine = TranscribeSessionMachine()
    /// 配置变更时整个换掉（ASRClient 的 config 是 let，无状态，重建比改字段更安全）
    private var client: TranscribeRequesting
    /// 上面那个 client 是按哪个目标造的。比它而不是比整份 TranscribeConfig：
    /// 改语言 / 热词不影响"发给谁"，白白重建客户端还会连带作废健康缓存。
    private var clientTarget: ASRClientConfig
    private var inFlight: Task<Void, Never>?
    /// 非当前输入源时只在进程内记一次日志：那是设计中的稳态，每次长按都打就是刷屏
    /// （与 ASRClient 对"连接被拒绝"闭嘴同理），但一次都不打又会让"听写没反应"无从下手。
    private var didLogInertHold = false

    private(set) var isRunning = false

    /// 当前状态，单测用
    var state: TranscribeSessionMachine.State { machine.state }

    // MARK: - Initialization

    init(hotKey: TranscribeHotKey = TranscribeHotKey(),
         recorder: AudioRecorder = AudioRecorder(),
         health: ASRHealthReading = ASRHealthMonitor(),
         makeClient: @escaping (TranscribeConfig) -> TranscribeRequesting = { ASRClient(config: ASRClientConfig($0)) },
         config: @escaping () -> TranscribeConfig = { AppDelegate.config.transcribe },
         inserter: TranscriptInserting = InertTranscriptSink(),
         hud: TranscribeHUDPresenting = SilentTranscribeHUD(),
         hotwords: HotwordSupplying? = nil,
         onMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         log: @escaping (String) -> Void = { NSLog("MarmotIM: %@", $0) }) {
        self.hotKey = hotKey
        self.recorder = recorder
        self.health = health
        self.makeClient = makeClient
        self.config = config
        self.inserter = inserter
        self.hud = hud
        self.hotwords = hotwords
        self.onMain = onMain
        self.log = log
        let initial = config()
        self.client = makeClient(initial)
        self.clientTarget = ASRClientConfig(initial)
    }

    /// 装配自检。两个缺省接缝（`InertTranscriptSink` / `SilentTranscribeHUD`）都是
    /// **安静地什么都不做**，所以漏注入的注册会照常启动、照常打日志、然后毫无症状 ——
    /// 而那个症状与决策 3 的"MarmotIM 不是当前输入源"一模一样，事后无从区分。
    /// 暴露这两个只读判据，是为了让生产装配那条用例有东西可断言。
    var hasLiveInsertionSeam: Bool { !(inserter is InertTranscriptSink) }
    var hasVisibleHUD: Bool { !(hud is SilentTranscribeHUD) }

    deinit {
        // 不走 stop()：状态机此刻已经没人看了。但 HUD 必须收 ——
        // 它是一个 floating 级别的窗口，协调器在录音中途被释放的话，那个窗口会一直
        // 悬在用户屏幕上，而"每次 finishCapture 恰好一次 conclude"那条不变量管不到
        // 这条路（根本没走到 conclude）。dismiss 自己会做主线程投递。
        inFlight?.cancel()
        recorder.cancel()
        hud.dismiss()
    }

    // MARK: - 生命周期

    /// 开始监听热键。重复调用无副作用。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        hotKey.onBegin = { [weak self] in self?.handleHoldBegan() }
        hotKey.onEnd = { [weak self] reason in self?.handleHoldEnded(reason) }
        recorder.onAutoStop = { [weak self] outcome in self?.handleAutoStop(outcome) }
        hotKey.start()
        log("转写：协调器已启动")
    }

    /// 停止监听并收干净：在录的停掉，在飞的撤回，HUD 关掉。重复调用无副作用。
    func stop() {
        guard isRunning else { return }
        isRunning = false
        // hotKey.stop() 自己会把在录的那次以 .aborted 收掉，随后的 .teardown 落在 idle 上。
        hotKey.stop()
        feed(.teardown)
        log("转写：协调器已停止")
    }

    // MARK: - 配置变更

    /// 设置页保存之后重新配置。由 AppDelegate 接 `.transcribeConfigDidChange` 调进来。
    ///
    /// **顺序是有依赖的**：设置页先 `save()`（写盘并发 `.configurationDidChange`，
    /// AppDelegate 据此把整份配置从盘上重载），再发 `.transcribeConfigDidChange`。
    /// 两次同步 post 有先后，所以走到这里时 `config()` 读到的一定是新值 ——
    /// 本方法自己不读盘，也不该读。
    ///
    /// **全程不阻塞。** 换客户端只是换个引用；作废健康缓存、切服务端模型都进 Task。
    /// 服务端释放一个 1.7B bf16 要占住 GIL 约 0.6 s，绝不能让设置界面等它，
    /// 更不能让它出现在任何与打字有关的路径上（决策 20）。
    func configurationDidChange() {
        let updated = config()

        // 关掉：拆热键监听、停在录的、撤在飞的。协调器对象留着（空闲时不跑计时器、
        // 不占麦克风），再打开时立刻生效，不必重启应用。
        guard updated.enabled else {
            stop()
            return
        }

        let target = ASRClientConfig(updated)
        let retargeted = target != clientTarget
        if retargeted {
            client = makeClient(updated)
            clientTarget = target
        }

        syncModel(updated, retargeted: retargeted)
        start()
    }

    /// 模型变体 → 服务端。**只在与服务端当前报告的模型不同时**才发 `/reload`。
    ///
    /// 为什么要先探一次再比：`ASRHealthSnapshot.model` 是 `/health` 报的"服务端此刻
    /// 加载着谁"。目标刚变过时，旧结论说的是另一个服务，必须先 `configDidChange`
    /// 把缓存整份作废再探；目标没变但缓存过期时也先探一次，否则可能拿 30 s 前的
    /// 模型名做决定。同时改端口和模型是一次真实的操作序列，这两步串在同一个 Task 里，
    /// 就不会出现"作废了缓存 → 拿不到模型名 → 新服务一直服务旧模型"。
    ///
    /// 拿不到模型名（服务没起、或从没探成功过）就什么都不做：那不是"模型不对"，
    /// 而是"我们不知道"。盲发一次 reload 只会把刚起来的服务推进一次 0.6 s 的停顿。
    /// 切换过程本身不必在这里等 —— 服务端 202 后台加载，健康监视器会把
    /// loading → ready 报给设置页的指示灯。
    private func syncModel(_ updated: TranscribeConfig, retargeted: Bool) {
        let monitor = health
        let requester = client
        let wanted = updated.modelVariant.rawValue
        let log = self.log
        Task {
            if retargeted {
                await monitor.configDidChange(updated)
            } else {
                await monitor.refreshIfStale(maxAge: ASRHealthMonitor.stalenessInterval)
            }
            guard let running = monitor.snapshot.model, running != wanted else { return }
            do {
                // 只发模型这一项。设置页里那些**只有客户端在用**的项（保持阈值、录音上限、
                // 标点、超时）不属于服务端，发过去只会让它把不认识的键忽略掉，白跑一趟。
                let answer = try await requester.reconfigure(
                    ReconfigureRequest(model: wanted))
                if answer.restartRequired {
                    log("转写：服务端为应用新配置正在重启（\(answer.applied.joined(separator: ", "))）")
                } else {
                    log("转写：已请求服务端切换模型 \(running) → \(wanted)")
                }
            } catch {
                log("转写：切换模型到 \(wanted) 失败（\(error)）")
            }
        }
    }

    // MARK: - 热键回调

    private func handleHoldBegan() {
        guard isRunning else { return }

        // 决策 3：不是当前输入源就整条无操作 —— 不录音、不发请求、不显示任何东西。
        // 检查放在**按下**这一侧，这样连麦克风都不会被点亮。
        guard inserter.isActiveInputSource else {
            if !didLogInertHold {
                didLogInertHold = true
                log("转写：MarmotIM 不是当前输入源，长按无操作（本条日志每进程只打一次）")
            }
            return
        }
        feed(.begin)
    }

    private func handleHoldEnded(_ reason: TranscribeHoldEndReason) {
        feed(.end(reason))
    }

    private func handleAutoStop(_ outcome: AudioRecorderOutcome) {
        pendingCeilingOutcome = outcome
        feed(.ceilingReached)
    }

    /// 卡键兜底交出来的那一段。`onAutoStop` 给的是值，而状态机只回动作，
    /// 所以要有个地方把它接住 —— 生存期只跨这一次 feed。
    private var pendingCeilingOutcome: AudioRecorderOutcome?

    // MARK: - 状态机驱动

    private func feed(_ signal: TranscribeSessionMachine.Signal) {
        apply(machine.handle(signal))
    }

    private func apply(_ action: TranscribeSessionMachine.Action) {
        switch action {
        case .none:
            break

        case .startCapture:
            beginCapture()

        case .discardCapture:
            recorder.cancel()
            hud.dismiss()
            log("转写：长按被打断，本次录音作废")

        case .finishCapture(let token):
            finishCapture(token: token)

        case .takeCeilingCapture(let token):
            let outcome = pendingCeilingOutcome
            pendingCeilingOutcome = nil
            log("转写：达到录音上限，提交已采到的部分")
            handle(outcome: outcome, token: token)

        case .supersedeAndStartCapture(let abandoned):
            inFlight?.cancel()
            inFlight = nil
            log("转写：新的长按取代了第 \(abandoned) 次转写，其结果将被丢弃")
            beginCapture()

        case .abandon(let token):
            inFlight?.cancel()
            inFlight = nil
            hud.dismiss()
            log("转写：撤回第 \(token) 次转写")

        case .settle(let token), .dropLate(let token):
            // 这两个只由 conclude(_:_:) 产生，不该从 feed 走到这里。
            log("转写：忽略状态机动作 settle/dropLate #\(token)（不应发生）")
        }
    }

    // MARK: - 采集

    private func beginCapture() {
        do {
            try recorder.start()
        } catch {
            // 麦克风起不来是失败，不是静默丢弃：用户按住说了话，什么都不说等于坏了。
            feed(.captureFailed)
            present(TranscribeCoordinator.classify(error))
            return
        }
        hud.showRecording()

        // 决策 20 / ASRHealthMonitor 的明文约束：过期刷新在**按下**这一刻踢出去，
        // 答案会在用户说完之前回来；放在松手后就是白给用户加一整秒。
        // 这里不 await，也不留引用 —— 监视器自己会把并发触发合流。
        let monitor = health
        Task { await monitor.refreshIfStale(maxAge: ASRHealthMonitor.stalenessInterval) }
    }

    private func finishCapture(token: UInt64) {
        // nil = 当时并没有在录（重复 stop，或卡键兜底已经交付过）—— 绝不重复处理。
        guard let outcome = recorder.stop() else {
            conclude(token, .discarded("松手时录音机已不在录音状态，无事可做"))
            return
        }
        handle(outcome: outcome, token: token)
    }

    private func handle(outcome: AudioRecorderOutcome?, token: UInt64) {
        guard let outcome else {
            conclude(token, .discarded("录音上限回调没有带回音频"))
            return
        }
        switch outcome {
        case .tooShort(let duration):
            // 误触。静默丢弃：不报错、不插字。
            conclude(token, .discarded(String(format: "录音仅 %.2f s，短于下限，静默丢弃", duration)))
        case .recorded(let recording):
            transcribe(recording, token: token)
        }
    }

    // MARK: - 转写

    private func transcribe(_ recording: AudioRecording, token: UInt64) {
        // 松手这一侧只读同步快照，绝不 await 健康探测。
        // 只有 .down 短路：它是唯一由"连接被拒绝"写入的状态，那次请求必然白跑。
        // .loading 同时是"从没探测过"的初始值，把它当"没准备好"会让首次转写永远失败。
        if health.state == .down {
            conclude(token, .failure(TranscribeFailure(message: "转写服务未运行",
                                                       reason: "健康快照为 down，跳过请求")))
            return
        }

        let current = config()
        let request = TranscribeRequest(
            audioBase64: TranscribeCoordinator.encodePCM(recording.samples),
            sampleRate: Int(recording.sampleRate),
            language: current.language.wireValue,
            context: HotwordContextBuilder.build(config: current, supplier: hotwords),
            maxNewTokens: current.maxNewTokens
        )

        hud.showTranscribing()
        log(String(format: "转写：提交第 %llu 次，%.2f s 音频", token, recording.duration))

        let requester = client
        let deliver = onMain
        inFlight = Task { [weak self] in
            let result: TranscribeSessionResult
            do {
                result = .transcript(try await requester.transcribe(request).text)
            } catch {
                result = TranscribeCoordinator.classify(error)
            }
            deliver { self?.conclude(token, result) }
        }
    }

    /// 结局的唯一漏斗。**每一次 finishCapture / takeCeilingCapture 都恰好经过这里一次** ——
    /// HUD 不会卡住的全部证明就在这一条不变量上。
    private func conclude(_ token: UInt64, _ result: TranscribeSessionResult) {
        switch machine.handle(.settled(token: token)) {
        case .settle:
            inFlight = nil
            present(result)
        case .dropLate:
            // 超时后服务端仍在解码，或这一代已被新的长按取代。丢掉，绝不插到光标处。
            log("转写：丢弃第 \(token) 次的迟到结果")
        default:
            log("转写：第 \(token) 次的结局无处安放（不应发生）")
        }
    }

    private func present(_ result: TranscribeSessionResult) {
        switch result {
        case .discarded(let reason):
            hud.dismiss()
            log("转写：\(reason)")

        case .failure(let failure):
            hud.showMessage(failure.message)
            log("转写失败：\(failure.reason)")

        case .transcript(let raw):
            let text = TranscriptPostProcessor.polish(raw,
                                                      stripTrailingPunctuation: config().stripTrailingPunctuation)
            // polish 无条件裁掉首尾空白，所以这一步就是"全空白"的判定。
            // AudioRecorder 头注点名的那条缝（按住 1.5 s 的 ⌘C 录到近乎无声）
            // 只有这一条挡得住 —— 0.2 s 的下限拦不住它。
            guard !text.isEmpty else {
                hud.dismiss()
                log("转写：结果为空，不插字")
                return
            }
            guard inserter.insertTranscript(text) else {
                // 转写期间焦点跑掉了。文本已经拿到却上不了屏，静默会让用户以为白说了。
                hud.showMessage("无法上屏")
                log("转写失败：上屏接缝拒绝了 \(text.count) 字")
                return
            }
            hud.dismiss()
            log("转写：已上屏 \(text.count) 字")
        }
    }

    // MARK: - 请求组装

    /// float32 小端裸 PCM 的 base64。不是 WAV —— 线格式就是裸浮点（见 TranscribeRequest）。
    static func encodePCM(_ samples: [Float]) -> String {
        let words = samples.map { $0.bitPattern.littleEndian }
        let data = words.withUnsafeBufferPointer { Data(buffer: $0) }
        return data.base64EncodedString()
    }

    // MARK: - 失败分类

    /// 每一个可达的错误 → 一句 HUD + 一行日志，或静默丢弃。
    ///
    /// 穷举 switch 是刻意的：契约任何一侧加了新码，这里会编译不过，而不是悄悄落到默认分支。
    static func classify(_ error: Error) -> TranscribeSessionResult {
        if let error = error as? ASRClientError { return classify(error) }
        if let error = error as? AudioRecorderError { return classify(error) }
        if error is CancellationError {
            return .discarded("本次转写已被撤回")
        }
        return .failure(TranscribeFailure(message: "转写失败", reason: "未分类错误 \(error)"))
    }

    static func classify(_ error: ASRClientError) -> TranscribeSessionResult {
        switch error {
        case .notRunning:
            // ASRClientError.isSilent 说的是健康探测那一侧的稳态。这里不一样：
            // 用户刚刚按住说完了话，什么都不显示才是 bug。
            return .failure(TranscribeFailure(message: "转写服务未运行",
                                              reason: "连接被拒绝（\(error)）"))
        case .timedOut(let endpoint):
            // 服务端仍在解码，完成后会写进一个没人读的 socket。我们只是放弃本次结果，
            // 不重试（重试等于再排一次队），HUD 立刻收掉。
            return .failure(TranscribeFailure(message: "转写超时",
                                              reason: "\(endpoint.path) 超时，服务端可能仍在解码"))
        case .server(let code, let detail):
            return classify(code, detail: detail)
        case .badModel(let detail):
            // 只可能出现在 /reload；转写路径上不可达，但不留空分支。
            return .failure(TranscribeFailure(message: "模型不可用",
                                              reason: "bad_model：\(detail ?? "无说明")"))
        case .unexpectedStatus(let status, let code, let detail):
            return .failure(TranscribeFailure(message: "转写服务异常",
                                              reason: "状态码 \(status)，code=\(code ?? "nil")，\(detail ?? "无说明")"))
        case .malformedResponse(let endpoint):
            return .failure(TranscribeFailure(message: "转写响应异常",
                                              reason: "\(endpoint.path) 返回的内容无法解析"))
        case .transport(let code):
            return .failure(TranscribeFailure(message: "转写连接失败",
                                              reason: "传输错误 \(code)"))
        }
    }

    static func classify(_ code: TranscribeServerErrorCode, detail: String?) -> TranscribeSessionResult {
        switch code {
        case .modelNotReady:
            // 契约里唯一可重试的状态，但**不自动重试**：用户正站着等，静默重试会把等待翻倍。
            return .failure(TranscribeFailure(message: "模型加载中，稍后再试",
                                              reason: "503 model_not_ready：\(detail ?? "无说明")"))
        case .audioTooShort:
            // 与本地 0.2 s 下限同源的误触。静默丢弃，保持两侧行为一致。
            return .discarded("服务端判定音频过短：\(detail ?? "无说明")")
        case .audioTooLong:
            return .failure(TranscribeFailure(message: "录音过长",
                                              reason: "400 audio_too_long：\(detail ?? "无说明")"))
        case .badAudio:
            return .failure(TranscribeFailure(message: "音频无法识别",
                                              reason: "400 bad_audio：\(detail ?? "无说明")"))
        case .inferenceFailed:
            return .failure(TranscribeFailure(message: "转写失败",
                                              reason: "500 inference_failed：\(detail ?? "无说明")"))
        }
    }

    static func classify(_ error: AudioRecorderError) -> TranscribeSessionResult {
        switch error {
        case .permissionDenied:
            return .failure(TranscribeFailure(message: "麦克风权限未开启",
                                              reason: "麦克风授权被拒，需到系统设置开启"))
        case .inputUnavailable:
            return .failure(TranscribeFailure(message: "没有可用的麦克风",
                                              reason: "输入设备不可用（拔掉了 / 采样率为 0）"))
        case .engineFailed(let detail):
            return .failure(TranscribeFailure(message: "麦克风启动失败",
                                              reason: "AVAudioEngine.start() 抛错：\(detail)"))
        case .converterUnavailable:
            return .failure(TranscribeFailure(message: "音频转换失败",
                                              reason: "建不出 AVAudioConverter"))
        }
    }
}

// MARK: - 缺省接缝

/// 缺省上屏接缝：永远不是当前输入源，永远插不进去。
///
/// 有意选这个方向：真实接缝（InputController 的活跃控制器引用）还没接上时，
/// 协调器整体是 inert 的 —— 宁可听写不工作，也不能有半条路能碰到光标。
final class InertTranscriptSink: TranscriptInserting {
    var isActiveInputSource: Bool { false }
    func insertTranscript(_ text: String) -> Bool { false }
}

/// 缺省 HUD：什么都不显示。真实实现复用 ModeIndicator 的视觉语言。
final class SilentTranscribeHUD: TranscribeHUDPresenting {
    func showRecording() {}
    func showTranscribing() {}
    func showMessage(_ text: String) {}
    func dismiss() {}
}

// MARK: - 真实上屏接缝

/// 上屏目标。生产实现只有一个：`InputController`。
///
/// 抽成协议只为一件事 —— 让 `IMETranscriptSink` 的两个判据（输入源 + 有没有目标）
/// 能在单测里被完整驱动。测试进程里造不出 `IMKInputController`（需要真实 IMKServer），
/// 没有这层就只能测到"没有目标 → 拒绝"那一半，而"两个都满足 → 插进去"那一半
/// 会是恒真的假绿。
protocol TranscriptCommitting: AnyObject {
    @discardableResult
    func insertTranscribedText(_ text: String) -> Bool
}

extension InputController: TranscriptCommitting {}

/// 走 IME 提交路径的上屏接缝：`InputController.insertTranscribedText`，
/// 也就是候选上屏那条路。没有剪贴板兜底，也不合成按键事件。
///
/// **`isActiveInputSource` 同时要求两件事，是刻意的：**
///
/// · **TIS 说当前键盘输入源就是 MarmotIM** —— 这是决策 3 那句话的**原命题**，
///   由系统直接回答，一次调用，只发生在按下的那一刻（不在任何按键路径上）。
/// · **确实存在一个活跃的 InputController** —— 保证文本有地方可去。没有它时
///   （比如焦点在 Finder 桌面上）录音必然白录，不如整条无操作。
///
/// 只用后者是不够的：活跃控制器引用回答的是"IMK 最近一次为某个 client 激活了我们"，
/// 它与原命题只在 `deactivated` 的 `===` 规则始终正确的前提下等价。规则一旦出偏差，
/// 失效方向是**在 MarmotIM 并非当前输入源时插字** —— 正是决策 3 要挡的那件事。
/// 反过来，TIS 判据自己出偏差的方向只能是听写永远不工作，这是安全的一侧。
final class IMETranscriptSink: TranscriptInserting {

    private let isCurrentInputSource: () -> Bool
    private let controller: () -> TranscriptCommitting?

    init(isCurrentInputSource: @escaping () -> Bool = IMETranscriptSink.marmotIsCurrentKeyboardInputSource,
         controller: @escaping () -> TranscriptCommitting? = { ActiveInputControllerRegistry.shared.current }) {
        self.isCurrentInputSource = isCurrentInputSource
        self.controller = controller
    }

    var isActiveInputSource: Bool {
        isCurrentInputSource() && controller() != nil
    }

    func insertTranscript(_ text: String) -> Bool {
        // 按下时查过一次，这里再查一次：转写要花一秒上下，其间用户完全可能切走输入源
        // 或换掉焦点。查两次的成本是两次系统调用，代价是别人的输入框里凭空多一段字。
        guard isCurrentInputSource(), let controller = controller() else { return false }
        return controller.insertTranscribedText(text)
    }

    /// 当前键盘输入源的 bundle id 是否就是本 app。
    ///
    /// MarmotIM.app 自己就是输入法 bundle，输入模式（ComponentInputModeDict）报的
    /// `kTISPropertyBundleID` 仍是容器 bundle 的 id，所以直接与 `Bundle.main` 比。
    /// 万一某天不成立，症状是听写恒定无操作 —— 失效方向在安全的一侧。
    static func marmotIsCurrentKeyboardInputSource() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return false }
        let bundleID = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return bundleID == Bundle.main.bundleIdentifier
    }
}

// MARK: - 真实 HUD

/// HUD 的绘制端。抽出来是为了让上面那层（主线程投递、自动消失、兜底关闭）
/// 能在单测里被完整驱动，而不必在测试进程里造 NSWindow。
/// HUD 左侧的图标。只有"正在录音"这一个状态配图 —— 图标出现即代表麦克风是开着的，
/// 这正是它存在的理由；错误提示、转写中都不配，免得把这个信号稀释掉。
enum TranscribeHUDIcon {
    case none
    /// 张嘴发声的土拨鼠（`MarmotRecordingView`）
    case recording
}

protocol TranscribeHUDRendering: AnyObject {
    /// `position` 为 nil 表示拿不到光标位置，由实现自行兜底。
    func render(_ text: String, at position: NSPoint?, icon: TranscribeHUDIcon)
    func clear()
}

/// 录音 HUD 的策略层：状态文案、主线程投递、自动消失、兜底关闭。
///
/// **为什么它住在这个文件里而不是自己一个文件。** `project.pbxproj` 只由 `foundation`
/// 目标维护，它一次性登记了本计划会新增的全部文件，没有给 HUD 留位置。所以要么住在
/// 已登记的文件里，要么去改 pbxproj —— 后者是明令禁止的。选 TranscribeCoordinator.swift
/// 是因为这里装的是**策略**（哪个状态显示什么、什么时候必须消失），它和协调器的
/// 生命周期是一件事；真正画窗口的那一半（`TranscribeHUDWindow`）放在 ModeIndicator.swift，
/// 紧挨着它复用的视觉语言。
///
/// **为什么不复用 `ModeIndicator.shared`。** 那个单例只拥有一个 NSWindow，
/// `show` / `showMessage` / `hide` 会互相顶掉。听写 HUD 会持续显示好几秒，其间用户
/// 完全可能敲一下 Shift 切中英 —— 那会把录音提示顶掉，而随后中英提示的自动消失
/// 又会把我们的窗口引用清空。两个各自持有窗口的对象没有这个问题。
final class TranscribeHUD: TranscribeHUDPresenting {

    /// 一句话提示停留多久。与 ModeIndicator.showMessage 的默认值一致。
    static let messageDuration: TimeInterval = 1.5

    private let renderer: TranscribeHUDRendering
    private let caret: () -> NSPoint?
    private let onMain: (@escaping () -> Void) -> Void
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let watchdog: () -> TimeInterval

    /// 每次显示换一代。计时器回调只有代次相符才动手 —— 否则"上一条的自动消失"
    /// 会把刚显示的下一条抹掉（松手那一刻录音提示紧接着换成转写提示，就会撞上）。
    private var generation: UInt64 = 0
    private var isShowing = false

    /// - Parameter watchdog: 持续态（录音中 / 转写中）最长能停留多久。缺省 135 s
    ///   略高于 `maxRecordingSeconds` 的缺省 120 s；`maxRecordingSeconds` 可被调到
    ///   600 s，所以注册方（AppDelegate）应当传 `config.maxRecordingSeconds + 15`。
    ///   它是**兜底**不是策略：正常路径上每一次采集都由 `conclude` 收口，永远轮不到它。
    init(renderer: TranscribeHUDRendering,
         caret: @escaping () -> NSPoint? = { ActiveInputControllerRegistry.shared.current?.caretPositionOnScreen() },
         watchdog: @escaping () -> TimeInterval = { 135 },
         onMain: @escaping (@escaping () -> Void) -> Void = TranscribeHUD.mainThread,
         after: @escaping (TimeInterval, @escaping () -> Void) -> Void = TranscribeHUD.mainThreadAfter) {
        self.renderer = renderer
        self.caret = caret
        self.watchdog = watchdog
        self.onMain = onMain
        self.after = after
    }

    // MARK: - TranscribeHUDPresenting

    func showRecording() { show("录音中", dismissAfter: nil, icon: .recording) }

    func showTranscribing() { show("转写中…", dismissAfter: nil) }

    func showMessage(_ text: String) { show(text, dismissAfter: TranscribeHUD.messageDuration) }

    func dismiss() {
        onMain { [self] in clear() }
    }

    // MARK: - 内部

    private func show(_ text: String, dismissAfter: TimeInterval?,
                      icon: TranscribeHUDIcon = .none) {
        onMain { [self] in
            generation &+= 1
            let shown = generation
            isShowing = true
            renderer.render(text, at: caret(), icon: icon)

            // 持续态也挂一个（长得多的）计时器：没有哪一代能永远留在屏幕上。
            after(dismissAfter ?? watchdog()) { [weak self] in
                guard let self, self.isShowing, self.generation == shown else { return }
                self.clear()
            }
        }
    }

    private func clear() {
        // 递增代次 = 让所有在途的计时器回调失效，包括刚刚那一条。
        generation &+= 1
        isShowing = false
        renderer.clear()
    }

    // MARK: - 缺省投递

    /// 已经在主线程就直接跑。听写的插入必须与 HUD 的顺序一致，多绕一圈 async
    /// 会让"先关 HUD 再插字"变成"先插字再关 HUD"。
    static func mainThread(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    static func mainThreadAfter(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - 应用共用的健康监视器

extension ASRHealthMonitor {

    /// 应用共用的那一份监视器。
    ///
    /// 住在这里而不是 `ASRHealthMonitor.swift`：那是 asr-client 已经定稿的文件，
    /// 而"谁和谁共用哪一份"是装配问题，属于本层。`static let` 是惰性的 ——
    /// 直到 AppDelegate 在启动**之后**真的去注册转写，它才被构造，启动路径上一行不跑。
    ///
    /// 输入路径和设置页指示灯共用这一份：`MonitorHealthProbe` 的缺省参数已改成
    /// `.shared`（原先各自 `ASRHealthMonitor()`，两边缓存可能给出不一致的结论）。
    /// 那处改动跨了 settings-ui 的文件边界，是在该目标完成、边界失效之后做的。
    static let shared = ASRHealthMonitor(config: AppDelegate.config.transcribe)
}

// MARK: - 生产装配

extension TranscribeCoordinator {

    /// 生产装配点。AppDelegate **只应**经由这里构造协调器。
    ///
    /// 缺省构造函数刻意是"安全缺省"：`InertTranscriptSink`（永远不是当前输入源、
    /// 永远插不进去）加 `SilentTranscribeHUD`（什么都不画）。半成品阶段这是对的，
    /// 但它同时意味着**漏掉真实接缝的注册会干干净净地跑起来、打出"协调器已启动"、
    /// 然后什么都不做** —— 而那个症状与决策 3 的"MarmotIM 不是当前输入源"完全一样。
    /// 所以生产装配收敛到这一个函数，并由测试盯住它确实注入了真家伙。
    static func makeProduction(hotwords: HotwordSupplying? = nil,
                               health: ASRHealthReading = ASRHealthMonitor.shared,
                               config: @escaping () -> TranscribeConfig = { AppDelegate.config.transcribe })
    -> TranscribeCoordinator {
        TranscribeCoordinator(
            // 热键的长按阈值也吃同一个 config 闭包：让缺省参数各读各的，
            // 会在有人用非缺省 config 调这里时安静地跑偏。
            hotKey: TranscribeHotKey(config: config),
            recorder: AudioRecorder(config: config),
            health: health,
            config: config,
            inserter: IMETranscriptSink(),
            hud: TranscribeHUD(renderer: TranscribeHUDWindow(),
                               watchdog: { TranscribeCoordinator.watchdogSeconds(for: config()) }),
            hotwords: hotwords)
    }

    /// 持续态 HUD 的兜底时长：录音上限再多留一点。
    ///
    /// 不能用 `TranscribeHUD` 的缺省 135 s。那个值只在 `maxRecordingSeconds`
    /// 取缺省 120 s 时才对，而它可以被调到 600 s —— 那时兜底会在录到第 135 s 时
    /// 把"录音中"从屏幕上抹掉，而录音还在继续，用户看到的是听写死了。
    static func watchdogSeconds(for config: TranscribeConfig) -> TimeInterval {
        config.maxRecordingSeconds + 15
    }
}

// MARK: - 真实热词来源

/// 用户词表的 frecency 供给方。**只读词表层，一个字都不写。**
///
/// 三条约束决定了它必须长成"缓存 + 后台刷新"的样子：
///
/// 1. `HotwordSupplying` 的头注明令：读取发生在组装请求的那一刻，用户已经松手在等
///    结果，这里每多花 10 ms 就是他多等 10 ms。所以读路径只有一次加锁加一次数组拷贝。
/// 2. 词表层没有"按 frecency 枚举用户词"的 API（`DictionaryEngine` 只有逐词的
///    `getUserLearning`），唯一的路子是 `getUserEntries()` + `loadAllUserLearning()` ——
///    两个都是全表扫描，只能在后台队列上跑。
/// 3. 词表一直在变（用户加词，而且每次上屏都在改 learning）。所以缓存有过期时间，
///    读到过期是**先把旧的返回出去**再在后台刷新：宁可这一次用上一批热词，
///    也不让任何人在这条路上等一次全表扫描。
final class FrecencyHotwordSupplier: HotwordSupplying {

    /// 缓存过期时间。热词表变化很慢（几分钟内新增几个词不影响识别效果），
    /// 而每次刷新是两次全表扫描，值得攒一攒。
    static let refreshInterval: TimeInterval = 300

    /// 缓存多少个词。`HotwordContextBuilder.frecencyWordLimit` 要 48，
    /// 多留一点给去重和长度上限淘汰掉的那些。
    static let cacheSize = 64

    private let lock = NSLock()
    private var words: [String] = []
    private var refreshedAt: Date?
    private var isRefreshing = false

    private let scan: () -> [String]
    private let now: () -> Date
    private let background: (@escaping () -> Void) -> Void

    init(scan: @escaping () -> [String] = FrecencyHotwordSupplier.scanUserDictionary,
         now: @escaping () -> Date = Date.init,
         background: @escaping (@escaping () -> Void) -> Void = {
             DispatchQueue.global(qos: .utility).async(execute: $0)
         }) {
        self.scan = scan
        self.now = now
        self.background = background
    }

    /// 预热。注册转写时调一次，好让第一次听写就已经有热词可用（否则第一次必然是空表，
    /// 而第一次恰恰是用户在试这个功能灵不灵的那一次）。
    func prime() {
        refreshInBackground()
    }

    // MARK: - HotwordSupplying

    /// **读路径。** 一次加锁、一次拷贝，不碰磁盘、不等任何 Task。
    func topFrecencyWords(limit: Int) -> [String] {
        lock.lock()
        let cached = words
        let stale = FrecencyHotwordSupplier.isStale(refreshedAt, now: now())
        lock.unlock()

        if stale { refreshInBackground() }
        return Array(cached.prefix(limit))
    }

    // MARK: - 刷新

    private static func isStale(_ refreshedAt: Date?, now: Date) -> Bool {
        guard let refreshedAt else { return true }
        let age = now.timeIntervalSince(refreshedAt)
        // 负数 = 时钟被回拨。当成过期处理：多扫一次远好过永远不再刷新。
        return age < 0 || age >= refreshInterval
    }

    private func refreshInBackground() {
        lock.lock()
        // 已经有一次在扫了就不再叠一次：两次全表扫描同时跑没有任何好处。
        guard !isRefreshing else { lock.unlock(); return }
        isRefreshing = true
        lock.unlock()

        background { [weak self] in
            guard let self else { return }
            let scanned = self.scan()
            self.lock.lock()
            self.words = scanned
            self.refreshedAt = self.now()
            self.isRefreshing = false
            self.lock.unlock()
        }
    }

    // MARK: - 词表扫描（只在后台队列上被调用）

    /// 全表扫描 → 按 frecency 从高到低的用户词。
    static func scanUserDictionary() -> [String] {
        let database = VocabularyDatabase.shared
        let entries = database.getUserEntries()
        guard !entries.isEmpty else { return [] }
        return rank(entries: entries, learning: database.loadAllUserLearning())
    }

    /// 排序规则本身，与磁盘分开，好让它能被单测驱动。
    ///
    /// 用的是候选排序那一套 `FrecencyScore`，不另起一套：这里要的正是"用户最常用的词"，
    /// 而那已经是 frecency 的定义。基础频次取两种输入模式里高的那个 —— 用户词表两边都
    /// 可能有码，取低的会让只在一侧有码的词无谓地掉队。
    static func rank(entries: [DictionaryEntry],
                     learning: [UInt32: (accessCount: UInt32, lastAccessTimestamp: UInt32, totalScore: Double)],
                     limit: Int = cacheSize) -> [String] {
        entries
            .map { entry -> (text: String, score: Double) in
                let stats = learning[entry.id]
                return (entry.text,
                        FrecencyScore.calculate(accessCount: stats?.accessCount ?? 0,
                                                lastAccessTimestamp: stats?.lastAccessTimestamp ?? 0,
                                                baseFrequency: max(entry.wubiBaseFrequency,
                                                                   entry.pinyinBaseFrequency)))
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.text)
    }
}
