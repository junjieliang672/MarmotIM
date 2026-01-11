import Cocoa
import InputMethodKit

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Singleton

    static var shared: AppDelegate?

    // MARK: - Properties

    /// Shared dictionary engine instance
    var dictionaryEngine: DictionaryEngine?

    /// Legacy user data store (kept for backward compatibility during migration)
    static var userDataStore: UserDataStore?

    /// Shared configuration
    static var config: AppConfig = AppConfig.default

    /// Status bar item for the input method menu
    private var statusItem: NSStatusItem?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSLog("MarmotIM: Application did finish launching")

        // Initialize the dictionary engine
        initializeDictionary()

        // Start background preloading immediately
        // This runs in background and doesn't block the UI
        startPreloading()

        // Initialize legacy user data store (for migration)
        initializeUserDataStore()

        // Load configuration
        loadConfiguration()

        // Setup status bar menu
        setupStatusBarMenu()

        // Setup notification observers
        setupNotificationObservers()

        NSLog("MarmotIM: Initialization complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("MarmotIM: Application will terminate")

        // Save any pending user data
        Self.userDataStore?.save()

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

    private func initializeUserDataStore() {
        // This is kept for backward compatibility
        // New code should use DictionaryEngine.getUserLearning() instead
        do {
            Self.userDataStore = try UserDataStore()
            NSLog("MarmotIM: Legacy user data store initialized")
        } catch {
            NSLog("MarmotIM: Failed to initialize legacy user data store: \(error)")
        }
    }

    private func loadConfiguration() {
        do {
            Self.config = try AppConfig.load()
            Self.config.validate()
            NSLog("MarmotIM: Configuration loaded")
        } catch {
            NSLog("MarmotIM: Using default configuration: \(error)")
            Self.config = .default
        }
    }

    // MARK: - Status Bar Menu

    private func setupStatusBarMenu() {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MarmotIM")
            button.image?.isTemplate = true
        }

        // Create menu
        let menu = NSMenu()

        // Settings item
        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Preload status item
        let statusItem = NSMenuItem(title: "词库状态: 加载中...", action: nil, keyEquivalent: "")
        statusItem.tag = 100  // Tag for updating later
        menu.addItem(statusItem)

        // Observe preload completion to update status
        NotificationCenter.default.addObserver(
            forName: .dictionaryPreloadComplete,
            object: nil,
            queue: .main
        ) { [weak menu] notification in
            if let item = menu?.item(withTag: 100),
               let time = notification.userInfo?["preloadTime"] as? Double {
                item.title = String(format: "词库状态: 已就绪 (%.1fs)", time)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // About item
        let aboutItem = NSMenuItem(title: "关于土拨鼠输入法", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        self.statusItem?.menu = menu
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
