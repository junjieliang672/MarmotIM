//
//  ASRHealthMonitor.swift
//  MarmotIM
//
//  语音转写：ASR 服务健康状态缓存
//
//  本文件承担「永不影响打字」保证里最吃重的那一半（决策 20）。四条不变量，逐条都有测试：
//
//  1. **读路径不做 I/O。** `snapshot` / `state` / `isStale` 只是在 NSLock 下拷一份值类型出来。
//     不发请求，不惰性刷新，不等待任何 Task，任意线程都能同步读。
//  2. **没有后台定时器。** 本文件里没有 Timer、没有 DispatchSourceTimer、也没有自我续期的
//     asyncAfter；探测只有三个触发点：`refreshForSettingsWindow()` / `configDidChange(_:)` /
//     `refreshIfStale()`。空闲的输入法不产生任何网络流量。
//     `refresh()` 是这三者共用的实现，不是第四个触发点：它是 internal 的（测试直接驱动它），
//     产品代码请走上面三个入口。这条不变量守的是**没有任何东西去排程它**，
//     而不是「没人能调用它」——真正危险的是周期性调用，不是多一个调用点。
//  3. **`.down` 只由「连接被拒绝」写入。** 超时、传输错误、取消都不降级成 .down ——
//     被拒绝是立刻失败的，慢恰恰说明有人在监听（实测切换模型时 /health 会到 613 ms，
//     而那正是用户刚改完设置的一刻，误报「未安装」最伤）。
//  4. **日志只在状态迁移时打 —— 外加一条有意为之的例外。** 连接被拒绝是功能没开时的
//     正常稳态，每次探测都打就是刷屏，所以 `emitTransition` 在状态没变时闭嘴。
//     例外是「探测没得出结论」（超时/传输错误）：那一支照打，理由和取值范围写在
//     `retainStateAfterInconclusiveProbe` 上 —— 它受 30 s 过期阈值天然限流（至多每 30 s 一行），
//     而它恰恰是事后最难复盘的分支。
//

import Foundation

// MARK: - 探测来源

/// 健康探测来源。
///
/// 抽成协议有两个用处：本类型不必知道 `ASRClient` 怎么构造，测试也能注入假探测，
/// 从而在毫秒级覆盖超时/拒绝这些真实 socket 很难稳定复现的分支。
protocol ASRHealthProbing: AnyObject {
    func probeHealth() async throws -> HealthResponse
}

extension ASRClient: ASRHealthProbing {
    func probeHealth() async throws -> HealthResponse { try await health() }
}

// MARK: - 快照

/// 缓存的健康快照。
///
/// 值类型、整体替换，读到的永远是自洽的一份（不会出现 state 是新的而 model 还是旧的）。
struct ASRHealthSnapshot: Equatable {
    /// 初始值是 `.loading` 而不是 `.down`：首次探测出结果之前我们并不知道服务在不在，
    /// 而 `.down` 在设置页上显示为「未安装」—— 那是个断言，不是「正在确认」。
    var state: ASRHealthState = .loading
    /// 上一次探测得出结论的时刻；nil = 从未探测过。
    var probedAt: Date?
    /// 服务端当前加载的模型（来自 /health），仅 `.ready` / `.loading` 时有意义。
    var model: String?
    /// status != "ready" 时服务端给的人类可读说明。
    var detail: String?

    var hasProbed: Bool { probedAt != nil }
}

// MARK: - 监视器

/// ASR 服务健康监视器
///
/// 维护一份原子更新的 `ASRHealthState` 快照供输入路径只读消费；
/// 不设后台定时器 —— 空闲的输入法不应产生网络流量。
final class ASRHealthMonitor {

    /// 惰性刷新的过期阈值（契约 client-side rules）：缓存超过 30 s，才在下一次转写前重新探测。
    static let stalenessInterval: TimeInterval = 30

    private let lock = NSLock()
    private var _snapshot = ASRHealthSnapshot()
    /// 当前探测目标。配置变更时整个换掉（端口都变了，旧结论跟新目标无关）。
    private var probe: ASRHealthProbing
    /// 正在飞的探测。并发触发合流到同一个 Task，不会连打两次。
    private var inFlight: Task<Void, Never>?
    /// 探测代次。配置一变，上一代的结论就与新目标无关：它既不该写进快照，
    /// 也不该在收尾时把新一代的 inFlight 清掉。
    private var generation: UInt64 = 0

    private let makeProbe: (TranscribeConfig) -> ASRHealthProbing
    private let now: () -> Date
    private let log: (String) -> Void

    // MARK: - Initialization

    init(config: TranscribeConfig = .default,
         makeProbe: @escaping (TranscribeConfig) -> ASRHealthProbing = { ASRClient(config: ASRClientConfig($0)) },
         now: @escaping () -> Date = Date.init,
         log: @escaping (String) -> Void = { NSLog("MarmotIM: %@", $0) }) {
        self.makeProbe = makeProbe
        self.now = now
        self.log = log
        self.probe = makeProbe(config)
    }

    // MARK: - 读路径（不做 I/O，任意线程）

    /// 当前缓存快照。**不发起任何请求，不做惰性刷新。**
    ///
    /// 这是输入路径唯一被允许接触的东西：一次加锁、一次值拷贝、解锁。
    var snapshot: ASRHealthSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return _snapshot
    }

    /// 当前健康状态。同上，纯读缓存。
    var state: ASRHealthState { snapshot.state }

    /// 缓存是否已过期（默认 30 s）。也是纯读，判断本身不触发刷新。
    var isStale: Bool { isStale(maxAge: ASRHealthMonitor.stalenessInterval) }

    func isStale(maxAge: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let probedAt = _snapshot.probedAt else { return true }
        let age = now().timeIntervalSince(probedAt)
        // 用挂钟而非 systemUptime：合盖八小时后服务很可能已经没了，而 systemUptime 在睡眠期间
        // 不走，会把八小时前的结论当新鲜的。代价是 NTP 回拨会算出负数 —— 当成过期处理，
        // 多探一次远好过一直不探。
        return age < 0 || age >= maxAge
    }

    // MARK: - 三个刷新触发点（全部 async，全部在输入路径之外）

    /// 触发一：设置窗口打开。用户正看着指示灯，无条件探一次。
    func refreshForSettingsWindow() async {
        await refresh()
    }

    /// 触发二：配置变更（host / port / 模型变体）。
    ///
    /// 换目标就意味着旧结论作废：整份快照复位到「未探测」，而不是留着上一个端口的结论装新鲜。
    /// 在飞的探测一并取消 —— 它问的是旧地址。
    func configDidChange(_ config: TranscribeConfig) async {
        let previous = retarget(config)
        emitTransition(from: previous, to: .loading, note: "配置变更，缓存作废")
        await refresh()
    }

    /// 换目标 + 作废旧结论。同步方法：临界区里不能有 await（NSLock 跨挂起点在 Swift 6 是错误）。
    private func retarget(_ config: TranscribeConfig) -> ASRHealthState {
        lock.lock()
        defer { lock.unlock() }
        let previous = _snapshot.state
        probe = makeProbe(config)
        inFlight?.cancel()
        inFlight = nil
        // 代次前进：即使刚才那次探测赶在取消之前跑完了，它的结论也已经作废。
        generation &+= 1
        _snapshot = ASRHealthSnapshot()
        return previous
    }

    /// 触发三：转写前的惰性刷新。缓存新鲜就立刻返回，一个字节都不发。
    ///
    /// **调用时机（给 integration 的约束）：在按住热键的那一刻踢，而不是松手之后。**
    /// 缓存过期时这个方法要等一次真实的 /health，最坏是整整 1 s；用户按住说话至少要几秒，
    /// 把它放在按下时发起，答案在松手前就已经到了。反过来放在松手后，就等于在
    /// 「说完了等结果」这段最敏感的时间里白加 1 s。松手那一侧只读同步的 `state`。
    @discardableResult
    func refreshIfStale(maxAge: TimeInterval = ASRHealthMonitor.stalenessInterval) async -> ASRHealthState {
        if isStale(maxAge: maxAge) {
            await refresh()
        }
        return state
    }

    /// 真正发探测。并发调用会合流到同一个在飞 Task。
    ///
    /// 注意合流带来的语义：探测是**共享**的，因此某一个调用方取消自己的 Task 并不会掐掉它 ——
    /// 别人可能还在等这个答案。唯一有权撤回探测的是 `configDidChange`，因为那时目标本身变了。
    func refresh() async {
        // 调用方已经撤回了（比如用户松手取消了这次转写），就别再新起一次探测。
        guard !Task.isCancelled else { return }
        await probeTask().value
    }

    private func probeTask() -> Task<Void, Never> {
        lock.lock()
        if let existing = inFlight {
            lock.unlock()
            return existing
        }
        generation &+= 1
        let generation = self.generation
        let source = probe
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runProbe(source, generation: generation)
        }
        inFlight = task
        lock.unlock()
        return task
    }

    // MARK: - 探测结果 → 状态

    /// 一次探测的结论。先算出来，再在确认「这一代还作数」之后落盘。
    private enum ProbeOutcome {
        /// 得出了明确结论
        case verdict(ASRHealthState, model: String?, detail: String?)
        /// 有人监听但没按时应答 —— 什么都没证明，只证明了不是「没人监听」
        case inconclusive(reason: String)
        /// 探测被撤回
        case withdrawn
    }

    private func runProbe(_ source: ASRHealthProbing, generation: UInt64) async {
        let outcome = await ASRHealthMonitor.evaluate(source)

        // 旧一代的结论直接丢弃：它问的是旧地址，且此刻新一代可能已经在飞，
        // 收尾时也刻意不去动新一代的 inFlight。
        guard finishProbe(generation: generation) else { return }

        switch outcome {
        case .verdict(let state, let model, let detail):
            apply(state, model: model, detail: detail)
        case .inconclusive(let reason):
            retainStateAfterInconclusiveProbe(reason: reason)
        case .withdrawn:
            // 什么都没学到，连时间戳都不该动。
            break
        }
    }

    /// 探测收尾。同步方法，理由同 `retarget`。
    /// 返回这一代是否仍然作数；只有作数时才清 inFlight，免得把新一代的槽位清掉。
    private func finishProbe(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation else { return false }
        inFlight = nil
        return true
    }

    private static func evaluate(_ source: ASRHealthProbing) async -> ProbeOutcome {
        do {
            let response = try await source.probeHealth()
            return .verdict(state(for: response), model: response.model, detail: response.detail)
        } catch let error as ASRClientError {
            switch error {
            case .notRunning:
                // **唯一写入 .down 的路径**：连接被拒绝 = 没人在监听。
                // 这是功能没开时的正常稳态：不弹错，不重试，日志只在迁移时打一行。
                return .verdict(.down, model: nil, detail: nil)

            case .timedOut, .transport:
                // 有人监听，但没按时应答。最典型的是切换模型时旧模型 close() 释放约 3.5 GB
                // 并持有 GIL（实测单次 613 ms，而空闲 p99 只有 3.61 ms）——
                // 服务好好的，只是正忙。绝不降级成 .down。
                return .inconclusive(reason: error.inconclusiveReason)

            default:
                // 有 HTTP 应答，但内容我们看不懂：端口被别的服务占了，或版本不匹配。
                // 那也不是「没装」—— 进程在，只是不对劲。
                return .verdict(.error, model: nil, detail: "\(error)")
            }
        } catch is CancellationError {
            return .withdrawn
        } catch {
            return .verdict(.error, model: nil, detail: "\(error)")
        }
    }

    /// 契约的三个 status 字符串 → 客户端四态。
    static func state(for response: HealthResponse) -> ASRHealthState {
        switch response.status {
        case "ready":
            // 契约里 ready 蕴含 model_loaded == true。真出现矛盾时以「权重还没进来」为准：
            // 宁可多显示一会儿加载中，也不要把一次必然失败的转写显示成就绪。
            return response.modelLoaded == false ? .loading : .ready
        case "loading":
            return .loading
        case "error":
            return .error
        default:
            return .error
        }
    }

    // MARK: - 快照写入

    private func apply(_ state: ASRHealthState, model: String?, detail: String?) {
        lock.lock()
        let previous = _snapshot.state
        _snapshot.state = state
        _snapshot.model = model
        _snapshot.detail = detail
        _snapshot.probedAt = now()
        lock.unlock()
        emitTransition(from: previous, to: state, note: detail)
    }

    /// 探测没得出结论时：保留上一次的结论，但照常盖时间戳。
    ///
    /// 保留 = 什么都不写 state。从没探测成功过时它就还是初始的 `.loading`，
    /// 于是「超时且无历史 ⇒ .loading」这条规则是初始值的自然结果，不需要额外分支。
    ///
    /// 时间戳照盖，是因为不盖的话缓存永远是过期的，每一次转写都要先赔一个完整的 1 s 超时 ——
    /// 那正是这套缓存要避免的事。代价是服务真卡住时最多沿用 30 s 的旧结论，可以接受：
    /// 旧结论若是 `.ready`，转写会撞上可重试的 503 model_not_ready，那条路已经有处理。
    private func retainStateAfterInconclusiveProbe(reason: String) {
        lock.lock()
        _snapshot.probedAt = now()
        let retained = _snapshot.state
        lock.unlock()
        // 这里不是状态迁移，但仍然打一行：超时罕见（30 s 内至多一次），且是最难事后复盘的分支。
        log("ASR health: \(reason)，保留 \(retained.rawValue)")
    }

    private func emitTransition(from previous: ASRHealthState, to next: ASRHealthState, note: String?) {
        guard previous != next else { return }   // ← 连接被拒绝的稳态在这里被消音
        if let note, !note.isEmpty {
            log("ASR health: \(previous.rawValue) → \(next.rawValue)（\(note)）")
        } else {
            log("ASR health: \(previous.rawValue) → \(next.rawValue)")
        }
    }
}

private extension ASRClientError {
    /// 「没得出结论」的原因，只用于日志。
    var inconclusiveReason: String {
        switch self {
        case .timedOut(let endpoint): return "\(endpoint.path) 探测超时"
        case .transport(let code): return "传输错误 \(code)"
        default: return "\(self)"
        }
    }
}
