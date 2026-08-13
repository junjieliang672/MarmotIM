//
//  AudioRecorder.swift
//  MarmotIM
//
//  语音转写：麦克风采集（AVAudioEngine → float32 16 kHz 单声道）
//
//  两条实测前提（spike Q1/Q2，见 docs/transcribe-spike-findings.md §5）：
//  1. 默认输入设备报的是 48000 Hz / 1 ch / float32 / non-interleaved。也就是说这里
//     **只需要重采样**：不用混单声道，不用改样本类型。AVAudioConverter 仍然按通用
//     路径写，换了台设备（立体声 / 44.1 kHz）也能自己降下来。
//  2. 麦克风授权由进程自己弹窗，且 ad-hoc 重签名之后授权仍在，开发期重装不会反复弹。
//
//  交出去的就是 float32 裸样本数组，不做 WAV 封装、不落临时文件 —— 线格式就是裸浮点。
//
//  与 TranscribeHotKey 的分工，有一条**没人认领**的缝，写在这里免得漏掉：
//  热键放弃了"长按期间敲字母就作废"（.flagsChanged 收不到字母），代价是"右拇指按住
//  Command 敲 ⌘C" 会多出一段近乎无声的录音。这里的 minimumRecordingSeconds 只挡得住
//  其中很短的那部分 —— 按住 1.5 s 的 ⌘C 并不算短。**另一半（转写结果为空/近乎为空时
//  丢弃、不插字）属于 integration，本文件管不到。** 少了那一半，误触会真的插字。
//

import Foundation
import AVFoundation

// MARK: - 类型

/// 麦克风授权状态（不弹窗即可查询）
enum MicrophonePermission: Equatable {
    /// 还没问过 —— 首次 start() 时由系统自己弹窗
    case notDetermined
    /// 已授权
    case granted
    /// 用户拒绝，或被描述文件限制 —— 只能引导去系统设置
    case denied
}

/// 采集失败的原因。每一种都是可处理的 Error，不存在崩溃或挂起的路径。
enum AudioRecorderError: Error, Equatable {
    /// 授权被拒 —— 不要再调 AVAudioEngine，直接失败
    case permissionDenied
    /// 没有可用输入设备（拔掉了 / 采样率报 0）
    case inputUnavailable
    /// AVAudioEngine.start() 抛错
    case engineFailed(String)
    /// 输入格式建不出转换器（理论上不该发生）
    case converterUnavailable
}

/// 一段已经采到的音频：16 kHz 单声道 float32
struct AudioRecording: Equatable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

/// 一次采集的结局
enum AudioRecorderOutcome: Equatable {
    /// 拿到了可用的一段
    case recorded(AudioRecording)
    /// 短于下限（误触）—— 调用方应当静默丢弃，不报错也不插字
    case tooShort(TimeInterval)
}

// MARK: - 采集安装点

/// AVAudioEngine 的安装点
///
/// 抽出来只为一件事：单测进程里没有可用输入设备，靠假实现直接喂 buffer，
/// 这样重采样、上限、下限都能在没有硬件的情况下验证。
protocol AudioInputCapturing: AnyObject {
    /// 装上 tap 并启动。buffer 在音频线程上回调。
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    /// 拆 tap 并停机；重复调用安全。
    func stop()
}

/// 真实实现：AVAudioEngine 输入节点上的 tap
final class AVAudioEngineCapture: AudioInputCapturing {

    private let engine = AVAudioEngine()
    private var isTapped = false

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        // 先拆再装：重复 start 不会叠出两个 tap
        stop()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // 设备被拔掉时这里报 0 Hz / 0 ch，installTap 会直接抛 NSException
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.inputUnavailable
        }

        // 100 ms 一块（实测就是 48 kHz 下的 4800 帧），与 spike 观测到的节奏一致
        let bufferSize = AVAudioFrameCount(format.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        isTapped = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw AudioRecorderError.engineFailed(error.localizedDescription)
        }
    }

    func stop() {
        if isTapped {
            engine.inputNode.removeTap(onBus: 0)
            isTapped = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    deinit {
        stop()
    }
}

// MARK: - 重采样

/// 把输入设备的格式转成 16 kHz 单声道 float32
///
/// AVAudioConverter 在做采样率转换时是**有状态**的（重采样滤波器跨 buffer 连续），
/// 所以整段录音必须复用同一个实例，不能每块新建、也不能中途 reset。
struct AudioResampler {

    /// 线格式采样率，与 TranscribeRequest.sampleRate 一致
    static let targetSampleRate: Double = 16_000

    /// 16 kHz / 单声道 / float32 / non-interleaved
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetSampleRate,
                                            channels: 1,
                                            interleaved: false)!

    private let converter: AVAudioConverter

    init?(sourceFormat: AVAudioFormat) {
        guard sourceFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat) else {
            return nil
        }
        self.converter = converter
    }

    /// 转一块。失败时返回空数组 —— 丢一块音频远好过让采集路径抛错。
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        // 多给一点余量：重采样滤波器可能把上一块攒下的尾巴一起吐出来
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return []
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            // 一次只喂一块；喂完就说没有了，转换器会把能出的都出掉
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

// MARK: - 录音服务

/// 麦克风录音服务
///
/// 按住热键期间采集音频，松开后交出一段 float32 PCM。
/// 只在主线程调用 start/stop/cancel；样本累积发生在音频线程，靠锁保护。
final class AudioRecorder {

    // MARK: - Constants

    /// 短于这个长度视为误触，静默丢弃。与服务端 `audio_too_short` 的门槛一致。
    static let minimumRecordingSeconds: TimeInterval = 0.2

    // MARK: - Callbacks

    /// 卡键兜底触发：录音被自动停掉，并把已经采到的交出来
    var onAutoStop: ((AudioRecorderOutcome) -> Void)?

    // MARK: - Properties

    private let capture: AudioInputCapturing
    private let config: () -> TranscribeConfig
    /// 授权查询点。注入是为了单测：测试进程自己的 TCC 状态不该决定用例走哪条分支。
    private let permission: () -> MicrophonePermission

    private let lock = NSLock()
    private var samples: [Float] = []
    private var resampler: AudioResampler?

    private var ceilingWorkItem: DispatchWorkItem?

    private(set) var isRecording = false

    /// 卡键兜底的上限（秒）。来自配置，AppConfig.validate 已把它夹在 5–600 s。
    /// 这是安全阀不是 UX 上限：不做静音检测，不提前停。
    var maxRecordingSeconds: TimeInterval {
        config().maxRecordingSeconds
    }

    // MARK: - Permission

    /// 当前授权状态。**不会弹窗**，可以在任何时候查。
    static var permission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    /// 显式请求授权（会弹窗）。已决定过的状态下系统直接回旧答案，不会重复弹。
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Initialization

    init(capture: AudioInputCapturing = AVAudioEngineCapture(),
         config: @escaping () -> TranscribeConfig = { AppDelegate.config.transcribe },
         permission: @escaping () -> MicrophonePermission = { AudioRecorder.permission }) {
        self.capture = capture
        self.config = config
        self.permission = permission
    }

    deinit {
        // 无条件拆引擎：绝不依赖某个可能永远不来的回调把它关掉
        ceilingWorkItem?.cancel()
        capture.stop()
    }

    // MARK: - Public Methods

    /// 开始采集。重复调用无副作用。
    ///
    /// 授权被拒时直接抛错，不去碰 AVAudioEngine —— 那条路只会静默录出全零。
    /// `.notDetermined` 放行：系统会在引擎启动时自己弹窗（spike Q1）。
    func start() throws {
        guard !isRecording else { return }

        if permission() == .denied {
            throw AudioRecorderError.permissionDenied
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        resampler = nil
        lock.unlock()

        do {
            try capture.start { [weak self] buffer in
                self?.append(buffer)
            }
        } catch let error as AudioRecorderError {
            throw error
        } catch {
            throw AudioRecorderError.engineFailed(error.localizedDescription)
        }

        isRecording = true
        scheduleCeiling()
        NSLog("MarmotIM: AudioRecorder - started (ceiling %.0f s)", maxRecordingSeconds)
    }

    /// 正常结束采集，交出这一段。
    ///
    /// 返回 nil 表示当时并没有在录（重复 stop、或已经被卡键兜底交付过）。
    @discardableResult
    func stop() -> AudioRecorderOutcome? {
        guard isRecording else { return nil }
        finish()
        return outcome()
    }

    /// 作废本次采集：拆引擎、丢样本，什么都不交出去。
    /// 长按被打断（`TranscribeHoldEndReason.aborted`）走这里。
    func cancel() {
        finish()
        lock.lock()
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    /// 卡键兜底到点（单测直接调它，免得等真实的 120 s）
    func handleCeiling() {
        guard isRecording else { return }
        let captured = outcome()
        finish()
        NSLog("MarmotIM: AudioRecorder - ceiling reached, yielding what was captured")
        onAutoStop?(captured)
    }

    // MARK: - Private Methods

    /// 音频线程：转成 16 kHz 追加到缓冲
    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        if resampler == nil {
            // 用 buffer 自己的格式建转换器，而不是启动时问到的格式 —— 两者理论上一致，
            // 以 buffer 为准更不容易出错
            resampler = AudioResampler(sourceFormat: buffer.format)
        }
        guard let resampler else { return }
        samples.append(contentsOf: resampler.convert(buffer))
    }

    /// 停引擎、停计时器、清标志。可重复调用。
    private func finish() {
        ceilingWorkItem?.cancel()
        ceilingWorkItem = nil
        capture.stop()
        isRecording = false
    }

    /// 按当前样本数判定结局
    private func outcome() -> AudioRecorderOutcome {
        lock.lock()
        let captured = samples
        lock.unlock()

        let recording = AudioRecording(samples: captured,
                                       sampleRate: AudioResampler.targetSampleRate)
        guard recording.duration >= Self.minimumRecordingSeconds else {
            return .tooShort(recording.duration)
        }
        return .recorded(recording)
    }

    private func scheduleCeiling() {
        ceilingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.handleCeiling()
        }
        ceilingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + maxRecordingSeconds, execute: item)
    }
}
