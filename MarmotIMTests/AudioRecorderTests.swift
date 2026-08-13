import XCTest
import AVFoundation
@testable import MarmotIM

/// Tests for AudioRecorder (microphone capture → float32 16 kHz mono).
///
/// 测试进程里没有可用输入设备，所以采集经由 `AudioInputCapturing` 的假实现驱动：
/// buffer 是合成的，重采样、上限、下限、错误分支都不依赖硬件。
final class AudioRecorderTests: XCTestCase {

    // MARK: - Fakes & Helpers

    /// 假采集端：手动喂 buffer，并记录装/拆次数
    private final class FakeAudioCapture: AudioInputCapturing {
        var startCount = 0
        var stopCount = 0
        var isRunning = false
        /// 非 nil 时 start() 抛这个错
        var startError: Error?

        private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

        func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
            if let startError { throw startError }
            startCount += 1
            isRunning = true
            self.onBuffer = onBuffer
        }

        func stop() {
            stopCount += 1
            isRunning = false
            onBuffer = nil
        }

        /// 模拟音频线程送上来一块
        func emit(_ buffer: AVAudioPCMBuffer) {
            onBuffer?(buffer)
        }
    }

    /// 合成一块正弦波 buffer（float32 non-interleaved），采样率任意
    private func makeBuffer(sampleRate: Double,
                            frames: AVAudioFrameCount,
                            channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: channels,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // 440 Hz，远低于 16 kHz 的奈奎斯特频率，重采样不会把它滤没
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                data[frame] = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / sampleRate)) * 0.5
            }
        }
        return buffer
    }

    private func makeConfig(maxRecordingSeconds: Double = 120.0) -> TranscribeConfig {
        var config = TranscribeConfig.default
        config.maxRecordingSeconds = maxRecordingSeconds
        return config
    }

    /// 按实测的 48 kHz 输入格式喂进 `seconds` 秒音频，100 ms 一块（与真实 tap 的节奏一致）
    private func feed(_ capture: FakeAudioCapture, seconds: Double) {
        for _ in 0..<Int((seconds * 10).rounded()) {
            capture.emit(makeBuffer(sampleRate: 48_000, frames: 4_800))
        }
    }

    private func makeRecorder(capture: FakeAudioCapture,
                              maxRecordingSeconds: Double = 120.0,
                              permission: MicrophonePermission = .granted) -> AudioRecorder {
        AudioRecorder(capture: capture,
                      config: { self.makeConfig(maxRecordingSeconds: maxRecordingSeconds) },
                      permission: { permission })
    }

    // MARK: - Resampling math

    /// 按真实节奏（100 ms 一块）跑一段，返回输出样本总数
    ///
    /// 不要用"一整块 1 s"来测：AVAudioConverter 是按内部块量出数的（实测每 100 ms 输入
    /// 出 1360/1664/1664/1664/1365… 而不是稳定的 1600），余数留在转换器里下次带出。
    /// 一次性喂一大块，尾巴会被截在块边界上，出多少取决于内部分块，测出来是假的。
    private func streamedSampleCount(sourceRate: Double,
                                     channels: AVAudioChannelCount = 1,
                                     seconds: Double) -> Int {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sourceRate,
                                   channels: channels,
                                   interleaved: false)!
        let resampler = AudioResampler(sourceFormat: format)!
        let framesPerChunk = AVAudioFrameCount(sourceRate / 10)
        return (0..<Int(seconds * 10)).reduce(0) { total, _ in
            total + resampler.convert(makeBuffer(sampleRate: sourceRate,
                                                 frames: framesPerChunk,
                                                 channels: channels)).count
        }
    }

    /// 实测输入就是 48 kHz —— 1 s 输入应当出约 16000 个样本
    func testResamplesFortyEightKilohertzToSixteen() {
        // 差额是重采样滤波器的一次性预热（实测约 262 个样本 / 16 ms）
        XCTAssertEqual(Double(streamedSampleCount(sourceRate: 48_000, seconds: 1.0)),
                       16_000, accuracy: 400)
    }

    /// 非整数倍的采样率也要能降下来，证明这不是写死的 /3
    func testResamplesNonIntegerRatioSourceRate() {
        // 16000/44100 不是整数比，转换器仍然应当出约 1 s 的量
        XCTAssertEqual(Double(streamedSampleCount(sourceRate: 44_100, seconds: 1.0)),
                       16_000, accuracy: 400)
    }

    /// 换成立体声设备时由转换器混单声道，不该报错也不该只出一半
    func testStereoSourceIsMixedDownToMono() {
        XCTAssertEqual(Double(streamedSampleCount(sourceRate: 48_000, channels: 2, seconds: 1.0)),
                       16_000, accuracy: 400)
    }

    /// 关键不变量：差额是**一次性**的预热，不是每块都丢
    ///
    /// 如果每块都丢一点，录得越久丢得越多，长录音会被压扁。跑 1 s 和 3 s 各一遍，
    /// 差额应当基本相同 —— 这才是"转换器状态跨 buffer 连续"的真正证据。
    func testShortfallIsOneTimePrimingNotPerBufferLoss() {
        let oneSecond = 16_000 - streamedSampleCount(sourceRate: 48_000, seconds: 1.0)
        let threeSeconds = 48_000 - streamedSampleCount(sourceRate: 48_000, seconds: 3.0)
        XCTAssertEqual(Double(threeSeconds), Double(oneSecond), accuracy: 100,
                       "差额随时长增长说明每块都在丢样本：1 s 差 \(oneSecond)，3 s 差 \(threeSeconds)")
    }

    /// 重采样出来的不能是全零 —— 数量对但内容空同样是坏的
    func testResampledOutputCarriesSignal() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000,
                                   channels: 1,
                                   interleaved: false)!
        let resampler = AudioResampler(sourceFormat: format)!
        _ = resampler.convert(makeBuffer(sampleRate: 48_000, frames: 4_800))
        // 用第二块看：第一块含滤波器预热段
        let output = resampler.convert(makeBuffer(sampleRate: 48_000, frames: 4_800))
        XCTAssertFalse(output.isEmpty)
        XCTAssertFalse(output.allSatisfy { $0 == 0 }, "重采样后不应该是全零")
    }

    /// 目标格式就是线格式：16 kHz / 单声道 / float32 / non-interleaved
    func testTargetFormatIsWireFormat() {
        let format = AudioResampler.targetFormat
        XCTAssertEqual(format.sampleRate, 16_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(format.isInterleaved)
    }

    // MARK: - 采集路径

    func testRecordsAndYieldsSixteenKilohertzSamples() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture)

        try recorder.start()
        XCTAssertTrue(recorder.isRecording)
        // 1 s @ 48 kHz
        feed(capture, seconds: 1.0)

        guard case .recorded(let recording)? = recorder.stop() else {
            return XCTFail("1 s 的录音应当是 .recorded")
        }
        XCTAssertEqual(recording.sampleRate, 16_000)
        XCTAssertEqual(recording.duration, 1.0, accuracy: 0.03)
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - 上限（卡键兜底）

    /// 上限来自配置，不是写死的 120
    func testCeilingComesFromConfig() {
        let recorder = makeRecorder(capture: FakeAudioCapture(), maxRecordingSeconds: 300.0)
        XCTAssertEqual(recorder.maxRecordingSeconds, 300.0)
    }

    /// 到点自动停，并把已经采到的交出来（而不是丢掉）
    func testCeilingAutoStopsAndYieldsWhatWasCaptured() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture)

        var delivered: AudioRecorderOutcome?
        recorder.onAutoStop = { delivered = $0 }

        try recorder.start()
        feed(capture, seconds: 1.0)
        recorder.handleCeiling()

        guard case .recorded(let recording)? = delivered else {
            return XCTFail("卡键兜底应当交出已采到的一段")
        }
        XCTAssertEqual(recording.duration, 1.0, accuracy: 0.03)
        XCTAssertFalse(recorder.isRecording, "兜底之后必须已经停机")
        XCTAssertFalse(capture.isRunning, "引擎必须被拆掉")
        // 已经交付过了，随后的 stop() 不该再交一次
        XCTAssertNil(recorder.stop())
    }

    /// 没在录的时候到点是空操作，不该凭空发一次回调
    func testCeilingWhileIdleDeliversNothing() {
        let recorder = makeRecorder(capture: FakeAudioCapture())
        var called = false
        recorder.onAutoStop = { _ in called = true }

        recorder.handleCeiling()
        XCTAssertFalse(called)
    }

    // MARK: - 下限（误触）

    func testSubThresholdCaptureIsReportedTooShort() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture)

        try recorder.start()
        // 0.1 s < 0.2 s 的下限
        feed(capture, seconds: 0.1)

        guard case .tooShort(let duration)? = recorder.stop() else {
            return XCTFail("0.1 s 应当被判为 .tooShort")
        }
        XCTAssertLessThan(duration, AudioRecorder.minimumRecordingSeconds)
    }

    /// 一次样本都没采到也走 .tooShort，而不是交出空录音或抛错
    func testEmptyCaptureIsTooShortRatherThanAnError() throws {
        let recorder = makeRecorder(capture: FakeAudioCapture())
        try recorder.start()

        guard case .tooShort(let duration)? = recorder.stop() else {
            return XCTFail("空采集应当是 .tooShort")
        }
        XCTAssertEqual(duration, 0)
    }

    /// 刚好越过下限的要能过 —— 下限不能顺手把正常短句也吃掉
    func testJustAboveThresholdIsRecorded() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture)
        try recorder.start()
        feed(capture, seconds: 0.5)

        guard case .recorded? = recorder.stop() else {
            return XCTFail("0.5 s 应当是 .recorded")
        }
    }

    // MARK: - 错误分支

    func testDeniedPermissionThrowsTypedErrorWithoutTouchingEngine() {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture, permission: .denied)

        XCTAssertThrowsError(try recorder.start()) { error in
            XCTAssertEqual(error as? AudioRecorderError, .permissionDenied)
        }
        XCTAssertEqual(capture.startCount, 0, "被拒时根本不该去启动引擎")
        XCTAssertFalse(recorder.isRecording)
    }

    /// 还没问过授权要放行 —— 弹窗由系统在引擎启动时自己出（spike Q1）
    func testNotDeterminedPermissionIsAllowedThrough() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture, permission: .notDetermined)

        try recorder.start()
        XCTAssertEqual(capture.startCount, 1)
    }

    func testUnavailableInputSurfacesAsTypedError() {
        let capture = FakeAudioCapture()
        capture.startError = AudioRecorderError.inputUnavailable
        let recorder = makeRecorder(capture: capture)

        XCTAssertThrowsError(try recorder.start()) { error in
            XCTAssertEqual(error as? AudioRecorderError, .inputUnavailable)
        }
        XCTAssertFalse(recorder.isRecording, "启动失败之后不能留在 recording 状态")
    }

    /// 引擎抛的是 NSError 之类的外部错误，也要收敛成本模块的类型
    func testForeignStartErrorIsWrappedAsEngineFailed() {
        let capture = FakeAudioCapture()
        capture.startError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10875)
        let recorder = makeRecorder(capture: capture)

        XCTAssertThrowsError(try recorder.start()) { error in
            guard case .engineFailed? = error as? AudioRecorderError else {
                return XCTFail("外部错误应当被包成 .engineFailed，实际是 \(error)")
            }
        }
    }

    // MARK: - 生命周期

    func testStartIsIdempotent() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture)

        try recorder.start()
        try recorder.start()
        XCTAssertEqual(capture.startCount, 1)
    }

    func testStopIsIdempotentAndSecondStopYieldsNothing() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture)

        try recorder.start()
        feed(capture, seconds: 1.0)
        XCTAssertNotNil(recorder.stop())
        XCTAssertNil(recorder.stop(), "重复 stop 不该再交出一段")
        XCTAssertFalse(capture.isRunning)
    }

    /// 长按被打断：拆引擎、丢样本，什么都不交出去
    func testCancelDiscardsCapturedAudio() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture)

        try recorder.start()
        feed(capture, seconds: 1.0)
        recorder.cancel()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(capture.isRunning)
        XCTAssertNil(recorder.stop(), "作废之后不该还能取回那段音频")
    }

    /// 没启动过就 cancel 也必须安全
    func testCancelWithoutStartIsSafe() {
        let recorder = makeRecorder(capture: FakeAudioCapture())
        recorder.cancel()
        XCTAssertFalse(recorder.isRecording)
    }

    /// 重新开始一次不会带上上一次的样本
    func testRestartClearsPreviousSamples() throws {
        let capture = FakeAudioCapture()
        let recorder = makeRecorder(capture: capture)

        try recorder.start()
        feed(capture, seconds: 1.0)
        _ = recorder.stop()

        try recorder.start()
        feed(capture, seconds: 0.5)
        guard case .recorded(let recording)? = recorder.stop() else {
            return XCTFail("第二次录音应当是 .recorded")
        }
        XCTAssertEqual(recording.duration, 0.5, accuracy: 0.03, "第二次不该带上第一次的 1 s")
    }

    // MARK: - 授权查询

    /// 查询本身不弹窗，任何时候都能安全调用
    func testPermissionIsQueryable() {
        let permission = AudioRecorder.permission
        XCTAssertTrue([.granted, .denied, .notDetermined].contains(permission))
    }
}

