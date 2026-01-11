import Foundation

// MARK: - Configuration Enums

/// Behavior when input code matches nothing
enum EmptyCodeBehavior: String, Codable, CaseIterable {
    case switchToEnglish = "switchToEnglish"  // Switch to temporary English mode
    case clearCode = "clearCode"              // Automatically clear the input code

    var displayName: String {
        switch self {
        case .switchToEnglish: return "转临时英文状态"
        case .clearCode: return "自动清除编码"
        }
    }
}

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

/// Page navigation key options
enum PageKeyOption: String, Codable, CaseIterable {
    case commaDot = "commaDot"       // , and .
    case minusEqual = "minusEqual"   // - and =
    case brackets = "brackets"       // [ and ]

    var displayName: String {
        switch self {
        case .commaDot: return ", ."
        case .minusEqual: return "- ="
        case .brackets: return "[ ]"
        }
    }
}

/// Key for switching between Chinese and English mode
enum ModeSwitchKey: String, Codable, CaseIterable {
    case shift = "shift"
    case control = "control"
    case fn = "fn"
    case disabled = "disabled"

    var displayName: String {
        switch self {
        case .shift: return "shift键"
        case .control: return "control键"
        case .fn: return "fn键"
        case .disabled: return "禁用"
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

    /// Behavior when input code matches nothing
    var emptyCodeBehavior: EmptyCodeBehavior

    /// Behavior when Enter key is pressed
    var enterKeyBehavior: EnterKeyBehavior

    // MARK: - Candidate Settings (候选词)

    /// Number of candidates to show (3-9)
    var candidateCount: Int

    /// Page navigation keys
    var pageKeys: PageKeyOption

    /// Key for switching between Chinese/English mode
    var modeSwitchKey: ModeSwitchKey

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

    /// Custom ranking formula in Python (optional)
    var customRankingFormula: String?

    // MARK: - Legacy Settings (现有设置)

    /// Enable auto-commit when there's a unique high-frequency match
    var enableAutoCommit: Bool

    /// Show code type hint (pinyin/wubi) in candidate window
    var showCodeHint: Bool

    /// Maximum total score before aging (default 10000)
    var frecencyMaxScore: Double

    /// Aging factor - what percentage to retain after aging (default 0.9)
    var frecencyAgingFactor: Double

    // MARK: - Default Configuration

    static let `default` = AppConfig(
        // Basic Settings
        emptyCodeBehavior: .switchToEnglish,
        enterKeyBehavior: .clearCode,

        // Candidate Settings
        candidateCount: 9,
        pageKeys: .commaDot,
        modeSwitchKey: .shift,

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
        customRankingFormula: nil,

        // Legacy Settings
        enableAutoCommit: false,
        showCodeHint: true,
        frecencyMaxScore: 10000.0,
        frecencyAgingFactor: 0.9
    )

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

        // Try to decode new format first
        do {
            return try decoder.decode(AppConfig.self, from: data)
        } catch {
            // Fall back to legacy format
            NSLog("MarmotIM: Config migration from legacy format")
            return try decodeLegacyConfig(from: data, decoder: decoder)
        }
    }

    /// Decode legacy configuration format
    private static func decodeLegacyConfig(from data: Data, decoder: JSONDecoder) throws -> AppConfig {
        // Try to decode as a partial config and fill in defaults
        struct LegacyConfig: Codable {
            var enableAutoCommit: Bool?
            var showCodeHint: Bool?
            var candidateCount: Int?
            var frecencyMaxScore: Double?
            var frecencyAgingFactor: Double?
            var theme: String?
        }

        let legacy = try decoder.decode(LegacyConfig.self, from: data)

        var config = AppConfig.default
        config.enableAutoCommit = legacy.enableAutoCommit ?? config.enableAutoCommit
        config.showCodeHint = legacy.showCodeHint ?? config.showCodeHint
        config.candidateCount = legacy.candidateCount ?? config.candidateCount
        config.frecencyMaxScore = legacy.frecencyMaxScore ?? config.frecencyMaxScore
        config.frecencyAgingFactor = legacy.frecencyAgingFactor ?? config.frecencyAgingFactor
        if let themeStr = legacy.theme {
            config.themeMode = ThemeMode(rawValue: themeStr) ?? .system
        }

        return config
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
    }
}

// MARK: - Config Coding Keys (for custom encoding if needed)

extension AppConfig {
    enum CodingKeys: String, CodingKey {
        case emptyCodeBehavior
        case enterKeyBehavior
        case candidateCount
        case pageKeys
        case modeSwitchKey
        case showStatusBarIcon
        case showModeIndicator
        case punctuationMode
        case customPunctuation
        case autoPairPunctuation
        case themeMode
        case candidateWindowStyle
        case rankingWeights
        case customRankingFormula
        case enableAutoCommit
        case showCodeHint
        case frecencyMaxScore
        case frecencyAgingFactor
    }
}
