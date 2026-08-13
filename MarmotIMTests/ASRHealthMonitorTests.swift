import XCTest
@testable import MarmotIM

/// ASRHealthMonitor：缓存的健康状态、三个刷新触发点、超时不降级、迁移才打日志。
///
/// 这里没有真实 socket —— 真实 socket 的覆盖在 ASRClientTests（StubASRServer）里。
/// 本文件要证的是**状态机**：超时/拒绝/取消这些分支用假探测才能毫秒级且确定性地复现。
final class ASRHealthMonitorTests: XCTestCase {

    // MARK: - 不变量 1：读路径不做 I/O

    /// 读缓存**永远**不发请求 —— 即使缓存已经过期。
    /// 谁要是哪天把 getter 改成惰性刷新，这条会红。
    func testReadingStateNeverPerformsIOEvenWhenStale() {
        let clock = TestClock()
        let probe = FakeProbe(.healthy(health("ready")))
        let monitor = makeMonitor(probe: probe, clock: clock)

        // 缓存从未探测过 ⇒ 一定是 stale 的；再把钟往前拨一小时，怎么读都还是 stale。
        clock.advance(3600)
        XCTAssertTrue(monitor.isStale)

        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            _ = monitor.state
            _ = monitor.snapshot
            _ = monitor.isStale
        }

        XCTAssertEqual(probe.callCount, 0, "读缓存不得触发任何探测")
    }

    /// 多线程读 + 同时刷新：读到的永远是一份自洽的快照，且不会崩。
    func testConcurrentReadsDuringRefreshAlwaysSeeAValidSnapshot() async {
        let probe = FakeProbe(.healthy(health("ready")))
        probe.delay = 0.05
        let monitor = makeMonitor(probe: probe)

        async let refreshed: Void = monitor.refresh()
        DispatchQueue.concurrentPerform(iterations: 2000) { _ in
            let snapshot = monitor.snapshot
            XCTAssertTrue(ASRHealthState.allCases.contains(snapshot.state))
        }
        await refreshed

        XCTAssertEqual(monitor.state, .ready)
    }

    // MARK: - 不变量 2：没有后台定时器

    /// 「不设定时器」是个否定式断言，唯一诚实的守法就是：源码里根本没有这些 API。
    /// 注释行被剔除后再比对（文件头恰好把这几个名字写进了不变量说明里）。
    func testMonitorSourceContainsNoTimerAPI() throws {
        let source = try String(contentsOf: monitorSourceURL, encoding: .utf8)
        let code = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return "" }
                guard let comment = text.range(of: "//") else { return text }
                return String(text[text.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")

        // 先证明剥注释之后还剩下代码，否则下面这组断言就是空过。
        XCTAssertTrue(code.contains("func refresh() async"), "注释剥离把代码也剥没了")

        for banned in ["Timer(", "DispatchSourceTimer", "asyncAfter", "scheduledTimer", "RunLoop"] {
            XCTAssertFalse(code.contains(banned),
                           "ASRHealthMonitor 不得出现 \(banned)：空闲的输入法必须零网络流量")
        }
    }

    // MARK: - 不变量 3：.down 只由「连接被拒绝」写入

    /// 首次探测出结果之前是 .loading，不是 .down。
    /// .down 在设置页上是「未安装」这个断言，还没问过就断言是错的。
    func testInitialStateIsLoadingNotDown() {
        let monitor = makeMonitor(probe: FakeProbe(.failure(ASRClientError.notRunning)))
        XCTAssertEqual(monitor.state, .loading)
        XCTAssertFalse(monitor.snapshot.hasProbed)
        XCTAssertTrue(monitor.isStale, "从未探测过的缓存永远算过期")
    }

    /// 连接被拒绝 ⇒ .down，无用户可见错误，且重复探测只打**一行**日志。
    func testConnectionRefusedIsSilentDownAndLogsOnlyTheTransition() async {
        let log = LogSpy()
        let monitor = makeMonitor(probe: FakeProbe(.failure(ASRClientError.notRunning)), log: log)

        await monitor.refresh()
        XCTAssertEqual(monitor.state, .down)
        XCTAssertEqual(log.lines.count, 1, "首次迁移打一行")

        for _ in 0..<10 { await monitor.refresh() }
        XCTAssertEqual(monitor.state, .down)
        XCTAssertEqual(log.lines.count, 1, "稳态在 .down 上，后续每次探测都不得再打日志")
        XCTAssertTrue(log.lines[0].contains("loading") && log.lines[0].contains("down"))
    }

    /// 超时**绝不**把状态降级成 .down：被拒绝是瞬间失败的，慢说明有人在监听。
    /// 场景就是实测到的那次 —— /reload 撞上在飞的转写，/health 花了 613 ms。
    func testTimedOutProbeRetainsPreviousStateAndNeverReportsDown() async {
        let probe = FakeProbe([
            .healthy(health("ready")),
            .failure(ASRClientError.timedOut(endpoint: .health))
        ])
        let clock = TestClock()
        let monitor = makeMonitor(probe: probe, clock: clock)

        await monitor.refresh()
        XCTAssertEqual(monitor.state, .ready)

        clock.advance(60)
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .ready, "服务只是忙，不是没装")
        XCTAssertNotEqual(monitor.state, .down)
    }

    /// 从没探测成功过又超时 ⇒ 停在 .loading（初始值），仍然不是 .down。
    func testTimedOutProbeWithNoPriorSuccessStaysLoading() async {
        let monitor = makeMonitor(probe: FakeProbe(.failure(ASRClientError.timedOut(endpoint: .health))))
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .loading)
    }

    /// 未知的传输错误同样不降级 —— 只有明确的「连接被拒绝」才算没装。
    func testUnknownTransportErrorDoesNotDowngradeToDown() async {
        let probe = FakeProbe([
            .healthy(health("ready")),
            .failure(ASRClientError.transport(code: -1005))
        ])
        let monitor = makeMonitor(probe: probe, clock: TestClock())
        await monitor.refresh()
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .ready)
    }

    /// 超时也要盖时间戳：否则每一次转写都得先赔一个完整的 1 s 超时，
    /// 而这套缓存的全部意义就是别让输入路径付这个钱。
    func testTimedOutProbeStampsFreshnessSoNextTranscribeDoesNotPayItAgain() async {
        let probe = FakeProbe(.failure(ASRClientError.timedOut(endpoint: .health)))
        let clock = TestClock()
        let monitor = makeMonitor(probe: probe, clock: clock)

        await monitor.refresh()
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertFalse(monitor.isStale)

        clock.advance(5)
        await monitor.refreshIfStale()
        XCTAssertEqual(probe.callCount, 1, "5 s 内不该再探")
    }

    /// 端口被别的服务占了 / 版本对不上：进程在，只是看不懂 ⇒ .error，不是 .down。
    func testMalformedOrUnexpectedHealthResponseIsErrorNotDown() async {
        let monitor = makeMonitor(probe: FakeProbe(.failure(ASRClientError.malformedResponse(endpoint: .health))))
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .error)
    }

    func testUnknownStatusStringMapsToErrorNotDown() {
        XCTAssertEqual(ASRHealthMonitor.state(for: health("wat")), .error)
    }

    /// status=ready 但 model_loaded=false 是自相矛盾的；按「权重还没进来」处理，
    /// 免得把一次必然失败的转写显示成就绪。
    func testReadyWithModelNotLoadedIsTreatedAsLoading() {
        XCTAssertEqual(ASRHealthMonitor.state(for: health("ready", loaded: false)), .loading)
        XCTAssertEqual(ASRHealthMonitor.state(for: health("ready", loaded: nil)), .ready)
        XCTAssertEqual(ASRHealthMonitor.state(for: health("loading", loaded: false)), .loading)
        XCTAssertEqual(ASRHealthMonitor.state(for: health("error", loaded: false, detail: "OOM")), .error)
    }

    /// 探测是共享的（并发触发会合流），所以某个调用方撤回自己的等待**不该**殃及别人 ——
    /// 它继续跑完并照常落盘。真正有权撤回探测的只有 configDidChange，那时目标本身变了。
    func testCancellingOneCallerDoesNotKillTheSharedProbe() async {
        let probe = FakeProbe(.healthy(health("ready")))
        probe.delay = 0.2
        let monitor = makeMonitor(probe: probe)

        let task = Task { await monitor.refresh() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value

        XCTAssertEqual(monitor.state, .ready)
        XCTAssertTrue(monitor.snapshot.hasProbed)
    }

    /// 调用方进来时就已经被取消了（用户松手撤回了这次转写）：不该再起一次探测。
    func testAlreadyCancelledCallerStartsNoProbe() async {
        let probe = FakeProbe(.healthy(health("ready")))
        let monitor = makeMonitor(probe: probe)

        let task = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)  // 被取消 ⇒ 立刻返回 nil
            await monitor.refresh()
        }
        task.cancel()
        await task.value

        XCTAssertEqual(probe.callCount, 0)
        XCTAssertEqual(monitor.state, .loading)
        XCTAssertFalse(monitor.snapshot.hasProbed, "撤回的探测不得盖时间戳")
    }

    // MARK: - 三个刷新触发点

    func testRefreshIfStaleSkipsTheProbeWhileCacheIsFresh() async {
        let probe = FakeProbe(.healthy(health("ready")))
        let clock = TestClock()
        let monitor = makeMonitor(probe: probe, clock: clock)

        await monitor.refreshForSettingsWindow()
        XCTAssertEqual(probe.callCount, 1)

        clock.advance(29.9)
        let state = await monitor.refreshIfStale()
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(probe.callCount, 1, "29.9 s 还没过期，不该发请求")
    }

    func testRefreshIfStaleProbesOnceCacheIsThirtySecondsOld() async {
        let probe = FakeProbe(.healthy(health("ready")))
        let clock = TestClock()
        let monitor = makeMonitor(probe: probe, clock: clock)

        await monitor.refresh()
        clock.advance(30)
        XCTAssertTrue(monitor.isStale)
        await monitor.refreshIfStale()
        XCTAssertEqual(probe.callCount, 2)
    }

    /// 挂钟被往回拨（NTP 校时）不能让缓存永远显得新鲜。
    func testBackwardClockJumpCountsAsStale() async {
        let probe = FakeProbe(.healthy(health("ready")))
        let clock = TestClock()
        let monitor = makeMonitor(probe: probe, clock: clock)

        await monitor.refresh()
        clock.advance(-120)
        XCTAssertTrue(monitor.isStale, "算出负数的年龄一律当过期")
    }

    /// 配置变更：换探测目标、旧结论作废（回到未探测的 .loading）、重新探一次。
    func testConfigChangeRebuildsProbeAndInvalidatesTheOldVerdict() async {
        let first = FakeProbe(.healthy(health("ready")))
        let second = FakeProbe(.failure(ASRClientError.notRunning))
        var built: [Int] = []
        let monitor = ASRHealthMonitor(
            config: .default,
            makeProbe: { config in
                built.append(config.port)
                return built.count == 1 ? first : second
            },
            now: { Date() },
            log: { _ in }
        )

        await monitor.refresh()
        XCTAssertEqual(monitor.state, .ready)

        var changed = TranscribeConfig.default
        changed.port = 59999
        await monitor.configDidChange(changed)

        XCTAssertEqual(built, [58471, 59999], "新配置必须重建探测目标")
        XCTAssertEqual(second.callCount, 1, "配置变更后立刻重探新地址")
        XCTAssertEqual(monitor.state, .down)
        XCTAssertEqual(first.callCount, 1, "旧目标不再被探测")
    }

    /// 配置变更会把在飞的探测取消掉 —— 它问的是旧地址，答案已经没有意义。
    func testConfigChangeCancelsTheInFlightProbeAgainstTheOldTarget() async {
        let stale = FakeProbe(.healthy(health("ready", model: "OLD-TARGET")))
        stale.delay = 5
        let fresh = FakeProbe(.healthy(health("loading")))
        var count = 0
        let monitor = ASRHealthMonitor(
            config: .default,
            makeProbe: { _ in
                count += 1
                return count == 1 ? stale : fresh
            },
            now: { Date() },
            log: { _ in }
        )

        let inFlight = Task { await monitor.refresh() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await monitor.configDidChange(.default)
        _ = await inFlight.value

        XCTAssertEqual(monitor.state, .loading)
        XCTAssertTrue(monitor.snapshot.hasProbed, "新目标的结论已经落定")
        XCTAssertNotEqual(monitor.snapshot.model, "OLD-TARGET", "旧目标的结论绝不能落进快照")
    }

    /// 并发触发合流：设置页打开的同时又要转写，只发一个请求。
    func testConcurrentRefreshesCoalesceIntoASingleProbe() async {
        let probe = FakeProbe(.healthy(health("ready")))
        probe.delay = 0.1
        let monitor = makeMonitor(probe: probe)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await monitor.refresh() }
            }
        }

        XCTAssertEqual(probe.callCount, 1, "8 个并发触发只该产生 1 次探测")
        XCTAssertEqual(monitor.state, .ready)
    }

    // MARK: - 不变量 4：只在迁移时打日志

    func testEveryStateTransitionIsLoggedExactlyOnce() async {
        let log = LogSpy()
        let probe = FakeProbe([
            .failure(ASRClientError.notRunning),   // loading → down
            .failure(ASRClientError.notRunning),   //（静默）
            .healthy(health("loading")),           // down → loading
            .healthy(health("ready")),             // loading → ready
            .healthy(health("ready")),             //（静默）
            .healthy(health("error", detail: "权重加载失败"))  // ready → error
        ])
        let monitor = makeMonitor(probe: probe, log: log)

        for _ in 0..<6 { await monitor.refresh() }

        XCTAssertEqual(monitor.state, .error)
        XCTAssertEqual(log.lines.count, 4, "6 次探测、4 次迁移 ⇒ 4 行")
        XCTAssertTrue(log.lines.last!.contains("权重加载失败"), "detail 要带进日志，否则没法排查")
    }

    /// 快照里带上模型名和 detail，设置页才有东西可显示。
    func testSnapshotCarriesModelAndDetail() async {
        let monitor = makeMonitor(probe: FakeProbe(.healthy(health("error", detail: "no such repo"))))
        await monitor.refresh()
        XCTAssertEqual(monitor.snapshot.detail, "no such repo")
        XCTAssertEqual(monitor.snapshot.model, "mlx-community/Qwen3-ASR-1.7B-bf16")
        XCTAssertTrue(monitor.snapshot.hasProbed)
    }

    /// down 是客户端侧的状态（连接被拒绝），不是服务端的 status 值。
    func testHealthStatesCoverServerStatusesPlusDown() {
        XCTAssertEqual(
            Set(ASRHealthState.allCases.map { $0.rawValue }),
            ["ready", "loading", "error", "down"]
        )
    }

    // MARK: - Helpers

    private var monitorSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MarmotIMTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MarmotIM/Services/ASRHealthMonitor.swift")
    }

    private func makeMonitor(probe: FakeProbe,
                             clock: TestClock? = nil,
                             log: LogSpy? = nil) -> ASRHealthMonitor {
        let now: () -> Date
        if let clock {
            now = { clock.now }
        } else {
            now = { Date() }
        }
        return ASRHealthMonitor(config: .default,
                                makeProbe: { _ in probe },
                                now: now,
                                log: { line in log?.append(line) })
    }

    private func health(_ status: String,
                        model: String? = "mlx-community/Qwen3-ASR-1.7B-bf16",
                        loaded: Bool? = true,
                        detail: String? = nil) -> HealthResponse {
        HealthResponse(status: status, model: model, modelLoaded: loaded, version: "1", detail: detail)
    }
}

// MARK: - 测试替身

/// 按顺序吐出预设结果的假探测；最后一个结果会被重复使用。
private final class FakeProbe: ASRHealthProbing {
    enum Outcome {
        case healthy(HealthResponse)
        case failure(Error)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var _callCount = 0
    /// 模拟慢应答（用于取消 / 合流测试）
    var delay: TimeInterval = 0

    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }
    convenience init(_ outcome: Outcome) { self.init([outcome]) }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func probeHealth() async throws -> HealthResponse {
        lock.lock()
        _callCount += 1
        let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        let delay = self.delay
        lock.unlock()

        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()

        switch outcome {
        case .healthy(let response): return response
        case .failure(let error): throw error
        }
    }
}

/// 可手动推进的挂钟，用来确定性地测 30 s 过期规则（真等 30 s 是不可接受的）。
private final class TestClock {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

private final class LogSpy {
    private let lock = NSLock()
    private var _lines: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _lines
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        _lines.append(line)
    }
}
