//
//  ASRClient.swift
//  MarmotIM
//
//  语音转写：本地 ASR 服务 HTTP 客户端
//
//  契约见 .flow/plan/2026-08-12-transcribe/reference-api-contract.md —— 两侧都不得单方面修改。
//
//  这里承担「永不影响打字」保证在网络层的那一半（决策 20）：
//  · 全部接口都是 async，调用方在输入路径之外；本文件里没有任何信号量 / DispatchQueue.sync。
//  · 连接被拒绝是功能未开启时的正常稳态，返回 .notRunning，本文件一行日志都不打
//    （状态迁移的日志归 ASRHealthMonitor，避免每次尝试都刷屏）。
//  · 客户端自身绝不重试：503 model_not_ready 是唯一可重试的状态，但重试与否由调用方决定 ——
//    服务端对并发请求是排队而非拒绝，客户端擅自重试只会把一次推理变成两次。
//

import Foundation

// MARK: - 客户端配置

/// `ASRClient` 的可配置项，从 `TranscribeConfig` 派生。
///
/// 单独成型而不是直接吃 `TranscribeConfig`，有两个原因：
/// 1. 健康探测超时（1 s）是契约常量，不在用户可见设置里，`TranscribeConfig` 没有对应字段；
/// 2. 测试要能把超时压到亚秒级，否则一条超时用例要跑满 15 s。
struct ASRClientConfig: Equatable {
    /// 契约固定值：/health 必须在 50 ms 内应答，1 s 已是极宽松的上限。
    /// 实测空闲 p99 为 3.61 ms；唯一可能逼近 1 s 的时刻是模型切换时旧模型 close()
    /// 释放显存并持有 GIL（实测单次 613 ms）—— 那不是「服务没装」，见 ASRHealthMonitor。
    static let defaultHealthTimeout: TimeInterval = 1.0

    /// /reload 只是接受请求（202 后台加载），但可能撞上旧模型的同步释放，给得比 health 宽。
    static let defaultReloadTimeout: TimeInterval = 5.0

    /// 只接受回环地址；任何其它主机名都会被 `resolvedHost` 强行拉回 127.0.0.1（决策 14）。
    static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    var host: String
    var port: Int
    var healthTimeout: TimeInterval
    var transcribeTimeout: TimeInterval
    var reloadTimeout: TimeInterval

    init(host: String = TranscribeConfig.default.host,
         port: Int = TranscribeConfig.default.port,
         healthTimeout: TimeInterval = ASRClientConfig.defaultHealthTimeout,
         transcribeTimeout: TimeInterval = TranscribeConfig.default.requestTimeoutSeconds,
         reloadTimeout: TimeInterval = ASRClientConfig.defaultReloadTimeout) {
        self.host = host
        self.port = port
        self.healthTimeout = healthTimeout
        self.transcribeTimeout = transcribeTimeout
        self.reloadTimeout = reloadTimeout
    }

    /// 从用户配置派生。用户能改的只有 host / port / 请求超时。
    init(_ transcribe: TranscribeConfig) {
        self.init(host: transcribe.host,
                  port: transcribe.port,
                  transcribeTimeout: transcribe.requestTimeoutSeconds)
    }

    /// 实际拨号用的主机：非回环一律回落到 127.0.0.1，绝不向局域网发音频。
    var resolvedHost: String {
        ASRClientConfig.loopbackHosts.contains(host.lowercased()) ? host.lowercased() : "127.0.0.1"
    }

    /// `http://127.0.0.1:58471`（IPv6 字面量补方括号）
    var baseURLString: String {
        let h = resolvedHost
        let authority = h.contains(":") ? "[\(h)]" : h
        return "http://\(authority):\(port)"
    }
}

// MARK: - 端点与错误

/// 出错时用来说明「哪一个请求出的错」，超时语义按端点区分（见 ASRClientError.timedOut）。
enum ASREndpoint: String, Equatable {
    case health
    case transcribe
    case reload

    var path: String { "/\(rawValue)" }
}

/// 客户端错误。
///
/// 关键区分：`.notRunning`（连接被拒绝 —— 没人在监听）与 `.timedOut`（有人监听但没按时应答）
/// 是两件完全不同的事。前者是功能未安装/未启动的正常稳态，后者说明服务活着只是很忙
/// （最典型的就是刚切换模型）。把后者当成「未安装」会在用户刚改完设置的那一刻误报。
enum ASRClientError: Error, Equatable {
    /// 连接被拒绝 / 无法建连 —— 服务没在跑。稳态，不做用户可见报错，不打日志。
    case notRunning
    /// 超时：TCP 连上了，但对端没在期限内应答。
    ///
    /// `.transcribe` 超时时服务端**仍在继续解码**（它对并发请求排队而非拒绝），
    /// 完成后会写进一个没人读的 socket。因此客户端只是放弃本次结果，
    /// 既不重试（重试会再排一次队），也不认为服务不可用。
    case timedOut(endpoint: ASREndpoint)
    /// 契约内的五个错误码之一（`/transcribe`）。
    case server(code: TranscribeServerErrorCode, detail: String?)
    /// `bad_model` 400 —— 只存在于 `/reload`，故意不进 `TranscribeServerErrorCode`
    /// 那个封闭的五值枚举（其 rawValue 被 foundation 的测试钉死，且契约把它排除在
    /// /transcribe 的分类之外）。这里就地处理。
    case badModel(detail: String?)
    /// 状态码不在预期内，或 `error` 字段是个我们不认识的码。
    case unexpectedStatus(status: Int, code: String?, detail: String?)
    /// 响应不是合法 JSON，或缺少契约要求的字段。
    case malformedResponse(endpoint: ASREndpoint)
    /// 其它传输层错误，保留 URLError 原始码便于诊断。
    case transport(code: Int)

    /// 是否属于「不该让用户看见」的错误。连接被拒绝是功能关闭时的常态。
    var isSilent: Bool {
        self == .notRunning
    }

    /// 是否值得由**调用方**重试。400 一律永久错误，绝不重试；
    /// 唯一可重试的是 503 model_not_ready（模型还在加载 / 正在切换）。
    var isRetryable: Bool {
        if case .server(let code, _) = self { return code == .modelNotReady }
        return false
    }
}

// MARK: - 客户端

/// 本地 ASR 服务客户端
///
/// 无状态、可安全并发调用。配置变更时由调用方重建实例（配置是 let，不存在读到半个新配置的窗口）。
final class ASRClient {

    let config: ASRClientConfig
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = ASRClient.makeEncoder()

    // MARK: - Initialization

    init(config: ASRClientConfig = ASRClientConfig(), session: URLSession? = nil) {
        self.config = config
        self.session = session ?? ASRClient.makeSession()
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // JSONEncoder 默认把 "/" 转义成 "\/"。两侧解码都不受影响，但 base64 字母表里
        // 约 1/64 的字符就是 "/"，120 s 音频的请求体会因此白白胖出百来 KB；
        // 而且 model 里的 "mlx-community/..." 打日志时也难读。关掉。
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // 回环请求没有「等网络恢复」这回事：没人监听就是没人监听，立刻失败。
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldUsePipelining = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }

    // MARK: - GET /health

    /// 探测服务健康。**这里发起真实网络请求**，输入路径永远不调用它 ——
    /// 输入路径只读 `ASRHealthMonitor` 的缓存快照。
    func health() async throws -> HealthResponse {
        try await perform(.health,
                          method: "GET",
                          body: nil,
                          timeout: config.healthTimeout,
                          successStatuses: [200])
    }

    // MARK: - POST /transcribe

    /// 提交一段音频。服务端返回模型原样输出，去尾标点是调用方之后的事（决策 5）。
    func transcribe(_ request: TranscribeRequest) async throws -> TranscribeResponse {
        try await perform(.transcribe,
                          method: "POST",
                          body: try encoder.encode(request),
                          timeout: config.transcribeTimeout,
                          successStatuses: [200])
    }

    // MARK: - POST /reload

    /// 切换服务端当前加载的模型。202 + 与 /health 同构的五键 body，随后 /health 会报 loading。
    ///
    /// 归属说明：这个调用属于本层（HTTP 就是本目标的职责）。设置页切换模型变体后会发
    /// `.transcribeConfigDidChange`，由 integration 把该通知接到这里 —— 否则变体选择器是个摆设，
    /// 服务端会一直服务旧模型直到有人重启它。重载当前已加载的模型是允许的，
    /// 也是从 `error` 状态恢复的正规手段。
    @discardableResult
    func reload(model: String) async throws -> HealthResponse {
        try await perform(.reload,
                          method: "POST",
                          body: try encoder.encode(ReloadRequest(model: model)),
                          timeout: config.reloadTimeout,
                          successStatuses: [200, 202])
    }

    // MARK: - 请求执行

    private func perform<T: Decodable>(_ endpoint: ASREndpoint,
                                       method: String,
                                       body: Data?,
                                       timeout: TimeInterval,
                                       successStatuses: Set<Int>) async throws -> T {
        guard let url = URL(string: config.baseURLString + endpoint.path) else {
            throw ASRClientError.notRunning
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw ASRClient.mapTransportError(urlError, endpoint: endpoint)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ASRClientError.malformedResponse(endpoint: endpoint)
        }
        guard successStatuses.contains(http.statusCode) else {
            throw ASRClient.mapServerError(status: http.statusCode, data: data, endpoint: endpoint)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ASRClientError.malformedResponse(endpoint: endpoint)
        }
    }

    /// URLError → 客户端语义。**唯一区分「没人监听」与「没按时应答」的地方。**
    private static func mapTransportError(_ error: URLError, endpoint: ASREndpoint) -> Error {
        switch error.code {
        case .timedOut:
            return ASRClientError.timedOut(endpoint: endpoint)
        case .cannotConnectToHost,        // ECONNREFUSED —— 服务没跑，稳态
             .cannotFindHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed:
            return ASRClientError.notRunning
        case .cancelled:
            // 调用方取消（例如用户松开热键就撤回了本次转写）——不是服务的问题。
            return CancellationError()
        default:
            return ASRClientError.transport(code: error.code.rawValue)
        }
    }

    /// 非成功状态码 → 契约错误分类。
    private static func mapServerError(status: Int, data: Data, endpoint: ASREndpoint) -> ASRClientError {
        // 服务端在所有错误路径上都返回 {"error", "detail"}；schema 违例和非 JSON body
        // 都被折叠成 bad_audio 400，因此不存在 FastAPI 那种 detail-是-数组的 422 形态。
        guard let payload = try? JSONDecoder().decode(TranscribeErrorResponse.self, from: data) else {
            return .malformedResponse(endpoint: endpoint)
        }
        if let code = TranscribeServerErrorCode(rawValue: payload.error) {
            return .server(code: code, detail: payload.detail)
        }
        // 第六个码，只在 /reload 上存在：模型不在白名单内。
        if endpoint == .reload, payload.error == "bad_model" {
            return .badModel(detail: payload.detail)
        }
        return .unexpectedStatus(status: status, code: payload.error, detail: payload.detail)
    }
}

// MARK: - 转写文本后处理

/// 转写结果的客户端后处理。
///
/// 契约写明服务端返回**模型原样输出**、绝不改写转写文本，去尾标点因此是客户端的事（决策 5）。
/// 放在这一层而不是提交路径上，是因为它是「服务返回了什么」的直接延伸：纯函数、无状态、
/// 不碰任何 UI，integration 在提交前调一次即可。
enum TranscriptPostProcessor {

    /// 会被去掉的句末标点，恰好三个 —— 决策 5 逐个列举过，不擅自扩充。
    ///
    /// 特意**不含** `？`/`！`：问号叹号带语气，去掉是信息损失，不是清理。
    /// 也不含 `、`/半角 `,`：它们几乎只出现在句中，出现在句末多半是模型自己断错了句，
    /// 那种情况下删掉它反而抹掉了「这里断错了」的痕迹。
    static let trailingPunctuation: Set<Character> = ["。", ".", "，"]

    /// - Parameters:
    ///   - text: 服务端给的 `TranscribeResponse.text`，未经任何加工。
    ///   - strip: 即 `TranscribeConfig.stripTrailingPunctuation`。
    /// - Returns: 可直接走 IME 提交路径的文本。
    static func polish(_ text: String, stripTrailingPunctuation strip: Bool) -> String {
        // 首尾空白**不受开关控制**，一律裁掉：开关的名字是「去句末标点」，
        // 而模型偶尔带出来的尾换行不是标点，是噪声 —— 把 "\n" 插进用户文档里
        // 任何时候都不是他要的。同时这一步也是尾标点规则能生效的前提：
        // 不先收掉尾部空白，"你好。\n" 的最后一个字符就是换行而不是句号。
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard strip, let last = trimmed.last, trailingPunctuation.contains(last) else {
            return trimmed
        }
        // **只去一个**：「好。。」→「好。」。句中标点一个都不动。
        var polished = trimmed
        polished.removeLast()
        // 英文里模型偶尔写成分开的 "hello ."，删掉句点会留下一个尾空格，一并收掉。
        return polished.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension TranscribeResponse {
    /// 按用户设置加工过、可直接提交的文本。原始 `text` 保持不变，便于诊断时对照。
    func polishedText(stripTrailingPunctuation strip: Bool) -> String {
        TranscriptPostProcessor.polish(text, stripTrailingPunctuation: strip)
    }
}

// MARK: - 热词 context 组装

/// 频次排序词表的供给方。
///
/// 抽成协议，是为了不让 HTTP 客户端反向依赖 ranking / dictionary 层 ——
/// 用户词表的 frecency 怎么算、存在哪（`UserTierIndex` / `FrecencyScore`），
/// 与「往请求里填哪些热词」无关。真实实现由 integration 注入，测试注入假的。
protocol HotwordSupplying {
    /// 按 frecency 从高到低返回至多 `limit` 个用户词。不足则少给，不必补齐。
    ///
    /// 调用时机在**输入路径之外**（录音结束、组装请求时），但也不该是重活：
    /// 用户此刻已经松手在等结果，这里每多花 10 ms 就是他多等 10 ms。
    /// 实现应当是内存索引的读取，不做磁盘扫描、不等锁。
    func topFrecencyWords(limit: Int) -> [String]
}

/// 把「用户手填的热词」和「词表里的高频词」合成 `/transcribe` 的 `context` 字段（决策 10）。
///
/// **context 不是装饰品，填错会倒扣分。** 服务端侧的 A/B 实测过：一份不相关的热词表
/// 会把模型原本就认对的词改错。因此这里的两条规则都是防守性的：
/// 1. 上限绑死时**先砍 frecency**。手填热词是用户明确下达的指令，frecency 是我们的猜测；
///    猜测不该把指令挤出去。
/// 2. 截断只按整词，绝不切半个词。半个词是纯粹的噪声输入，比不给还糟。
enum HotwordContextBuilder {

    /// `context` 总长上限（字符）。
    ///
    /// 这串东西会拼进每一次转写的 prompt 前缀 —— 它的成本是**每次**转写的 prefill，
    /// 而收益随长度递减（列表越长，单个词得到的偏置越薄，撞上无关词的概率越高）。
    /// 200 字符大约容得下 25–60 个词，覆盖得了任何人真正常用的专名表，
    /// 又不至于让整份用户词表倒灌进 prompt。
    static let maxContextCharacters = 200

    /// 单个热词的长度上限。超过这个长度的多半是用户把整句话贴进了热词框，
    /// 那不是热词，而且它一个人就能吃掉大半个预算。
    static let maxWordCharacters = 24

    /// 向供给方一次要多少个词。要得比预算能装下的略多，因为去重会淘汰掉一部分。
    static let frecencyWordLimit = 48

    /// 手填热词的分隔符。设置页写的是「空格分隔」，但中文用户顺手打出「土拨鼠，五笔」
    /// 是必然会发生的事；那样切不开就会变成一个 6 字的假词 —— 正是上面说的倒扣分情形。
    /// 所以这里对分隔符放宽，宁可多切也不要留下假词。
    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "，,、；;/|"))

    /// - Parameters:
    ///   - manual: `TranscribeConfig.hotwords` 原文。
    ///   - supplier: frecency 词源；nil 表示只用手填热词。
    /// - Returns: 空表时返回 nil —— 契约允许省略该键，省略比发 `""` 更干净。
    static func build(manual: String,
                      supplier: HotwordSupplying?,
                      maxCharacters: Int = maxContextCharacters) -> String? {
        var chosen: [String] = []
        var seen = Set<String>()
        var used = 0

        /// 按优先级喂词，遇到装不下的就停，返回「这一批是否全部收完」。
        ///
        /// 停而不是「跳过这个、试试后面更短的」：顺序即优先级，
        /// 让一个低优先级的短词插队挤掉高优先级的长词，就把规则 1 破坏掉了。
        /// 空词、超长词、重复词只是跳过，不算被预算挡住。
        func admit(_ candidates: [String]) -> Bool {
            for word in candidates {
                guard !word.isEmpty, word.count <= maxWordCharacters else { continue }
                guard !seen.contains(word) else { continue }
                let cost = word.count + (chosen.isEmpty ? 0 : 1)   // 词之间一个空格
                guard used + cost <= maxCharacters else { return false }
                chosen.append(word)
                seen.insert(word)
                used += cost
            }
            return true
        }

        // 手填在先：预算不够时被牺牲的一定是 frecency 那一半。
        let manualFitsEntirely = admit(tokenize(manual))

        // 只有手填热词全部装下、且还有余量，才去问词表。
        // 手填都没装完就轮不到 frecency：那时再塞猜出来的词，等于让低优先级的短词
        // 顶掉刚刚被砍掉的手填词 —— 规则 1 要防的正是这件事。
        if manualFitsEntirely, used < maxCharacters, let supplier {
            _ = admit(supplier.topFrecencyWords(limit: frecencyWordLimit).map(sanitize))
        }

        return chosen.isEmpty ? nil : chosen.joined(separator: " ")
    }

    /// 直接吃配置的便捷入口。
    static func build(config: TranscribeConfig, supplier: HotwordSupplying?) -> String? {
        build(manual: config.hotwords, supplier: supplier)
    }

    private static func tokenize(_ raw: String) -> [String] {
        raw.components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// 词表来的词理论上不含空白，但一个带空格的词会在 wire 上被当成两个词，
    /// 于是「上限」和实际生效的词数就对不上了。这里就地收紧。
    private static func sanitize(_ word: String) -> String {
        word.components(separatedBy: separators).filter { !$0.isEmpty }.joined()
    }
}
