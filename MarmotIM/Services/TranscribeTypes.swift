//
//  TranscribeTypes.swift
//  MarmotIM
//
//  语音转写：与本地 ASR 服务之间的共享数据类型
//  契约来源：.flow/plan/2026-08-12-transcribe/reference-api-contract.md
//
//  仅声明，不含逻辑。网络实现属于 ASRClient。
//

import Foundation

// MARK: - /transcribe

/// `POST /transcribe` 请求体
///
/// `audioBase64` 是原始 float32 小端 PCM（16 kHz 单声道）的 base64，不是 WAV。
struct TranscribeRequest: Codable, Equatable {
    let audioBase64: String
    let sampleRate: Int
    /// nil 表示自动识别语种
    let language: String?
    /// 空格分隔的热词；无热词时为 "" 或省略
    let context: String?
    /// nil / 省略 ⇒ 服务端传 `max_tokens=None`，由库自动取 `max(256, duration * 50)`；
    /// 非 nil ⇒ 服务端原样透传为 `max_tokens`（决策 13）
    let maxNewTokens: Int?

    enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base64"
        case sampleRate = "sample_rate"
        case language
        case context
        case maxNewTokens = "max_new_tokens"
    }
}

/// `POST /transcribe` 成功响应（HTTP 200）
///
/// 服务端返回模型原样输出；去除句末标点是客户端的职责（决策 5）。
struct TranscribeResponse: Codable, Equatable {
    let text: String
    /// 识别到的或回显的语种
    let language: String?
    /// 音频时长（秒）
    let duration: Double?
    /// 服务端处理耗时（秒）
    let elapsed: Double?
}

// MARK: - 错误

/// 服务端错误码（HTTP 4xx / 5xx 的 `error` 字段）
enum TranscribeServerErrorCode: String, Codable, Equatable, CaseIterable {
    /// 503：模型仍在加载，或正在切换模型
    case modelNotReady = "model_not_ready"
    /// 400：音频过短（< 0.2 s），视为误触
    case audioTooShort = "audio_too_short"
    /// 400：音频超过服务端上限（客户端已在 120 s 处兜底）
    case audioTooLong = "audio_too_long"
    /// 400：负载无法解码 / 采样率不对
    case badAudio = "bad_audio"
    /// 500：模型推理抛错
    case inferenceFailed = "inference_failed"
}

/// 服务端错误响应体：`{"error": "<code>", "detail": "<message>"}`
struct TranscribeErrorResponse: Codable, Equatable {
    let error: String
    let detail: String?
}

// MARK: - /health

/// `GET /health` 响应体
struct HealthResponse: Codable, Equatable {
    let status: String
    let model: String?
    let modelLoaded: Bool?
    let version: String?
    /// status != "ready" 时的人类可读说明
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case status
        case model
        case modelLoaded = "model_loaded"
        case version
        case detail
    }
}

/// 客户端缓存的健康状态
///
/// 输入路径只读取这个枚举的原子快照，绝不发起同步网络请求（决策 20）。
enum ASRHealthState: String, Equatable, CaseIterable {
    /// 服务就绪，模型已加载
    case ready
    /// 进程在，权重仍在加载（冷启动 / 切换模型）
    case loading
    /// 进程在，模型加载失败
    case error
    /// 连接被拒绝或超时 —— 功能关闭时的正常稳态，不做用户可见报错
    case down
}

// MARK: - /reload

/// `POST /reload` 请求体（可选，用于切换模型）
struct ReloadRequest: Codable, Equatable {
    /// HuggingFace 仓库 id
    let model: String
}

// MARK: - /reconfigure

/// `POST /reconfigure` 请求体：把设置页改动的服务端项目一次交给服务端。
///
/// 全部 optional，且 nil 的键**不会出现在 JSON 里**（Swift 的 nil Optional 直接省略该键，
/// 见 docs/transcribe-spike-findings.md §6）—— 服务端据此把"没提到"和"改成这个值"区分开。
/// 只发用户真的改了的项，不发整份快照：整份快照会让旧版设置页把新版加的项悄悄改回默认。
///
/// **哪些要重启由服务端决定，不在这里判断。** 端口、主机、日志级别要重开进程，
/// 模型可以原地换 —— 这是服务端的知识，客户端只管发和读 `restartRequired`。
struct ReconfigureRequest: Codable, Equatable {
    var host: String?
    var port: Int?
    var model: String?
    var language: String?
    var minAudioSeconds: Double?
    var maxAudioSeconds: Double?
    var logLevel: String?

    enum CodingKeys: String, CodingKey {
        case host, port, model, language
        case minAudioSeconds = "min_audio_seconds"
        case maxAudioSeconds = "max_audio_seconds"
        case logLevel = "log_level"
    }

    /// 一项都没有就没必要发请求。
    var isEmpty: Bool {
        host == nil && port == nil && model == nil && language == nil
            && minAudioSeconds == nil && maxAudioSeconds == nil && logLevel == nil
    }
}

/// `POST /reconfigure` 的 202 应答：/health 的五个键，外加这两个。
struct ReconfigureResponse: Codable, Equatable {
    /// 服务端认定真正发生变化的键；空数组表示发过来的值与现状一致，什么都没做。
    let applied: [String]
    /// 服务端是否正在为此重启。true 时它会在应答送达后自行退出，由 launchd 拉起来。
    let restartRequired: Bool

    let status: String
    let model: String?
    let modelLoaded: Bool?
    let version: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case applied
        case restartRequired = "restart_required"
        case status, model, version, detail
        case modelLoaded = "model_loaded"
    }
}
