import Cocoa
import InputMethodKit

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Singleton

    static var shared: AppDelegate?

    // MARK: - Properties

    /// Shared dictionary engine instance
    var dictionaryEngine: DictionaryEngine?

    /// Shared configuration
    static var config: AppConfig = AppConfig.default

    /// 语音转写协调器。**功能开启时才构造，且一定在启动之后**：它会装一个全局
    /// NSEvent 监听并持有一个 AVAudioEngine，这些绝不能挂在
    /// `applicationDidFinishLaunching` 的同步路径上（决策 20 —— 转写子系统既不能
    /// 影响打字，也不能影响启动）。功能没开时它一直是 nil，一行转写代码都不跑。
    private var transcribe: TranscribeCoordinator?

    /// 转写热词的来源：用户词表按 frecency 排序的一份缓存，只读、后台刷新。
    private var transcribeHotwords: FrecencyHotwordSupplier?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSLog("MarmotIM: Application did finish launching")

        // Initialize the dictionary engine
        initializeDictionary()

        // Start background preloading immediately
        // This runs in background and doesn't block the UI
        startPreloading()

        // Load configuration
        loadConfiguration()

        // Setup notification observers
        setupNotificationObservers()

        // Start iCloud sync service
        iCloudSyncManager.shared.start()

        // 语音转写：排到下一轮 runloop 再装配，本方法内一行都不跑。
        // 功能没开就连协调器都不构造 —— 没有监听、没有麦克风、没有网络。
        DispatchQueue.main.async { [weak self] in
            self?.activateTranscribeIfEnabled()
        }

        NSLog("MarmotIM: Initialization complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("MarmotIM: Application will terminate")

        // Stop iCloud sync service
        iCloudSyncManager.shared.stop()

        // 转写：拆掉全局 NSEvent 监听、停掉可能还在录的 AVAudioEngine、撤回在飞的请求。
        // 不能指望 deinit —— 进程退出时 AppDelegate 未必被释放。
        transcribe?.stop()

        // Save configuration
        try? Self.config.save()

        // Force WAL checkpoint to ensure all data is written to disk
        // This prevents data loss when process is killed by pkill
        VocabularyDatabase.shared.checkpoint()
    }

    // MARK: - Initialization

    private func initializeDictionary() {
        do {
            dictionaryEngine = try DictionaryEngine()
            NSLog("MarmotIM: Dictionary engine initialized")
        } catch {
            NSLog("MarmotIM: Failed to initialize dictionary engine: \(error)")
            // Fall back to empty dictionary - will still work but no suggestions
            dictionaryEngine = try? DictionaryEngine(entries: [])
        }
    }

    private func startPreloading() {
        guard let engine = dictionaryEngine else { return }

        // Start preloading in background
        // This will load all entries from SQLite into the Trie
        DictionaryPreloadService.shared.startPreloading(engine: engine) {
            NSLog("MarmotIM: Dictionary preload complete - ready for instant input")

            // Migrate legacy user dictionary if it exists
            engine.loadUserDictionary()

            // Note: ReverseLookupTable now queries database directly
            // No preloading needed
        }
    }

    private func loadConfiguration() {
        do {
            Self.config = try AppConfig.load()
            Self.config.validate()
            NSLog("MarmotIM: Configuration loaded - enterKeyBehavior=%@",
                  Self.config.enterKeyBehavior.rawValue)
        } catch {
            NSLog("MarmotIM: Using default configuration: \(error)")
            Self.config = .default
        }
    }

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        // Configuration changed notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChanged),
            name: .configurationDidChange,
            object: nil
        )

        // User dictionary changed notification (legacy - kept for compatibility)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserDictionaryChanged),
            name: .userDictionaryDidChange,
            object: nil
        )

        // Suppressed words changed notification (from iCloud sync)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSuppressedWordsChanged),
            name: .suppressedWordsDidChange,
            object: nil
        )

        // Relative-ordering changed notification (spec-003; from iCloud sync
        // or local settings UI mutation).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRelativeOrderingChanged),
            name: .relativeOrderingDidChange,
            object: nil
        )

        // 转写设置变更。设置页每次保存都先发 .configurationDidChange（上面那条观察者
        // 已经把整份配置从盘上重载过），再发这一条，两次都是同步 post，所以处理这一条时
        // Self.config 一定已经是新值。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscribeConfigChanged),
            name: .transcribeConfigDidChange,
            object: nil
        )
    }

    // MARK: - 语音转写

    /// 启动之后的装配。功能没开就什么都不做：不构造协调器、不装监听、不碰麦克风。
    private func activateTranscribeIfEnabled() {
        guard Self.config.transcribe.enabled else { return }
        transcribeCoordinator().configurationDidChange()
    }

    /// 惰性构造。一旦造出来就留着：停用只是 `stop()`（拆热键监听、停录音、撤请求），
    /// 空闲的协调器不跑计时器也不占麦克风，留着能让"再打开"立刻生效而不必重启。
    ///
    /// **必须走 `makeProduction`。** 直接 `TranscribeCoordinator()` 会拿到安全缺省
    /// （inert 上屏 + 静默 HUD），一切照常启动却什么都不做 —— 那个症状与"MarmotIM
    /// 不是当前输入源"无从区分。
    @discardableResult
    private func transcribeCoordinator() -> TranscribeCoordinator {
        if let transcribe { return transcribe }
        let hotwords = FrecencyHotwordSupplier()
        hotwords.prime()   // 后台预热，第一次听写就有热词可用
        let coordinator = TranscribeCoordinator.makeProduction(hotwords: hotwords)
        transcribeHotwords = hotwords
        transcribe = coordinator
        return coordinator
    }

    // MARK: - Menu Actions

    @objc private func openSettings() {
        SettingsWindowController.shared.showSettings()
    }

    @objc private func openAbout() {
        // Open settings window on About tab
        SettingsWindowController.shared.showSettings()
        // Note: Could implement tab switching in the future
    }

    // MARK: - Notification Handlers

    @objc private func handleConfigurationChanged() {
        NSLog("MarmotIM: Configuration changed, reloading")
        loadConfiguration()
    }

    @objc private func handleTranscribeConfigChanged() {
        if Self.config.transcribe.enabled {
            transcribeCoordinator().configurationDidChange()
        } else {
            // 从没开过就没有东西可停 —— 不为了关掉一个不存在的东西去把它构造出来。
            transcribe?.configurationDidChange()
        }
    }

    @objc private func handleUserDictionaryChanged() {
        // Fired after iCloud sync merges remote user_favorites into the local
        // DB (via a raw sqlite3 connection that bypasses
        // DictionaryEngine.addUserEntry()). Reconcile this process's
        // in-memory userTierIndex/entries table against user_favorites so
        // synced words are typable without restarting the input method.
        guard let engine = dictionaryEngine, engine.isPreloaded else { return }
        let fixedCount = engine.ensureUserFavoritesIndexed()
        let cleanedCount = engine.cleanupDeletedUserFavorites()
        NSLog("MarmotIM: User dictionary changed - reindexed \(fixedCount), cleaned \(cleanedCount)")
    }

    @objc private func handleSuppressedWordsChanged() {
        NSLog("MarmotIM: Suppressed words changed, refreshing cache")
        dictionaryEngine?.updateSuppressedWordsCache()
    }

    @objc private func handleRelativeOrderingChanged() {
        NSLog("MarmotIM: Relative-ordering rules changed, refreshing cache")
        dictionaryEngine?.updateRelativeOrderingCache()
    }
}
