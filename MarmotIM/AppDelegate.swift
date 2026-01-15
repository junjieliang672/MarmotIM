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

        NSLog("MarmotIM: Initialization complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("MarmotIM: Application will terminate")

        // Stop iCloud sync service
        iCloudSyncManager.shared.stop()

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

            // Preload reverse lookup table for 划词入库 feature
            // This runs asynchronously to avoid blocking
            ReverseLookupTable.shared.loadAsync {
                NSLog("MarmotIM: Reverse lookup table preload complete")
            }
        }
    }

    private func loadConfiguration() {
        do {
            Self.config = try AppConfig.load()
            Self.config.validate()
            NSLog("MarmotIM: Configuration loaded - enterKeyBehavior=%@, modeSwitchKey=%@",
                  Self.config.enterKeyBehavior.rawValue, Self.config.modeSwitchKey.rawValue)
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

    @objc private func handleUserDictionaryChanged() {
        // Legacy notification handler - kept for backward compatibility
        // New code uses direct API calls and doesn't need this
        NSLog("MarmotIM: User dictionary changed notification received (legacy)")
    }
}
