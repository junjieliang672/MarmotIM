import Foundation
import SQLite3

/// Manages iCloud sync for user dictionary data
/// Runs entirely on a background queue - zero impact on main thread
class iCloudSyncManager {

    // MARK: - Singleton

    static let shared = iCloudSyncManager()

    // MARK: - Public State (for UI)

    private(set) var lastSyncTime: Date?
    private(set) var lastSyncSuccess: Bool = true
    private(set) var isSyncing: Bool = false
    private(set) var isICloudAvailable: Bool = false

    /// 最近一次同步失败的原因。成功时清空。
    ///
    /// **为什么它必须存在。** 在此之前失败原因只进 `NSLog`，而 NSLog 的 `%@` 载荷在
    /// 统一日志里渲染成 `<private>` —— 也就是说那个原因事实上是拿不回来的。菜单里
    /// 只有一句「同步失败 · 点击重试」，`containerNotFound`（签名缺 entitlement，
    /// 永远不会自己好）和一次网络抖动（下次就好了）长得一模一样。
    ///
    /// 这不是假设：2026-08-13 安装脚本用源 entitlements 文件重签，丢掉了
    /// `com.apple.application-identifier`，iCloud Drive 被系统拒绝，而界面上什么
    /// 异常都看不出来 —— 五个 JSON 文件照常写进容器目录（非沙盒进程写自己家目录
    /// 本来就不需要授权），只是再没有一个字节上过云。最后是靠翻 CloudDocs 的日志
    /// 才找出来的。存下这个值，是为了下一次不必再翻。
    private(set) var lastSyncError: Error?

    // MARK: - Private Properties

    private let syncQueue = DispatchQueue(label: "com.marmotim.sync", qos: .utility)
    private var syncTimer: Timer?
    private var metadataQuery: NSMetadataQuery?
    private let syncInterval: TimeInterval = 1800  // 30 minutes

    // Database path
    private let localDBPath: URL

    // iCloud container identifier
    private let containerIdentifier = "iCloud.com.marmotim.inputmethod.MarmotIM"

    // JSON file names
    private let learningFileName = "user_learning.json"
    private let favoritesFileName = "user_favorites.json"
    private let filterFreqFileName = "filter_user_freq.json"
    private let suppressedWordsFileName = "user_suppressed_words.json"
    private let relativeOrderingFileName = "user_relative_ordering.json"

    // MARK: - Initialization

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        localDBPath = appSupport.appendingPathComponent("MarmotIM/dictionary.db")
    }

    // MARK: - Public Methods

    /// Start sync service (call on app launch)
    func start() {
        syncQueue.async { [weak self] in
            self?.checkICloudAvailability()
            if self?.isICloudAvailable == true {
                self?.performSync()
            }
        }
        setupMetadataQuery()
        startTimer()
        NSLog("MarmotIM: iCloudSyncManager started")
    }

    /// Stop sync service (call on app termination)
    func stop() {
        syncTimer?.invalidate()
        syncTimer = nil
        metadataQuery?.stop()
        metadataQuery = nil
        NSLog("MarmotIM: iCloudSyncManager stopped")
    }

    /// Manually trigger sync (user clicked sync button)
    func syncNow() {
        NSLog("MarmotIM: syncNow called - checking conditions...")
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if iCloud is available before attempting sync
            self.checkICloudAvailability()
            
            if !self.isICloudAvailable {
                NSLog("MarmotIM: iCloud is NOT available - attempting to initialize anyway to prompt user login/setup")
            }
            
            self.performSync()
        }
    }

    // MARK: - Timer Management

    private func startTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.syncTimer = Timer.scheduledTimer(
                withTimeInterval: self.syncInterval,
                repeats: true
            ) { [weak self] _ in
                self?.syncQueue.async {
                    self?.performSync()
                }
            }
        }
    }

    // MARK: - iCloud Availability

    private func checkICloudAvailability() {
        let token = FileManager.default.ubiquityIdentityToken
        isICloudAvailable = token != nil
        NSLog("MarmotIM: iCloud available check: \(isICloudAvailable) (token: \(token == nil ? "nil" : "present"))")
    }

    // MARK: - Metadata Query (Watch for remote changes)

    private func setupMetadataQuery() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.metadataQueryDidUpdate(_:)),
                name: .NSMetadataQueryDidUpdate,
                object: query
            )

            query.start()
            self.metadataQuery = query
        }
    }

    @objc private func metadataQueryDidUpdate(_ notification: Notification) {
        // Remote file changed, trigger sync
        syncQueue.async { [weak self] in
            NSLog("MarmotIM: iCloud file changed, syncing...")
            self?.performSync()
        }
    }

    // MARK: - Core Sync Logic

    private func performSync() {
        if isSyncing {
            NSLog("MarmotIM: Sync already in progress, skipping")
            return
        }

        checkICloudAvailability()

        // If manual sync (user triggered), we should try even if checkICloudAvailability returned false initially,
        // because accessing the URL might trigger system prompts or reveal status.
        // But for safety, we still check availability unless we want to force an error.

        guard isICloudAvailable else {
            NSLog("MarmotIM: iCloud not available (no identity token), aborting sync")
            // Update status to reflect failure due to unavailability
            lastSyncSuccess = false
            lastSyncError = SyncError.iCloudNotAvailable
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        do {
            // 1. Get iCloud container URL
            guard let containerURL = FileManager.default.url(
                forUbiquityContainerIdentifier: containerIdentifier
            ) else {
                throw SyncError.containerNotFound
            }

            let documentsURL = containerURL.appendingPathComponent("Documents")
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)

            // 2. Drive the testable sync entry point with the production
            // iCloud documents URL + the production DB path.
            try syncOnce(documentsURL: documentsURL, dbPath: localDBPath)

            // 3. Update status
            lastSyncTime = Date()
            lastSyncSuccess = true
            lastSyncError = nil
            NSLog("MarmotIM: Sync completed successfully")

        } catch {
            lastSyncSuccess = false
            lastSyncError = error
            NSLog("MarmotIM: Sync failed: \(error)")
        }
    }

    /// Test-facing sync entry point. Performs one full round of sync
    /// (learning + favorites + filter freq + suppressed words + relative
    /// ordering) against the given documents directory and local DB file,
    /// no iCloud entitlement required.
    ///
    /// Production `performSync` wraps this with the real iCloud container
    /// lookup and lifecycle flags. Tests (DualDeviceSyncHarness, T7) call
    /// this directly against a tempDir acting as the "iCloud" directory.
    /// See decision 004-testability-via-syncOnce-refactor in spec-003.
    internal func syncOnce(documentsURL: URL, dbPath: URL) throws {
        // Save current DB path, swap in the test path if different, and
        // restore on exit so the same manager can be reused for either.
        let savedPath = localDBPathOverride
        localDBPathOverride = dbPath
        defer { localDBPathOverride = savedPath }

        try syncLearningData(documentsURL: documentsURL)
        try syncFavoritesData(documentsURL: documentsURL)
        try syncFilterFreqData(documentsURL: documentsURL)
        try syncSuppressedWordsData(documentsURL: documentsURL)
        try syncRelativeOrderingData(documentsURL: documentsURL)
    }

    /// Dynamic DB path used by all read/write helpers. Defaults to the
    /// production localDBPath; `syncOnce` swaps this to a test path for
    /// the duration of a test call. Thread safety: syncQueue serializes.
    private var localDBPathOverride: URL?
    internal var activeLocalDBPath: URL {
        return localDBPathOverride ?? localDBPath
    }

    // MARK: - Per-payload sync state markers (spec-004 decision 012)
    //
    // Track whether this device has ever successfully synced each payload
    // so the `.notFound` branch can distinguish:
    //
    //   (a) first-ever upload on a fresh device — safe to write local up.
    //   (b) cloud file deleted after a prior sync — dangerous; skip write.
    //
    // The marker is a small empty file placed next to the active DB,
    // named `.marmotim.sync-state.<payload-name>`. We use the DB's parent
    // directory so it inherits the DB's lifecycle (tests in harness share
    // tempDir, production uses ~/Library/Application Support/MarmotIM/).

    private func syncStateMarkerURL(for payloadFileName: String) -> URL {
        let dir = activeLocalDBPath.deletingLastPathComponent()
        return dir.appendingPathComponent(".marmotim.sync-state.\(payloadFileName)")
    }

    internal func hasPayloadEverSynced(_ payloadFileName: String) -> Bool {
        return FileManager.default.fileExists(atPath: syncStateMarkerURL(for: payloadFileName).path)
    }

    internal func markPayloadSynced(_ payloadFileName: String) {
        let marker = syncStateMarkerURL(for: payloadFileName)
        // Ensure parent dir exists (defensive — in prod the dir is always there).
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: marker.path) {
            let ok = FileManager.default.createFile(atPath: marker.path, contents: nil)
            if !ok {
                NSLog("MarmotIM: [W][sync] sync-state marker write failed payload=\(payloadFileName) action=will_retry_next_sync impact=first_sync_skip_heuristic_degraded")
            }
        }
    }

    // MARK: - Sync User Learning

    private func syncLearningData(documentsURL: URL) throws {
        let remoteURL = documentsURL.appendingPathComponent(learningFileName)

        let localRecords = try readLocalLearning()

        // Check file download status before reading
        let downloadStatus = ensureFileDownloaded(at: remoteURL)

        switch downloadStatus {
        case .ready:
            // Normal case: file is ready, proceed with merge
            let remoteRecords = try readRemoteLearningContent(from: remoteURL)
            let merged = SyncMerger.mergeLearning(local: localRecords, remote: remoteRecords)

            let changed = SyncMerger.findChangedLearning(merged: merged, original: localRecords)
            if !changed.isEmpty {
                try writeLocalLearning(changed)
                NSLog("MarmotIM: Updated \(changed.count) learning records")
            }

            // Safe to write merged result back
            try writeRemoteLearning(merged, to: remoteURL)
            markPayloadSynced(learningFileName)

        case .notFound:
            // File missing in cloud. Spec-004 decision 012 bifurcation:
            //   (a) marker set (we've synced before) → local is
            //       authoritative for the state WE contributed; upload
            //       it to restore cloud.
            //   (b) marker absent + non-empty local → genuine first-ever
            //       upload (or new device whose cloud state was a race
            //       casualty; accept the residual risk). Upload.
            //   (c) marker absent + empty local → no signal at all that
            //       we have any right to establish cloud state. Skip to
            //       avoid clobbering what another device may have had.
            if localRecords.isEmpty && !hasPayloadEverSynced(learningFileName) {
                NSLog("MarmotIM: [I][sync] learning file notFound first_sync=true local_empty=true action=skip reason=decision_012")
            } else {
                NSLog("MarmotIM: [I][sync] learning file notFound action=upload prior_sync=\(hasPayloadEverSynced(learningFileName)) local_rows=\(localRecords.count)")
                try writeRemoteLearning(localRecords, to: remoteURL)
                markPayloadSynced(learningFileName)
            }

        case .downloadFailed:
            // CRITICAL: Remote file exists but couldn't be downloaded
            // DO NOT write to remote - this would overwrite valid cloud data!
            NSLog("MarmotIM: Skipping learning sync - remote file download failed, preventing data loss")
        }
    }

    // MARK: - Sync User Favorites

    private func syncFavoritesData(documentsURL: URL) throws {
        let remoteURL = documentsURL.appendingPathComponent(favoritesFileName)

        let localRecords = try readLocalFavorites()

        // Check file download status before reading
        let downloadStatus = ensureFileDownloaded(at: remoteURL)

        switch downloadStatus {
        case .ready:
            // Normal case: file is ready, proceed with merge
            let remoteRecords = try readRemoteFavoritesContent(from: remoteURL)
            let merged = SyncMerger.mergeFavorites(local: localRecords, remote: remoteRecords)

            let changed = SyncMerger.findChangedFavorites(merged: merged, original: localRecords)
            if !changed.isEmpty {
                try writeLocalFavorites(changed)
                NSLog("MarmotIM: Updated \(changed.count) favorite records")
                // writeLocalFavorites only touches user_favorites via a raw
                // sqlite3 connection — it never goes through
                // DictionaryEngine.addUserEntry(), so the running process's
                // in-memory userTierIndex/entries table is now stale. Notify
                // so AppDelegate can reconcile it without a restart.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .userDictionaryDidChange, object: nil)
                }
            }

            // Safe to write merged result back
            try writeRemoteFavorites(merged, to: remoteURL)
            markPayloadSynced(favoritesFileName)

        case .notFound:
            // See syncLearningData for rationale (decision 012).
            if localRecords.isEmpty && !hasPayloadEverSynced(favoritesFileName) {
                NSLog("MarmotIM: [I][sync] favorites file notFound first_sync=true local_empty=true action=skip reason=decision_012")
            } else {
                NSLog("MarmotIM: [I][sync] favorites file notFound action=upload prior_sync=\(hasPayloadEverSynced(favoritesFileName)) local_rows=\(localRecords.count)")
                try writeRemoteFavorites(localRecords, to: remoteURL)
                markPayloadSynced(favoritesFileName)
            }

        case .downloadFailed:
            // CRITICAL: Remote file exists but couldn't be downloaded
            // DO NOT write to remote - this would overwrite valid cloud data!
            NSLog("MarmotIM: Skipping favorites sync - remote file download failed, preventing data loss")
        }
    }

    // MARK: - Sync Filter User Freq

    private func syncFilterFreqData(documentsURL: URL) throws {
        let remoteURL = documentsURL.appendingPathComponent(filterFreqFileName)

        let localRecords = try readLocalFilterFreq()

        // Check file download status before reading
        let downloadStatus = ensureFileDownloaded(at: remoteURL)

        switch downloadStatus {
        case .ready:
            // Normal case: file is ready, proceed with merge
            let remoteRecords = try readRemoteFilterFreqContent(from: remoteURL)
            let merged = SyncMerger.mergeFilterFreq(local: localRecords, remote: remoteRecords)

            let changed = SyncMerger.findChangedFilterFreq(merged: merged, original: localRecords)
            if !changed.isEmpty {
                try writeLocalFilterFreq(changed)
                NSLog("MarmotIM: Updated \(changed.count) filter freq records")
            }

            // Safe to write merged result back
            try writeRemoteFilterFreq(merged, to: remoteURL)
            markPayloadSynced(filterFreqFileName)

        case .notFound:
            // See syncLearningData for rationale (decision 012).
            if localRecords.isEmpty && !hasPayloadEverSynced(filterFreqFileName) {
                NSLog("MarmotIM: [I][sync] filter freq file notFound first_sync=true local_empty=true action=skip reason=decision_012")
            } else {
                NSLog("MarmotIM: [I][sync] filter freq file notFound action=upload prior_sync=\(hasPayloadEverSynced(filterFreqFileName)) local_rows=\(localRecords.count)")
                try writeRemoteFilterFreq(localRecords, to: remoteURL)
                markPayloadSynced(filterFreqFileName)
            }

        case .downloadFailed:
            // CRITICAL: Remote file exists but couldn't be downloaded
            // DO NOT write to remote - this would overwrite valid cloud data!
            NSLog("MarmotIM: Skipping filter freq sync - remote file download failed, preventing data loss")
        }
    }

    // MARK: - Sync Suppressed Words

    private func syncSuppressedWordsData(documentsURL: URL) throws {
        let remoteURL = documentsURL.appendingPathComponent(suppressedWordsFileName)

        let localRecords = try readLocalSuppressedWords()

        // Check file download status before reading
        let downloadStatus = ensureFileDownloaded(at: remoteURL)

        switch downloadStatus {
        case .ready:
            // Normal case: file is ready, proceed with merge
            let remoteRecords = try readRemoteSuppressedWordsContent(from: remoteURL)
            let merged = SyncMerger.mergeSuppressedWords(local: localRecords, remote: remoteRecords)

            let changed = SyncMerger.findChangedSuppressedWords(merged: merged, original: localRecords)
            if !changed.isEmpty {
                try writeLocalSuppressedWords(changed)
                NSLog("MarmotIM: Updated \(changed.count) suppressed word records")
                // Post notification to update suppressed words cache
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .suppressedWordsDidChange, object: nil)
                }
            }

            // Safe to write merged result back
            try writeRemoteSuppressedWords(merged, to: remoteURL)
            markPayloadSynced(suppressedWordsFileName)

        case .notFound:
            // See syncLearningData for rationale (decision 012).
            if localRecords.isEmpty && !hasPayloadEverSynced(suppressedWordsFileName) {
                NSLog("MarmotIM: [I][sync] suppressed words file notFound first_sync=true local_empty=true action=skip reason=decision_012")
            } else {
                NSLog("MarmotIM: [I][sync] suppressed words file notFound action=upload prior_sync=\(hasPayloadEverSynced(suppressedWordsFileName)) local_rows=\(localRecords.count)")
                try writeRemoteSuppressedWords(localRecords, to: remoteURL)
                markPayloadSynced(suppressedWordsFileName)
            }

        case .downloadFailed:
            // CRITICAL: Remote file exists but couldn't be downloaded
            // DO NOT write to remote - this would overwrite valid cloud data!
            NSLog("MarmotIM: Skipping suppressed words sync - remote file download failed, preventing data loss")
        }
    }

    // MARK: - Sync Relative Ordering (spec-003)

    private func syncRelativeOrderingData(documentsURL: URL) throws {
        let remoteURL = documentsURL.appendingPathComponent(relativeOrderingFileName)

        let localRecords = try readLocalRelativeOrdering()

        let downloadStatus = ensureFileDownloaded(at: remoteURL)

        switch downloadStatus {
        case .ready:
            NSLog("MarmotIM: [I][sync] syncing relative order file status=ready")
            let remoteRecords = try readRemoteRelativeOrderingContent(from: remoteURL)
            let (merged, dropped) = SyncMerger.mergeRelativeOrdering(
                local: localRecords,
                remote: remoteRecords
            )
            let changed = SyncMerger.findChangedRelativeOrdering(merged: merged, original: localRecords)
            if !changed.isEmpty {
                try writeLocalRelativeOrdering(changed)
                NSLog("MarmotIM: [I][sync] relative order merge complete records_received=\(remoteRecords.count) records_new=\(changed.count) records_cycle_dropped=\(dropped.count)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .relativeOrderingDidChange, object: nil)
                }
            } else {
                NSLog("MarmotIM: [I][sync] relative order merge complete records_received=\(remoteRecords.count) records_new=0 records_cycle_dropped=\(dropped.count)")
            }
            try writeRemoteRelativeOrdering(merged, to: remoteURL)
            markPayloadSynced(relativeOrderingFileName)

        case .notFound:
            // See syncLearningData for rationale (decision 012).
            if localRecords.isEmpty && !hasPayloadEverSynced(relativeOrderingFileName) {
                NSLog("MarmotIM: [I][sync] relative order file notFound first_sync=true local_empty=true action=skip reason=decision_012")
            } else {
                NSLog("MarmotIM: [I][sync] relative order file notFound action=upload prior_sync=\(hasPayloadEverSynced(relativeOrderingFileName)) local_rows=\(localRecords.count)")
                try writeRemoteRelativeOrdering(localRecords, to: remoteURL)
                markPayloadSynced(relativeOrderingFileName)
            }

        case .downloadFailed:
            NSLog("MarmotIM: [W][sync] syncing relative order file status=downloadFailed action=skip")
        }
    }

    private func readLocalRelativeOrdering() throws -> [String: RelativeOrderingRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(activeLocalDBPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        // Include tombstones — sync needs them for LWW semantics.
        var records: [String: RelativeOrderingRecord] = [:]
        let sql = "SELECT word_a, word_b, created_at, updated_at, is_deleted FROM user_relative_order"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let wordA = String(cString: sqlite3_column_text(stmt, 0))
            let wordB = String(cString: sqlite3_column_text(stmt, 1))
            let createdAt = Int(sqlite3_column_int(stmt, 2))
            let updatedAt = Int(sqlite3_column_int(stmt, 3))
            let isDeleted = sqlite3_column_int(stmt, 4) != 0
            if wordA.isEmpty || wordB.isEmpty { continue }
            let key = RelativeOrderingRecord.makeKey(wordA: wordA, wordB: wordB)
            records[key] = RelativeOrderingRecord(
                createdAt: createdAt,
                updatedAt: updatedAt,
                isDeleted: isDeleted
            )
        }
        return records
    }

    private func readRemoteRelativeOrderingContent(from url: URL) throws -> [String: RelativeOrderingRecord] {
        var coordinatorError: NSError?
        var readError: Error?
        var records: [String: RelativeOrderingRecord] = [:]

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordURL in
            do {
                let data = try Data(contentsOf: coordURL)
                let syncFile = try JSONDecoder().decode(SyncFile<RelativeOrderingRecord>.self, from: data)
                records = syncFile.records
            } catch {
                readError = error
            }
        }
        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = readError { throw error }
        return records
    }

    private func writeLocalRelativeOrdering(_ records: [(String, RelativeOrderingRecord)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(activeLocalDBPath.path, &db) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        let sql = """
            INSERT INTO user_relative_order
            (word_a, word_b, created_at, updated_at, is_deleted)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(word_a, word_b) DO UPDATE SET
                created_at = MIN(user_relative_order.created_at, excluded.created_at),
                updated_at = excluded.updated_at,
                is_deleted = excluded.is_deleted
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        for (key, record) in records {
            guard let pair = RelativeOrderingRecord.parseKey(key) else {
                NSLog("MarmotIM: [W][sync] relative order skipping invalid key action=noop")
                continue
            }
            let aNS = pair.wordA as NSString
            let bNS = pair.wordB as NSString
            sqlite3_bind_text(stmt, 1, aNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, bNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 3, Int32(record.createdAt))
            sqlite3_bind_int(stmt, 4, Int32(record.updatedAt))
            sqlite3_bind_int(stmt, 5, record.isDeleted ? 1 : 0)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func writeRemoteRelativeOrdering(_ records: [String: RelativeOrderingRecord], to url: URL) throws {
        let syncFile = SyncFile(records: records)
        let data = try JSONEncoder().encode(syncFile)

        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = writeError { throw error }
    }

    // MARK: - Read Local Database

    private func readLocalLearning() throws -> [String: LearningRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(activeLocalDBPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        var records: [String: LearningRecord] = [:]
        let sql = "SELECT entry_id, access_count, last_access_timestamp, total_score FROM user_learning"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let entryId = String(sqlite3_column_int64(stmt, 0))
            let record = LearningRecord(
                accessCount: Int(sqlite3_column_int(stmt, 1)),
                lastAccessTimestamp: Int(sqlite3_column_int(stmt, 2)),
                totalScore: sqlite3_column_double(stmt, 3)
            )
            records[entryId] = record
        }

        return records
    }

    private func readLocalFavorites() throws -> [String: FavoriteRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(activeLocalDBPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        var records: [String: FavoriteRecord] = [:]
        let sql = "SELECT text, wubi_code, pinyin_code, added_timestamp, is_deleted FROM user_favorites"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(stmt, 0))
            let wubiCode = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let pinyinCode = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let addedTimestamp = Int(sqlite3_column_int(stmt, 3))
            let isDeleted = sqlite3_column_int(stmt, 4) != 0

            records[text] = FavoriteRecord(
                wubiCode: wubiCode,
                pinyinCode: pinyinCode,
                addedTimestamp: addedTimestamp,
                isDeleted: isDeleted
            )
        }

        return records
    }

    private func readLocalFilterFreq() throws -> [String: FilterFreqRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(activeLocalDBPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        var records: [String: FilterFreqRecord] = [:]
        let sql = "SELECT filter_type, code, word, frequency, last_used FROM filter_user_freq"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let filterType = String(cString: sqlite3_column_text(stmt, 0))
            let code = String(cString: sqlite3_column_text(stmt, 1))
            let word = String(cString: sqlite3_column_text(stmt, 2))
            let frequency = Int(sqlite3_column_int(stmt, 3))
            let lastUsed = sqlite3_column_double(stmt, 4)

            let key = FilterFreqRecord.makeKey(filterType: filterType, code: code, word: word)
            records[key] = FilterFreqRecord(frequency: frequency, lastUsed: lastUsed)
        }

        return records
    }

    private func readLocalSuppressedWords() throws -> [String: SuppressedWordRecord] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(activeLocalDBPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        var records: [String: SuppressedWordRecord] = [:]
        let sql = "SELECT text, suppressed_timestamp, is_deleted FROM user_suppressed_words"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(stmt, 0))
            let suppressedTimestamp = Int(sqlite3_column_int(stmt, 1))
            let isDeleted = sqlite3_column_int(stmt, 2) != 0

            records[text] = SuppressedWordRecord(
                suppressedTimestamp: suppressedTimestamp,
                isDeleted: isDeleted
            )
        }

        return records
    }

    // MARK: - iCloud File Download Status

    /// Status of an iCloud file download attempt
    private enum FileDownloadStatus {
        case ready          // File is downloaded and ready to read
        case notFound       // File doesn't exist in iCloud
        case downloadFailed // File exists in iCloud but download failed/timed out
    }

    /// Ensure an iCloud file is downloaded before reading
    /// Uses URL resource values to check actual download status (Apple recommended approach)
    private func ensureFileDownloaded(at url: URL) -> FileDownloadStatus {
        let fileManager = FileManager.default

        // First check if the file is an iCloud ubiquitous item or exists locally
        guard fileManager.isUbiquitousItem(at: url) || fileManager.fileExists(atPath: url.path) else {
            // Check for .icloud placeholder (indicates file is in cloud but not downloaded)
            let placeholderName = "." + url.lastPathComponent + ".icloud"
            let placeholderURL = url.deletingLastPathComponent().appendingPathComponent(placeholderName)

            if fileManager.fileExists(atPath: placeholderURL.path) {
                // Placeholder exists - file is in iCloud but not downloaded
                return triggerDownloadAndWait(at: url)
            }

            // No file and no placeholder - file doesn't exist
            return .notFound
        }

        // Check download status using URL resource values (Apple recommended approach)
        do {
            let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if let status = resourceValues.ubiquitousItemDownloadingStatus {
                switch status {
                case .current, .downloaded:
                    return .ready
                case .notDownloaded:
                    return triggerDownloadAndWait(at: url)
                default:
                    // Handle any future cases by attempting download
                    return triggerDownloadAndWait(at: url)
                }
            }
        } catch {
            NSLog("MarmotIM: Failed to get resource values for \(url.lastPathComponent): \(error)")
        }

        // Fallback: if file exists locally, it's ready
        if fileManager.fileExists(atPath: url.path) {
            return .ready
        }

        return .notFound
    }

    /// Trigger download of an iCloud file and wait for it to complete
    private func triggerDownloadAndWait(at url: URL) -> FileDownloadStatus {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            NSLog("MarmotIM: Triggered download for iCloud file: \(url.lastPathComponent)")

            // Wait for download with timeout
            let timeout: TimeInterval = 30.0  // 30 seconds for larger files
            let startTime = Date()

            while true {
                if FileManager.default.fileExists(atPath: url.path) {
                    // Double-check it's actually downloaded
                    if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                       let status = values.ubiquitousItemDownloadingStatus,
                       status == .current || status == .downloaded {
                        return .ready
                    }
                    // File exists locally, assume it's ready
                    return .ready
                }

                if Date().timeIntervalSince(startTime) > timeout {
                    NSLog("MarmotIM: Timeout waiting for iCloud file download: \(url.lastPathComponent)")
                    return .downloadFailed
                }

                Thread.sleep(forTimeInterval: 0.2)
            }
        } catch {
            NSLog("MarmotIM: Failed to start downloading iCloud file: \(error)")
            return .downloadFailed
        }
    }

    // MARK: - Read Remote (iCloud)

    /// Read remote learning records (caller must ensure file is downloaded first)
    private func readRemoteLearningContent(from url: URL) throws -> [String: LearningRecord] {
        var coordinatorError: NSError?
        var readError: Error?
        var records: [String: LearningRecord] = [:]

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordURL in
            do {
                let data = try Data(contentsOf: coordURL)
                let syncFile = try JSONDecoder().decode(SyncFile<LearningRecord>.self, from: data)
                records = syncFile.records
            } catch {
                readError = error
            }
        }

        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = readError {
            throw error
        }

        return records
    }

    /// Read remote favorites records (caller must ensure file is downloaded first)
    private func readRemoteFavoritesContent(from url: URL) throws -> [String: FavoriteRecord] {
        var coordinatorError: NSError?
        var readError: Error?
        var records: [String: FavoriteRecord] = [:]

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordURL in
            do {
                let data = try Data(contentsOf: coordURL)
                let syncFile = try JSONDecoder().decode(SyncFile<FavoriteRecord>.self, from: data)
                records = syncFile.records
            } catch {
                readError = error
            }
        }

        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = readError {
            throw error
        }

        return records
    }

    /// Read remote filter freq records (caller must ensure file is downloaded first)
    private func readRemoteFilterFreqContent(from url: URL) throws -> [String: FilterFreqRecord] {
        var coordinatorError: NSError?
        var readError: Error?
        var records: [String: FilterFreqRecord] = [:]

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordURL in
            do {
                let data = try Data(contentsOf: coordURL)
                let syncFile = try JSONDecoder().decode(SyncFile<FilterFreqRecord>.self, from: data)
                records = syncFile.records
            } catch {
                readError = error
            }
        }

        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = readError {
            throw error
        }

        return records
    }

    /// Read remote suppressed words records (caller must ensure file is downloaded first)
    private func readRemoteSuppressedWordsContent(from url: URL) throws -> [String: SuppressedWordRecord] {
        var coordinatorError: NSError?
        var readError: Error?
        var records: [String: SuppressedWordRecord] = [:]

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordURL in
            do {
                let data = try Data(contentsOf: coordURL)
                let syncFile = try JSONDecoder().decode(SyncFile<SuppressedWordRecord>.self, from: data)
                records = syncFile.records
            } catch {
                readError = error
            }
        }

        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = readError {
            throw error
        }

        return records
    }

    // MARK: - Write Local Database

    private func writeLocalLearning(_ records: [(String, LearningRecord)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(activeLocalDBPath.path, &db) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let sql = """
            INSERT OR REPLACE INTO user_learning
            (entry_id, access_count, last_access_timestamp, total_score)
            VALUES (?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        for (entryIdStr, record) in records {
            guard let entryId = Int64(entryIdStr) else { continue }
            sqlite3_bind_int64(stmt, 1, entryId)
            sqlite3_bind_int(stmt, 2, Int32(record.accessCount))
            sqlite3_bind_int(stmt, 3, Int32(record.lastAccessTimestamp))
            sqlite3_bind_double(stmt, 4, record.totalScore)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func writeLocalFavorites(_ records: [(String, FavoriteRecord)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(activeLocalDBPath.path, &db) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let sql = """
            INSERT OR REPLACE INTO user_favorites
            (text, wubi_code, pinyin_code, added_timestamp, is_deleted)
            VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        for (text, record) in records {
            let textNS = text as NSString
            sqlite3_bind_text(stmt, 1, textNS.utf8String, -1, nil)
            if let wubi = record.wubiCode {
                let wubiNS = wubi as NSString
                sqlite3_bind_text(stmt, 2, wubiNS.utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let pinyin = record.pinyinCode {
                let pinyinNS = pinyin as NSString
                sqlite3_bind_text(stmt, 3, pinyinNS.utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int(stmt, 4, Int32(record.addedTimestamp))
            sqlite3_bind_int(stmt, 5, record.isDeleted ? 1 : 0)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func writeLocalFilterFreq(_ records: [(String, FilterFreqRecord)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(activeLocalDBPath.path, &db) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let sql = """
            INSERT OR REPLACE INTO filter_user_freq
            (filter_type, code, word, frequency, last_used)
            VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        for (key, record) in records {
            guard let parts = FilterFreqRecord.parseKey(key) else { continue }
            let filterTypeNS = parts.filterType as NSString
            let codeNS = parts.code as NSString
            let wordNS = parts.word as NSString
            sqlite3_bind_text(stmt, 1, filterTypeNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, codeNS.utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, wordNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, Int32(record.frequency))
            sqlite3_bind_double(stmt, 5, record.lastUsed)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func writeLocalSuppressedWords(_ records: [(String, SuppressedWordRecord)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(activeLocalDBPath.path, &db) == SQLITE_OK else {
            throw SyncError.databaseOpenFailed
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

        let sql = """
            INSERT OR REPLACE INTO user_suppressed_words
            (text, suppressed_timestamp, is_deleted)
            VALUES (?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        for (text, record) in records {
            let textNS = text as NSString
            sqlite3_bind_text(stmt, 1, textNS.utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(record.suppressedTimestamp))
            sqlite3_bind_int(stmt, 3, record.isDeleted ? 1 : 0)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    // MARK: - Write Remote (iCloud)

    private func writeRemoteLearning(_ records: [String: LearningRecord], to url: URL) throws {
        let syncFile = SyncFile(records: records)
        let data = try JSONEncoder().encode(syncFile)

        var coordinatorError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = writeError {
            throw error
        }
    }

    private func writeRemoteFavorites(_ records: [String: FavoriteRecord], to url: URL) throws {
        let syncFile = SyncFile(records: records)
        let data = try JSONEncoder().encode(syncFile)

        var coordinatorError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = writeError {
            throw error
        }
    }

    private func writeRemoteFilterFreq(_ records: [String: FilterFreqRecord], to url: URL) throws {
        let syncFile = SyncFile(records: records)
        let data = try JSONEncoder().encode(syncFile)

        var coordinatorError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = writeError {
            throw error
        }
    }

    private func writeRemoteSuppressedWords(_ records: [String: SuppressedWordRecord], to url: URL) throws {
        let syncFile = SyncFile(records: records)
        let data = try JSONEncoder().encode(syncFile)

        var coordinatorError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let error = coordinatorError {
            throw SyncError.fileCoordinationFailed(underlying: error)
        }
        if let error = writeError {
            throw error
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when suppressed words are updated via sync
    static let suppressedWordsDidChange = Notification.Name("MarmotIMSuppressedWordsDidChange")

    /// Posted when relative-ordering rules are updated via sync (spec-003).
    /// Observers (AppDelegate) should call
    /// `DictionaryEngine.updateRelativeOrderingCache()` so the ranker's
    /// in-memory rule cache stays fresh.
    static let relativeOrderingDidChange = Notification.Name("MarmotIMRelativeOrderingDidChange")
}
