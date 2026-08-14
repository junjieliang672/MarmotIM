import XCTest
import Cocoa
import AVFoundation
@testable import MarmotIM

/// Tests for TranscribeCoordinator (hotkey → record → transcribe → commit).
///
/// 两层分开测，与生产代码的分层一致：
/// · `TranscribeSessionMachine` 是纯类型，每一条转移（含每一条失败边）同步驱动；
/// · `TranscribeCoordinator` 用假采集端 / 假监听 / 假客户端 / 假健康 / 假 HUD / 假上屏
///   走完整条路，不碰麦克风也不碰网络。
///
/// 异步那一段刻意保留真实形态（`Task` + `DispatchQueue.main.async`）而不是同步注入：
/// "结果回到主线程之后才动状态机" 本身就是要被验证的性质，把它同步掉就等于不测它。
/// 代价是测试要泵主 runloop，`spin(until:)` 干这件事。
final class TranscribeCoordinatorTests: XCTestCase {

    // MARK: - 纯状态机

    func testMachineStartsIdleAndBeginStartsCapture() {
        var machine = TranscribeSessionMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.begin), .startCapture)
        XCTAssertEqual(machine.state, .recording)
    }

    func testMachineIdleIgnoresEverythingButBegin() {
        for signal: TranscribeSessionMachine.Signal in [.end(.released), .end(.aborted),
                                                        .captureFailed, .ceilingReached, .teardown] {
            var machine = TranscribeSessionMachine()
            XCTAssertEqual(machine.handle(signal), .none, "idle 不该对 \(signal) 有反应")
            XCTAssertEqual(machine.state, .idle)
        }
        var machine = TranscribeSessionMachine()
        // teardown / 取代之后才回来的答案：丢，不是无事发生 —— 调用方要知道该闭嘴。
        XCTAssertEqual(machine.handle(.settled(token: 7)), .dropLate(token: 7))
    }

    func testMachineReleaseFinishesCaptureUnderAToken() {
        var machine = TranscribeSessionMachine()
        _ = machine.handle(.begin)
        XCTAssertEqual(machine.handle(.end(.released)), .finishCapture(token: 1))
        XCTAssertEqual(machine.state, .transcribing(token: 1))
    }

    func testMachineAbortDiscardsAndNeverTranscribes() {
        var machine = TranscribeSessionMachine()
        _ = machine.handle(.begin)
        XCTAssertEqual(machine.handle(.end(.aborted)), .discardCapture)
        XCTAssertEqual(machine.state, .idle)
    }

    func testMachineCeilingTakesWhatWasCaptured() {
        var machine = TranscribeSessionMachine()
        _ = machine.handle(.begin)
        XCTAssertEqual(machine.handle(.ceilingReached), .takeCeilingCapture(token: 1))
        XCTAssertEqual(machine.state, .transcribing(token: 1))
        // 兜底交付之后用户才松手：不能再收一次
        XCTAssertEqual(machine.handle(.end(.released)), .none)
        XCTAssertEqual(machine.state, .transcribing(token: 1))
    }

    func testMachineCaptureFailureReturnsToIdleWithoutDiscardingAnything() {
        var machine = TranscribeSessionMachine()
        _ = machine.handle(.begin)
        XCTAssertEqual(machine.handle(.captureFailed), .none)
        XCTAssertEqual(machine.state, .idle)
    }

    func testMachineTeardownWhileRecordingDiscards() {
        var machine = TranscribeSessionMachine()
        _ = machine.handle(.begin)
        XCTAssertEqual(machine.handle(.teardown), .discardCapture)
        XCTAssertEqual(machine.state, .idle)
    }

    func testMachineSettleOnlyAcceptsTheCurrentGeneration() {
        var machine = TranscribeSessionMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.end(.released))          // → transcribing(1)
        XCTAssertEqual(machine.handle(.settled(token: 99)), .dropLate(token: 99))
        XCTAssertEqual(machine.state, .transcribing(token: 1), "迟到的答案不该动状态")
        XCTAssertEqual(machine.handle(.settled(token: 1)), .settle(token: 1))
        XCTAssertEqual(machine.state, .idle)
    }

    func testMachineSecondHoldSupersedesTheInFlightGeneration() {
        var machine = TranscribeSessionMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.end(.released))          // → transcribing(1)

        XCTAssertEqual(machine.handle(.begin), .supersedeAndStartCapture(abandoning: 1))
        XCTAssertEqual(machine.state, .recording)
        // 第一代此刻回来了：必须被丢掉，而不是插到第二段前面
        XCTAssertEqual(machine.handle(.settled(token: 1)), .dropLate(token: 1))
        XCTAssertEqual(machine.state, .recording, "迟到的第一代不该把正在录的这次踢回 idle")

        XCTAssertEqual(machine.handle(.end(.released)), .finishCapture(token: 2))
        XCTAssertEqual(machine.handle(.settled(token: 2)), .settle(token: 2))
        XCTAssertEqual(machine.state, .idle)
    }

    func testMachineTeardownWhileTranscribingAbandons() {
        var machine = TranscribeSessionMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.end(.released))
        XCTAssertEqual(machine.handle(.teardown), .abandon(token: 1))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.settled(token: 1)), .dropLate(token: 1))
    }

    func testMachineIgnoresStrayHoldSignalsWhileTranscribing() {
        for signal: TranscribeSessionMachine.Signal in [.end(.released), .end(.aborted),
                                                        .ceilingReached, .captureFailed] {
            var machine = TranscribeSessionMachine()
            _ = machine.handle(.begin)
            _ = machine.handle(.end(.released))
            XCTAssertEqual(machine.handle(signal), .none, "transcribing 不该对 \(signal) 有反应")
            XCTAssertEqual(machine.state, .transcribing(token: 1))
        }
    }

    func testMachineTokensStrictlyIncreaseAcrossSessions() {
        var machine = TranscribeSessionMachine()
        for expected in UInt64(1)...5 {
            _ = machine.handle(.begin)
            XCTAssertEqual(machine.handle(.end(.released)), .finishCapture(token: expected))
            _ = machine.handle(.settled(token: expected))
        }
    }

    // MARK: - 失败分类

    /// 契约的五个服务端错误码逐个走一遍。用 allCases 而不是手写列表：
    /// 契约加了第六个码，这条用例会跟着覆盖到，而不是悄悄漏掉。
    func testEveryServerErrorCodeIsClassified() {
        for code in TranscribeServerErrorCode.allCases {
            let result = TranscribeCoordinator.classify(code, detail: "d")
            switch code {
            case .audioTooShort:
                // 与本地 0.2 s 下限同源的误触：静默丢弃，不报错也不插字
                guard case .discarded = result else {
                    return XCTFail("audio_too_short 必须静默丢弃，实际 \(result)")
                }
            default:
                guard case .failure(let failure) = result else {
                    return XCTFail("\(code) 应当是失败，实际 \(result)")
                }
                XCTAssertFalse(failure.message.isEmpty, "\(code) 缺少 HUD 文案")
                XCTAssertTrue(failure.reason.contains("d"), "\(code) 的日志行丢了 detail")
            }
        }
    }

    func testEveryClientErrorIsClassifiedWithAMessageAndALogLine() {
        let errors: [ASRClientError] = [
            .notRunning,
            .timedOut(endpoint: .transcribe),
            .server(code: .inferenceFailed, detail: "boom"),
            .badModel(detail: "nope"),
            .unexpectedStatus(status: 418, code: "teapot", detail: "?"),
            .malformedResponse(endpoint: .transcribe),
            .transport(code: -1005)
        ]
        for error in errors {
            guard case .failure(let failure) = TranscribeCoordinator.classify(error) else {
                return XCTFail("\(error) 应当是失败")
            }
            XCTAssertFalse(failure.message.isEmpty, "\(error) 缺少 HUD 文案")
            XCTAssertFalse(failure.reason.isEmpty, "\(error) 缺少日志行")
        }
    }

    func testEveryRecorderErrorIsClassified() {
        let errors: [AudioRecorderError] = [
            .permissionDenied, .inputUnavailable, .engineFailed("x"), .converterUnavailable
        ]
        for error in errors {
            guard case .failure(let failure) = TranscribeCoordinator.classify(error) else {
                return XCTFail("\(error) 应当是失败")
            }
            XCTAssertFalse(failure.message.isEmpty, "\(error) 缺少 HUD 文案")
        }
    }

    func testCancellationIsSilentAndUnknownErrorsStillGetAMessage() {
        guard case .discarded = TranscribeCoordinator.classify(CancellationError()) else {
            return XCTFail("撤回不该报错")
        }
        struct Weird: Error {}
        guard case .failure(let failure) = TranscribeCoordinator.classify(Weird()) else {
            return XCTFail("未分类错误也必须有兜底文案")
        }
        XCTAssertFalse(failure.message.isEmpty)
    }

    // MARK: - PCM 编码

    func testEncodePCMIsLittleEndianFloat32() {
        let samples: [Float] = [0.0, 1.0, -1.0, 0.5]
        guard let data = Data(base64Encoded: TranscribeCoordinator.encodePCM(samples)) else {
            return XCTFail("编码结果不是合法 base64")
        }
        XCTAssertEqual(data.count, samples.count * 4)

        // 逐字节按小端重组，而不是 unsafeBitCast 整块 —— 后者在小端机上
        // 无论生产代码写没写 littleEndian 都会通过，等于什么都没验。
        let roundTrip: [Float] = data.withUnsafeBytes { raw in
            (0..<samples.count).map { index in
                var word: UInt32 = 0
                for byte in 0..<4 {
                    word |= UInt32(raw[index * 4 + byte]) << (8 * byte)
                }
                return Float(bitPattern: UInt32(littleEndian: word))
            }
        }
        XCTAssertEqual(roundTrip, samples)
    }

    // MARK: - 端到端（假硬件 / 假网络）

    func testHappyPathRecordsTranscribesAndInserts() {
        let harness = Harness()
        harness.client.text = "你好世界。"
        harness.start()

        harness.press()
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.hud.events, [.recording])
        XCTAssertEqual(harness.coordinator.state, .recording)

        harness.feedAudio(seconds: 0.5)
        harness.release()
        XCTAssertEqual(harness.hud.events, [.recording, .transcribing])

        XCTAssertTrue(spin { harness.sink.inserted.count == 1 }, "转写结果没有上屏")
        // polish 去掉了句末的一个句号（stripTrailingPunctuation 默认开）
        XCTAssertEqual(harness.sink.inserted, ["你好世界"])
        XCTAssertEqual(harness.hud.events, [.recording, .transcribing, .dismissed])
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.client.requestCount, 1)
    }

    func testHoldIsInertWhenMarmotIMIsNotTheActiveInputSource() {
        let harness = Harness()
        harness.sink.isActive = false
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertEqual(harness.capture.startCount, 0, "非当前输入源时不该点亮麦克风")
        XCTAssertEqual(harness.hud.events, [], "非当前输入源时不该有任何 UI")
        XCTAssertEqual(harness.client.requestCount, 0)
        XCTAssertEqual(harness.health.refreshCount, 0, "非当前输入源时连健康探测都不该踢")
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.sink.inserted, [])
    }

    func testAbortedHoldCancelsTheRecordingAndNeverTranscribes() {
        let harness = Harness()
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.abortWithOtherModifier()

        XCTAssertEqual(harness.client.requestCount, 0, "被打断的长按绝不能变成一次插字")
        XCTAssertEqual(harness.sink.inserted, [])
        XCTAssertEqual(harness.hud.events, [.recording, .dismissed])
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testTooShortRecordingIsDiscardedSilently() {
        let harness = Harness()
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.05)     // 低于 0.2 s 下限
        harness.release()

        XCTAssertEqual(harness.client.requestCount, 0)
        XCTAssertEqual(harness.sink.inserted, [])
        XCTAssertEqual(harness.hud.events, [.recording, .dismissed], "误触不该弹错误提示")
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testCeilingAutoStopStillTranscribesWhatWasCaptured() {
        let harness = Harness()
        harness.client.text = "卡键了"
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.recorder.handleCeiling()

        XCTAssertTrue(spin { harness.sink.inserted.count == 1 })
        XCTAssertEqual(harness.sink.inserted, ["卡键了"])

        // 兜底之后用户才松手：stop() 返回 nil，绝不能再走一遍
        harness.release()
        XCTAssertEqual(harness.client.requestCount, 1)
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testEmptyTranscriptIsDroppedWithoutInsertingOrErroring() {
        let harness = Harness()
        harness.client.text = "  \n  "        // 误触录到近乎无声时模型给的东西
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertTrue(spin { harness.coordinator.state == .idle })
        XCTAssertEqual(harness.sink.inserted, [], "空转写结果不能插字")
        XCTAssertEqual(harness.hud.events, [.recording, .transcribing, .dismissed],
                       "空结果是静默丢弃，不是报错")
    }

    func testServerFailureShowsABriefMessageAndClearsTheHUD() {
        let harness = Harness()
        harness.client.error = ASRClientError.server(code: .inferenceFailed, detail: "boom")
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertTrue(spin { harness.coordinator.state == .idle })
        XCTAssertEqual(harness.hud.events, [.recording, .transcribing, .message("转写失败")])
        XCTAssertEqual(harness.sink.inserted, [])
    }

    func testTimeoutLeavesNoStuckHUD() {
        let harness = Harness()
        harness.client.error = ASRClientError.timedOut(endpoint: .transcribe)
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertTrue(spin { harness.coordinator.state == .idle })
        XCTAssertEqual(harness.hud.events.last, .message("转写超时"))
    }

    func testDownHealthShortCircuitsWithoutIssuingARequest() {
        let harness = Harness()
        harness.health.state = .down
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertEqual(harness.client.requestCount, 0, "已知连接被拒绝时不该白跑一趟")
        XCTAssertEqual(harness.hud.events, [.recording, .message("转写服务未运行")])
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    /// `.loading` 同时是"从没探测过"的初始值 —— 把它当"没准备好"会让首次转写永远失败。
    func testLoadingHealthDoesNotShortCircuit() {
        let harness = Harness()
        harness.health.state = .loading
        harness.client.text = "首次"
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertTrue(spin { harness.sink.inserted.count == 1 })
        XCTAssertEqual(harness.client.requestCount, 1)
    }

    func testHealthRefreshIsKickedAtHoldStartNotAtRelease() {
        let harness = Harness()
        harness.start()

        harness.press()
        XCTAssertTrue(spin { harness.health.refreshCount == 1 },
                      "过期刷新必须在按下那一刻踢出去")

        harness.feedAudio(seconds: 0.5)
        harness.release()
        XCTAssertTrue(spin { harness.coordinator.state == .idle })
        XCTAssertEqual(harness.health.refreshCount, 1, "松手一侧只读同步快照，不该再探一次")
    }

    func testSecondHoldWhileTranscribingDiscardsTheFirstResult() {
        let harness = Harness()
        // 用 max_new_tokens 当代次标记：它原样进请求，比"第几次调用"可靠。
        harness.client.respond = { $0.maxNewTokens == 1 ? ("第一段", 0.4) : ("第二段", 0) }
        harness.start()

        harness.configBox.value.maxNewTokens = 1
        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()
        XCTAssertEqual(harness.coordinator.state, .transcribing(token: 1))

        // 第一段还在飞，用户已经开始说第二段
        harness.configBox.value.maxNewTokens = 2
        harness.press()
        XCTAssertEqual(harness.coordinator.state, .recording, "重叠长按必须能重新开始录音")
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertTrue(spin { harness.sink.inserted.count == 1 })
        XCTAssertEqual(harness.sink.inserted, ["第二段"])

        // 给被取代的那一代足够时间回来，确认它没有插进去
        _ = spin(timeout: 0.8) { harness.sink.inserted.count > 1 }
        XCTAssertEqual(harness.sink.inserted, ["第二段"], "被取代的那一代绝不能插到光标处")
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.hud.events.last, .dismissed)
    }

    /// 上一条走的是"旧结果回来时状态机已经回 idle"那条路。这一条专打代次守卫本身：
    /// 让第一代在**第二代还在飞**的时候回来，那时状态机是 transcribing(2)，
    /// 只有 token 比对能拦住它。（第一版没有这条用例，是一次变异测试发现的缺口。）
    func testLateResultArrivingWhileANewerRequestIsInFlightIsDropped() {
        let harness = Harness()
        harness.client.respond = { $0.maxNewTokens == 1 ? ("第一段", 0.45) : ("第二段", 0.60) }
        harness.start()

        harness.configBox.value.maxNewTokens = 1
        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()
        XCTAssertEqual(harness.coordinator.state, .transcribing(token: 1))

        harness.configBox.value.maxNewTokens = 2
        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()
        XCTAssertEqual(harness.coordinator.state, .transcribing(token: 2))

        XCTAssertTrue(spin { !harness.sink.inserted.isEmpty })
        XCTAssertEqual(harness.sink.inserted, ["第二段"],
                       "第二代在飞时回来的第一代结果必须被丢掉")
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testStopWhileTranscribingClearsTheHUDAndDropsTheLateResult() {
        let harness = Harness()
        harness.client.respond = { _ in ("来不及了", 0.3) }
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()
        XCTAssertEqual(harness.coordinator.state, .transcribing(token: 1))

        harness.coordinator.stop()
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.hud.events.last, .dismissed)

        _ = spin(timeout: 0.8) { !harness.sink.inserted.isEmpty }
        XCTAssertEqual(harness.sink.inserted, [], "停掉之后回来的结果不能插字")
    }

    func testStopWhileRecordingCancelsTheCapture() {
        let harness = Harness()
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.coordinator.stop()

        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.client.requestCount, 0)
        XCTAssertFalse(harness.capture.isRunning, "停掉协调器必须把引擎也拆掉")
        XCTAssertEqual(harness.hud.events.last, .dismissed)
    }

    func testMicrophoneFailureSurfacesAsAMessageAndLeavesNoRecording() {
        let harness = Harness(permission: .denied)
        harness.start()

        harness.press()

        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.hud.events, [.message("麦克风权限未开启")])
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.health.refreshCount, 0, "起不来的录音不该顺手去探健康")

        // 状态确实回到了 idle：下一次长按还能正常开始
        harness.release()
        XCTAssertEqual(harness.coordinator.state, .idle)
    }

    func testRefusedInsertionSurfacesRatherThanSilentlyLosingTheText() {
        let harness = Harness()
        harness.client.text = "焦点跑了"
        harness.sink.accept = false
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertTrue(spin { harness.coordinator.state == .idle })
        XCTAssertEqual(harness.hud.events.last, .message("无法上屏"))
    }

    // MARK: - 请求组装

    func testRequestCarriesLanguageContextAndTokenBudget() {
        let harness = Harness()
        harness.configBox.value.language = .chinese
        harness.configBox.value.hotwords = "土拨鼠，五笔"
        harness.configBox.value.maxNewTokens = 128
        harness.coordinator.hotwords = FixedHotwords(["频次词甲", "频次词乙"])
        harness.client.text = "好"
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertTrue(spin { harness.client.lastRequest != nil })
        let request = harness.client.lastRequest!
        XCTAssertEqual(request.sampleRate, 16_000)
        XCTAssertEqual(request.language, "zh")
        XCTAssertEqual(request.maxNewTokens, 128)
        // 手填热词在先（全角逗号也切得开），frecency 补在后
        XCTAssertEqual(request.context, "土拨鼠 五笔 频次词甲 频次词乙")

        let decoded = Data(base64Encoded: request.audioBase64)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.count % 4, 0)
        XCTAssertGreaterThan(decoded!.count, 0)
    }

    func testAutoLanguageOmitsTheLanguageField() {
        let harness = Harness()
        harness.configBox.value.language = .auto
        harness.client.text = "好"
        harness.start()

        harness.press()
        harness.feedAudio(seconds: 0.5)
        harness.release()

        XCTAssertTrue(spin { harness.client.lastRequest != nil })
        XCTAssertNil(harness.client.lastRequest?.language)
        XCTAssertNil(harness.client.lastRequest?.context, "没有热词时应当省略 context")
    }

    // MARK: - 活跃控制器登记处

    /// IMK 不保证前一个 client 的 `deactivateServer` 与后一个 client 的
    /// `activateServer` 谁先到。这条用例走的就是"顺序反了"那一版：
    /// B 已经激活之后，A 的注销才姗姗来迟。
    ///
    /// 无条件清空时它会红，而线上的症状是听写"偶尔没反应"—— 与"MarmotIM 不是
    /// 当前输入源所以无操作"的正常行为完全无法区分，所以只能靠这条用例守。
    func testDeactivatingAnAlreadySupersededControllerDoesNotClearTheCurrentOne() {
        let registry = ActiveInputControllerRegistry()
        let a = NSObject()
        let b = NSObject()

        registry.activated(a)
        XCTAssertTrue(registry.currentObject === a)

        registry.activated(b)                 // IMK 先把 B 激活了
        registry.deactivated(a)               // A 的注销才到

        XCTAssertTrue(registry.currentObject === b,
                      "迟到的 deactivate(A) 不能把已经生效的 B 抹掉")
    }

    func testDeactivatingTheCurrentControllerClearsIt() {
        let registry = ActiveInputControllerRegistry()
        let a = NSObject()
        registry.activated(a)
        registry.deactivated(a)
        XCTAssertNil(registry.currentObject)
        XCTAssertNil(registry.current)
    }

    /// weak 存储：客户端 app 退出、控制器被释放之后，登记处不能把它吊住。
    func testRegistryHoldsTheControllerWeakly() {
        let registry = ActiveInputControllerRegistry()
        autoreleasepool {
            let transient = NSObject()
            registry.activated(transient)
            XCTAssertNotNil(registry.currentObject)
        }
        XCTAssertNil(registry.currentObject, "登记处不该延长控制器的寿命")
    }

    // MARK: - 真实上屏接缝的两个判据

    /// 决策 3 的判据是**两个条件的与**：TIS 说当前输入源是 MarmotIM，且确实有活跃控制器。
    /// 四种组合逐个钉死 —— 只测 false 分支的话，`return false` 会是恒绿的假通过。
    func testActiveInputSourceRequiresBothTheInputSourceAndALiveController() {
        let target = FakeCommitTarget()
        let cases: [(tis: Bool, hasController: Bool, expected: Bool)] = [
            (true,  true,  true),
            (true,  false, false),
            (false, true,  false),
            (false, false, false),
        ]
        for c in cases {
            let sink = IMETranscriptSink(isCurrentInputSource: { c.tis },
                                         controller: { c.hasController ? target : nil })
            XCTAssertEqual(sink.isActiveInputSource, c.expected,
                           "tis=\(c.tis) controller=\(c.hasController)")
        }
    }

    func testInsertionGoesThroughTheControllerWhenBothConditionsHold() {
        let target = FakeCommitTarget()
        let sink = IMETranscriptSink(isCurrentInputSource: { true }, controller: { target })
        XCTAssertTrue(sink.insertTranscript("上屏"))
        XCTAssertEqual(target.inserted, ["上屏"])
    }

    /// 按下时查过一次，插入时再查一次：转写要花一秒上下，其间用户完全可能切走输入源。
    /// 拒绝而不是硬插 —— 协调器会把 false 翻成"无法上屏"，文本不会凭空进别人的输入框。
    func testInsertionIsRefusedIfTheInputSourceChangedDuringTranscription() {
        let target = FakeCommitTarget()
        var stillOurs = true
        let sink = IMETranscriptSink(isCurrentInputSource: { stillOurs }, controller: { target })

        XCTAssertTrue(sink.isActiveInputSource)      // 按下那一刻
        stillOurs = false                            // 转写期间用户切走了
        XCTAssertFalse(sink.insertTranscript("不该出现"))
        XCTAssertEqual(target.inserted, [], "不是当前输入源时一个字都不能插")
    }

    func testInsertionIsRefusedWhenTheControllerIsGone() {
        let sink = IMETranscriptSink(isCurrentInputSource: { true }, controller: { nil })
        XCTAssertFalse(sink.insertTranscript("没有落点"))
    }

    // MARK: - 「不是当前输入源时也能听写」

    /// 开关关着时（缺省），组合接缝必须与 `IMETranscriptSink` 逐字节同行为。
    ///
    /// 这条是整个功能的安全底线：默认配置下新代码一行都不该改变结论。退路的接缝
    /// 被造出来了，但既不参与判据也不接收文本。
    func testFallbackIsCompletelyInertWhileTheSwitchIsOff() {
        let primary = fakeSink(active: false)
        let fallback = fakeSink(active: true)   // 退路本身完全可用
        let sink = FallbackTranscriptSink(primary: primary, fallback: fallback,
                                          isFallbackEnabled: { false })

        XCTAssertFalse(sink.isActiveInputSource,
                       "开关关着时，退路可用与否都不该让长按有反应")
        XCTAssertFalse(sink.insertTranscript("不该出现"))
        XCTAssertEqual(fallback.inserted, [], "开关关着时退路一个字都不能收到")
    }

    /// 开关开着，但没有辅助功能授权 —— 仍然整条无操作。
    ///
    /// 「打开开关本身不会让任何事情变得能用」是设置页写给用户的原话，这里把它钉死。
    func testFallbackStaysInertWithoutAccessibilityEvenWhenTheSwitchIsOn() {
        let primary = fakeSink(active: false)
        let fallback = fakeSink(active: false)  // 未授权
        let sink = FallbackTranscriptSink(primary: primary, fallback: fallback,
                                          isFallbackEnabled: { true })

        XCTAssertFalse(sink.isActiveInputSource)
        XCTAssertFalse(sink.insertTranscript("不该出现"))
        XCTAssertEqual(fallback.inserted, [])
    }

    /// 开关开着且已授权，而 IME 那条路走不通 —— 这才是这个功能存在的理由。
    func testFallbackTakesOverWhenTheIMEPathIsUnavailable() {
        let primary = fakeSink(active: false)
        let fallback = fakeSink(active: true)
        let sink = FallbackTranscriptSink(primary: primary, fallback: fallback,
                                          isFallbackEnabled: { true })

        XCTAssertTrue(sink.isActiveInputSource, "退路可用就应当开始录音")
        XCTAssertTrue(sink.insertTranscript("退路上屏"))
        XCTAssertEqual(fallback.inserted, ["退路上屏"])
        XCTAssertEqual(primary.inserted, [], "主路走不通，不该假装插进去了")
    }

    /// 主路可用时永远走主路，与开关无关。
    ///
    /// 退路需要授权、插入位置无从核对、密码框下会被吞 —— 每一条都比主路弱，
    /// 所以主路能走时用退路是纯粹的退步。
    func testPrimaryWinsWheneverItIsAvailableRegardlessOfTheSwitch() {
        for switchOn in [true, false] {
            let primary = fakeSink(active: true)
            let fallback = fakeSink(active: true)
            let sink = FallbackTranscriptSink(primary: primary, fallback: fallback,
                                              isFallbackEnabled: { switchOn })

            XCTAssertTrue(sink.isActiveInputSource, "switchOn=\(switchOn)")
            XCTAssertTrue(sink.insertTranscript("主路上屏"), "switchOn=\(switchOn)")
            XCTAssertEqual(primary.inserted, ["主路上屏"], "switchOn=\(switchOn)")
            XCTAssertEqual(fallback.inserted, [],
                           "主路插成功之后退路不该再收到同一段文字（switchOn=\(switchOn)）—— "
                           + "那会让文字上两遍")
        }
    }

    /// 按下时可用、转写期间授权被撤销 —— 与 `IMETranscriptSink` 那条同源的双查。
    func testFallbackRefusesIfTheSwitchIsTurnedOffDuringTranscription() {
        let primary = fakeSink(active: false)
        let fallback = fakeSink(active: true)
        var switchOn = true
        let sink = FallbackTranscriptSink(primary: primary, fallback: fallback,
                                          isFallbackEnabled: { switchOn })

        XCTAssertTrue(sink.isActiveInputSource)   // 按下那一刻
        switchOn = false                          // 转写期间用户关掉了开关
        XCTAssertFalse(sink.insertTranscript("不该出现"))
        XCTAssertEqual(fallback.inserted, [])
    }

    /// 合成键盘事件的分片不得切开代理对。
    ///
    /// emoji 和部分罕用汉字在 UTF-16 里是一对两个 code unit，按 code unit 硬切会把
    /// 一个字劈成两个非法的半个字符 —— 目标 app 收到的是乱码而不是字。
    func testSynthesizedKeystrokeChunkingNeverSplitsSurrogatePairs() {
        let text = String(repeating: "🦫", count: 30) + String(repeating: "字", count: 30)
        let chunks = SynthesizedKeystrokeSink.chunks(of: text)

        XCTAssertEqual(chunks.joined(), text, "分片重新拼起来必须与原文逐字节相同")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.utf16.count, SynthesizedKeystrokeSink.chunkSize,
                                     "分片不得超过上限：\(chunk)")
            XCTAssertFalse(chunk.unicodeScalars.contains { $0.properties.isDefaultIgnorableCodePoint
                                                           && $0.value == 0xFFFD },
                           "出现了替换字符，说明有代理对被切开了：\(chunk)")
        }
    }

    /// 空串不发事件。`CGEvent` 那套对空载荷的行为没有保证，而空转写本来就该被上游丢掉。
    func testSynthesizedKeystrokeSinkRefusesEmptyText() {
        let sink = SynthesizedKeystrokeSink(trust: AlwaysTrusted())
        XCTAssertFalse(sink.insertTranscript(""))
    }

    /// 没有授权时连事件都不构造。
    func testSynthesizedKeystrokeSinkIsInertWithoutTrust() {
        let sink = SynthesizedKeystrokeSink(trust: NeverTrusted())
        XCTAssertFalse(sink.isActiveInputSource)
        XCTAssertFalse(sink.insertTranscript("不该出现"))
    }

    /// `FakeSink` 是 class，没有逐成员构造器 —— 造完再赋值这一步在每条用例里重复
    /// 一遍会把用例本身淹掉。
    ///
    /// **`accept` 必须跟着 `isActive` 一起设。** `FakeSink` 的两个旋钮是各自独立的，
    /// 但真实接缝里它们不独立：`IMETranscriptSink` 与 `SynthesizedKeystrokeSink`
    /// 的 `insertTranscript` 都会先把 `isActiveInputSource` 那套判据重查一遍，
    /// 不可用就返回 false。只设 `isActive` 会造出一个"不可用却照收不误"的接缝 ——
    /// 现实中不存在，却足以让这几条用例全部误判。
    private func fakeSink(active: Bool) -> FakeSink {
        let sink = FakeSink()
        sink.isActive = active
        sink.accept = active
        return sink
    }

    private struct AlwaysTrusted: AccessibilityTrusting {
        var isTrusted: Bool { true }
        func promptForTrust() {}
    }

    private struct NeverTrusted: AccessibilityTrusting {
        var isTrusted: Bool { false }
        func promptForTrust() {}
    }

    // MARK: - HUD 策略

    func testHUDRendersEachStateInTurnAndAlwaysClears() {
        let harness = HUDHarness()
        harness.hud.showRecording()
        XCTAssertEqual(harness.renderer.rendered, ["录音中"])

        harness.hud.showTranscribing()
        XCTAssertEqual(harness.renderer.rendered, ["录音中", "转写中…"])
        XCTAssertEqual(harness.renderer.clearCount, 0, "录音中 → 转写中 之间不该闪一下")

        harness.hud.dismiss()
        XCTAssertEqual(harness.renderer.clearCount, 1)
    }

    func testErrorMessageAutoDismissesOnItsOwn() {
        let harness = HUDHarness()
        harness.hud.showMessage("转写超时")
        XCTAssertEqual(harness.renderer.rendered, ["转写超时"])
        XCTAssertEqual(harness.timers.last?.delay, TranscribeHUD.messageDuration)

        harness.timers.fireAll()
        XCTAssertEqual(harness.renderer.clearCount, 1, "一句话提示必须自己消失")
    }

    /// 持续态也挂计时器，但用的是长得多的兜底时长 —— 它不是策略，只是"没有哪一代
    /// 能永远留在屏幕上"的最后一道保险。正常路径永远轮不到它（每次采集都由
    /// conclude 收口），所以这里只钉时长和"到点确实会关"。
    func testPersistentStatesCarryAWatchdogThatEventuallyCloses() {
        let harness = HUDHarness(watchdog: 42)
        harness.hud.showRecording()
        XCTAssertEqual(harness.timers.last?.delay, 42)
        XCTAssertNotEqual(harness.timers.last?.delay, TranscribeHUD.messageDuration,
                          "录音中不能用一句话提示的 1.5 s")

        harness.timers.fireAll()
        XCTAssertEqual(harness.renderer.clearCount, 1)
    }

    /// 最容易写错的一条：松手那一刻录音提示紧接着换成转写提示，此时录音那一代的
    /// 计时器还在途中。没有代次比对的话，它到点会把**刚显示的转写提示**关掉，
    /// 于是用户按住说完话，HUD 在等待期间凭空消失。
    func testAStaleTimerFromAnEarlierStateCannotCloseTheCurrentOne() {
        let harness = HUDHarness()
        harness.hud.showMessage("上一条")
        let stale = harness.timers.last!

        harness.hud.showRecording()          // 新的一代
        stale.fire()                         // 上一代的计时器现在才到点

        XCTAssertEqual(harness.renderer.clearCount, 0,
                       "上一代的自动消失不能把刚显示的这一代抹掉")
        XCTAssertEqual(harness.renderer.rendered.last, "录音中")
    }

    /// dismiss 之后在途的计时器到点：不能再关一次（那会把之后新显示的内容关掉）。
    func testTimersAreNeutralisedByAnExplicitDismiss() {
        let harness = HUDHarness()
        harness.hud.showRecording()
        let inFlight = harness.timers.last!

        harness.hud.dismiss()
        XCTAssertEqual(harness.renderer.clearCount, 1)

        harness.hud.showTranscribing()
        inFlight.fire()                      // 录音那一代的兜底现在才到点
        XCTAssertEqual(harness.renderer.clearCount, 1, "已经作废的计时器不能再关一次")
    }

    /// 协调器把结果送回主线程用的是 DispatchQueue.main.async，但 HUD 也可能被
    /// 别的路径（deinit、后台清理）从非主线程调到。这条用真实的投递函数验证落点。
    func testHUDMarshalsOntoTheMainThreadWhenCalledFromElsewhere() {
        let renderer = RecordingRenderer()
        let hud = TranscribeHUD(renderer: renderer,
                                caret: { nil },
                                watchdog: { 999 },
                                after: { _, _ in })   // 真实 onMain，计时器不接
        DispatchQueue.global().async { hud.showRecording() }

        XCTAssertTrue(spin { renderer.rendered.count == 1 })
        XCTAssertEqual(renderer.renderedOnMainThread, [true],
                       "HUD 必须在主线程上碰窗口")
    }

    // MARK: - 配置变更（开关 / 重建客户端 / 切服务端模型）

    func testTurningTheFeatureOffStopsTheCoordinatorAndDropsWhateverWasInProgress() {
        let harness = Harness()
        harness.start()
        harness.press()
        harness.feedAudio(seconds: 1.0)
        XCTAssertEqual(harness.coordinator.state, .recording)

        harness.configBox.value.enabled = false
        harness.coordinator.configurationDidChange()

        XCTAssertFalse(harness.coordinator.isRunning)
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.client.requestCount, 0, "关掉开关不能把正在录的那段发出去")
        XCTAssertEqual(harness.hud.events.last, .dismissed, "HUD 不能留在屏幕上")
    }

    func testTurningTheFeatureOnStartsTheCoordinatorWithoutARestart() {
        let harness = Harness()
        harness.configBox.value.enabled = false
        harness.coordinator.configurationDidChange()
        XCTAssertFalse(harness.coordinator.isRunning)

        harness.configBox.value.enabled = true
        harness.coordinator.configurationDidChange()
        XCTAssertTrue(harness.coordinator.isRunning, "打开开关必须当场生效，不必重启应用")
    }

    func testAConfigChangeThatDoesNotMoveTheTargetKeepsTheClientAndTheHealthCache() {
        let harness = Harness()
        harness.start()
        XCTAssertEqual(harness.clientBuilds.value, 1, "构造协调器本身算一次")

        harness.configBox.value.language = .chinese
        harness.configBox.value.hotwords = "土拨鼠"
        harness.coordinator.configurationDidChange()

        XCTAssertEqual(harness.clientBuilds.value, 1, "改语言 / 热词不影响请求发给谁")
        XCTAssertTrue(spin { harness.health.refreshCount >= 1 })
        XCTAssertEqual(harness.health.retargetCount, 0,
                       "白白作废健康缓存会让下一次转写先赔一次 /health")
    }

    func testChangingThePortRebuildsTheClientAndInvalidatesTheHealthCache() {
        let harness = Harness()
        harness.start()
        harness.configBox.value.port = 58472
        harness.coordinator.configurationDidChange()

        XCTAssertEqual(harness.clientBuilds.value, 2,
                       "换了目标就得换客户端：ASRClient 的 config 是 let，改不了")
        XCTAssertTrue(spin { harness.health.retargetCount == 1 })
        XCTAssertEqual(harness.health.refreshCount, 0,
                       "目标变了要走 configDidChange（作废旧结论），不是 refreshIfStale")
    }

    /// 变体选择器不接到 `/reload`，服务端会一直服务旧模型直到有人重启它。
    func testSelectingADifferentModelVariantAsksTheServerToReload() {
        let harness = Harness()
        harness.start()
        harness.health.reportedModel = TranscribeModelVariant.qwen1_7B_bf16.rawValue
        harness.configBox.value.modelVariant = .qwen0_6B_bf16
        harness.coordinator.configurationDidChange()

        XCTAssertTrue(spin { harness.client.reloadedModels
                                == [TranscribeModelVariant.qwen0_6B_bf16.rawValue] },
                      "选了别的变体，就必须让服务端真的换过去")
    }

    /// 改热词不该让服务端停顿 —— 但**判断谁变了已经移到服务端**。
    ///
    /// 客户端不再自己 diff：`/health` 根本不报 min/max_audio_seconds 和 log_level，
    /// 拿不到现值就无从比较，而服务端本来就要比一次。所以这里改成断言新的分工：
    /// 客户端把整份服务端子集发过去，一次，不重复发。
    /// "值没变就什么都不做"那一半由 server/tests/test_reconfigure.py 的
    /// test_posting_values_that_already_hold_changes_nothing 守着。
    func testChangingAClientOnlySettingStillSendsExactlyOneReconfigure() {
        let harness = Harness()
        harness.start()
        harness.health.reportedModel = TranscribeModelVariant.qwen1_7B_bf16.rawValue   // 与配置一致
        harness.configBox.value.hotwords = "五笔"
        harness.coordinator.configurationDidChange()

        XCTAssertTrue(spin { harness.health.refreshCount >= 1 })
        XCTAssertTrue(spin { harness.client.reconfigured.count == 1 },
                      "整份服务端子集只发一次，由服务端决定其中哪些真的变了")
        // 发出去的模型就是配置里选的那个，不是凭空捏的。
        XCTAssertEqual(harness.client.reconfigured.first?.model,
                       TranscribeModelVariant.qwen1_7B_bf16.rawValue)
    }

    /// 服务端没报告过模型（服务没起 / 从没探成功过）是"我们不知道"，不是"模型不对"。
    func testNoReloadWhenTheServerHasNeverReportedAModel() {
        let harness = Harness()
        harness.start()
        harness.health.reportedModel = nil
        harness.configBox.value.modelVariant = .qwen0_6B_bf16
        harness.coordinator.configurationDidChange()

        XCTAssertTrue(spin { harness.health.refreshCount >= 1 })
        XCTAssertEqual(harness.client.reloadedModels, [],
                       "盲发一次 reload 只会把刚起来的服务推进一次 0.6 s 的停顿")
    }

    func testDisablingTheFeatureNeverTouchesTheServer() {
        let harness = Harness()
        harness.start()
        harness.health.reportedModel = TranscribeModelVariant.qwen1_7B_bf16.rawValue
        harness.configBox.value.modelVariant = .qwen0_6B_bf16
        harness.configBox.value.enabled = false
        harness.coordinator.configurationDidChange()

        XCTAssertFalse(spin(timeout: 0.3) { !harness.client.reloadedModels.isEmpty },
                       "功能关着还去切模型，就是关掉的功能在产生网络流量")
        XCTAssertEqual(harness.health.refreshCount, 0)
        XCTAssertEqual(harness.health.retargetCount, 0)
    }

    // MARK: - 生产装配

    /// 两个缺省接缝都是"安静地什么都不做"，所以漏注入的注册会照常启动、照常打日志、
    /// 然后毫无症状 —— 与"MarmotIM 不是当前输入源"无从区分。这条用例守的就是这件事。
    func testProductionAssemblyInjectsTheRealSeamsRatherThanTheSafeDefaults() {
        let coordinator = TranscribeCoordinator.makeProduction(config: { .default })

        XCTAssertTrue(coordinator.hasLiveInsertionSeam, "生产装配必须注入真实上屏接缝")
        XCTAssertTrue(coordinator.hasVisibleHUD, "生产装配必须注入真实 HUD")
        XCTAssertFalse(coordinator.isRunning, "装配不等于启动：注册时机由 AppDelegate 决定")

        // 判据本身要有区分力，否则上面两条是恒真的。
        let bare = TranscribeCoordinator()
        XCTAssertFalse(bare.hasLiveInsertionSeam)
        XCTAssertFalse(bare.hasVisibleHUD)
    }

    func testHUDWatchdogFollowsTheRecordingCeilingRatherThanTheDefault() {
        var config = TranscribeConfig.default
        XCTAssertEqual(TranscribeCoordinator.watchdogSeconds(for: config), 135)

        config.maxRecordingSeconds = 600
        XCTAssertEqual(TranscribeCoordinator.watchdogSeconds(for: config), 615,
                       "上限调到 600 s 还用 135 s 的兜底，会在录到一半时把 HUD 抹掉，"
                       + "而录音仍在继续 —— 用户看到的是听写死了")
    }

    // MARK: - 真实热词来源

    func testHotwordRankingOrdersUserWordsByFrecency() {
        let entries = [
            userEntry(id: 1, text: "甲"),
            userEntry(id: 2, text: "乙"),
            // 频次只落在拼音那一列：只看 wubiBaseFrequency 的话，丙 会与 丁 打平，
            // 而 丁 的五笔频次更高，顺序就会反过来。
            userEntry(id: 3, text: "丙", pinyinBaseFrequency: 65_535),
            userEntry(id: 4, text: "丁", wubiBaseFrequency: 100)
        ]
        let now = UInt32(Date().timeIntervalSince1970)
        let learning: [UInt32: (accessCount: UInt32, lastAccessTimestamp: UInt32, totalScore: Double)] = [
            1: (accessCount: 100, lastAccessTimestamp: now, totalScore: 0),
            2: (accessCount: 100, lastAccessTimestamp: now - 30 * 86_400, totalScore: 0)
        ]

        XCTAssertEqual(FrecencyHotwordSupplier.rank(entries: entries, learning: learning, limit: 4),
                       ["甲", "乙", "丙", "丁"])
        XCTAssertEqual(FrecencyHotwordSupplier.rank(entries: entries, learning: learning, limit: 2),
                       ["甲", "乙"], "上限要真的截断")
    }

    /// 读路径发生在"用户松手在等结果"的那一刻。它可以返回旧表，但绝不能就地扫一次全表。
    func testHotwordReadPathServesTheCacheAndNeverScansInline() {
        var scans = 0
        let supplier = FrecencyHotwordSupplier(scan: { scans += 1; return ["土拨鼠", "五笔"] },
                                               background: { $0() })   // 同步跑，好断言先后

        XCTAssertEqual(supplier.topFrecencyWords(limit: 8), [],
                       "缓存还是空的：这一次只能给空表，不能等扫描")
        XCTAssertEqual(scans, 1, "但它必须把扫描踢出去，好让下一次有东西可用")
        XCTAssertEqual(supplier.topFrecencyWords(limit: 8), ["土拨鼠", "五笔"])
        XCTAssertEqual(scans, 1, "缓存没过期就不该再扫一遍全表")
    }

    func testPrimingFillsTheCacheBeforeTheFirstDictation() {
        let supplier = FrecencyHotwordSupplier(scan: { ["土拨鼠"] }, background: { $0() })
        supplier.prime()

        XCTAssertEqual(supplier.topFrecencyWords(limit: 8), ["土拨鼠"],
                       "第一次听写恰恰是用户在试这个功能灵不灵的那一次")
    }

    func testHotwordCacheRefreshesOnceItExpiresAndServesTheOldListMeanwhile() {
        var clock = Date()
        var words = ["旧词"]
        let supplier = FrecencyHotwordSupplier(scan: { words },
                                               now: { clock },
                                               background: { $0() })
        supplier.prime()
        XCTAssertEqual(supplier.topFrecencyWords(limit: 8), ["旧词"])

        words = ["新词"]
        XCTAssertEqual(supplier.topFrecencyWords(limit: 8), ["旧词"], "没过期就不重扫")

        clock = clock.addingTimeInterval(FrecencyHotwordSupplier.refreshInterval + 1)
        XCTAssertEqual(supplier.topFrecencyWords(limit: 8), ["旧词"],
                       "过期的那一次仍然先把旧表交出去")
        XCTAssertEqual(supplier.topFrecencyWords(limit: 8), ["新词"], "下一次才用上新表")
    }

    private func userEntry(id: UInt32,
                           text: String,
                           wubiBaseFrequency: UInt16 = 0,
                           pinyinBaseFrequency: UInt16 = 0) -> DictionaryEntry {
        DictionaryEntry(id: id, text: text, pinyin: "", wubi: nil,
                        wubiBaseFrequency: wubiBaseFrequency,
                        pinyinBaseFrequency: pinyinBaseFrequency,
                        source: EntrySource.user.rawValue, length: text.count)
    }

    // MARK: - 骨架保留

    func testTranscribeCoordinatorTypeExists() {
        XCTAssertNotNil(TranscribeCoordinator())
    }

    // MARK: - Helpers

    /// 泵主 runloop，直到条件成立或超时。协调器把结果送回主线程用的是
    /// `DispatchQueue.main.async`，不泵就永远看不到它。
    @discardableResult
    private func spin(timeout: TimeInterval = 3.0, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return predicate()
    }

    // MARK: - Fakes

    private final class ConfigBox {
        var value = TranscribeConfig.default
    }

    private final class Counter {
        var value = 0
    }

    private final class FixedHotwords: HotwordSupplying {
        private let words: [String]
        init(_ words: [String]) { self.words = words }
        func topFrecencyWords(limit: Int) -> [String] { Array(words.prefix(limit)) }
    }

    private final class FakeCapture: AudioInputCapturing {
        var startCount = 0
        var isRunning = false
        private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

        func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
            startCount += 1
            isRunning = true
            self.onBuffer = onBuffer
        }

        func stop() {
            isRunning = false
            onBuffer = nil
        }

        func emit(_ buffer: AVAudioPCMBuffer) { onBuffer?(buffer) }
    }

    private final class FakeMonitor: TranscribeEventMonitoring {
        func install(handler: @escaping (UInt16, UInt) -> Void) {}
        func uninstall() {}
    }

    /// 假客户端。`transcribe` 在协作线程上被调用，所以计数与请求都加锁。
    private final class FakeClient: TranscribeRequesting {
        var text = "好"
        var error: Error?

        /// 按**请求内容**决定回什么。多段重叠时必须用这个而不是"第几次调用"：
        /// 两个 Task 谁先跑起来不保证，改 `text` 再按第二次会撞上竞态。
        /// 请求是在松手那一刻同步组装好的，所以请求里的字段是可靠的标记。
        var respond: ((TranscribeRequest) -> (text: String, delay: TimeInterval))?

        private let lock = NSLock()
        private var _requests: [TranscribeRequest] = []

        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requests.count }
        var lastRequest: TranscribeRequest? { lock.lock(); defer { lock.unlock() }; return _requests.last }

        func transcribe(_ request: TranscribeRequest) async throws -> TranscribeResponse {
            lock.lock()
            _requests.append(request)
            lock.unlock()

            let scripted = respond?(request)
            if let delay = scripted?.delay, delay > 0 {
                await FakeClient.sleepIgnoringCancellation(delay)
            }
            if let error { throw error }
            return TranscribeResponse(text: scripted?.text ?? text,
                                      language: nil, duration: nil, elapsed: nil)
        }

        private var _reloaded: [String] = []
        var reloadedModels: [String] { lock.lock(); defer { lock.unlock() }; return _reloaded }
        var reloadError: Error?

        func reload(model: String) async throws -> HealthResponse {
            lock.lock()
            _reloaded.append(model)
            let failure = reloadError
            lock.unlock()
            if let failure { throw failure }
            return HealthResponse(status: "loading", model: model, modelLoaded: false,
                                  version: nil, detail: nil)
        }

        private var _reconfigured: [ReconfigureRequest] = []
        var reconfigured: [ReconfigureRequest] { lock.lock(); defer { lock.unlock() }; return _reconfigured }
        /// 服务端说"我要重启了"时的应答，默认为不需要重启。
        var reconfigureRestarts = false

        func reconfigure(_ request: ReconfigureRequest) async throws -> ReconfigureResponse {
            lock.lock()
            _reconfigured.append(request)
            // 模型经由 reconfigure 下发时，服务端内部仍走 reload —— 替身把它记在同一处，
            // 既有那些断言 reloadedModels 的用例才不会因为换了出口就失去意义。
            if let model = request.model { _reloaded.append(model) }
            let failure = reloadError
            let restarts = reconfigureRestarts
            lock.unlock()
            if let failure { throw failure }
            return ReconfigureResponse(applied: request.model.map { _ in ["model"] } ?? [],
                                       restartRequired: restarts,
                                       status: restarts ? "restarting" : "loading",
                                       model: request.model, modelLoaded: false,
                                       version: nil, detail: nil)
        }

        /// **不可取消**的等待，这是刻意的：契约写明服务端对并发请求排队而非拒绝，
        /// 超时/取消之后它仍在解码。用 `Task.sleep` 会在 cancel 时立刻返回，
        /// 于是"迟到的结果"根本不迟到，代次守卫就永远不会被真正考验到。
        private static func sleepIgnoringCancellation(_ seconds: TimeInterval) async {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    continuation.resume()
                }
            }
        }
    }

    private final class FakeHealth: ASRHealthReading {
        var state: ASRHealthState = .ready
        /// 服务端此刻加载着谁。nil = 从没探成功过（模型比较无从下手）。
        var reportedModel: String?
        private let lock = NSLock()
        private var _refreshCount = 0
        private var _retargetCount = 0
        var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return _refreshCount }
        var retargetCount: Int { lock.lock(); defer { lock.unlock() }; return _retargetCount }

        var snapshot: ASRHealthSnapshot {
            ASRHealthSnapshot(state: state, probedAt: nil, model: reportedModel, detail: nil)
        }

        func refreshIfStale(maxAge: TimeInterval) async -> ASRHealthState {
            lock.lock()
            _refreshCount += 1
            lock.unlock()
            return state
        }

        func configDidChange(_ config: TranscribeConfig) async {
            lock.lock()
            _retargetCount += 1
            lock.unlock()
        }
    }

    private final class FakeSink: TranscriptInserting {
        var isActive = true
        var accept = true
        var inserted: [String] = []

        var isActiveInputSource: Bool { isActive }

        func insertTranscript(_ text: String) -> Bool {
            guard accept else { return false }
            inserted.append(text)
            return true
        }
    }

    private final class FakeHUD: TranscribeHUDPresenting {
        enum Event: Equatable {
            case recording
            case transcribing
            case message(String)
            case dismissed
        }
        var events: [Event] = []

        func showRecording() { events.append(.recording) }
        func showTranscribing() { events.append(.transcribing) }
        func showMessage(_ text: String) { events.append(.message(text)) }
        func dismiss() { events.append(.dismissed) }
    }

    /// 假上屏目标，替 InputController —— 测试进程里造不出 IMKInputController。
    private final class FakeCommitTarget: TranscriptCommitting {
        var inserted: [String] = []
        var accept = true
        func insertTranscribedText(_ text: String) -> Bool {
            guard accept else { return false }
            inserted.append(text)
            return true
        }
    }

    /// 假绘制端。记下"在哪个线程被调的"，好让主线程投递那条用例有东西可断言。
    private final class RecordingRenderer: TranscribeHUDRendering {
        private let lock = NSLock()
        private var _rendered: [String] = []
        private var _onMain: [Bool] = []
        private var _clearCount = 0

        var rendered: [String] { lock.lock(); defer { lock.unlock() }; return _rendered }
        var renderedOnMainThread: [Bool] { lock.lock(); defer { lock.unlock() }; return _onMain }
        var clearCount: Int { lock.lock(); defer { lock.unlock() }; return _clearCount }

        func render(_ text: String, at position: NSPoint?, icon: TranscribeHUDIcon) {
            lock.lock(); _rendered.append(text); _onMain.append(Thread.isMainThread); lock.unlock()
        }
        func clear() {
            lock.lock(); _clearCount += 1; lock.unlock()
        }
    }

    /// 手动计时器。HUD 的自动消失与兜底关闭都要能**在测试里精确地到点**，
    /// 而且要能只放行其中某一条（陈旧代次那条用例的全部内容就是这个）。
    private final class ManualTimers {
        final class Scheduled {
            let delay: TimeInterval
            private let work: () -> Void
            init(delay: TimeInterval, work: @escaping () -> Void) { self.delay = delay; self.work = work }
            func fire() { work() }
        }
        private(set) var scheduled: [Scheduled] = []
        var last: Scheduled? { scheduled.last }

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            scheduled.append(Scheduled(delay: delay, work: work))
        }
        func fireAll() {
            let pending = scheduled
            scheduled = []
            pending.forEach { $0.fire() }
        }
    }

    /// HUD 策略层 + 假绘制端 + 手动计时器。`onMain` 同步执行：这里要验的是
    /// 状态与代次，不是投递本身（投递另有一条用真实函数的用例）。
    private final class HUDHarness {
        let renderer = RecordingRenderer()
        let timers = ManualTimers()
        let hud: TranscribeHUD

        init(watchdog: TimeInterval = 135) {
            let timers = self.timers
            hud = TranscribeHUD(renderer: renderer,
                                caret: { nil },
                                watchdog: { watchdog },
                                onMain: { $0() },
                                after: { delay, work in timers.schedule(delay, work) })
        }
    }

    /// 把协调器接到全套假件上：没有麦克风、没有 NSEvent、没有网络。
    private final class Harness {
        let capture = FakeCapture()
        let client = FakeClient()
        let health = FakeHealth()
        let sink = FakeSink()
        let hud = FakeHUD()
        let configBox = ConfigBox()
        /// 客户端被造了几次。构造协调器本身就算一次，所以基线是 1。
        let clientBuilds = Counter()
        let recorder: AudioRecorder
        let hotKey: TranscribeHotKey
        let coordinator: TranscribeCoordinator

        init(permission: MicrophonePermission = .granted) {
            let box = configBox
            configBox.value.enabled = true
            recorder = AudioRecorder(capture: capture,
                                     config: { box.value },
                                     permission: { permission })
            hotKey = TranscribeHotKey(monitor: FakeMonitor(), config: { box.value })
            let client = self.client
            let builds = self.clientBuilds
            coordinator = TranscribeCoordinator(hotKey: hotKey,
                                                recorder: recorder,
                                                health: health,
                                                makeClient: { _ in builds.value += 1; return client },
                                                config: { box.value },
                                                inserter: sink,
                                                hud: hud,
                                                log: { _ in })
        }

        func start() { coordinator.start() }

        /// 按下右 Command 并直接把长按阈值走完（不等真实的 250 ms）
        func press() {
            hotKey.handle(keyCode: TranscribeHotKey.rightCommandKeyCode,
                          rawFlags: NSEvent.ModifierFlags.command.rawValue | TranscribeHotKey.rightCommandDeviceMask)
            hotKey.handleHoldDeadline()
        }

        func release() {
            hotKey.handle(keyCode: TranscribeHotKey.rightCommandKeyCode, rawFlags: 0)
        }

        /// 长按期间按下 Shift：热键把本次长按作废（.aborted）
        func abortWithOtherModifier() {
            hotKey.handle(keyCode: 0x38,
                          rawFlags: NSEvent.ModifierFlags.command.rawValue
                              | TranscribeHotKey.rightCommandDeviceMask
                              | NSEvent.ModifierFlags.shift.rawValue)
        }

        /// 按实测的 48 kHz 输入格式喂音频，100 ms 一块
        func feedAudio(seconds: Double) {
            let blocks = max(1, Int((seconds * 10).rounded()))
            for _ in 0..<blocks {
                capture.emit(Harness.makeBuffer(sampleRate: 48_000, frames: 4_800))
            }
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
}
