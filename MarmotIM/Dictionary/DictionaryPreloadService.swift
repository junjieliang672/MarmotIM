import Foundation

/// Background service for preloading dictionary into memory
/// Ensures zero-latency when user switches to Chinese input
///
/// This service runs automatically when the app launches - no user configuration required.
/// The input method app is launched by macOS when the user enables it in System Preferences.
final class DictionaryPreloadService {

    // MARK: - Singleton

    static let shared = DictionaryPreloadService()

    // MARK: - Properties

    /// Background queue for preloading
    private let preloadQueue = DispatchQueue(
        label: "com.marmotim.preload",
        qos: .userInitiated
    )

    /// Whether preloading is complete
    private(set) var isPreloaded = false

    /// Whether preloading is in progress
    private(set) var isPreloading = false

    /// Preload progress (0.0 - 1.0)
    private(set) var progress: Double = 0.0

    /// Time taken for preload (in seconds)
    private(set) var preloadTime: Double = 0.0

    /// Completion callbacks
    private var completionHandlers: [() -> Void] = []

    /// Lock for thread safety
    private let lock = NSLock()

    // MARK: - Initialization

    private init() {}

    // MARK: - Preloading

    /// Start preloading the dictionary in background
    /// This is called automatically by AppDelegate on app launch
    /// - Parameters:
    ///   - engine: The dictionary engine to preload
    ///   - completion: Optional callback when preload completes
    func startPreloading(engine: DictionaryEngine, completion: (() -> Void)? = nil) {
        lock.lock()

        // Already preloaded
        if isPreloaded {
            lock.unlock()
            completion?()
            return
        }

        // Already preloading - add to completion handlers
        if isPreloading {
            if let completion = completion {
                completionHandlers.append(completion)
            }
            lock.unlock()
            return
        }

        // Start preloading
        isPreloading = true
        if let completion = completion {
            completionHandlers.append(completion)
        }
        lock.unlock()

        NSLog("MarmotIM: Starting dictionary preload...")
        let startTime = CFAbsoluteTimeGetCurrent()

        preloadQueue.async { [weak self] in
            guard let self = self else { return }

            // Perform the actual preloading
            self.performPreload(engine: engine)

            // Calculate elapsed time
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            self.preloadTime = elapsed

            // Mark as complete and notify
            self.lock.lock()
            self.isPreloading = false
            self.isPreloaded = true
            self.progress = 1.0
            let handlers = self.completionHandlers
            self.completionHandlers.removeAll()
            self.lock.unlock()

            NSLog("MarmotIM: Dictionary preload complete in %.2fs", elapsed)

            // Call completion handlers on main thread
            DispatchQueue.main.async {
                for handler in handlers {
                    handler()
                }
            }

            // Post notification
            NotificationCenter.default.post(
                name: .dictionaryPreloadComplete,
                object: nil,
                userInfo: ["preloadTime": elapsed]
            )
        }
    }

    /// Wait for preload to complete (blocking with timeout)
    /// Use this if you need to ensure the dictionary is ready before proceeding
    /// - Parameter timeout: Maximum time to wait (default: 10 seconds)
    /// - Returns: True if preload completed within timeout
    func waitForPreload(timeout: TimeInterval = 10.0) -> Bool {
        // Already done
        if isPreloaded { return true }

        let deadline = Date(timeIntervalSinceNow: timeout)

        while !isPreloaded && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        return isPreloaded
    }

    /// Add a completion handler to be called when preload finishes
    /// If already preloaded, the handler is called immediately
    /// - Parameter handler: The completion handler
    func onPreloadComplete(_ handler: @escaping () -> Void) {
        lock.lock()
        if isPreloaded {
            lock.unlock()
            DispatchQueue.main.async { handler() }
        } else {
            completionHandlers.append(handler)
            lock.unlock()
        }
    }

    // MARK: - Private Methods

    private func performPreload(engine: DictionaryEngine) {
        let db = VocabularyDatabase.shared

        // Perform schema migrations (ensures user data is preserved across updates)
        db.performMigrations()

        // Check if migration is needed (first-time setup)
        if db.needsMigration() {
            NSLog("MarmotIM: Database needs migration, performing first-time setup...")
            performMigration(db: db)
        }

        // Load jianma table for protected tier validation
        updateProgress(0.05)
        NSLog("MarmotIM: Loading jianma table...")
        engine.loadJianmaTable()

        // Load English words
        NSLog("MarmotIM: Loading English words...")
        engine.loadEnglishWords()

        // Load pinyin indexes into Trie
        updateProgress(0.1)
        NSLog("MarmotIM: Loading pinyin indexes...")
        let pinyinIndexes = db.loadAllPinyinIndexes()
        engine.bulkLoadPinyinIndexes(pinyinIndexes)
        updateProgress(0.4)

        // Load wubi indexes into Trie
        NSLog("MarmotIM: Loading wubi indexes...")
        let wubiIndexes = db.loadAllWubiIndexes()
        engine.bulkLoadWubiIndexes(wubiIndexes)
        updateProgress(0.7)

        // Load user learning data
        NSLog("MarmotIM: Loading user learning data...")
        let userLearning = db.loadAllUserLearning()
        engine.loadUserLearningData(userLearning)
        updateProgress(0.9)

        // Final setup
        engine.finalizePreload()
        updateProgress(0.93)

        // Cleanup deleted user favorites (entries that were soft-deleted but still have orphaned data)
        let cleanedCount = engine.cleanupDeletedUserFavorites()
        if cleanedCount > 0 {
            NSLog("MarmotIM: Cleaned up \(cleanedCount) deleted user favorites")
        }
        updateProgress(0.96)

        // Fix user_favorites that may not be indexed (one-time migration)
        let fixedCount = engine.ensureUserFavoritesIndexed()
        if fixedCount > 0 {
            NSLog("MarmotIM: Fixed indexes for \(fixedCount) user favorites")
        }
        updateProgress(1.0)

        NSLog("MarmotIM: Preloaded \(pinyinIndexes.count) pinyin, \(wubiIndexes.count) wubi, \(userLearning.count) user learning entries")
    }

    private func performMigration(db: VocabularyDatabase) {
        // Try to load from Application Support first
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dictPath = appSupport.appendingPathComponent("MarmotIM/dict/entries.json")

        var jsonURL: URL?

        if FileManager.default.fileExists(atPath: dictPath.path) {
            jsonURL = dictPath
        } else if let bundlePath = Bundle.main.url(forResource: "entries", withExtension: "json") {
            jsonURL = bundlePath
        }

        if let url = jsonURL {
            do {
                try db.importFromJSON(url: url) { [weak self] current, total in
                    let progress = Double(current) / Double(total) * 0.1 // 10% of total progress for migration
                    self?.updateProgress(progress)
                }
            } catch {
                NSLog("MarmotIM: Failed to import from JSON: \(error)")
            }
        } else {
            NSLog("MarmotIM: No dictionary JSON found for migration")
        }

        // Migrate old frecency data
        db.migrateFromFrecencyDB()
    }

    private func updateProgress(_ newProgress: Double) {
        lock.lock()
        progress = newProgress
        lock.unlock()
    }

    // MARK: - Status

    /// Get current preload status
    var status: PreloadStatus {
        lock.lock()
        defer { lock.unlock() }

        if isPreloaded {
            return .complete(time: preloadTime)
        } else if isPreloading {
            return .inProgress(progress: progress)
        } else {
            return .notStarted
        }
    }
}

// MARK: - Preload Status

enum PreloadStatus {
    case notStarted
    case inProgress(progress: Double)
    case complete(time: Double)

    var description: String {
        switch self {
        case .notStarted:
            return "Not started"
        case .inProgress(let progress):
            return String(format: "Loading... %.0f%%", progress * 100)
        case .complete(let time):
            return String(format: "Ready (loaded in %.1fs)", time)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when dictionary preload completes
    /// userInfo contains "preloadTime" (Double) - time taken in seconds
    static let dictionaryPreloadComplete = Notification.Name("MarmotIMDictionaryPreloadComplete")
}
