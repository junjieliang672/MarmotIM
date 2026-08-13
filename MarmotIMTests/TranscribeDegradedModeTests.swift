import XCTest
import AppKit
import AVFoundation
@testable import MarmotIM

/// 决策 20 的守门测试：ASR 服务不在时，打字/候选/排序/上屏必须**逐字节**不变。
///
/// ## 为什么不是「跑一遍没崩就算过」
///
/// 「输入路径不受影响」是个否定式命题。用「没有异常抛出」去证它，在转写还没接线的今天
/// 必然通过，在接线之后也几乎不会红 —— 那种测试的作用只是把问题从待办里划掉。
/// 所以这里记的是**观察**而不是**缺席**：把一次脚本化打字会话中每一次
/// `search` → `rank` → `applyRelativeOrdering` → `recordSelection` 的输出，
/// 完整抄成一份文本流水（`TypingTranscript`），对照组与降级组各跑一份，逐字节比对。
/// 流水会变，"没崩" 不会。
///
/// ## 确定性的边界（这条决定了流水里记什么）
///
/// `FrecencyScore.calculateRecencyScore` 读挂钟：两组之间隔一秒，`recordSelection`
/// 写下的时间戳就差一秒，分数随之差约 8000 分（λ=ln2/86400，初值 1e9）。
/// 所以流水分两段：
///
/// - **提交前**：引擎里没有任何用户学习数据 ⇒ recency / tierOverride / frequency 全为 0，
///   分数 = tierBonus + base + shortWordBonus，完全确定 ⇒ **连分数一起逐字节记**。
/// - **提交后**：分数含挂钟项，改记名次 + entryId + text + accessCount + jianma/boosted 标志。
///   这些才是用户看得见的东西，且是整数/顺序，跨组稳定。
///
/// 两组在**同一个进程**里跑，因此 Swift Dictionary 的逐进程随机哈希种子相同，
/// `rank` 内部 `textToMatch` 的遍历顺序、以及非稳定 `sort` 对同分项的处理，两组一致。
///
/// ## 这套比对能不能红 —— 见 `testTranscriptComparatorCatchesAViolation`
///
/// 兄弟目标立过两种反空过的先例：`settings-ui` 把修复回退掉看两条测试变红；
/// `asr-client` 在扫源码的测试里加一条 "剥完注释还剩代码" 的断言。
/// 这里用的是第一种的可自动化版本：同一套比对器喂两个**故意违规**的替身
/// （一个改状态、一个改排序），断言它必须报出差异。比对器自己因此不能空过。
///
/// ## 逐字节可比的前提：`DictionaryEngine(entries:)` 的用户学习是**每实例独立**的
///
/// 两组各自 `try DictionaryEngine(entries: Corpus.entries)`，而 `recordSelection` 写的是
/// 实例自己的 `userLearningCache`（落盘那一半走后台队列，且 `init(entries:)` 从不回读）。
/// 所以第二组开跑时 accessCount 是 0 而不是 1 —— 若哪天这个构造函数改成会预热用户学习，
/// 本文件的每一条比较都会因为两组起点不同而失去意义，而症状会是"降级组多了一次访问计数"，
/// 看上去像转写在污染输入路径。改到那里的人请先回来看这一段。
final class TranscribeDegradedModeTests: XCTestCase {

    // MARK: - item-0001：降级模式逐字节保证

    /// 对照组（进程里完全没有转写栈）vs 降级组（转写栈构造好、真探测过一个没人监听的端口）。
    /// 两份流水必须逐字节相同。
    func testTypingIsByteForByteIdenticalWithTheASRStackPresentButDead() async throws {
        let control = try runTypingSession()

        // 降级组：真的构造 ASRClient + ASRHealthMonitor，真的打一次 loopback 探测。
        // 端口选一个不太可能有人监听的高位端口 —— 我们要的正是 connection refused。
        // 用默认的 58471 会在开发机上真连上本地 LaunchAgent，那就不是「服务缺席」了。
        var dead = TranscribeConfig.default
        dead.enabled = true
        dead.port = 59993

        let client = ASRClient(config: ASRClientConfig(dead))
        let monitor = ASRHealthMonitor(config: dead, makeProbe: { _ in client }, log: { _ in })
        await monitor.refresh()

        // 先证明这一组不是个空壳：探测真的发生过，而且得出了「没人监听」的结论。
        XCTAssertTrue(monitor.snapshot.hasProbed, "降级组必须真的探测过，否则这一组等于对照组")
        XCTAssertEqual(monitor.state, .down,
                       "端口 \(dead.port) 上不该有人监听；若这里是 .ready，说明端口选错了，本测试失去意义")

        let degraded = try runTypingSession()

        assertTranscriptIsSubstantive(control)
        XCTAssertEqual(control, degraded,
                       "ASR 栈在场且已判定为 down 时，输入路径的输出必须逐字节不变（决策 20）")

        // 转写栈仍然活着（没被 ARC 收走）才让上面的比较有意义。
        XCTAssertEqual(monitor.state, .down)
        _ = client
    }

    /// 反空过证明：同一套比对器，喂两个故意违规的替身，必须报差异。
    ///
    /// 违规一 —— **状态污染**：转写路径「抢先上屏」，即在打字会话之外对引擎
    /// `recordSelection`。这是接线之后最可能出现的真实破坏形态。
    /// 违规二 —— **纯名次扰动**：相对顺序规则被换掉，候选文本、分数、accessCount
    /// 一个都不变，只有名次变。用来证明比对器不是只盯着计数器。
    ///
    /// 试过但**没能**造成差异、因而没有留用的第三种扰动，记在这里免得下一个人重走：
    /// 给 `rank` 传屏蔽词集合。屏蔽只清掉 tierOverride / recency / frequency 三项，
    /// 而本流水记分数的那一段恰好在任何 `recordSelection` 之前（那时这三项本就是 0），
    /// 记名次的那一段又不记分数 —— 于是屏蔽在这份流水里天然不可见。
    func testTranscriptComparatorCatchesAViolation() throws {
        let control = try runTypingSession()

        let stateViolation = try runTypingSession(beforeSession: { engine in
            // 假装转写在会话开始前把一段文本「上屏」了并记了一次选择。
            engine.recordSelection(entryId: Corpus.chengGong, baseFrequency: 30000)
        })
        XCTAssertNotEqual(control, stateViolation,
                          "比对器必须能看见转写路径对引擎状态的污染，否则它证明不了任何事")

        // 规则反向 ⇒ 变成 no-op ⇒ 对照组里被换到前面的 策试 留在原位。
        let orderingViolation = try runTypingSession(orderingRules: [(wordA: "测试", wordB: "策试")])
        XCTAssertNotEqual(control, orderingViolation,
                          "比对器必须能看见纯名次扰动（文本/分数/计数器全不变，只有顺序变）")
    }

    // MARK: - item-0002：打字期间零网络探测

    /// 打字不得触发任何 /health 探测。计数探针注入 `ASRHealthMonitor`，
    /// 跑完整场会话后必须仍是 0。
    ///
    /// 断言 0 本身可以因为「计数器根本不可能增加」而空过，所以最后显式踢一次
    /// `refreshForSettingsWindow()`，证明这个计数器确实会动。
    func testTypingIssuesZeroHealthProbes() async throws {
        let probe = CountingProbe()
        var config = TranscribeConfig.default
        config.enabled = true
        let monitor = ASRHealthMonitor(config: config, makeProbe: { _ in probe }, log: { _ in })

        // 只读缓存 —— 这是输入路径唯一被允许接触监视器的方式。
        _ = monitor.state
        _ = monitor.snapshot
        _ = monitor.isStale

        let transcript = try runTypingSession()
        assertTranscriptIsSubstantive(transcript)

        XCTAssertEqual(probe.count, 0, "打字期间不得发出任何 /health 探测")

        // 反空过：证明这个计数器会动。
        await monitor.refreshForSettingsWindow()
        XCTAssertEqual(probe.count, 1, "计数探针本身必须可增；否则上面的 0 是空过")
    }

    /// 启动路径不得对转写产生依赖：`AppDelegate` 里任何转写符号的**构造**，
    /// 都必须在 `transcribe.enabled` 判定之后，且一处都不能落在
    /// `applicationDidFinishLaunching` 的方法体里。
    ///
    /// 接线之前它是个引信（那时一个转写符号都没有）。现在注册路径真的存在了，它有了牙：
    ///
    /// - **构造 ≠ 声明。** `private var transcribe: TranscribeCoordinator?` 是个存储属性，
    ///   不会构造任何东西；把它算成"使用"会让这条测试因为一行类型标注就红，
    ///   于是唯一的修法变成把声明挪到判定后面 —— 那没有守住任何东西。所以只认
    ///   `符号(` 和 `符号.`：真正把对象造出来或去碰它静态成员的那两种写法。
    /// - **`applicationDidFinishLaunching` 的方法体单独再查一遍。** 顺序判据挡不住
    ///   "先写个 guard，再在启动方法里构造" —— 而决策 20 要的是启动路径上一行都不跑。
    /// - **必须走 `makeProduction`。** 裸的 `TranscribeCoordinator(` 会拿到安全缺省
    ///   （inert 上屏 + 静默 HUD）：一切照常启动、照常打日志、然后什么都不做，
    ///   而那个症状与"MarmotIM 不是当前输入源"无从区分，事后无从诊断。
    func testAppDelegateConstructsNothingTranscribeRelatedOutsideTheEnabledGuard() throws {
        let code = strippingComments(try String(contentsOf: appDelegateSourceURL, encoding: .utf8))

        // 先证明剥完注释还剩代码，否则下面整组断言就是空过。
        XCTAssertTrue(code.contains("func applicationDidFinishLaunching"),
                      "剥注释把代码也剥没了，或者文件挪了位置")

        guard let firstUse = firstConstructionSite(in: code) else {
            return XCTFail("AppDelegate 里一处转写符号的构造都找不到 —— 注册路径没了，"
                           + "或者扫描规则与代码写法脱节，这条测试已经抓不住任何东西")
        }
        guard let gate = code.range(of: "transcribe.enabled")?.lowerBound else {
            return XCTFail("AppDelegate 引用了转写类型却没有 transcribe.enabled 判定（决策 20：功能关闭时不构造任何东西）")
        }
        XCTAssertLessThan(gate, firstUse,
                          "transcribe.enabled 判定必须出现在第一处转写符号构造之前")

        let launchBody = try XCTUnwrap(methodBody(named: "applicationDidFinishLaunching", in: code),
                                       "取不到 applicationDidFinishLaunching 的方法体")

        // 提取本身也会空过，而且是无声的。`methodBody` 靠"第一行恰好等于四个空格加右括号"
        // 找方法尾；哪天有人在这个方法里加个嵌套类型、一段 `#if`、或者一个收在四格缩进的
        // 尾随闭包，扫描就会提前收尾，于是下面那条断言变成"在半个方法里没找到构造" ——
        // 永远绿，什么都不守，且没有任何症状。所以先钉住它确实扫到了方法的最后一句。
        // （这与本测试自己踩过的那个坑同类：判据与文件写法脱节时，要响，不要静静地放行。）
        XCTAssertTrue(launchBody.contains("activateTranscribeIfEnabled"),
                      "方法体里没有那句延后装配 —— 要么注册路径改了，要么方法体被截短了")
        XCTAssertTrue(launchBody.contains("Initialization complete"),
                      "取到的方法体没覆盖到 applicationDidFinishLaunching 的最后一句："
                      + "花括号扫描已与文件写法脱节，下面那条断言只看了半个方法")

        XCTAssertNil(firstConstructionSite(in: launchBody),
                     "启动方法体里不得构造任何转写对象：装配必须排到启动之后（决策 20）")

        XCTAssertFalse(code.contains("TranscribeCoordinator("),
                       "生产装配必须走 TranscribeCoordinator.makeProduction —— "
                       + "裸构造拿到的是 inert 上屏与静默 HUD，会安静地什么都不做")
    }

    /// 一次真正的构造/静态成员访问的位置。声明（`: Symbol?`、`-> Symbol`）不算。
    private func firstConstructionSite(in code: String) -> String.Index? {
        // 随接线增长：协调器、热键、录音、健康、HTTP、后处理、热词、上屏接缝、HUD。
        let symbols = ["TranscribeCoordinator", "TranscribeHotKey", "AudioRecorder",
                       "ASRHealthMonitor", "ASRClient", "TranscriptPostProcessor",
                       "HotwordContextBuilder", "FrecencyHotwordSupplier",
                       "IMETranscriptSink", "TranscribeHUD"]
        var sites: [String.Index] = []
        for symbol in symbols {
            var searchFrom = code.startIndex
            while let found = code.range(of: symbol, range: searchFrom..<code.endIndex) {
                searchFrom = found.upperBound
                guard found.upperBound < code.endIndex else { break }
                let next = code[found.upperBound]
                if next == "(" || next == "." { sites.append(found.lowerBound) }
            }
        }
        return sites.min()
    }

    /// 取一个方法的方法体。依赖本仓库一致的缩进风格：方法在类型里缩进 4 格，
    /// 因此它的收尾大括号是单独一行的 `    }`。
    private func methodBody(named name: String, in code: String) -> String? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)") }) else { return nil }
        guard let end = lines[start...].firstIndex(where: { $0 == "    }" }) else { return nil }
        return lines[start...end].joined(separator: "\n")
    }

    // MARK: - item-0027：把上面两条比对器对准**真实接线**

    // 上面那两条（item-0001 / item-0002）是在接线之前立的。它们各自都被证明过能红，
    // 但证明用的是替身：一个拿两份故意违规的流水，一个拿计数探针。接线做完之后它们
    // 对着的仍然是一段空缝 —— 没有人按过热键，上屏接缝从头到尾没被碰过一次。
    //
    // 下面三条把同样的判据对准真家伙：走完一整次长按（按下 → 采到音 → 松手 → 结局），
    // 协调器是生产件，客户端是真 `ASRClient`，健康监视器是真 `ASRHealthMonitor`。
    // 只有三处替身，且每一处都是测试进程里根本造不出来的东西：
    //
    // · 麦克风采集 —— 没有授权，也不该让一次单测真的开麦；
    // · NSEvent 监听 —— 长按要能在测试里被精确驱动；
    // · 上屏接缝 —— `IMKInputController` 需要真实 IMKServer，造不出来；而这几条用例
    //   问的恰恰是"它到底有没有被调到"，所以换成一个记录用的替身。
    //
    // 服务缺席有**两种到达顺序**，两条都要证，而且都必须是确定的（不能靠"探测大概还没回来"）：
    // 健康快照已经判定 `.down`（短路，一个字节都不发），和快照还没有结论（真发一次 HTTP，
    // 吃到 connection refused）。第三条是反空过：同一套装置，只把服务端换成会答话的那个，
    // 证明这条观察通道确实看得见插入 —— 否则前两条的"没插入"可能只是长按压根没跑起来。

    /// 服务缺席、且健康快照已经知道它缺席：短路，不发请求，不插字，打字流水逐字节不变。
    func testAHoldAgainstAKnownDownServerIssuesNoRequestAndLeavesTypingUntouched() async throws {
        let control = try runTypingSession()

        let rig = DegradedRig(config: DegradedRig.deadServerConfig)
        await rig.health.refresh()
        XCTAssertEqual(rig.health.state, .down,
                       "端口 \(DegradedRig.deadServerConfig.port) 上不该有人监听；"
                       + "若这里不是 .down，本条用例失去意义")

        rig.runOneHold()
        XCTAssertTrue(spin(until: { rig.coordinator.state == .idle }),
                      "会话必须收口 —— 停在 transcribing 说明结局漏斗没走到")

        XCTAssertEqual(rig.requests.calls, 0, "快照已是 down，这一次必须连请求都不发")
        XCTAssertEqual(rig.sink.inserted, [], "服务缺席时不得有任何文本被送到光标处")
        XCTAssertEqual(rig.hud.events.last, .message("转写服务未运行"),
                       "失败必须收在一句 HUD 提示上，不能留个挂着的 HUD")

        let degraded = try runTypingSession()
        assertTranscriptIsSubstantive(control)
        XCTAssertEqual(control, degraded,
                       "转写栈接好线、真跑过一整次长按之后，输入路径的输出仍必须逐字节不变（决策 20）")

        rig.coordinator.stop()
    }

    /// 服务缺席、健康快照还没有结论：不短路，真的经 `ASRClient` 连一次那个没人监听的端口。
    ///
    /// 探针刻意用一个**永不回话**的替身，好让 `.loading` 这个初值确定地留住 ——
    /// 用真探针的话，"探测回来把状态写成 .down" 与"用户松手"是两条并发的路，
    /// 哪条先到不确定，这条用例就会时而走短路、时而走真请求。判据不能靠赛跑决定。
    /// 缺席本身由 `ASRClient` 那一侧如实承担：端口是真的没人听，拒连是真的。
    func testAHoldWhileHealthIsStillUnknownReallyHitsTheDeadPortAndInsertsNothing() throws {
        let control = try runTypingSession()

        let probe = HangingProbe()
        let rig = DegradedRig(config: DegradedRig.deadServerConfig, probe: probe)
        XCTAssertEqual(rig.health.state, .loading, "初值必须是 .loading，否则不会走到真请求")

        rig.runOneHold()
        XCTAssertTrue(spin(until: { rig.coordinator.state == .idle }),
                      "会话必须收口")

        XCTAssertEqual(rig.requests.calls, 1, "快照没结论时不该短路：这一次必须真的发出去")
        XCTAssertEqual(rig.sink.inserted, [], "连接被拒绝之后不得有任何文本被送到光标处")
        XCTAssertEqual(rig.hud.events.last, .message("转写服务未运行"),
                       "这句提示要来自真实的 connection refused 分类")

        let degraded = try runTypingSession()
        assertTranscriptIsSubstantive(control)
        XCTAssertEqual(control, degraded,
                       "真发过一次注定失败的请求之后，输入路径的输出仍必须逐字节不变（决策 20）")

        rig.coordinator.stop()
        probe.release()
    }

    /// 反空过：**急切上屏的那一版**。装置一字不改，只把服务端换成会答话的替身 ——
    /// 也就是"服务其实缺席，协调器却照样把一段文本插到了光标处"这个破坏形态。
    ///
    /// 没有这一条，上面两条的 `inserted == []` 可以因为长按压根没跑起来而空过：
    /// 热键阈值没走完、采集没喂到音、上屏接缝被判定为非活跃 —— 任何一个都会让
    /// "什么都没插" 成为恒真。这一条证明同一条通道确实看得见插入。
    func testTheSameRigDoesSeeTextReachingTheCursorWhenTheCoordinatorInsertsEagerly() throws {
        let rig = DegradedRig(config: DegradedRig.deadServerConfig,
                              probe: HangingProbe(),
                              makeClient: { _ in AnsweringRequester(text: "念到光标处") })

        rig.runOneHold()
        XCTAssertTrue(spin(until: { !rig.sink.inserted.isEmpty || rig.coordinator.state == .idle }),
                      "会话必须收口")

        XCTAssertEqual(rig.sink.inserted, ["念到光标处"],
                       "同一套装置必须看得见上屏；看不见的话，上面两条的『没插入』是空过")
        XCTAssertEqual(rig.hud.events.last, .dismissed, "成功上屏之后 HUD 应当收掉")

        rig.coordinator.stop()
    }

    /// 生产注册路径（`makeProduction` + `configurationDidChange`）不得等服务端回话。
    ///
    /// 探针永不回话 —— 这正是"服务器在那儿但没反应"的最坏形态，比连接被拒绝更坏：
    /// 拒连会立刻返回，挂死不会。注册在这种服务器面前仍必须当场返回并完成，
    /// 随后整场打字会话一次探测都不许多发。
    ///
    /// 这条同时是 item-0002 对准真接线的那一半：上面那条计数探针用例里的监视器是
    /// 测试自己造的，这里的协调器是 `TranscribeCoordinator.makeProduction` 造的
    /// 生产装配件 —— 真热键、真录音机、真 HUD、真 `IMETranscriptSink`。
    func testProductionRegistrationNeverWaitsOnTheServerAndTypingStillProbesZeroTimes() throws {
        let control = try runTypingSession()

        let probe = HangingProbe()
        var enabled = TranscribeConfig.default
        enabled.enabled = true
        let monitor = ASRHealthMonitor(config: enabled, makeProbe: { _ in probe }, log: { _ in })
        let coordinator = TranscribeCoordinator.makeProduction(health: monitor, config: { enabled })

        let began = Date()
        coordinator.configurationDidChange()      // AppDelegate 注册时调的就是这一句
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertLessThan(elapsed, 1.0,
                          "注册不得等服务端回话：探针永不返回，注册却必须当场结束")
        XCTAssertTrue(coordinator.isRunning, "探测还挂在半空，注册也必须已经完成")
        XCTAssertTrue(spin(until: { probe.started == 1 }),
                      "注册应当在后台踢出一次探测（异步，不在返回路径上）")
        XCTAssertEqual(probe.finished, 0, "这次探测必须仍挂着 —— 它就是那台不回话的服务器")

        let typed = try runTypingSession()
        assertTranscriptIsSubstantive(control)
        XCTAssertEqual(control, typed,
                       "生产协调器已注册并在监听时，输入路径的输出必须逐字节不变（决策 20）")
        XCTAssertEqual(probe.started, 1, "打字期间不得再发出任何 /health 探测")

        coordinator.stop()
        probe.release()
    }

    /// 泵主 runloop，直到条件成立或超时。结果是经 `DispatchQueue.main.async` 回来的，
    /// 不泵就永远看不到。
    @discardableResult
    private func spin(timeout: TimeInterval = 3.0, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return predicate()
    }

    // MARK: - 打字会话录制器

    /// 一次脚本化打字会话的逐字节流水。
    ///
    /// - Parameters:
    ///   - orderingRules: 喂给 `applyRelativeOrdering` 的规则。只有反空过测试会改它。
    ///   - beforeSession: 会话开始前对引擎做的手脚。只有反空过测试会传。
    private func runTypingSession(orderingRules: [(wordA: String, wordB: String)] = [(wordA: "策试", wordB: "测试")],
                                  beforeSession: ((DictionaryEngine) -> Void)? = nil) throws -> String {
        let engine = try DictionaryEngine(entries: Corpus.entries)
        beforeSession?(engine)

        var lines: [String] = []

        // —— 提交前：引擎里没有用户学习数据，分数完全确定，逐字节记分数。——
        for code in ["c", "cg", "cgx", "ce", "ceshi"] {
            let matches = engine.search(code: code, limit: 10)
            let ranked = CandidateRanker.rank(matches: matches, inputCode: code, engine: engine)
            lines.append("search(\(code)) -> n=\(ranked.count)")
            for (i, c) in ranked.enumerated() {
                lines.append(String(format: "  rank[%d] id=%u text=%@ score=%.6f jianma=%@ boosted=%@",
                                    i, c.entryId, c.text, c.score,
                                    String(c.isJianma), String(c.isBoosted)))
            }
        }

        // 排序后处理（spec-003）：相对顺序规则也在输入路径上，一并录。
        let ceshiMatches = engine.search(code: "ceshi", limit: 10)
        let ceshiRanked = CandidateRanker.rank(matches: ceshiMatches, inputCode: "ceshi", engine: engine)
        let reordered = CandidateRanker.applyRelativeOrdering(candidates: ceshiRanked, rules: orderingRules)
        // 标签刻意不含规则内容：否则反空过测试会因为「标签行不同」而通过，
        // 而不是因为它真的看见了名次变化。
        lines.append("relativeOrdering -> n=\(reordered.count)")
        for (i, c) in reordered.enumerated() {
            lines.append(String(format: "  ord[%d] id=%u text=%@", i, c.entryId, c.text))
        }

        // —— 上屏：选中候选并记学习。——
        // 这一步之后分数含挂钟项，流水改记名次 + 计数器。
        let committed = try XCTUnwrap(ceshiRanked.first)
        engine.recordSelection(entryId: committed.entryId, baseFrequency: committed.baseFrequency)
        let learned = engine.getUserLearning(entryId: committed.entryId)
        lines.append("commit(id=\(committed.entryId) text=\(committed.text)) access=\(learned?.accessCount ?? 0)")

        // —— 提交后：只记用户看得见的东西（名次、文本、计数器、标志）。——
        for code in ["ceshi", "cgx", "kha"] {
            let matches = engine.search(code: code, limit: 10)
            let ranked = CandidateRanker.rank(matches: matches, inputCode: code, engine: engine)
            lines.append("research(\(code)) -> n=\(ranked.count)")
            for (i, c) in ranked.enumerated() {
                let access = engine.getUserLearning(entryId: c.entryId)?.accessCount ?? 0
                lines.append(String(format: "  rank[%d] id=%u text=%@ access=%u jianma=%@ boosted=%@",
                                    i, c.entryId, c.text, access,
                                    String(c.isJianma), String(c.isBoosted)))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// 流水本身不能是空的或只有几行 —— 否则「两份相同」说明不了任何事。
    private func assertTranscriptIsSubstantive(_ transcript: String,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        let lines = transcript.split(separator: "\n")
        XCTAssertGreaterThan(lines.count, 20,
                             "流水太短，录制器八成没真的跑起来", file: file, line: line)
        XCTAssertTrue(transcript.contains("成功") && transcript.contains("测试"),
                      "流水里应当出现真实候选文本", file: file, line: line)
        XCTAssertTrue(transcript.contains("commit(") && transcript.contains("score="),
                      "流水必须同时覆盖排序输出与上屏", file: file, line: line)
    }

    // MARK: - 语料与替身

    private enum Corpus {
        static let ci: UInt32 = 900_101
        static let chengGong: UInt32 = 900_102
        static let hu: UInt32 = 900_103
        static let zhongYing: UInt32 = 900_104
        static let ceShi: UInt32 = 900_105
        static let ceShi2: UInt32 = 900_106

        /// id 取 900_1xx，避开真实词库与其它测试的用户学习写入。
        static let entries: [DictionaryEntry] = [
            DictionaryEntry(id: ci, text: "词", pinyin: "ci", wubi: "cgx",
                            wubiBaseFrequency: 30000, pinyinBaseFrequency: 30000,
                            source: 1, length: 1),
            DictionaryEntry(id: chengGong, text: "成功", pinyin: "chenggong", wubi: "cgx",
                            wubiBaseFrequency: 30000, pinyinBaseFrequency: 30000,
                            source: 1, length: 2),
            DictionaryEntry(id: hu, text: "唬", pinyin: "hu", wubi: "kha",
                            wubiBaseFrequency: 30000, pinyinBaseFrequency: 30000,
                            source: 1, length: 1),
            DictionaryEntry(id: zhongYing, text: "中英", pinyin: "zhongying", wubi: "kha",
                            wubiBaseFrequency: 30000, pinyinBaseFrequency: 30000,
                            source: 1, length: 2),
            DictionaryEntry(id: ceShi, text: "测试", pinyin: "ceshi", wubi: nil,
                            wubiBaseFrequency: 50000, pinyinBaseFrequency: 50000,
                            source: 2, length: 2),
            DictionaryEntry(id: ceShi2, text: "策试", pinyin: "ceshi", wubi: nil,
                            wubiBaseFrequency: 20000, pinyinBaseFrequency: 20000,
                            source: 2, length: 2),
        ]
    }

    // MARK: - 真实接线的长按装置（item-0027）

    /// 一次"服务缺席"的完整长按装置。除采集 / NSEvent / 上屏三处替身外全是生产件。
    private final class DegradedRig {

        /// 端口选一个不太可能有人监听的高位端口 —— 要的正是 connection refused。
        /// 用缺省的 58471 会在开发机上真连上本地 LaunchAgent，那就不是「服务缺席」了。
        static var deadServerConfig: TranscribeConfig {
            var dead = TranscribeConfig.default
            dead.enabled = true
            dead.port = 59993
            return dead
        }

        let capture = FakeCapture()
        let sink = RecordingSink()
        let hud = EventHUD()
        let health: ASRHealthMonitor
        /// 真客户端外面套一层只数次数的壳：短路与真发请求这两条路要能被分开断言，
        /// 而真 `ASRClient` 自己不记账。壳只数数，请求原样转发。
        let requests: CountingRequester
        let hotKey: TranscribeHotKey
        let recorder: AudioRecorder
        let coordinator: TranscribeCoordinator

        /// - Parameters:
        ///   - probe: nil = 用生产缺省探针（真 `ASRClient` 打那个死端口）。
        ///   - makeClient: 缺省就是协调器自己的生产闭包 —— 真 `ASRClient`。
        init(config: TranscribeConfig,
             probe: ASRHealthProbing? = nil,
             makeClient: @escaping (TranscribeConfig) -> TranscribeRequesting
                 = { ASRClient(config: ASRClientConfig($0)) }) {
            if let probe {
                health = ASRHealthMonitor(config: config, makeProbe: { _ in probe }, log: { _ in })
            } else {
                health = ASRHealthMonitor(config: config, log: { _ in })
            }
            requests = CountingRequester(wrapping: makeClient(config))
            recorder = AudioRecorder(capture: capture, config: { config }, permission: { .granted })
            hotKey = TranscribeHotKey(monitor: FakeMonitor(), config: { config })
            let requests = self.requests
            coordinator = TranscribeCoordinator(hotKey: hotKey,
                                                recorder: recorder,
                                                health: health,
                                                makeClient: { _ in requests },
                                                config: { config },
                                                inserter: sink,
                                                hud: hud,
                                                log: { _ in })
        }

        /// 一次完整的长按：起监听 → 按下并走完阈值 → 喂一秒音频 → 松手。
        func runOneHold(seconds: Double = 1.0) {
            coordinator.start()
            hotKey.handle(keyCode: TranscribeHotKey.rightCommandKeyCode,
                          rawFlags: NSEvent.ModifierFlags.command.rawValue
                              | TranscribeHotKey.rightCommandDeviceMask)
            hotKey.handleHoldDeadline()
            // 按实测的 48 kHz 输入格式喂，100 ms 一块
            for _ in 0..<max(1, Int((seconds * 10).rounded())) {
                capture.emit(DegradedRig.makeBuffer(sampleRate: 48_000, frames: 4_800))
            }
            hotKey.handle(keyCode: TranscribeHotKey.rightCommandKeyCode, rawFlags: 0)
        }

        private static func makeBuffer(sampleRate: Double, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate,
                                       channels: 1,
                                       interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let data = buffer.floatChannelData![0]
            for frame in 0..<Int(frames) {
                data[frame] = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / sampleRate)) * 0.5
            }
            return buffer
        }
    }

    /// 数请求次数的转发壳。`transcribe` 在协作线程上被调用，所以加锁。
    private final class CountingRequester: TranscribeRequesting {
        private let inner: TranscribeRequesting
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

        init(wrapping inner: TranscribeRequesting) { self.inner = inner }

        /// 计数留在同步方法里：`NSLock.lock()` 直接写在 async 函数体内在 Swift 6 是错误。
        private func note() { lock.lock(); _calls += 1; lock.unlock() }

        func transcribe(_ request: TranscribeRequest) async throws -> TranscribeResponse {
            note()
            return try await inner.transcribe(request)
        }

        func reload(model: String) async throws -> HealthResponse {
            try await inner.reload(model: model)
        }

        func reconfigure(_ request: ReconfigureRequest) async throws -> ReconfigureResponse {
            note()
            return try await inner.reconfigure(request)
        }
    }

    /// 会答话的服务端替身。只有反空过那一条用它 —— 它扮演的是"服务缺席却照样上屏"。
    private final class AnsweringRequester: TranscribeRequesting {
        private let text: String
        init(text: String) { self.text = text }
        func transcribe(_ request: TranscribeRequest) async throws -> TranscribeResponse {
            TranscribeResponse(text: text, language: nil, duration: nil, elapsed: nil)
        }
        func reload(model: String) async throws -> HealthResponse {
            HealthResponse(status: "ok", model: model, modelLoaded: true, version: nil, detail: nil)
        }

        func reconfigure(_ request: ReconfigureRequest) async throws -> ReconfigureResponse {
            ReconfigureResponse(applied: [], restartRequired: false, status: "ok",
                                model: request.model, modelLoaded: true,
                                version: nil, detail: nil)
        }
    }

    /// 喂音频用的采集替身（测试进程里不开麦）。
    private final class FakeCapture: AudioInputCapturing {
        private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
        func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws { self.onBuffer = onBuffer }
        func stop() { onBuffer = nil }
        func emit(_ buffer: AVAudioPCMBuffer) { onBuffer?(buffer) }
    }

    /// 不装真 NSEvent 监听：长按由测试直接驱动。
    private final class FakeMonitor: TranscribeEventMonitoring {
        func install(handler: @escaping (UInt16, UInt) -> Void) {}
        func uninstall() {}
    }

    /// 记录上屏接缝收到了什么。永远是活跃输入源 —— 这几条用例要问的不是决策 3，
    /// 而是"服务缺席时有没有东西被插进去"，所以不能让 inert 判据把答案变成恒真。
    private final class RecordingSink: TranscriptInserting {
        var inserted: [String] = []
        var isActiveInputSource: Bool { true }
        func insertTranscript(_ text: String) -> Bool {
            inserted.append(text)
            return true
        }
    }

    private final class EventHUD: TranscribeHUDPresenting {
        enum Event: Equatable {
            case recording, transcribing, dismissed
            case message(String)
        }
        var events: [Event] = []
        func showRecording() { events.append(.recording) }
        func showTranscribing() { events.append(.transcribing) }
        func showMessage(_ text: String) { events.append(.message(text)) }
        func dismiss() { events.append(.dismissed) }
    }

    /// 永不回话的探针：服务器在那儿，但一个字节都不回。
    ///
    /// 比连接被拒绝更坏 —— 拒连立刻返回，挂死不会 —— 所以它才是"注册不许等服务端"
    /// 那条判据该用的服务器。上限 10 s 只是别让进程退不出去，不是策略。
    private final class HangingProbe: ASRHealthProbing {
        private let lock = NSLock()
        private var _started = 0
        private var _finished = 0
        private var _released = false

        var started: Int { lock.lock(); defer { lock.unlock() }; return _started }
        var finished: Int { lock.lock(); defer { lock.unlock() }; return _finished }
        private var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return _released }

        func release() { lock.lock(); _released = true; lock.unlock() }

        /// 加锁留在同步方法里：`NSLock.lock()` 直接写在 async 函数体内在 Swift 6 是错误。
        private func noteStart() { lock.lock(); _started += 1; lock.unlock() }
        private func noteFinish() { lock.lock(); _finished += 1; lock.unlock() }

        func probeHealth() async throws -> HealthResponse {
            noteStart()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !isReleased, !Task.isCancelled {
                // 取消之后 Task.sleep 会立刻返回，`try?` 又把错误吞掉 ——
                // 不在这里再判一次就会空转到 10 s 上限。
                try? await Task.sleep(nanoseconds: 20_000_000)
                if Task.isCancelled { break }
            }
            noteFinish()
            throw ASRClientError.notRunning
        }
    }

    /// 只数调用次数的探针。答什么不重要 —— 这个测试问的是「有没有人问」。
    private final class CountingProbe: ASRHealthProbing {
        private(set) var count = 0
        func probeHealth() async throws -> HealthResponse {
            count += 1
            throw ASRClientError.notRunning
        }
    }

    // MARK: - 源码扫描辅助

    private var appDelegateSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MarmotIMTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("MarmotIM/AppDelegate.swift")
    }

    private func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let text = String(line)
                if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return "" }
                guard let comment = text.range(of: "//") else { return text }
                return String(text[text.startIndex..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }
}
