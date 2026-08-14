import Foundation

// MARK: - Configuration Enums

/// Behavior when Enter key is pressed
enum EnterKeyBehavior: String, Codable, CaseIterable {
    case clearCode = "clearCode"    // Clear the input code
    case outputCode = "outputCode"  // Output the raw code as text

    var displayName: String {
        switch self {
        case .clearCode: return "清除编码"
        case .outputCode: return "输出编码"
        }
    }
}

/// Punctuation handling mode
enum PunctuationMode: String, Codable, CaseIterable {
    case chinese = "chinese"   // Always use Chinese punctuation
    case english = "english"   // Always use English punctuation
    case custom = "custom"     // Use custom mapping

    var displayName: String {
        switch self {
        case .chinese: return "只使用中文标点"
        case .english: return "只使用英文标点"
        case .custom: return "自定义"
        }
    }
}

/// Theme mode
enum ThemeMode: String, Codable, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }
}

// MARK: - Ranking Weights Configuration

/// All configurable ranking weight parameters
struct RankingWeights: Codable, Equatable {
    /// Weight for base frequency from dictionary
    var baseFrequencyWeight: Double

    /// Bonus for full match vs prefix match
    var fullMatchBonus: Double

    /// Bonus per character shorter than max length
    var lengthBonus: Double

    /// Bonus for entries from wubi dictionary
    var wubiSourceBonus: Double

    /// User learning multiplier (scales user behavior impact)
    var userLearningMultiplier: Double

    /// Bonus for recent selection (absolute priority)
    var recentSelectionBonus: Double

    /// Time window for recent selection boost (in seconds)
    var recentSelectionBoostTime: Double

    // Time decay weights
    var recencyWeightWithinHour: Double
    var recencyWeightWithinDay: Double
    var recencyWeightWithinWeek: Double
    var recencyWeightOlder: Double

    static let `default` = RankingWeights(
        baseFrequencyWeight: 1.0,
        fullMatchBonus: 50000.0,
        lengthBonus: 10000.0,
        wubiSourceBonus: 5000.0,
        userLearningMultiplier: 100000.0,
        recentSelectionBonus: 500000.0,
        recentSelectionBoostTime: 3600.0,
        recencyWeightWithinHour: 4.0,
        recencyWeightWithinDay: 2.0,
        recencyWeightWithinWeek: 1.0,
        recencyWeightOlder: 0.5
    )
}

// MARK: - Candidate Window Style

/// Visual style for the candidate window
struct CandidateWindowStyle: Codable, Equatable {
    var fontSize: Double
    var cornerRadius: Double
    var backgroundOpacity: Double

    static let `default` = CandidateWindowStyle(
        fontSize: 14.0,
        cornerRadius: 8.0,
        backgroundOpacity: 0.95
    )
}

// MARK: - Fuzzy Pinyin Configuration

/// Fuzzy pinyin configuration
struct FuzzyPinyinConfig: Codable, Equatable {
    var enabled: Bool = true

    // Initial (声母) fuzzy rules
    var zh_z: Bool = true
    var ch_c: Bool = true
    var sh_s: Bool = true
    var n_l: Bool = true
    var r_l: Bool = true
    var f_h: Bool = true

    // Final (韵母) fuzzy rules
    var an_ang: Bool = true
    var en_eng: Bool = true
    var in_ing: Bool = true
    var ian_iang: Bool = true
    var uan_uang: Bool = true

    static let `default` = FuzzyPinyinConfig()
}

// MARK: - Transcribe Configuration (语音转写)

/// ASR model variant. The raw value is the real HuggingFace repo id so that
/// settings, server and installer cannot drift from one another.
///
/// Only bf16 repos are listed: `qwen3-asr-mlx` 0.2.0 uses strict `load_weights`
/// and cannot load the 8-bit repo, and upstream `Qwen/Qwen3-ASR-0.6B` uses the
/// `thinker.`-prefixed Omni layout (决策 6/8).
enum TranscribeModelVariant: String, Codable, CaseIterable {
    case qwen0_6B_bf16 = "mlx-community/Qwen3-ASR-0.6B-bf16"
    case qwen1_7B_bf16 = "mlx-community/Qwen3-ASR-1.7B-bf16"

    var displayName: String {
        switch self {
        case .qwen0_6B_bf16: return "0.6B（更快）"
        case .qwen1_7B_bf16: return "1.7B（更准，默认）"
        }
    }
}

/// Recognition language. `.auto` sends no `language` field (决策 9).
enum TranscribeLanguage: String, Codable, CaseIterable {
    case auto = "auto"
    case chinese = "zh"
    case english = "en"

    var displayName: String {
        switch self {
        case .auto: return "自动检测"
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    /// `/reconfigure` 用的值，与上面那个**语义不同**，所以是两个属性而不是一个。
    ///
    /// 转写请求里 nil ＝ 这次不指定语言；但在 /reconfigure 里 nil ＝ 这一项不改，
    /// 于是"把语言改成自动"就永远发不出去。服务端把空串和 null 都解释成自动检测
    /// （app.py: `str(raw).strip() or None`），所以这里发空串。
    var reconfigureValue: String { self == .auto ? "" : rawValue }

    /// Wire value for `TranscribeRequest.language` — nil means auto-detect.
    var wireValue: String? {
        self == .auto ? nil : rawValue
    }
}

/// Speech-to-text configuration
struct TranscribeConfig: Codable, Equatable {
    /// Master switch. Off by default — a dead server must never affect typing (决策 20).
    var enabled: Bool = false

    /// Local ASR server host. 127.0.0.1 only, no LAN exposure (决策 14).
    var host: String = "127.0.0.1"
    var port: Int = 58471

    var modelVariant: TranscribeModelVariant = .qwen1_7B_bf16
    var language: TranscribeLanguage = .auto

    /// Space-separated hotwords merged into the request `context` (决策 10)
    var hotwords: String = ""

    /// nil ⇒ 自动 (server passes `max_tokens=None`, library computes
    /// `max(256, duration * 50)`). A literal value is passed through verbatim (决策 13).
    var maxNewTokens: Int? = nil

    var requestTimeoutSeconds: Double = 15.0

    /// Stuck-modifier safety valve, not a UX cap (决策 14c)
    var maxRecordingSeconds: Double = 120.0

    /// Hold duration before recording starts, so a quick tap does nothing (决策 1)
    var holdThresholdMilliseconds: Int = 250

    /// 不是当前输入源时也允许听写。默认关闭。
    ///
    /// 关闭时（决策 3 的原样行为）：只有 MarmotIM 是当前键盘输入源、且有活跃的
    /// `InputController` 时长按才有反应，文字走候选上屏那条路插进去。
    ///
    /// 打开时：上面那条路仍然优先；只有走不通时才退到合成键盘事件
    /// （`CGEventKeyboardSetUnicodeString`）。这条退路**需要辅助功能授权**，
    /// 没授权就还是无操作 —— 打开这个开关本身不会让任何事情变得能用。
    ///
    /// 代价写在这里而不是只写在设置页里：这一项把失效方向翻了个面。关闭时它坏了的
    /// 样子是「听写从来不工作」，打开时是「文字出现在别人的输入框里」。所以它默认关闭，
    /// 而且退路只在主路走不通时才用。
    var worksWhenInactive: Bool = false

    // MARK: - 服务端项目
    //
    // 下面三项**不是**客户端行为，它们通过 POST /reconfigure 下发给本机服务，
    // 由服务端决定能否原地生效（前两项可以，logLevel 要重开进程）。
    // 存在这里而不是只留在服务端，是为了和 modelVariant 一致：设置页是真相来源，
    // 服务端的 overlay 是它的镜像 —— 否则重装一次服务，用户改过的值就悄悄回到默认。

    /// 短于此长度的音频按 audio_too_short 静默丢弃。
    var minAudioSeconds: Double = 0.2

    /// 长于此长度的音频按 audio_too_long 拒绝。客户端本来就有 120 s 卡键兜底，
    /// 所以服务端这道上限是刻意宽松的第二道。
    var maxAudioSeconds: Double = 300.0

    /// 服务端日志级别（uvicorn 的取值）。改它要重开进程。
    var logLevel: String = "info"

    /// uvicorn 认得的级别。别的值会让服务端起不来 —— 而它起不来就没有界面能改回去。
    static let knownLogLevels = ["critical", "error", "warning", "info", "debug", "trace"]

    /// Strip ONE trailing 。/ . / ，from the transcript (决策 5)
    var stripTrailingPunctuation: Bool = true

    /// 声明 `init(from:)` 会顶掉编译器合成的逐成员构造器，而全部属性都有默认值，
    /// 所以这里补一个空构造器就够了 —— 逐成员那份没有任何调用方（查过）。
    init() {}

    static let `default` = TranscribeConfig()

    // MARK: - Resilient Decoding

    /// 与 `AppConfig.init(from:)` 同样的容错，只是低一层。
    ///
    /// **为什么必须有。** `AppConfig` 那份注释说得很清楚：容错解码是为了「字段增删
    /// 之后配置不会被重置」。但它对本结构体只做了一次
    /// `(try? container.decode(TranscribeConfig.self, …)) ?? d.transcribe` ——
    /// 而合成的 `init(from:)` 对缺失的键是**抛错**的，属性上的默认值不参与解码
    /// （实测：`keyNotFound`，不是回退到默认值）。两者合起来的效果是：只要给本结构体
    /// 加一个字段，旧版本写下的 `config.json` 就整块解码失败，于是主机、端口、模型、
    /// 热词、以及用户改过的一切**一起悄悄回到默认值** —— 上层的 `??` 把异常吞掉了，
    /// 没有任何地方会报错。
    ///
    /// 所以这里逐字段 `decodeIfPresent`。加 `worksWhenInactive` 是第一次踩到它，
    /// 但这个坑对之前每一次字段增补都成立，写在这里一次性了结。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranscribeConfig()

        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        host = (try? container.decode(String.self, forKey: .host)) ?? d.host
        port = (try? container.decode(Int.self, forKey: .port)) ?? d.port
        modelVariant = (try? container.decode(TranscribeModelVariant.self, forKey: .modelVariant)) ?? d.modelVariant
        language = (try? container.decode(TranscribeLanguage.self, forKey: .language)) ?? d.language
        hotwords = (try? container.decode(String.self, forKey: .hotwords)) ?? d.hotwords
        // maxNewTokens 是 Optional，nil 是一个有意义的取值（"自动"）。缺键、显式 null、
        // 解不动，三种情况都落到 d.maxNewTokens —— 它本身就是 nil，所以结论一致。
        maxNewTokens = (try? container.decode(Int.self, forKey: .maxNewTokens)) ?? d.maxNewTokens
        requestTimeoutSeconds = (try? container.decode(Double.self, forKey: .requestTimeoutSeconds)) ?? d.requestTimeoutSeconds
        maxRecordingSeconds = (try? container.decode(Double.self, forKey: .maxRecordingSeconds)) ?? d.maxRecordingSeconds
        holdThresholdMilliseconds = (try? container.decode(Int.self, forKey: .holdThresholdMilliseconds)) ?? d.holdThresholdMilliseconds
        worksWhenInactive = (try? container.decode(Bool.self, forKey: .worksWhenInactive)) ?? d.worksWhenInactive
        minAudioSeconds = (try? container.decode(Double.self, forKey: .minAudioSeconds)) ?? d.minAudioSeconds
        maxAudioSeconds = (try? container.decode(Double.self, forKey: .maxAudioSeconds)) ?? d.maxAudioSeconds
        logLevel = (try? container.decode(String.self, forKey: .logLevel)) ?? d.logLevel
        stripTrailingPunctuation = (try? container.decode(Bool.self, forKey: .stripTrailingPunctuation)) ?? d.stripTrailingPunctuation
    }
}

// MARK: - Default Punctuation Mapping

/// Default Chinese punctuation mapping
let defaultChinesePunctuation: [String: String] = [
    "!": "！",
    "\"": "\u{201C}",  // Left double quotation mark "
    "'": "\u{2018}",   // Left single quotation mark '
    "(": "（",
    ")": "）",
    ",": "，",
    ".": "。",
    ":": "：",
    ";": "；",
    "?": "？",
    "[": "【",
    "]": "】",
    "\\": "、",
    "^": "……",
    "_": "——",
    "~": "～"
]

// MARK: - Application Configuration

/// Application configuration
struct AppConfig: Codable {

    // MARK: - Basic Settings (编码)

    /// Behavior when Enter key is pressed
    var enterKeyBehavior: EnterKeyBehavior

    /// When input buffer contains a capital letter, treat number keys as input to buffer instead of candidate selection
    var numberAsInputWhenCapital: Bool

    // MARK: - Candidate Settings (候选词)

    /// Number of candidates to show (3-9)
    var candidateCount: Int

    /// Add a space after selecting an English candidate
    var addSpaceAfterEnglish: Bool

    // MARK: - Icon Settings (图标)

    /// Show extra icon in status bar
    var showStatusBarIcon: Bool

    /// Show mode indicator when switching
    var showModeIndicator: Bool

    // MARK: - Punctuation Settings (标点符号)

    /// Punctuation handling mode
    var punctuationMode: PunctuationMode

    /// Custom punctuation mapping (key -> output)
    var customPunctuation: [String: String]

    /// Auto-pair punctuation (e.g., typing ( outputs （）)
    var autoPairPunctuation: Bool

    // MARK: - Theme Settings (主题)

    /// Theme mode (system/light/dark)
    var themeMode: ThemeMode

    /// Candidate window visual style
    var candidateWindowStyle: CandidateWindowStyle

    // MARK: - Ranking Settings (排序算法)

    /// All ranking weight parameters
    var rankingWeights: RankingWeights

    // MARK: - Fuzzy Pinyin Settings (模糊拼音)

    /// Fuzzy pinyin configuration
    var fuzzyPinyin: FuzzyPinyinConfig = .default

    // MARK: - Transcribe Settings (语音转写)

    /// Speech-to-text configuration
    var transcribe: TranscribeConfig = .default

    // MARK: - Legacy Settings (现有设置)

    /// Show code type hint (pinyin/wubi) in candidate window
    var showCodeHint: Bool

    // MARK: - Memberwise Init

    init(
        enterKeyBehavior: EnterKeyBehavior,
        numberAsInputWhenCapital: Bool,
        candidateCount: Int,
        addSpaceAfterEnglish: Bool,
        showStatusBarIcon: Bool,
        showModeIndicator: Bool,
        punctuationMode: PunctuationMode,
        customPunctuation: [String: String],
        autoPairPunctuation: Bool,
        themeMode: ThemeMode,
        candidateWindowStyle: CandidateWindowStyle,
        rankingWeights: RankingWeights,
        fuzzyPinyin: FuzzyPinyinConfig = .default,
        transcribe: TranscribeConfig = .default,
        showCodeHint: Bool
    ) {
        self.enterKeyBehavior = enterKeyBehavior
        self.numberAsInputWhenCapital = numberAsInputWhenCapital
        self.candidateCount = candidateCount
        self.addSpaceAfterEnglish = addSpaceAfterEnglish
        self.showStatusBarIcon = showStatusBarIcon
        self.showModeIndicator = showModeIndicator
        self.punctuationMode = punctuationMode
        self.customPunctuation = customPunctuation
        self.autoPairPunctuation = autoPairPunctuation
        self.themeMode = themeMode
        self.candidateWindowStyle = candidateWindowStyle
        self.rankingWeights = rankingWeights
        self.fuzzyPinyin = fuzzyPinyin
        self.transcribe = transcribe
        self.showCodeHint = showCodeHint
    }

    // MARK: - Default Configuration

    static let `default` = AppConfig(
        // Basic Settings
        enterKeyBehavior: .clearCode,
        numberAsInputWhenCapital: true,

        // Candidate Settings
        candidateCount: 9,
        addSpaceAfterEnglish: false,

        // Icon Settings
        showStatusBarIcon: false,
        showModeIndicator: true,

        // Punctuation Settings
        punctuationMode: .custom,
        customPunctuation: defaultChinesePunctuation,
        autoPairPunctuation: true,

        // Theme Settings
        themeMode: .system,
        candidateWindowStyle: .default,

        // Ranking Settings
        rankingWeights: .default,

        // Fuzzy Pinyin Settings
        fuzzyPinyin: .default,

        // Transcribe Settings
        transcribe: .default,

        // Legacy Settings
        showCodeHint: true
    )

    // MARK: - Resilient Decoding

    /// Custom decoder that tolerates missing fields by falling back to defaults.
    /// This prevents config reset when fields are added/removed between builds.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig.default

        enterKeyBehavior = (try? container.decode(EnterKeyBehavior.self, forKey: .enterKeyBehavior)) ?? d.enterKeyBehavior
        numberAsInputWhenCapital = (try? container.decode(Bool.self, forKey: .numberAsInputWhenCapital)) ?? d.numberAsInputWhenCapital
        candidateCount = (try? container.decode(Int.self, forKey: .candidateCount)) ?? d.candidateCount
        addSpaceAfterEnglish = (try? container.decode(Bool.self, forKey: .addSpaceAfterEnglish)) ?? d.addSpaceAfterEnglish
        showStatusBarIcon = (try? container.decode(Bool.self, forKey: .showStatusBarIcon)) ?? d.showStatusBarIcon
        showModeIndicator = (try? container.decode(Bool.self, forKey: .showModeIndicator)) ?? d.showModeIndicator
        punctuationMode = (try? container.decode(PunctuationMode.self, forKey: .punctuationMode)) ?? d.punctuationMode
        customPunctuation = (try? container.decode([String: String].self, forKey: .customPunctuation)) ?? d.customPunctuation
        autoPairPunctuation = (try? container.decode(Bool.self, forKey: .autoPairPunctuation)) ?? d.autoPairPunctuation
        themeMode = (try? container.decode(ThemeMode.self, forKey: .themeMode)) ?? d.themeMode
        candidateWindowStyle = (try? container.decode(CandidateWindowStyle.self, forKey: .candidateWindowStyle)) ?? d.candidateWindowStyle
        rankingWeights = (try? container.decode(RankingWeights.self, forKey: .rankingWeights)) ?? d.rankingWeights
        fuzzyPinyin = (try? container.decode(FuzzyPinyinConfig.self, forKey: .fuzzyPinyin)) ?? d.fuzzyPinyin
        transcribe = (try? container.decode(TranscribeConfig.self, forKey: .transcribe)) ?? d.transcribe
        showCodeHint = (try? container.decode(Bool.self, forKey: .showCodeHint)) ?? d.showCodeHint
    }

    // MARK: - Backward Compatibility

    /// Legacy theme property (for backward compatibility)
    var theme: String {
        get { themeMode.rawValue }
        set { themeMode = ThemeMode(rawValue: newValue) ?? .system }
    }

    // MARK: - Load/Save

    private static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MarmotIM/config.json")
    }

    /// Load configuration from file
    static func load() throws -> AppConfig {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(AppConfig.self, from: data)
    }

    /// Save configuration to file
    func save() throws {
        let url = Self.configURL

        // Create directory if needed
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }

    // MARK: - Validation

    /// Validate and fix any out-of-range values
    mutating func validate() {
        // Candidate count must be 3-9
        candidateCount = min(9, max(3, candidateCount))

        // Ensure positive values for ranking weights
        rankingWeights.baseFrequencyWeight = max(0, rankingWeights.baseFrequencyWeight)
        rankingWeights.fullMatchBonus = max(0, rankingWeights.fullMatchBonus)
        rankingWeights.lengthBonus = max(0, rankingWeights.lengthBonus)
        rankingWeights.wubiSourceBonus = max(0, rankingWeights.wubiSourceBonus)
        rankingWeights.userLearningMultiplier = max(0, rankingWeights.userLearningMultiplier)
        rankingWeights.recentSelectionBonus = max(0, rankingWeights.recentSelectionBonus)
        rankingWeights.recentSelectionBoostTime = max(0, rankingWeights.recentSelectionBoostTime)

        // Ensure positive time decay weights
        rankingWeights.recencyWeightWithinHour = max(0, rankingWeights.recencyWeightWithinHour)
        rankingWeights.recencyWeightWithinDay = max(0, rankingWeights.recencyWeightWithinDay)
        rankingWeights.recencyWeightWithinWeek = max(0, rankingWeights.recencyWeightWithinWeek)
        rankingWeights.recencyWeightOlder = max(0, rankingWeights.recencyWeightOlder)

        // Window style validation
        candidateWindowStyle.fontSize = min(24, max(10, candidateWindowStyle.fontSize))
        candidateWindowStyle.cornerRadius = min(20, max(0, candidateWindowStyle.cornerRadius))
        candidateWindowStyle.backgroundOpacity = min(1.0, max(0.5, candidateWindowStyle.backgroundOpacity))

        // Transcribe validation
        // Port must be a usable unprivileged TCP port
        transcribe.port = min(65535, max(1024, transcribe.port))

        // nil means "let the server decide" (决策 13) — only clamp an explicit value
        if let tokens = transcribe.maxNewTokens {
            transcribe.maxNewTokens = min(4096, max(16, tokens))
        }

        transcribe.requestTimeoutSeconds = min(120.0, max(1.0, transcribe.requestTimeoutSeconds))

        // Stuck-modifier guard: long enough to be a safety valve, not a UX cap
        transcribe.maxRecordingSeconds = min(600.0, max(5.0, transcribe.maxRecordingSeconds))

        transcribe.holdThresholdMilliseconds = min(2000, max(50, transcribe.holdThresholdMilliseconds))

        // 服务端项目。钳制区间与 server/config.py 的 validate() 对齐 —— 客户端先钳一次，
        // 是为了不让设置页把一个服务端必然拒绝的值发出去再显示一条错误。
        transcribe.minAudioSeconds = min(10.0, max(0.0, transcribe.minAudioSeconds))
        transcribe.maxAudioSeconds = min(3600.0, max(1.0, transcribe.maxAudioSeconds))
        // max 必须大于 min，否则服务端会拒绝整份配置。宁可把 max 顶上去，
        // 也不要让一个不可能生效的组合落盘。
        if transcribe.maxAudioSeconds <= transcribe.minAudioSeconds {
            transcribe.maxAudioSeconds = transcribe.minAudioSeconds + 1.0
        }
        if !TranscribeConfig.knownLogLevels.contains(transcribe.logLevel) {
            transcribe.logLevel = "info"
        }

        // A blank host would silently break every request
        if transcribe.host.trimmingCharacters(in: .whitespaces).isEmpty {
            transcribe.host = TranscribeConfig.default.host
        }
    }
}

// MARK: - Config Coding Keys (for custom encoding if needed)

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case enterKeyBehavior
        case numberAsInputWhenCapital
        case candidateCount
        case addSpaceAfterEnglish
        case showStatusBarIcon
        case showModeIndicator
        case punctuationMode
        case customPunctuation
        case autoPairPunctuation
        case themeMode
        case candidateWindowStyle
        case rankingWeights
        case fuzzyPinyin
        case transcribe
        case showCodeHint
    }
}
