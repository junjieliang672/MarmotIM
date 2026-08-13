import XCTest
import Network
@testable import MarmotIM

// MARK: - 打桩用的本地 HTTP 服务

/// 一个只够用来测契约的极简 HTTP/1.1 服务，跑在随机回环端口上。
///
/// 刻意用真实 socket 而不是 URLProtocol 打桩：本目标最重要的一条行为是
/// 「连接被拒绝是正常稳态」，而连接被拒绝这件事只有真的没人监听才能复现。
final class StubASRServer {

    struct Request: Equatable {
        var method: String
        var path: String
        var body: String
    }

    struct Reply {
        var status: Int
        var body: String
        /// 延迟应答，用来复现超时（服务在，只是没按时答）。
        var delay: TimeInterval = 0
    }

    private let handler: (Request) -> Reply
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.marmotim.tests.stub-asr")
    private let lock = NSLock()
    private var _received: [Request] = []
    private var connections: [NWConnection] = []

    private(set) var port: Int = 0

    /// 收到过的请求，按顺序。用来断言「客户端没有偷偷重试」。
    var received: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    init(handler: @escaping (Request) -> Reply) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let assigned = listener.port else {
            listener.cancel()
            throw NSError(domain: "StubASRServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        self.port = Int(assigned.rawValue)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    // MARK: 连接处理

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }
            if let request = StubASRServer.parse(accumulated) {
                self.respond(connection, to: request)
            } else if error == nil && !isComplete {
                self.receive(connection, buffer: accumulated)
            } else {
                connection.cancel()
            }
        }
    }

    /// 返回 nil 表示「还没收全」，继续读。
    private static func parse(_ buffer: Data) -> Request? {
        guard let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<terminator.lowerBound], as: UTF8.self)
        let bodyBytes = buffer[terminator.upperBound...]

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.components(separatedBy: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard bodyBytes.count >= contentLength else { return nil }

        return Request(method: requestLine[0],
                       path: requestLine[1],
                       body: String(decoding: bodyBytes.prefix(contentLength), as: UTF8.self))
    }

    private func respond(_ connection: NWConnection, to request: Request) {
        lock.lock(); _received.append(request); lock.unlock()
        let reply = handler(request)
        let send = {
            let body = Data(reply.body.utf8)
            let head = """
            HTTP/1.1 \(reply.status) \(StubASRServer.reason(reply.status))\r
            Content-Type: application/json\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
            connection.send(content: Data(head.utf8) + body,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
        if reply.delay > 0 {
            queue.asyncAfter(deadline: .now() + reply.delay, execute: send)
        } else {
            send()
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

// MARK: - 测试

/// `ASRClient` 的契约测试：编解码、超时、错误分类。
///
/// 用例顺序刻意从「连接被拒绝」开始，而不是从 happy path 开始 ——
/// 绝大多数机器上服务是不存在的，那才是这个客户端最常走的路径。
final class ASRClientTests: XCTestCase {

    // MARK: 稳态：没人监听

    /// 服务没跑 ⇒ .notRunning，且这是一个「静默」错误：不给用户看，不刷日志。
    func testConnectionRefusedIsSilentAndNotAnError() async throws {
        let server = try StubASRServer { _ in Reply.ok("{}") }
        let deadPort = server.port
        server.stop()

        let client = ASRClient(config: ASRClientConfig(port: deadPort, healthTimeout: 1.0))
        await assertThrows(.notRunning) { try await client.health() }

        XCTAssertTrue(ASRClientError.notRunning.isSilent,
                      "连接被拒绝是功能未启用时的正常稳态，不能变成用户可见报错")
        XCTAssertFalse(ASRClientError.notRunning.isRetryable)
    }

    /// 转写路径上同样静默：没人监听不是「转写失败」，也不该重试。
    func testTranscribeAgainstDeadServerIsNotRunning() async throws {
        let server = try StubASRServer { _ in Reply.ok("{}") }
        let deadPort = server.port
        server.stop()

        let client = ASRClient(config: ASRClientConfig(port: deadPort, transcribeTimeout: 1.0))
        await assertThrows(.notRunning) { try await client.transcribe(sampleRequest()) }
    }

    // MARK: 超时 ≠ 没人监听

    /// 有人监听但没按时应答 ⇒ .timedOut，必须和 .notRunning 区分得开。
    ///
    /// 现实场景：/reload 期间旧模型 close() 释放约 3.5 GB 并持有 GIL，
    /// 实测把一次 /health 拖到 613 ms。那一刻服务是好的，绝不能报成「未安装」。
    func testHealthTimeoutIsDistinctFromConnectionRefused() async throws {
        let server = try StubASRServer { _ in Reply.ok(Self.readyBody, delay: 1.2) }
        defer { server.stop() }

        let client = ASRClient(config: ASRClientConfig(port: server.port, healthTimeout: 0.3))
        await assertThrows(.timedOut(endpoint: .health)) { try await client.health() }

        XCTAssertNotEqual(ASRClientError.timedOut(endpoint: .health), .notRunning)
        XCTAssertFalse(ASRClientError.timedOut(endpoint: .health).isSilent,
                       "超时是有信息量的信号，和「没装」不是一回事")
    }

    /// 转写超时后客户端不重试：服务端对并发请求是排队而非拒绝，
    /// 重试只会再排一次队，把一次推理变成两次。
    func testTranscribeTimeoutDoesNotRetry() async throws {
        let server = try StubASRServer { _ in Reply.ok(Self.transcribeBody, delay: 1.5) }
        defer { server.stop() }

        let client = ASRClient(config: ASRClientConfig(port: server.port, transcribeTimeout: 0.3))
        await assertThrows(.timedOut(endpoint: .transcribe)) { try await client.transcribe(sampleRequest()) }

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.received.count, 1, "客户端不得自行重试")
    }

    // MARK: /health

    func testHealthReadyDecodes() async throws {
        let server = try StubASRServer { request in
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, "/health")
            return Reply.ok(Self.readyBody)
        }
        defer { server.stop() }

        let health = try await ASRClient(config: ASRClientConfig(port: server.port)).health()
        XCTAssertEqual(health.status, "ready")
        XCTAssertEqual(health.model, "mlx-community/Qwen3-ASR-1.7B-bf16")
        XCTAssertEqual(health.modelLoaded, true)
        XCTAssertEqual(health.version, "1")
        XCTAssertNil(health.detail)
    }

    func testHealthLoadingCarriesDetail() async throws {
        let body = #"{"status":"loading","model":"m","model_loaded":false,"version":"1","detail":"model is loading: startup"}"#
        let server = try StubASRServer { _ in Reply.ok(body) }
        defer { server.stop() }

        let health = try await ASRClient(config: ASRClientConfig(port: server.port)).health()
        XCTAssertEqual(health.status, "loading")
        XCTAssertEqual(health.modelLoaded, false)
        XCTAssertEqual(health.detail, "model is loading: startup")
    }

    // MARK: /transcribe

    func testTranscribeSuccessDecodes() async throws {
        let server = try StubASRServer { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/transcribe")
            return Reply.ok(Self.transcribeBody)
        }
        defer { server.stop() }

        let response = try await ASRClient(config: ASRClientConfig(port: server.port))
            .transcribe(sampleRequest())
        XCTAssertEqual(response.text, "你好，今天天气很好。")
        XCTAssertEqual(response.language, "zh")
        XCTAssertEqual(response.duration, 2.31)
        XCTAssertEqual(response.elapsed, 0.84)
    }

    /// 线上编码：可选字段为 nil 时整个键被省略（合成的 encoder 用 encodeIfPresent），
    /// 不会出现字面量 null —— 任何断言 `"max_new_tokens": null` 的测试都是错的。
    func testNilOptionalsAreOmittedFromTheWire() async throws {
        let server = try StubASRServer { _ in Reply.ok(Self.transcribeBody) }
        defer { server.stop() }

        _ = try await ASRClient(config: ASRClientConfig(port: server.port))
            .transcribe(sampleRequest())

        let body = try XCTUnwrap(server.received.first?.body)
        XCTAssertTrue(body.contains("\"audio_base64\""))
        XCTAssertTrue(body.contains("\"sample_rate\":16000") || body.contains("\"sample_rate\" : 16000"))
        XCTAssertFalse(body.contains("language"), "自动检测时不发 language 键（TranscribeLanguage.wireValue 返回 nil）")
        XCTAssertFalse(body.contains("max_new_tokens"), "nil 上限必须省略键，而不是发 null 或 256")
        XCTAssertFalse(body.contains("context"))
    }

    func testExplicitFieldsReachTheWireVerbatim() async throws {
        let server = try StubASRServer { _ in Reply.ok(Self.transcribeBody) }
        defer { server.stop() }

        _ = try await ASRClient(config: ASRClientConfig(port: server.port))
            .transcribe(sampleRequest(language: TranscribeLanguage.chinese.wireValue,
                                      context: "土拨鼠 五笔",
                                      maxNewTokens: 512))

        let body = try XCTUnwrap(server.received.first?.body)
        XCTAssertTrue(body.contains("\"zh\""))
        XCTAssertTrue(body.contains("土拨鼠 五笔"), "热词必须原样透传，不做过滤或改写")
        XCTAssertTrue(body.contains("512"))
    }

    // MARK: 错误分类

    /// 契约里那五个码，逐个走一遍真实 HTTP。
    func testEveryServerErrorCodeMaps() async throws {
        let cases: [(TranscribeServerErrorCode, Int)] = [
            (.modelNotReady, 503),
            (.audioTooShort, 400),
            (.audioTooLong, 400),
            (.badAudio, 400),
            (.inferenceFailed, 500),
        ]
        for (code, status) in cases {
            let server = try StubASRServer { _ in
                Reply(status: status, body: #"{"error":"\#(code.rawValue)","detail":"boom"}"#)
            }
            let client = ASRClient(config: ASRClientConfig(port: server.port, transcribeTimeout: 2))
            await assertThrows(.server(code: code, detail: "boom")) {
                try await client.transcribe(sampleRequest())
            }
            server.stop()
        }
    }

    /// 400 是永久错误，绝不重试；唯一可重试的是 503 model_not_ready。
    func testOnlyModelNotReadyIsRetryable() {
        XCTAssertTrue(ASRClientError.server(code: .modelNotReady, detail: nil).isRetryable)
        for code in TranscribeServerErrorCode.allCases where code != .modelNotReady {
            XCTAssertFalse(ASRClientError.server(code: code, detail: nil).isRetryable,
                           "\(code.rawValue) 不可重试")
        }
        XCTAssertFalse(ASRClientError.timedOut(endpoint: .transcribe).isRetryable)
    }

    func testMalformedSuccessBodyIsMalformedResponse() async throws {
        let server = try StubASRServer { _ in Reply.ok("not json at all{") }
        defer { server.stop() }

        let client = ASRClient(config: ASRClientConfig(port: server.port, transcribeTimeout: 2))
        await assertThrows(.malformedResponse(endpoint: .transcribe)) {
            try await client.transcribe(sampleRequest())
        }
    }

    func testMalformedErrorBodyIsMalformedResponse() async throws {
        let server = try StubASRServer { _ in Reply(status: 500, body: "<html>oops</html>") }
        defer { server.stop() }

        let client = ASRClient(config: ASRClientConfig(port: server.port, transcribeTimeout: 2))
        await assertThrows(.malformedResponse(endpoint: .transcribe)) {
            try await client.transcribe(sampleRequest())
        }
    }

    func testUnknownErrorCodeIsUnexpectedStatus() async throws {
        let server = try StubASRServer { _ in Reply(status: 418, body: #"{"error":"teapot","detail":"?"}"#) }
        defer { server.stop() }

        let client = ASRClient(config: ASRClientConfig(port: server.port, transcribeTimeout: 2))
        await assertThrows(.unexpectedStatus(status: 418, code: "teapot", detail: "?")) {
            try await client.transcribe(sampleRequest())
        }
    }

    // MARK: /reload

    func testReloadAccepts202AndDecodesHealthBody() async throws {
        let server = try StubASRServer { request in
            XCTAssertEqual(request.path, "/reload")
            XCTAssertTrue(request.body.contains(TranscribeModelVariant.qwen0_6B_bf16.rawValue))
            return Reply(status: 202, body: #"{"status":"loading","model":"mlx-community/Qwen3-ASR-0.6B-bf16","model_loaded":false,"version":"1","detail":"model is loading: reload"}"#)
        }
        defer { server.stop() }

        let health = try await ASRClient(config: ASRClientConfig(port: server.port))
            .reload(model: TranscribeModelVariant.qwen0_6B_bf16.rawValue)
        XCTAssertEqual(health.status, "loading")
    }

    /// bad_model 是只存在于 /reload 的第六个码，就地处理，不进那个封闭的五值枚举。
    func testBadModelIsHandledLocallyAndIsNotInTheFiveCodeEnum() async throws {
        XCTAssertNil(TranscribeServerErrorCode(rawValue: "bad_model"))

        let server = try StubASRServer { _ in
            Reply(status: 400, body: #"{"error":"bad_model","detail":"model not in allowlist"}"#)
        }
        defer { server.stop() }

        let client = ASRClient(config: ASRClientConfig(port: server.port))
        await assertThrows(.badModel(detail: "model not in allowlist")) {
            try await client.reload(model: "evil/model")
        }
    }

    // MARK: 配置

    /// 非回环主机一律被拉回 127.0.0.1：音频永远不出本机。
    func testNonLoopbackHostFallsBackToLoopback() {
        XCTAssertEqual(ASRClientConfig(host: "192.168.1.5", port: 58471).baseURLString,
                       "http://127.0.0.1:58471")
        XCTAssertEqual(ASRClientConfig(host: "evil.example.com", port: 9).baseURLString,
                       "http://127.0.0.1:9")
        XCTAssertEqual(ASRClientConfig(host: "localhost", port: 1).baseURLString,
                       "http://localhost:1")
        XCTAssertEqual(ASRClientConfig(host: "::1", port: 1).baseURLString,
                       "http://[::1]:1")
    }

    /// 超时来自配置：health 固定 1 s（契约常量），transcribe 跟随用户设置。
    func testTimeoutsComeFromConfiguration() {
        let derived = ASRClientConfig(TranscribeConfig.default)
        XCTAssertEqual(derived.healthTimeout, 1.0)
        XCTAssertEqual(derived.transcribeTimeout, 15.0)
        XCTAssertEqual(derived.port, 58471)

        var custom = TranscribeConfig.default
        custom.requestTimeoutSeconds = 30
        custom.port = 60000
        XCTAssertEqual(ASRClientConfig(custom).transcribeTimeout, 30)
        XCTAssertEqual(ASRClientConfig(custom).port, 60000)
    }

    func testASRClientTypeExists() {
        XCTAssertNotNil(ASRClient())
    }

    /// The five server error codes are pinned by the HTTP contract; if this
    /// list changes, reference-api-contract.md changed first.
    func testServerErrorCodeRawValues() {
        XCTAssertEqual(
            Set(TranscribeServerErrorCode.allCases.map { $0.rawValue }),
            ["model_not_ready", "audio_too_short", "audio_too_long", "bad_audio", "inference_failed"]
        )
    }

    // MARK: - Helpers

    private typealias Reply = StubASRServer.Reply

    private static let readyBody = #"{"status":"ready","model":"mlx-community/Qwen3-ASR-1.7B-bf16","model_loaded":true,"version":"1","detail":null}"#
    private static let transcribeBody = #"{"text":"你好，今天天气很好。","language":"zh","duration":2.31,"elapsed":0.84}"#

    private func sampleRequest(language: String? = nil,
                               context: String? = nil,
                               maxNewTokens: Int? = nil) -> TranscribeRequest {
        TranscribeRequest(audioBase64: "AAAAAAAAAAA=",
                          sampleRate: 16000,
                          language: language,
                          context: context,
                          maxNewTokens: maxNewTokens)
    }

    private func assertThrows<T>(_ expected: ASRClientError,
                                 file: StaticString = #filePath,
                                 line: UInt = #line,
                                 _ operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected), got a value", file: file, line: line)
        } catch let error as ASRClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private extension StubASRServer.Reply {
    static func ok(_ body: String, delay: TimeInterval = 0) -> StubASRServer.Reply {
        StubASRServer.Reply(status: 200, body: body, delay: delay)
    }
}

// MARK: - 去尾标点（决策 5）

/// 规则很小，但它作用在**每一次**转写结果上，且服务端已明确不做任何改写 ——
/// 这里错一个字符，用户就得手动删一个字符，每次。
final class TranscriptPostProcessorTests: XCTestCase {

    private func polish(_ text: String, strip: Bool = true) -> String {
        TranscriptPostProcessor.polish(text, stripTrailingPunctuation: strip)
    }

    /// 决策 5 逐个列举的三个标点，逐个走一遍。
    func testStripsExactlyTheThreeListedMarks() {
        XCTAssertEqual(polish("你好，今天天气很好。"), "你好，今天天气很好")
        XCTAssertEqual(polish("hello world."), "hello world")
        XCTAssertEqual(polish("嗯我想想，"), "嗯我想想")
    }

    /// 只去一个。连着两个句号是模型的毛病，但删光了就不再是「去尾标点」而是重写句子。
    func testStripsAtMostOneMark() {
        XCTAssertEqual(polish("好。。"), "好。")
        XCTAssertEqual(polish("等等...", strip: true), "等等..")
    }

    /// 句中标点一个都不许动 —— 决策 5 明说保留模型给出的内部标点。
    func testInternalPunctuationSurvives() {
        XCTAssertEqual(polish("你好，世界，再见。"), "你好，世界，再见")
        XCTAssertEqual(polish("A. B. C."), "A. B. C")
    }

    /// 问号叹号带语气，删掉是信息损失；顿号、半角逗号不在决策里，不擅自扩充。
    func testMarksOutsideTheListAreKept() {
        for text in ["你吃了吗？", "太好了！", "苹果、香蕉、梨、", "yes,", "结束…"] {
            XCTAssertEqual(polish(text), text, "\(text) 的句末标点不在决策 5 的三个之内")
        }
    }

    /// 开关关掉 ⇒ 标点原样保留。
    func testDisabledKeepsPunctuation() {
        XCTAssertEqual(polish("你好，今天天气很好。", strip: false), "你好，今天天气很好。")
        XCTAssertEqual(polish("hello.", strip: false), "hello.")
    }

    /// 尾部空白不受开关控制：开关的名字是「去句末标点」，换行不是标点，是噪声。
    /// 把 "\n" 提交进用户的文档里，任何配置下都不是他想要的。
    func testSurroundingWhitespaceIsAlwaysTrimmed() {
        XCTAssertEqual(polish("  你好。\n", strip: false), "你好。")
        XCTAssertEqual(polish("\n\t你好 \n", strip: false), "你好")
    }

    /// 而且这一步是尾标点规则能生效的前提：不先收掉尾换行，最后一个字符就不是句号。
    func testTrailingNewlineDoesNotHideThePunctuation() {
        XCTAssertEqual(polish("你好。\n"), "你好")
        XCTAssertEqual(polish("hello. "), "hello")
        // 英文里分写的 "hello ." 删掉句点后留下的尾空格也要收掉。
        XCTAssertEqual(polish("hello ."), "hello")
    }

    /// 边界：整段就是一个标点、或者本来就是空的。提交空串等于什么都不提交，可以接受。
    func testDegenerateInputs() {
        XCTAssertEqual(polish("。"), "")
        XCTAssertEqual(polish(""), "")
        XCTAssertEqual(polish("   \n  "), "")
        XCTAssertEqual(polish("好"), "好")
    }

    /// 便捷入口和裸函数必须给出同一个结果，否则 integration 走哪个都得先猜。
    func testResponseConvenienceMatchesTheFunction() {
        let response = TranscribeResponse(text: "你好。", language: "zh", duration: 1, elapsed: 0.2)
        XCTAssertEqual(response.polishedText(stripTrailingPunctuation: true), "你好")
        XCTAssertEqual(response.polishedText(stripTrailingPunctuation: false), "你好。")
        XCTAssertEqual(response.text, "你好。", "原始文本必须保持原样，便于诊断时对照")
    }
}

// MARK: - 热词 context 组装（决策 10）

/// 假词源。记录被问了几次、要了多少个 —— 「预算满了就别去打扰词表」这条要靠它来断言。
private final class FakeHotwordSupplier: HotwordSupplying {
    var words: [String]
    private(set) var callCount = 0
    private(set) var lastLimit: Int?

    init(_ words: [String]) { self.words = words }

    func topFrecencyWords(limit: Int) -> [String] {
        callCount += 1
        lastLimit = limit
        return Array(words.prefix(limit))
    }
}

/// context 填错会**倒扣分**（服务端侧 A/B 实测：不相关的热词会把模型原本认对的词改错），
/// 所以这里的用例重点不在「装了多少词」，而在「该被砍的时候砍对了哪一半」。
final class HotwordContextBuilderTests: XCTestCase {

    func testManualOnly() {
        XCTAssertEqual(HotwordContextBuilder.build(manual: "土拨鼠 五笔", supplier: nil),
                       "土拨鼠 五笔")
    }

    func testEmptySourcesProduceNilNotEmptyString() {
        XCTAssertNil(HotwordContextBuilder.build(manual: "", supplier: nil))
        XCTAssertNil(HotwordContextBuilder.build(manual: "   \n  ", supplier: FakeHotwordSupplier([])))
    }

    /// 手填在先，词表在后 —— 顺序即优先级。
    func testManualComesFirstThenFrecency() {
        let supplier = FakeHotwordSupplier(["频率", "候选窗"])
        XCTAssertEqual(HotwordContextBuilder.build(manual: "土拨鼠 五笔", supplier: supplier),
                       "土拨鼠 五笔 频率 候选窗")
        XCTAssertEqual(supplier.callCount, 1)
        XCTAssertEqual(supplier.lastLimit, HotwordContextBuilder.frecencyWordLimit)
    }

    /// 同一个词在两边都出现时只发一次，且留在手填给的位置上。
    func testDuplicatesAcrossSourcesAreDroppedKeepingTheEarlierPosition() {
        let supplier = FakeHotwordSupplier(["频率", "土拨鼠", "五笔"])
        XCTAssertEqual(HotwordContextBuilder.build(manual: "土拨鼠 五笔", supplier: supplier),
                       "土拨鼠 五笔 频率")
    }

    /// 中文用户顺手打出「土拨鼠，五笔」是必然的。切不开就会变成一个 6 字假词 ——
    /// 而假词正是会把认对的词改错的那种输入。
    func testLiberalSeparators() {
        XCTAssertEqual(HotwordContextBuilder.build(manual: "土拨鼠，五笔、拼音；候选\n频率", supplier: nil),
                       "土拨鼠 五笔 拼音 候选 频率")
    }

    /// 上限绑死时**先砍 frecency**：手填是用户的指令，frecency 只是我们的猜测。
    func testFrecencyIsTheHalfThatLosesWhenTheCapBinds() throws {
        let manual = "甲 乙 丙 丁 戊 己 庚 辛"   // 8 个词 + 7 个空格 = 15 字符
        let supplier = FakeHotwordSupplier(["频率", "候选窗"])

        let context = try XCTUnwrap(HotwordContextBuilder.build(manual: manual,
                                                               supplier: supplier,
                                                               maxCharacters: 18))
        // 15 + 1 + 2 = 18 恰好装下第一个词表词；第二个要 4 个字符，装不下。
        XCTAssertEqual(context, manual + " 频率")
        XCTAssertFalse(context.contains("候选窗"), "预算绑死时被砍的必须是 frecency 那一半")
    }

    /// 手填热词自己就超了预算：按顺序丢尾巴，并且**根本不去问词表** ——
    /// 那时再塞猜出来的短词，等于让低优先级的词顶掉刚被砍掉的手填词。
    func testManualOverflowDropsItsTailAndNeverQueriesTheSupplier() {
        let supplier = FakeHotwordSupplier(["短"])
        let context = HotwordContextBuilder.build(manual: "甲甲甲 乙乙乙 丙丙丙",
                                                  supplier: supplier,
                                                  maxCharacters: 7)
        XCTAssertEqual(context, "甲甲甲 乙乙乙")
        XCTAssertEqual(supplier.callCount, 0, "手填都没装完，就轮不到 frecency")
    }

    /// 截断只按整词。半个词是纯噪声，比不给还糟。
    func testTruncationNeverCutsAWordInHalf() throws {
        let context = try XCTUnwrap(HotwordContextBuilder.build(manual: "土拨鼠 五笔输入法",
                                                               supplier: nil,
                                                               maxCharacters: 6))
        XCTAssertEqual(context, "土拨鼠")
        XCTAssertFalse(context.contains("五"), "不得出现半个「五笔输入法」")
    }

    /// 整句话被贴进热词框：它一个人就能吃掉大半预算，直接丢掉，但不影响后面的正常词。
    func testOverlongTokenIsSkippedWithoutStoppingTheRest() {
        let sentence = String(repeating: "长", count: HotwordContextBuilder.maxWordCharacters + 1)
        XCTAssertEqual(HotwordContextBuilder.build(manual: "\(sentence) 五笔", supplier: nil),
                       "五笔")
    }

    /// 词表给回带空格的词会在 wire 上被当成两个词，令「上限」和实际词数对不上，就地收紧。
    func testSupplierWordsWithWhitespaceAreCollapsed() {
        let supplier = FakeHotwordSupplier(["五 笔", "拼音"])
        XCTAssertEqual(HotwordContextBuilder.build(manual: "", supplier: supplier), "五笔 拼音")
    }

    /// 默认预算是有上限的，且组装结果确实受它约束（防止有人把上限改成 Int.max）。
    func testDefaultCapIsEnforced() throws {
        let many = (0..<500).map { "词\($0)" }
        let context = try XCTUnwrap(HotwordContextBuilder.build(manual: "",
                                                               supplier: FakeHotwordSupplier(many)))
        XCTAssertLessThanOrEqual(context.count, HotwordContextBuilder.maxContextCharacters)
        XCTAssertFalse(context.isEmpty)
    }

    /// 组装出来的 context 必须能原样上 wire（客户端不得再做二次改写）。
    func testAssembledContextReachesTheWireVerbatim() async throws {
        let server = try StubASRServer { _ in
            StubASRServer.Reply(status: 200,
                                body: #"{"text":"好","language":"zh","duration":1,"elapsed":0.1}"#)
        }
        defer { server.stop() }

        var config = TranscribeConfig.default
        config.hotwords = "土拨鼠，五笔"
        let context = HotwordContextBuilder.build(config: config,
                                                  supplier: FakeHotwordSupplier(["频率"]))
        XCTAssertEqual(context, "土拨鼠 五笔 频率")

        _ = try await ASRClient(config: ASRClientConfig(port: server.port))
            .transcribe(TranscribeRequest(audioBase64: "AAAAAAAAAAA=",
                                          sampleRate: 16000,
                                          language: nil,
                                          context: context,
                                          maxNewTokens: nil))
        let body = try XCTUnwrap(server.received.first?.body)
        XCTAssertTrue(body.contains("土拨鼠 五笔 频率"))
    }
}
