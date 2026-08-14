import XCTest
@testable import MarmotIM

/// Tests for the transcribe settings: config round-trip, validate() clamps,
/// and the 转写 tab. Owned thereafter by the `settings-ui` goal.
final class TranscribeSettingsTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultsMatchLockedDecisions() {
        let t = TranscribeConfig.default
        XCTAssertFalse(t.enabled, "transcribe is off by default (决策 20)")
        XCTAssertEqual(t.host, "127.0.0.1", "127.0.0.1 only, no LAN exposure (决策 14)")
        XCTAssertEqual(t.port, 58471)
        XCTAssertEqual(t.modelVariant, .qwen1_7B_bf16, "1.7B-bf16 is the default checkpoint (决策 6)")
        XCTAssertEqual(t.language, .auto, "auto-detect by default (决策 9)")
        XCTAssertNil(t.maxNewTokens, "nil means the server auto-computes max_tokens (决策 13)")
        XCTAssertEqual(t.maxRecordingSeconds, 120.0, "stuck-key guard (决策 14c)")
        XCTAssertEqual(t.holdThresholdMilliseconds, 250)
        XCTAssertTrue(t.stripTrailingPunctuation)
    }

    /// The raw values are the real HuggingFace repo ids, so settings / server /
    /// installer cannot drift. Only the two proven-loadable bf16 repos exist.
    func testModelVariantRawValuesAreRealRepoIds() {
        XCTAssertEqual(Set(TranscribeModelVariant.allCases.map { $0.rawValue }),
                       ["mlx-community/Qwen3-ASR-0.6B-bf16",
                        "mlx-community/Qwen3-ASR-1.7B-bf16"])
    }

    func testAutoLanguageSendsNoWireValue() {
        XCTAssertNil(TranscribeLanguage.auto.wireValue)
        XCTAssertEqual(TranscribeLanguage.chinese.wireValue, "zh")
        XCTAssertEqual(TranscribeLanguage.english.wireValue, "en")
    }

    // MARK: - Round-trip

    func testTranscribeConfigRoundTripsThroughJSON() throws {
        var config = AppConfig.default
        config.transcribe.enabled = true
        config.transcribe.port = 12345
        config.transcribe.modelVariant = .qwen0_6B_bf16
        config.transcribe.language = .chinese
        config.transcribe.hotwords = "土拨鼠 五笔"
        config.transcribe.maxNewTokens = 512
        config.transcribe.stripTrailingPunctuation = false

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded.transcribe, config.transcribe)
    }

    func testNilMaxNewTokensSurvivesRoundTrip() throws {
        var config = AppConfig.default
        config.transcribe.maxNewTokens = nil

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertNil(decoded.transcribe.maxNewTokens)
    }

    /// A config written by an older build has no `transcribe` key at all; the
    /// tolerant decoder must fall back to defaults rather than throwing.
    func testLegacyConfigWithoutTranscribeKeyDecodes() throws {
        let legacy = """
        {"candidateCount": 7, "showCodeHint": false}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)

        XCTAssertEqual(decoded.candidateCount, 7)
        XCTAssertFalse(decoded.showCodeHint)
        XCTAssertEqual(decoded.transcribe, TranscribeConfig.default)
    }

    /// 一份**有** `transcribe` 键、但缺了后加字段的旧配置，必须逐字段回退，
    /// 而不是整块丢掉。
    ///
    /// 这条盯的是一个会静默吃掉用户设置的坑：`TranscribeConfig` 原先用合成的
    /// `Codable`，而合成解码器对缺键是抛错的（属性默认值不参与解码）。上层
    /// `AppConfig.init(from:)` 又用 `(try? …) ?? d.transcribe` 把异常吞掉 ——
    /// 于是每加一个字段，旧用户改过的主机、端口、模型、热词会一起悄悄回到默认值，
    /// 而且没有任何地方会报错。`worksWhenInactive` 是第一个踩到它的字段。
    func testConfigFromAnOlderBuildKeepsItsTranscribeSettingsWhenAFieldIsAdded() throws {
        // 一份不含 worksWhenInactive 的 transcribe 块，其余项都被用户改过。
        let legacy = """
        {"transcribe": {"enabled": true, "host": "127.0.0.1", "port": 51234,
                        "modelVariant": "mlx-community/Qwen3-ASR-0.6B-bf16",
                        "language": "zh", "hotwords": "土拨鼠 五笔",
                        "requestTimeoutSeconds": 30.0, "maxRecordingSeconds": 200.0,
                        "holdThresholdMilliseconds": 400, "minAudioSeconds": 0.5,
                        "maxAudioSeconds": 250.0, "logLevel": "debug",
                        "stripTrailingPunctuation": false}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy).transcribe

        XCTAssertFalse(decoded.worksWhenInactive,
                       "缺失的新字段应当取默认值（关闭）")
        // 逐项核对，不是抽查：这条用例的全部意义就是"其余的一个都没丢"。
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.port, 51234, "用户改过的端口不得被重置")
        XCTAssertEqual(decoded.modelVariant, .qwen0_6B_bf16)
        XCTAssertEqual(decoded.language, .chinese)
        XCTAssertEqual(decoded.hotwords, "土拨鼠 五笔")
        XCTAssertEqual(decoded.requestTimeoutSeconds, 30.0)
        XCTAssertEqual(decoded.maxRecordingSeconds, 200.0)
        XCTAssertEqual(decoded.holdThresholdMilliseconds, 400)
        XCTAssertEqual(decoded.minAudioSeconds, 0.5)
        XCTAssertEqual(decoded.maxAudioSeconds, 250.0)
        XCTAssertEqual(decoded.logLevel, "debug")
        XCTAssertFalse(decoded.stripTrailingPunctuation)
    }

    /// 新开关默认必须是关的 —— 它把失效方向从"听写不工作"翻成"文字进了别人的输入框"。
    func testWorksWhenInactiveDefaultsToOff() {
        XCTAssertFalse(TranscribeConfig.default.worksWhenInactive)
        XCTAssertFalse(AppConfig.default.transcribe.worksWhenInactive)
    }

    // MARK: - validate()

    func testValidateClampsOutOfRangeValues() {
        var config = AppConfig.default
        config.transcribe.port = 80
        config.transcribe.maxNewTokens = 999_999
        config.transcribe.requestTimeoutSeconds = 0
        config.transcribe.maxRecordingSeconds = 100_000
        config.transcribe.holdThresholdMilliseconds = 0
        config.transcribe.host = "   "

        config.validate()

        XCTAssertEqual(config.transcribe.port, 1024)
        XCTAssertEqual(config.transcribe.maxNewTokens, 4096)
        XCTAssertEqual(config.transcribe.requestTimeoutSeconds, 1.0)
        XCTAssertEqual(config.transcribe.maxRecordingSeconds, 600.0)
        XCTAssertEqual(config.transcribe.holdThresholdMilliseconds, 50)
        XCTAssertEqual(config.transcribe.host, "127.0.0.1")
    }

    /// nil means "let the server decide" — validate() must not substitute a number.
    func testValidateLeavesNilMaxNewTokensAlone() {
        var config = AppConfig.default
        config.transcribe.maxNewTokens = nil
        config.validate()
        XCTAssertNil(config.transcribe.maxNewTokens)
    }

    func testValidateLeavesInRangeValuesUntouched() {
        var config = AppConfig.default
        config.transcribe.port = 58471
        config.transcribe.maxNewTokens = 256
        config.validate()
        XCTAssertEqual(config.transcribe.port, 58471)
        XCTAssertEqual(config.transcribe.maxNewTokens, 256)
        XCTAssertEqual(config.transcribe.maxRecordingSeconds, 120.0)
    }

    // MARK: - Tab registration

    func testTranscribeTabIsRegistered() {
        XCTAssertTrue(SettingsTab.allCases.contains(.transcribe))
        XCTAssertEqual(SettingsTab.transcribe.rawValue, "转写")
        XCTAssertEqual(SettingsTab.transcribe.icon, "mic")
    }

    /// The notification the transcribe subsystem listens on.
    func testTranscribeNotificationName() {
        XCTAssertEqual(Notification.Name.transcribeConfigDidChange.rawValue,
                       "MarmotIMTranscribeConfigDidChange")
    }

    // MARK: - 麦克风权限（设置页）

    /// Each state must be distinguishable to the user, and only the two states
    /// that need an affordance may offer one: 未决定 self-prompts, 已拒绝 can only
    /// be undone in System Settings, 已授权 offers nothing.
    func testMicrophonePermissionAffordances() {
        XCTAssertTrue(MicrophonePermission.notDetermined.canRequestInline)
        XCTAssertFalse(MicrophonePermission.notDetermined.requiresSystemSettings)

        XCTAssertFalse(MicrophonePermission.denied.canRequestInline)
        XCTAssertTrue(MicrophonePermission.denied.requiresSystemSettings)

        XCTAssertFalse(MicrophonePermission.granted.canRequestInline)
        XCTAssertFalse(MicrophonePermission.granted.requiresSystemSettings)

        let labels = [MicrophonePermission.notDetermined, .granted, .denied].map { $0.displayName }
        XCTAssertEqual(Set(labels).count, 3, "each permission state needs its own label")
        XCTAssertEqual(labels, ["尚未授权", "已授权", "已拒绝"])
    }

    func testModelReadsPermissionOnInitAndOnRefresh() {
        let stub = StubMicrophonePermission(status: .denied)
        let model = TranscribeSettingsModel(permission: stub)
        XCTAssertEqual(model.microphone, .denied)

        // The user flipped the switch in System Settings while the window was open.
        stub.status = .granted
        XCTAssertEqual(model.microphone, .denied, "state must not change without a refresh")
        model.refresh()
        XCTAssertEqual(model.microphone, .granted)
    }

    func testRequestingAccessRefreshesTheDisplayedState() {
        let stub = StubMicrophonePermission(status: .notDetermined)
        let model = TranscribeSettingsModel(permission: stub)

        let updated = expectation(description: "permission state refreshed")
        stub.onRequest = { stub.status = .granted }
        model.requestMicrophoneAccess()
        DispatchQueue.main.async { updated.fulfill() }
        waitForExpectations(timeout: 1)

        XCTAssertEqual(model.microphone, .granted)
        XCTAssertEqual(stub.requestCount, 1)
    }

    // MARK: - 保存与通知

    func testPersistPostsTranscribeConfigDidChange() {
        let model = TranscribeSettingsModel(permission: StubMicrophonePermission(status: .granted))
        let posted = expectation(forNotification: .transcribeConfigDidChange, object: nil)
        model.notifyTranscribeChanged()
        wait(for: [posted], timeout: 1)
    }

    // MARK: - 字段校验（拒绝，而不是钳制）

    /// 本页最要紧的一条：越界输入在字段上就被退回，用户敲的东西原样留着。
    /// `validate()` 的钳制是最后一道防线（手改配置文件、旧版本升级），不是界面的行为。
    func testOutOfRangeInputIsRejectedRatherThanClamped() {
        switch NumericFieldSpec.port.parse("70000") {
        case .success(let value):
            XCTFail("70000 必须被退回，而不是变成 \(value)")
        case .failure(let error):
            XCTAssertTrue(error.message.contains("65535"), "错误里要说清允许的上界：\(error.message)")
        }

        switch NumericFieldSpec.port.parse("80") {
        case .success(let value):
            XCTFail("特权端口必须被退回，而不是变成 \(value)")
        case .failure(let error):
            XCTAssertTrue(error.message.contains("1024"))
        }

        XCTAssertEqual(NumericFieldSpec.port.parse("58471"), .success(58471))
        XCTAssertEqual(NumericFieldSpec.port.parse("1024"), .success(1024), "下界本身合法")
        XCTAssertEqual(NumericFieldSpec.port.parse("65535"), .success(65535), "上界本身合法")
    }

    func testNonNumericAndEmptyInputAreRejectedWithTheirOwnMessages() {
        XCTAssertEqual(NumericFieldSpec.port.parse(""), .failure(FieldError("不能为空")))
        XCTAssertEqual(NumericFieldSpec.port.parse("   "), .failure(FieldError("不能为空")))
        XCTAssertEqual(NumericFieldSpec.port.parse("58471x"), .failure(FieldError("请输入数字")))
        XCTAssertEqual(NumericFieldSpec.port.parse("5847.5"), .failure(FieldError("必须是整数")))
        XCTAssertEqual(NumericFieldSpec.holdThreshold.parse("250.5"), .failure(FieldError("必须是整数")))
        // inf / nan 能被 Double 解析出来，但不是能填进配置的数
        XCTAssertEqual(NumericFieldSpec.maxRecording.parse("inf"), .failure(FieldError("请输入数字")))
        XCTAssertEqual(NumericFieldSpec.maxRecording.parse("nan"), .failure(FieldError("请输入数字")))
        // 秒是可以带小数的
        XCTAssertEqual(NumericFieldSpec.requestTimeout.parse("2.5"), .success(2.5))
    }

    /// 界面的区间必须与 `AppConfig.validate()` 的钳制区间一致，否则界面上写的
    /// 「请输入 5 – 600」和实际被接受的范围会悄悄分家。
    func testFieldBoundsMatchAppConfigClamps() {
        func clamped(_ mutate: (inout TranscribeConfig) -> Void) -> TranscribeConfig {
            var config = AppConfig.default
            mutate(&config.transcribe)
            config.validate()
            return config.transcribe
        }

        XCTAssertEqual(Double(clamped { $0.port = 0 }.port), NumericFieldSpec.port.lowerBound)
        XCTAssertEqual(Double(clamped { $0.port = 999_999 }.port), NumericFieldSpec.port.upperBound)

        XCTAssertEqual(clamped { $0.requestTimeoutSeconds = 0 }.requestTimeoutSeconds,
                       NumericFieldSpec.requestTimeout.lowerBound)
        XCTAssertEqual(clamped { $0.requestTimeoutSeconds = 9_999 }.requestTimeoutSeconds,
                       NumericFieldSpec.requestTimeout.upperBound)

        XCTAssertEqual(clamped { $0.maxRecordingSeconds = 0 }.maxRecordingSeconds,
                       NumericFieldSpec.maxRecording.lowerBound)
        XCTAssertEqual(clamped { $0.maxRecordingSeconds = 100_000 }.maxRecordingSeconds,
                       NumericFieldSpec.maxRecording.upperBound)

        XCTAssertEqual(Double(clamped { $0.holdThresholdMilliseconds = 0 }.holdThresholdMilliseconds),
                       NumericFieldSpec.holdThreshold.lowerBound)
        XCTAssertEqual(Double(clamped { $0.holdThresholdMilliseconds = 99_999 }.holdThresholdMilliseconds),
                       NumericFieldSpec.holdThreshold.upperBound)
    }

    /// 非回环地址在 `ASRClientConfig.resolvedHost` 里会被强行改成 127.0.0.1（决策 14）。
    /// 界面必须当场退回，而不是收下再背着用户换掉。
    func testHostFieldRejectsNonLoopbackAddresses() {
        for host in ["192.168.1.10", "example.com", "0.0.0.0"] {
            switch TranscribeHostRule.parse(host) {
            case .success(let accepted):
                XCTFail("\(host) 必须被退回，而不是接受成 \(accepted)")
            case .failure(let error):
                XCTAssertTrue(error.message.contains("127.0.0.1"))
            }
            XCTAssertEqual(ASRClientConfig(host: host, port: 58471).resolvedHost, "127.0.0.1",
                           "被退回的正是客户端本来就会改写掉的那些地址")
        }

        XCTAssertEqual(TranscribeHostRule.parse("127.0.0.1"), .success("127.0.0.1"))
        XCTAssertEqual(TranscribeHostRule.parse("localhost"), .success("localhost"))
        XCTAssertEqual(TranscribeHostRule.parse("::1"), .success("::1"))
        XCTAssertEqual(TranscribeHostRule.parse("  127.0.0.1 "), .success("127.0.0.1"), "去掉首尾空格")
        XCTAssertEqual(TranscribeHostRule.parse(""), .failure(FieldError("不能为空")))
    }

    // MARK: - 高级项的配置往返

    /// 高级区里的每一项都要能存下来。已有的往返用例只覆盖了基础项。
    func testAdvancedFieldsRoundTripThroughJSON() throws {
        var config = AppConfig.default
        config.transcribe.host = "localhost"
        config.transcribe.port = 60000
        config.transcribe.modelVariant = .qwen0_6B_bf16
        config.transcribe.requestTimeoutSeconds = 8.5
        config.transcribe.maxRecordingSeconds = 90
        config.transcribe.holdThresholdMilliseconds = 400
        config.transcribe.stripTrailingPunctuation = false

        var decoded = try JSONDecoder().decode(AppConfig.self,
                                               from: try JSONEncoder().encode(config))
        XCTAssertEqual(decoded.transcribe, config.transcribe)

        // 而且这一组值是合法的：validate() 不会再动它们（否则界面收下的值下次启动就变样了）。
        decoded.validate()
        XCTAssertEqual(decoded.transcribe, config.transcribe)
    }

    // MARK: - 服务健康指示灯

    /// 四态各自可分辨 —— 把「未安装」和「异常」混为一谈会让排障从第一步就跑偏。
    func testHealthStatesAreEachLabelled() {
        let labels = ASRHealthState.allCases.map { $0.settingsDisplayName }
        XCTAssertEqual(Set(labels).count, ASRHealthState.allCases.count)
        XCTAssertEqual(ASRHealthState.down.settingsDisplayName, "未安装")
        XCTAssertEqual(ASRHealthState.loading.settingsDisplayName, "启动中")
        XCTAssertEqual(ASRHealthState.ready.settingsDisplayName, "正常")
        XCTAssertEqual(ASRHealthState.error.settingsDisplayName, "异常")
    }

    /// 打开页面时还没有结论，就显示「尚未检查」——不能把监视器的初始 `.loading`
    /// 当成结论显示成「启动中」。
    func testHealthIsUnknownUntilAProbeConcludes() {
        let probe = StubHealthProbe(snapshot: ASRHealthSnapshot(state: .ready, probedAt: Date()))
        probe.defersCompletion = true
        let model = TranscribeSettingsModel(permission: StubMicrophonePermission(status: .granted),
                                            healthProbe: probe)

        XCTAssertNil(model.health)
        model.checkHealth(.default)
        XCTAssertNil(model.health, "探测在飞时仍然没有结论")
        XCTAssertTrue(model.isCheckingHealth)

        probe.finish()
        XCTAssertEqual(model.health?.state, .ready)
        XCTAssertFalse(model.isCheckingHealth)
    }

    func testHealthSurfacesTheServersDetailOnError() {
        let probe = StubHealthProbe(snapshot: ASRHealthSnapshot(
            state: .error,
            probedAt: Date(),
            detail: "failed to load weights: no such file"))
        let model = TranscribeSettingsModel(permission: StubMicrophonePermission(status: .granted),
                                            healthProbe: probe)

        model.checkHealth(.default)

        XCTAssertEqual(model.health?.state, .error)
        XCTAssertEqual(model.health?.detail, "failed to load weights: no such file",
                       "服务给的说明原样呈现，不改写不吞掉")
    }

    /// 一次探测在飞时再点「检查」不应该再排一次。
    func testConcurrentHealthChecksAreCoalesced() {
        let probe = StubHealthProbe(snapshot: ASRHealthSnapshot(state: .ready, probedAt: Date()))
        probe.defersCompletion = true
        let model = TranscribeSettingsModel(permission: StubMicrophonePermission(status: .granted),
                                            healthProbe: probe)

        model.checkHealth(.default)
        model.checkHealth(.default)
        XCTAssertEqual(probe.refreshCount, 1)

        probe.finish()
        model.checkHealth(.default)
        XCTAssertEqual(probe.refreshCount, 2, "上一次出结论之后可以再探")
    }

    /// 探测被取消时监视器的 `probedAt` 仍是 nil —— 那不是结论，不能显示。
    func testCancelledProbeLeavesTheIndicatorUnknown() {
        let probe = StubHealthProbe(snapshot: ASRHealthSnapshot(state: .loading))
        let model = TranscribeSettingsModel(permission: StubMicrophonePermission(status: .granted),
                                            healthProbe: probe)

        model.checkHealth(.default)

        XCTAssertNil(model.health)
        XCTAssertFalse(model.isCheckingHealth, "没出结论也要把按钮放开")
    }

    /// 改了主机 / 端口之后，旧结论说的已经不是同一个服务。
    func testInvalidateHealthClearsThePreviousConclusion() {
        let probe = StubHealthProbe(snapshot: ASRHealthSnapshot(state: .ready, probedAt: Date()))
        let model = TranscribeSettingsModel(permission: StubMicrophonePermission(status: .granted),
                                            healthProbe: probe)

        model.checkHealth(.default)
        XCTAssertEqual(model.health?.state, .ready)

        model.invalidateHealth()
        XCTAssertNil(model.health)
    }

    /// 指示灯探的必须是配置里的地址，而不是默认地址。
    func testHealthProbeUsesTheConfiguredTarget() {
        let probe = StubHealthProbe(snapshot: ASRHealthSnapshot(state: .down, probedAt: Date()))
        let model = TranscribeSettingsModel(permission: StubMicrophonePermission(status: .granted),
                                            healthProbe: probe)

        var config = TranscribeConfig.default
        config.port = 60123
        model.checkHealth(config)

        XCTAssertEqual(probe.lastConfig?.port, 60123)
        XCTAssertEqual(model.health?.state, .down)
    }

    // MARK: - MonitorHealthProbe 选哪个刷新入口

    /// 本页第一次刷新**不得**被当成「目标变了」。
    ///
    /// `probedTarget` 初值是 nil。若把 nil 判成变化，首次刷新就会走 `configDidChange` ——
    /// 而监视器是应用共用的（integration 接管后就是输入路径手里那一份），那一下会把别人
    /// 已经探出的 `.ready` 抹回未探测的 `.loading`、取消在飞的探测、并让代次前进。
    /// 于是「打开一次设置窗口」就足以让紧接着的转写读到 `.loading`。
    ///
    /// 监视器只在 init 和 `retarget()`（即 `configDidChange`）里重建探测源，
    /// 所以 `ProbeFactory.calls` 就是「缓存被整份作废了几次」。
    func testFirstRefreshDoesNotInvalidateASharedMonitorsCache() {
        let factory = ProbeFactory()
        let monitor = ASRHealthMonitor(config: .default, makeProbe: factory.make, log: { _ in })

        // 先让输入路径探一次：此刻缓存里已经有结论，正是共用监视器被注入时的样子。
        seed(monitor)
        XCTAssertEqual(factory.calls, 1, "只有 init 建过探测源")
        XCTAssertTrue(monitor.snapshot.hasProbed)

        // 设置窗口第一次打开：目标没变。
        let probe = MonitorHealthProbe(monitor: monitor)
        awaitRefresh(probe, config: .default)

        XCTAssertEqual(factory.calls, 1,
                       "首次刷新走的必须是 refreshForSettingsWindow，不是 configDidChange")
        XCTAssertTrue(monitor.snapshot.hasProbed, "输入路径的结论没有被抹掉")
    }

    /// 反面：host / port 真的变了才作废缓存；改语言不算 —— 探的还是同一个服务。
    func testOnlyAChangedTargetInvalidatesTheCache() {
        let factory = ProbeFactory()
        let monitor = ASRHealthMonitor(config: .default, makeProbe: factory.make, log: { _ in })
        let probe = MonitorHealthProbe(monitor: monitor)

        awaitRefresh(probe, config: .default)
        XCTAssertEqual(factory.calls, 1)

        var moved = TranscribeConfig.default
        moved.port = 60123
        awaitRefresh(probe, config: moved)
        XCTAssertEqual(factory.calls, 2, "换了端口，旧结论说的不是同一个服务")

        var relabelled = moved
        relabelled.language = .english
        relabelled.hotwords = "土拨鼠"
        awaitRefresh(probe, config: relabelled)
        XCTAssertEqual(factory.calls, 2, "改语言 / 热词不影响探谁，不该白白作废缓存")
    }

    // MARK: - Helpers

    /// 让监视器自己探一次，模拟输入路径已经在缓存里留下结论。
    private func seed(_ monitor: ASRHealthMonitor) {
        let done = expectation(description: "seeded")
        Task {
            await monitor.refreshForSettingsWindow()
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    private func awaitRefresh(_ probe: MonitorHealthProbe, config: TranscribeConfig) {
        let done = expectation(description: "refreshed")
        probe.refresh(for: config) { _ in done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    // MARK: - 中文标签

    /// The language picker renders `displayName`; every option must be labelled.
    func testLanguageDisplayNamesAreDistinctAndNonEmpty() {
        let names = TranscribeLanguage.allCases.map { $0.displayName }
        XCTAssertEqual(names, ["自动检测", "中文", "English"])
        XCTAssertEqual(Set(names).count, names.count)
    }
}

// MARK: - Test doubles

/// Injectable health source, so the tests never open a socket. `defersCompletion`
/// models a probe that is still in flight — the case the page has to render before
/// any answer arrives.
private final class StubHealthProbe: TranscribeHealthProbing {
    var snapshot: ASRHealthSnapshot
    var refreshCount = 0
    var lastConfig: TranscribeConfig?
    var defersCompletion = false
    private var pending: ((ASRHealthSnapshot) -> Void)?

    init(snapshot: ASRHealthSnapshot) {
        self.snapshot = snapshot
    }

    func refresh(for config: TranscribeConfig, completion: @escaping (ASRHealthSnapshot) -> Void) {
        refreshCount += 1
        lastConfig = config
        if defersCompletion {
            pending = completion
        } else {
            completion(snapshot)
        }
    }

    /// Deliver the deferred answer.
    func finish() {
        let completion = pending
        pending = nil
        completion?(snapshot)
    }
}

/// 一个永远回答 ready 的假 /health，让监视器能在毫秒级得出结论而不开 socket。
private final class StubASRProbe: ASRHealthProbing {
    func probeHealth() async throws -> HealthResponse {
        HealthResponse(status: "ready",
                       model: "Qwen3-ASR-0.6B",
                       modelLoaded: true,
                       version: nil,
                       detail: nil)
    }
}

/// 数 `ASRHealthMonitor` 重建了几次探测源。监视器只在 init 和 `retarget()` 里换源，
/// 所以这个计数就是「缓存被整份作废了几次」—— 也就是本页有没有踩到输入路径。
private final class ProbeFactory {
    private let lock = NSLock()
    private var _calls = 0

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    lazy var make: (TranscribeConfig) -> ASRHealthProbing = { [weak self] _ in
        self?.lock.lock()
        self?._calls += 1
        self?.lock.unlock()
        return StubASRProbe()
    }
}

/// Injectable microphone-permission source, so the tests never touch TCC.
private final class StubMicrophonePermission: MicrophonePermissionProviding {
    var status: MicrophonePermission
    var requestCount = 0
    /// Runs inside `requestAccess`, before the completion fires — lets a test
    /// simulate the user answering the system prompt.
    var onRequest: (() -> Void)?

    init(status: MicrophonePermission) {
        self.status = status
    }

    func currentStatus() -> MicrophonePermission { status }

    func requestAccess(_ completion: @escaping () -> Void) {
        requestCount += 1
        onRequest?()
        completion()
    }
}

// MARK: - 服务安装状态（ASRAgentStatus）

/// 「装没装 / 会不会开机自启」是从 plist 读出来的，不是猜的，也不起进程（决策 15）。
final class ASRAgentStatusTests: XCTestCase {

    private func writePlist(_ dict: [String: Any]) throws -> String {
        let path = NSTemporaryDirectory() + "marmot-agent-\(UUID().uuidString).plist"
        let data = try PropertyListSerialization.data(fromPropertyList: dict,
                                                     format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    func testAMissingPlistReadsAsNotInstalled() {
        let status = ASRAgentStatus.read(at: NSTemporaryDirectory() + "definitely-absent.plist")
        XCTAssertFalse(status.isInstalled)
        XCTAssertFalse(status.startsAtLogin)
    }

    func testAPlistWithRunAtLoadTrueReportsBothFacts() throws {
        let path = try writePlist(["Label": "com.marmotim.asr", "RunAtLoad": true])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let status = ASRAgentStatus.read(at: path)
        XCTAssertTrue(status.isInstalled)
        XCTAssertTrue(status.startsAtLogin)
    }

    func testAnInstalledAgentWithoutRunAtLoadIsInstalledButNotAutoStarting() throws {
        // 这两件事必须分开：装了却不自启，是需要用户动手的那一种「正常」。
        let path = try writePlist(["Label": "com.marmotim.asr"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let status = ASRAgentStatus.read(at: path)
        XCTAssertTrue(status.isInstalled)
        XCTAssertFalse(status.startsAtLogin)
    }

    func testGarbageIsTreatedAsNotInstalledRatherThanAnError() throws {
        let path = NSTemporaryDirectory() + "marmot-garbage-\(UUID().uuidString).plist"
        try "not a plist at all".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // 从用户角度，读不动的 plist 和没装是同一件事；报个解析错误只会让人更迷惑。
        XCTAssertEqual(ASRAgentStatus.read(at: path), .notInstalled)
    }

    // MARK: - 每一种处境给出的话与命令

    func testNotInstalledPointsAtTheInstallCommand() {
        let advice = ASRAgentStatus.notInstalled.advice(isRunning: false)
        XCTAssertEqual(advice.command, "bash scripts/build_and_install.sh --all")
    }

    func testInstalledButNotRunningPointsAtTheLogRatherThanReinstalling() {
        // KeepAlive 会一直重启它，所以「装了却没应答」多半是起不来 —— 先看日志。
        let advice = ASRAgentStatus(isInstalled: true, startsAtLogin: true)
            .advice(isRunning: false)
        XCTAssertEqual(advice.command, "tail -20 ~/Library/Logs/MarmotIM/asr-server.err.log")
    }

    func testRunningWithoutAutoStartOffersTheFix() {
        let advice = ASRAgentStatus(isInstalled: true, startsAtLogin: false)
            .advice(isRunning: true)
        XCTAssertEqual(advice.command, "bash scripts/install_asr.sh --reinstall")
    }

    func testEverythingHealthyOffersNoCommandAtAll() {
        // 一切正常时不该还挂着一条命令让人以为有事要做。
        let advice = ASRAgentStatus(isInstalled: true, startsAtLogin: true)
            .advice(isRunning: true)
        XCTAssertNil(advice.command)
    }
}
