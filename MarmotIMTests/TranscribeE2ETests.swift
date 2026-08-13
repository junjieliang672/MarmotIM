import XCTest
@testable import MarmotIM

// MARK: - 归一化与模糊比对

/// 转写结果的比对器。**绝不做逐字相等** —— ASR 输出会随模型版本、温度、
/// 甚至同一段音频的重复提交而微变，逐字相等的断言只会变成一台产生 flaky 的机器，
/// 然后在第三次红之后被人 disable 掉，从此永远绿着什么也不证明。
///
/// 两条规则，方向相反，缺一不可：
/// 1. **宽到能容错**：空白、句末标点、大小写、全半角差异一律抹平，个别字错也仍算通过。
/// 2. **窄到会红**：另一句同样长度的真话必须被拒。否则"通过"没有信息量。
///
/// 阈值是**契约**不是旋钮。下面 `testMatcher…` 那几条从两侧把它钉死：调高会让容错用例红，
/// 调低会让拒斥用例红。模型认错了字就换 fixture，不要动这个数 ——
/// 一个被调松到能通过的归一化器，是唯一一种永远绿着的失败。
enum TranscriptMatcher {

    /// 归一化相似度的通过线。
    ///
    /// 0.85 的来历是取短句的可容忍错字数：一句 9 字的中文允许错 1 个字（8/9 = 0.89 通过，
    /// 7/9 = 0.78 不通过），一句 35 字的英文允许错 5 个字符。再松，两句不同的短句就开始
    /// 互相通过；再紧，一个同音字就红。
    static let threshold = 0.85

    /// 比对前的归一化。
    ///
    /// **空白整个删掉**而不是折叠成一个空格：中文侧模型是否在词间加空格纯属随机，
    /// 英文侧两边同样处理因此词界并不丢失（字符序列本身带着它）。
    /// 标点整类删掉而不只删句末：决策 5 的去尾标点是**提交路径**的事，
    /// 比对这一侧应当对句中标点也免疫，模型在哪儿断句不是本测试要断言的东西。
    static func normalize(_ text: String) -> String {
        let folded = text
            .precomposedStringWithCompatibilityMapping   // 全角字母数字 → 半角
            .lowercased()
        return String(folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        })
    }

    /// 归一化后的字符级编辑距离相似度，`1 - distance / max(count)`。
    ///
    /// 两侧都空时返回 0 而不是 1：一个空的期望值与一个空的转写"完全一致"，
    /// 正是本测试最需要拒绝的那种空过。
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(normalize(lhs))
        let b = Array(normalize(rhs))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let distance = levenshtein(a, b)
        return 1.0 - Double(distance) / Double(max(a.count, b.count))
    }

    static func matches(_ actual: String, expected: String) -> Bool {
        similarity(actual, expected) >= threshold
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

// MARK: - WAV fixture 解码

/// 一段解出来的 fixture 音频。
struct WAVFixture {
    let samples: [Float]
    let sampleRate: Int
    let channelCount: Int

    var duration: Double { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }
}

enum WAVFixtureError: Error, CustomStringConvertible {
    case notRIFFWAVE
    case truncated(String)
    case unsupportedFormat(code: Int, bits: Int)
    case wrongShape(sampleRate: Int, channels: Int)

    var description: String {
        switch self {
        case .notRIFFWAVE:
            return "不是 RIFF/WAVE 文件"
        case .truncated(let what):
            return "文件被截断：读不到 \(what)"
        case .unsupportedFormat(let code, let bits):
            return "不支持的采样格式 audioFormat=\(code) bits=\(bits)（只接受 PCM16 与 float32）"
        case .wrongShape(let sampleRate, let channels):
            return "fixture 必须是 16000 Hz 单声道，实际为 \(sampleRate) Hz \(channels) 声道"
        }
    }
}

/// 最小 WAV 解析器：RIFF 头 + fmt + data，PCM16 或 float32。
///
/// 手写而不是用 `AVAudioFile`，是因为这里同时要当**格式校验**用：fixture 采样率或声道数
/// 不对时，服务端 `decode_pcm()` 会以 400 回绝，那在客户端看起来是一个传输错误而不是
/// "fixture 录错了"。让错误在读文件这一步就说人话，比在 HTTP 那一步猜要好。
enum WAVFixtureDecoder {

    static func decode(_ data: Data) throws -> WAVFixture {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) throws -> Int {
            guard offset + 2 <= bytes.count else { throw WAVFixtureError.truncated("offset \(offset) 处的 16 位字段") }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset + 4 <= bytes.count else { throw WAVFixtureError.truncated("offset \(offset) 处的 32 位字段") }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        func fourCC(_ offset: Int) throws -> String {
            guard offset + 4 <= bytes.count else { throw WAVFixtureError.truncated("offset \(offset) 处的块标识") }
            return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
        }

        guard bytes.count >= 12, try fourCC(0) == "RIFF", try fourCC(8) == "WAVE" else {
            throw WAVFixtureError.notRIFFWAVE
        }

        var audioFormat = 0, channels = 0, sampleRate = 0, bitsPerSample = 0
        var payload: ArraySlice<UInt8>?
        var cursor = 12

        // 块遍历而不是假定 fmt 紧跟其后：`afconvert` 与 QuickTime 都会插 LIST/fact 块。
        while cursor + 8 <= bytes.count {
            let id = try fourCC(cursor)
            let size = try u32(cursor + 4)
            let body = cursor + 8
            guard size >= 0, body + size <= bytes.count else {
                throw WAVFixtureError.truncated("\(id) 块声明的 \(size) 字节")
            }
            switch id {
            case "fmt ":
                audioFormat = try u16(body)
                channels = try u16(body + 2)
                sampleRate = try u32(body + 4)
                bitsPerSample = try u16(body + 14)
                // WAVE_FORMAT_EXTENSIBLE：真正的格式码在 GUID 的头两字节里。
                if audioFormat == 0xFFFE, size >= 26 {
                    audioFormat = try u16(body + 24)
                }
            case "data":
                payload = bytes[body..<(body + size)]
            default:
                break
            }
            cursor = body + size + (size % 2)   // 块按偶数字节对齐
        }

        guard let payload else { throw WAVFixtureError.truncated("data 块") }

        let samples: [Float]
        switch (audioFormat, bitsPerSample) {
        case (1, 16):
            samples = stride(from: payload.startIndex, to: payload.endIndex - 1, by: 2).map { i in
                let raw = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
                return Float(raw) / 32768.0
            }
        case (3, 32):
            samples = stride(from: payload.startIndex, to: payload.endIndex - 3, by: 4).map { i in
                let raw = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                    | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                return Float(bitPattern: raw)
            }
        default:
            throw WAVFixtureError.unsupportedFormat(code: audioFormat, bits: bitsPerSample)
        }

        return WAVFixture(samples: samples, sampleRate: sampleRate, channelCount: channels)
    }

    /// 解码并强制 fixture 契约：16 kHz 单声道。服务端只收这一种。
    static func decodeStrict(_ data: Data) throws -> WAVFixture {
        let fixture = try decode(data)
        guard fixture.sampleRate == 16000, fixture.channelCount == 1 else {
            throw WAVFixtureError.wrongShape(sampleRate: fixture.sampleRate, channels: fixture.channelCount)
        }
        return fixture
    }
}

// MARK: - fixture 与期望文本

/// `<name>.expected.json` 的内容 —— 期望转写与它的来龙去脉。
///
/// `source` 存在的唯一理由：合成语音（`/usr/bin/say`）足以证明**链路**通，
/// 但它不是关于真人麦克风识别率的证据。读到这个测试通过的人不该把前者误读成后者。
struct TranscribeFixtureExpectation: Codable {
    /// 人工核对过的期望转写。
    let text: String
    /// 期望语种（"zh" / "en"）。请求本身发的是 auto，这里只用于校验自动识别的结果。
    let language: String
    /// "microphone"（真人录音）或 "tts"（合成）。
    let source: String
    let note: String?
}

/// 一对 `<name>.wav` + `<name>.expected.json`。
struct TranscribeFixture {
    let name: String
    let audioURL: URL
    let expectation: TranscribeFixtureExpectation
}

// MARK: - 端到端

/// 把一段签入仓库的音频，经真实本地 ASR 服务，跑到一个**模糊**断言上。
///
/// ## 三道闸门，跳过而不是失败（决策 22）
/// 1. `MARMOT_TRANSCRIBE_E2E=1` 没设 —— 默认 `swift test` 不该背上一次真模型推理的秒数；
/// 2. fixture 没签入 —— 录音是人工环节，见 `MarmotIMTests/Fixtures/README.md`；
/// 3. 服务没跑或模型没加载 —— 没装这套东西的机器（含 CI）必须绿。
///
/// ## 这套断言能不能红
/// 上面 `testMatcher…` 那一组用例是本文件的反空过装置：它们不碰网络、不碰 fixture，
/// 因此在跳过闸门全部生效时**照样运行**。没有它们，本文件在一台没装模型的机器上
/// 全部跳过，看起来是绿的，而实际上归一化器有没有被写对一个字节都没验过。
final class TranscribeE2ETests: XCTestCase {

    /// 打开慢速真模型用例的环境变量。
    ///
    /// 用环境变量而不是 `MarmotIM.xctestplan` 的 `skippedTests`，是因为本仓库的测试
    /// **只经 SwiftPM 运行**：Xcode 工程里没有测试 target，`MarmotIM.xctestplan` 和
    /// `.xcscheme` 引用的那个 target id 在 `project.pbxproj` 里根本不存在。
    /// 在一个没人执行的测试计划里登记，是纸面工作；env 闸门才是真正生效的那一道。
    /// （测试计划一侧仍然登记了跳过项，见该文件 —— 万一将来补上测试 target，
    /// 默认的 ⌘U 行为与这里一致。）
    static let gateVariable = "MARMOT_TRANSCRIBE_E2E"

    static var fixturesDirectory: URL? {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)
    }

    /// 读一对 fixture。wav 缺失返回 nil（跳过）；wav 在而 sidecar 不在则**抛错**——
    /// 那是坏掉的 fixture，不是"还没录"，静默跳过会把它藏起来。
    static func fixture(named name: String) throws -> TranscribeFixture? {
        guard let dir = fixturesDirectory else { return nil }
        let audio = dir.appendingPathComponent("\(name).wav")
        guard FileManager.default.fileExists(atPath: audio.path) else { return nil }

        let sidecar = dir.appendingPathComponent("\(name).expected.json")
        let data = try Data(contentsOf: sidecar)
        let expectation = try JSONDecoder().decode(TranscribeFixtureExpectation.self, from: data)
        return TranscribeFixture(name: name, audioURL: audio, expectation: expectation)
    }

    /// 闸门 1 + 2。返回可用的 fixture，或抛出 `XCTSkip`。
    func requireFixture(_ name: String) throws -> TranscribeFixture {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.gateVariable] == "1",
            "慢速真模型用例默认关闭。开启：\(Self.gateVariable)=1 swift test --filter TranscribeE2ETests"
        )
        guard let fixture = try Self.fixture(named: name) else {
            throw XCTSkip("""
                缺少 MarmotIMTests/Fixtures/\(name).wav —— 录音是人工环节。
                所需内容与格式见 MarmotIMTests/Fixtures/README.md。
                """)
        }
        return fixture
    }

    /// 闸门 3。服务端就绪才继续，否则跳过并说明怎么把它装起来。
    func requireReadyServer() async throws -> ASRClient {
        let client = ASRClient(config: ASRClientConfig(healthTimeout: 2.0, transcribeTimeout: 60.0))
        let health: HealthResponse
        do {
            health = try await client.health()
        } catch {
            throw XCTSkip("""
                本地 ASR 服务不可达（\(error)）。装它：bash scripts/install_asr.sh，
                随后 launchctl list | grep com.marmotim.asr 应能看到它在跑。
                """)
        }
        try XCTSkipUnless(
            health.status == "ready",
            "ASR 服务在跑但未就绪（status=\(health.status)，model=\(health.model ?? "?")）—— 模型仍在加载或加载失败。"
        )
        return client
    }

    /// 提交一段 fixture，返回服务端原样输出。
    ///
    /// **请求是手工组装的，不走 `TranscribeCoordinator` 的采集侧**：本测试要证明的是
    /// 音频→文本这条链路，而不是热键与录音机（那两者各有自己的用例）。因此：
    /// · `context` 显式钉成 nil —— 生产路径会把用户词表的高频词灌进去，
    ///   而热词是能把模型原本认对的词改错的（见 `HotwordContextBuilder` 的注释）。
    ///   一个随运行机器的用户词表而变的断言，红了也没人知道该看哪。
    /// · `sampleRate` 取自解码结果并已被 `decodeStrict` 钉死为 16000 ——
    ///   请求组装在生产侧是从录音机读的，这里没有录音机。
    /// · base64 编码复用 `TranscribeCoordinator.encodePCM` —— 生产路径发的就是这一份代码，
    ///   重写一遍等于在测一个没人发货的编码器。
    func submit(_ fixture: TranscribeFixture, to client: ASRClient) async throws -> TranscribeResponse {
        let audio = try WAVFixtureDecoder.decodeStrict(Data(contentsOf: fixture.audioURL))
        let request = TranscribeRequest(
            audioBase64: TranscribeCoordinator.encodePCM(audio.samples),
            sampleRate: audio.sampleRate,
            language: nil,          // auto —— 语种自动识别正是本组用例要证明的
            context: nil,
            maxNewTokens: nil
        )
        return try await client.transcribe(request)
    }

    /// sidecar 里的 ISO 码 → 服务端可能回的语种**名**。
    ///
    /// 服务端回的 `language` 不是 `"zh"` / `"en"`，而是模型自己生成的语种名：
    /// qwen3_asr_mlx 的 `TranscriptionResult.language` 文档就写着 e.g. `"English"`
    /// （`model.py` 的 dataclass 注释），值来自 `parse_language_and_output` 从
    /// `language {name}<asr_text>` 前缀里切出来的 `{name}`（`tokenizer.py`），
    /// `server/app.py` 把 `result.language` 原样透传。
    /// 所以 `detected.hasPrefix("zh")` 这类写法对中文**永远不成立** —— 本方法就是为
    /// 修掉那个写法而存在的。
    static let acceptedLanguageNames: [String: Set<String>] = [
        "zh": ["chinese", "mandarin", "chinese (mandarin)", "zh"],
        "en": ["english", "en"],
    ]

    /// 语种自动识别的断言。
    ///
    /// **两个语种的证据强度并不对称，这一点必须写下来而不是默认它们一样。**
    /// `parse_language_and_output` 的 `default_language` 参数默认就是 `"English"`：
    /// 模型若压根没吐出 `language …<asr_text>` 前缀，库会**替它填上 "English"**。
    /// 因此英文 fixture 回 `"English"` 并不单独证明自动识别发生过；
    /// 而中文 fixture 回 `"Chinese"` 只可能来自模型自己生成的前缀 —— 那一条才是承重的。
    /// （空音频的早返回会回 `"Unknown"`，两边都不该接受。）
    func assertDetectedLanguage(_ response: TranscribeResponse,
                                matches fixture: TranscribeFixture,
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        // 不用 `if let` 静默放过：language 缺席时，"自动识别跨语种可用"这条验收标准
        // 就没有任何证据，而一个从没执行过的条件体看起来和通过一模一样。
        guard let raw = response.language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return XCTFail("""
                \(fixture.name)：服务端没回 language。请求里 language 是省略的（auto），
                所以这一条本该带回模型判定的语种；没有它，语种自动识别就只剩推测。
                """, file: file, line: line)
        }
        let code = fixture.expectation.language.lowercased()
        let accepted = Self.acceptedLanguageNames[code] ?? [code]
        XCTAssertTrue(
            accepted.contains(raw.lowercased()),
            "\(fixture.name)：语种自动识别成了「\(raw)」，期望 \(code)（可接受：\(accepted.sorted().joined(separator: "/"))）",
            file: file, line: line
        )
    }

    /// 一次通用的断言：模糊匹配 + 自动识别出的语种。
    func assertTranscript(_ response: TranscribeResponse,
                          matches fixture: TranscribeFixture,
                          file: StaticString = #filePath,
                          line: UInt = #line) {
        let expected = fixture.expectation.text
        let polished = response.polishedText(stripTrailingPunctuation: true)
        let score = TranscriptMatcher.similarity(polished, expected)
        XCTAssertTrue(
            TranscriptMatcher.matches(polished, expected: expected),
            """
            \(fixture.name)：转写与期望差得太远（相似度 \(String(format: "%.3f", score))，通过线 \(TranscriptMatcher.threshold)）
              期望：\(expected)
              实得：\(polished)
            模型认错了字就换一段更清楚的 fixture，不要调低通过线。
            """,
            file: file, line: line
        )
        assertDetectedLanguage(response, matches: fixture, file: file, line: line)
    }

    // MARK: - 真链路

    func testChineseFixtureTranscribesEndToEnd() async throws {
        let fixture = try requireFixture("zh-short")
        let client = try await requireReadyServer()
        let response = try await submit(fixture, to: client)
        assertTranscript(response, matches: fixture)
    }

    /// 英文那一条存在的理由不是"再测一遍"，而是**语种自动识别**：
    /// 请求里 `language` 被整个省略（`testAutoLanguageOmitsTheLanguageField` 钉的就是这个），
    /// 服务端因此必须自己判断。同一套断言跑在另一个语种上，才说明它判的是音频而不是默认值。
    func testEnglishFixtureTranscribesEndToEndUnderAutoLanguage() async throws {
        let fixture = try requireFixture("en-short")
        let client = try await requireReadyServer()
        let response = try await submit(fixture, to: client)
        assertTranscript(response, matches: fixture)
    }

    // MARK: - 反空过：比对器自身

    /// 正控：归一化该抹平的差异确实被抹平了。
    func testNormalizerErasesWhitespaceAndPunctuation() {
        let expected = "土拨鼠输入法很好用"
        XCTAssertEqual(TranscriptMatcher.similarity("土拨鼠输入法很好用。", expected), 1.0,
                       "句末句号必须被抹平")
        XCTAssertEqual(TranscriptMatcher.similarity(" 土拨鼠，输入法很好用！\n", expected), 1.0,
                       "首尾空白、句中逗号、叹号都不该影响比对")
        XCTAssertEqual(TranscriptMatcher.similarity("The quick brown fox.", "the quick  brown fox"), 1.0,
                       "英文侧大小写与多余空格同样被抹平")
    }

    /// 正控：真实 ASR 会犯的那类小错（同音字、单字之差）仍然通过。
    /// 没有这一条，通过线可以被无限调高，测试就退化成逐字相等。
    func testMatcherStillAcceptsARealisticSingleCharacterError() {
        let expected = "土拨鼠输入法很好用"
        XCTAssertTrue(TranscriptMatcher.matches("土拨鼠输入法很好用", expected: expected))
        XCTAssertTrue(TranscriptMatcher.matches("土拔鼠输入法很好用", expected: expected),
                      "一个同音错字必须仍算通过，否则这就不是模糊比对")
    }

    /// 负控：另一句**同样长度的真话**必须被拒。
    /// 这一条是本文件唯一能证明"通过"有信息量的东西 —— 少了它，
    /// 把通过线调到 0 也能让全部端到端用例变绿。
    func testMatcherRejectsADifferentSentenceOfTheSameLength() {
        let expected = "土拨鼠输入法很好用"
        XCTAssertFalse(TranscriptMatcher.matches("今天天气真不错啊", expected: expected),
                       "不相干的一句话不得通过")
        XCTAssertFalse(TranscriptMatcher.matches("输入法", expected: expected),
                       "只转出三分之一也不得通过")
        XCTAssertFalse(TranscriptMatcher.matches("", expected: expected),
                       "空转写不得通过")
        XCTAssertFalse(TranscriptMatcher.matches("", expected: ""),
                       "两边都空也不得算一致 —— 那是最典型的空过")
    }

    // MARK: - 反空过：语种映射表自身

    /// 正控 + 负控：语种表认得模型真会回的那些字符串，且不会把两个语种混为一谈。
    ///
    /// 这一条不碰网络也不碰 fixture，因此在真链路全跳过的机器上照样运行。
    /// 它挡住的具体错误是本文件自己犯过的一个：原先写的是
    /// `detected.hasPrefix("zh")` —— 中文回 `"Chinese"` 时恒为假（本该通过的会红），
    /// 而英文回 `"English"` 时恰好为真（"en" 是 "english" 的前缀），
    /// 于是一个两侧都错的判断在英文那侧看起来是对的。
    func testLanguageTableMapsTheNamesTheModelActuallyReturns() {
        func accepts(_ code: String, _ name: String) -> Bool {
            (TranscribeE2ETests.acceptedLanguageNames[code] ?? []).contains(name.lowercased())
        }
        XCTAssertTrue(accepts("zh", "Chinese"), "模型回的是语种名而不是 ISO 码")
        XCTAssertTrue(accepts("zh", "Mandarin"))
        XCTAssertTrue(accepts("en", "English"))
        XCTAssertFalse(accepts("zh", "English"), "英文不得算作中文")
        XCTAssertFalse(accepts("en", "Chinese"))
        XCTAssertFalse(accepts("zh", "Unknown"), "空音频的早返回回的就是 Unknown，不是一次成功的识别")
        XCTAssertFalse(accepts("en", "Unknown"))
    }

    // MARK: - 反空过：WAV 解码器自身

    /// 正控：解码器确实看得见样本。
    /// 手工拼一段 PCM16 WAV，逐样本核对，证明上面的 `submit` 不是在把空数组发出去。
    func testDecoderReadsKnownPCM16Samples() throws {
        let raw: [Int16] = [0, 16384, -16384, 32767, -32768]
        let wav = Self.makePCM16WAV(raw, sampleRate: 16000, channels: 1)
        let fixture = try WAVFixtureDecoder.decodeStrict(wav)

        XCTAssertEqual(fixture.sampleRate, 16000)
        XCTAssertEqual(fixture.channelCount, 1)
        XCTAssertEqual(fixture.samples.count, raw.count)
        for (decoded, original) in zip(fixture.samples, raw) {
            XCTAssertEqual(decoded, Float(original) / 32768.0, accuracy: 1e-6)
        }
        // 并且这些样本能被生产编码器吃下去 —— 端到端路径发的就是这一串字节。
        XCTAssertFalse(TranscribeCoordinator.encodePCM(fixture.samples).isEmpty)
    }

    /// 负控：录错格式的 fixture 必须在读文件这一步就说人话，
    /// 而不是让服务端以 400 bad_audio 回绝、在客户端看起来像一次传输故障。
    func testDecoderRejectsFixturesThatAreNotSixteenKilohertzMono() {
        let stereo = Self.makePCM16WAV([0, 1, 0, 1], sampleRate: 16000, channels: 2)
        XCTAssertThrowsError(try WAVFixtureDecoder.decodeStrict(stereo))

        let wrongRate = Self.makePCM16WAV([0, 1], sampleRate: 44100, channels: 1)
        XCTAssertThrowsError(try WAVFixtureDecoder.decodeStrict(wrongRate)) { error in
            guard case WAVFixtureError.wrongShape(let rate, _)? = error as? WAVFixtureError else {
                return XCTFail("应报格式不符，实得 \(error)")
            }
            XCTAssertEqual(rate, 44100)
        }

        XCTAssertThrowsError(try WAVFixtureDecoder.decode(Data("not a wav at all".utf8)))
    }

    /// 最小 PCM16 WAV 生成器 —— 仅供上面两条自检用例，不用于生成 fixture。
    /// **fixture 必须是真录音**，合成或人造的音频证明不了识别质量。
    static func makePCM16WAV(_ samples: [Int16], sampleRate: Int, channels: Int) -> Data {
        var data = Data()
        func append32(_ value: Int) { data.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }
        func append16(_ value: Int) { data.append(contentsOf: (0..<2).map { UInt8((value >> ($0 * 8)) & 0xFF) }) }

        let payloadBytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + payloadBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)                                   // PCM
        append16(channels)
        append32(sampleRate)
        append32(sampleRate * channels * 2)           // byte rate
        append16(channels * 2)                        // block align
        append16(16)                                  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(payloadBytes)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }
}
