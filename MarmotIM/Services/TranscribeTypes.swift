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
