import Foundation
import SQLite3

private let SQLITE_TRANSIENT_SYNC = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    /// Delay between a local edit and the sync it triggers. Several edits in a
    /// row (deleting a batch of words in settings) collapse into one upload.
    private let localChangeDebounce: TimeInterval = 5
    private var pendingLocalSync: DispatchWorkItem?

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localSyncedDataDidChange(_:)),
            name: .localSyncedDataDidChange,
            object: nil
        )
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

    @objc private func localSyncedDataDidChange(_ notification: Notification) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingLocalSync?.cancel()
            let work = DispatchWorkItem { [weak self] in
                NSLog("MarmotIM: [I][sync] local change, syncing")
                self?.performSync()
            }
            self.pendingLocalSync = work
            self.syncQueue.asyncAfter(deadline: .now() + self.localChangeDebounce, execute: work)
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

        // Each payload is independent: a corrupt or unreadable file must not
        // stop the other four from syncing. The first error is rethrown at
        // the end so the menu still reports the failure.
        let payloads: [(String, (URL) throws -> Void)] = [
            (learningFileName, syncLearningData),
            (favoritesFileName, syncFavoritesData),
            (filterFreqFileName, syncFilterFreqData),
            (suppressedWordsFileName, syncSuppressedWordsData),
            (relativeOrderingFileName, syncRelativeOrderingData),
        ]
        var firstError: Error?
        for (name, sync) in payloads {
            do {
                try sync(documentsURL)
            } catch {
                NSLog("MarmotIM: [E][sync] payload failed file=\(name) error=\(error)")
                if firstError == nil { firstError = error }
            }
        }
        if let error = firstError { throw error }
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
            let (remoteFolded, conflicts) = foldConflictVersions(
                remoteRecords, at: remoteURL, merge: SyncMerger.mergeLearning)
            let merged = SyncMerger.mergeLearning(local: localRecords, remote: remoteFolded)

            let changed = SyncMerger.findChangedLearning(merged: merged, original: localRecords)
            if !changed.isEmpty {
                try writeLocalLearning(changed)
                NSLog("MarmotIM: Updated \(changed.count) learning records")
                // The ranker reads userLearningCache, which is only filled at
                // preload. Without a reload the synced rows never reach ranking,
                // and the next selection writes the stale cached score back.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .userLearningDidChange, object: nil)
                }
            }

            if merged != remoteRecords || !conflicts.isEmpty {
                try writeRemoteLearning(merged, to: remoteURL)
            }
            resolveConflictVersions(conflicts, at: remoteURL)
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
            let (remoteFolded, conflicts) = foldConflictVersions(
                remoteRecords, at: remoteURL, merge: SyncMerger.mergeFavorites)
            let merged = SyncMerger.mergeFavorites(local: localRecords, remote: remoteFolded)

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

            if merged != remoteRecords || !conflicts.isEmpty {
                try writeRemoteFavorites(merged, to: remoteURL)
            }
            resolveConflictVersions(conflicts, at: remoteURL)
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
            let (remoteFolded, conflicts) = foldConflictVersions(
                remoteRecords, at: remoteURL, merge: SyncMerger.mergeFilterFreq)
            let merged = SyncMerger.mergeFilterFreq(local: localRecords, remote: remoteFolded)

            let changed = SyncMerger.findChangedFilterFreq(merged: merged, original: localRecords)
            if !changed.isEmpty {
                try writeLocalFilterFreq(changed)
                NSLog("MarmotIM: Updated \(changed.count) filter freq records")
            }

            if merged != remoteRecords || !conflicts.isEmpty {
                try writeRemoteFilterFreq(merged, to: remoteURL)
            }
            resolveConflictVersions(conflicts, at: remoteURL)
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
            let (remoteFolded, conflicts) = foldConflictVersions(
                remoteRecords, at: remoteURL, merge: SyncMerger.mergeSuppressedWords)
            let merged = SyncMerger.mergeSuppressedWords(local: localRecords, remote: remoteFolded)

            let changed = SyncMerger.findChangedSuppressedWords(merged: merged, original: localRecords)
            if !changed.isEmpty {
                try writeLocalSuppressedWords(changed)
                NSLog("MarmotIM: Updated \(changed.count) suppressed word records")
                // Post notification to update suppressed words cache
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .suppressedWordsDidChange, object: nil)
                }
            }

            if merged != remoteRecords || !conflicts.isEmpty {
                try writeRemoteSuppressedWords(merged, to: remoteURL)
            }
            resolveConflictVersions(conflicts, at: remoteURL)
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
            let (remoteFolded, conflicts) = foldConflictVersions(remoteRecords, at: remoteURL) {
                SyncMerger.mergeRelativeOrdering(local: $0, remote: $1).merged
            }
            let (merged, dropped) = SyncMerger.mergeRelativeOrdering(
                local: localRecords,
                remote: remoteFolded
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
            if merged != remoteRecords || !conflicts.isEmpty {
                try writeRemoteRelativeOrdering(merged, to: remoteURL)
            }
            resolveConflictVersions(conflicts, at: remoteURL)
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
        try writeLocalRows(records, sql: """
            INSERT INTO user_relative_order
            (word_a, word_b, created_at, updated_at, is_deleted)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(word_a, word_b) DO UPDATE SET
                created_at = MIN(user_relative_order.created_at, excluded.created_at),
                updated_at = excluded.updated_at,
                is_deleted = excluded.is_deleted
        """) { stmt, row in
            let (key, record) = row
            guard let pair = RelativeOrderingRecord.parseKey(key) else {
                NSLog("MarmotIM: [W][sync] relative order skipping invalid key action=noop")
                return false
            }
            sqlite3_bind_text(stmt, 1, pair.wordA, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_text(stmt, 2, pair.wordB, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_int(stmt, 3, Int32(record.createdAt))
            sqlite3_bind_int(stmt, 4, Int32(record.updatedAt))
            sqlite3_bind_int(stmt, 5, record.isDeleted ? 1 : 0)
            return true
        }
    }

    private func writeRemoteRelativeOrdering(_ records: [String: RelativeOrderingRecord], to url: URL) throws {
        try writeRemoteRecords(records, to: url)
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
                case .current:
                    return .ready
                case .downloaded:
                    // A local copy exists but iCloud has a newer one. Merging the
                    // stale copy and writing it back with .forReplacing would
                    // overwrite the other Mac's changes.
                    return triggerDownloadAndWait(at: url)
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
                // Wait for .current. A dataless (evicted) file already "exists"
                // on macOS 14+, so fileExists says nothing about freshness.
                var fetchURL = url
                fetchURL.removeAllCachedResourceValues()
                let status = (try? fetchURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus
                if status == .current {
                    return .ready
                }
                if status == nil && FileManager.default.fileExists(atPath: url.path) {
                    // Not an iCloud item: the local file is the file
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
        try writeLocalRows(records, sql: """
            INSERT OR REPLACE INTO user_learning
            (entry_id, access_count, last_access_timestamp, total_score)
            VALUES (?, ?, ?, ?)
        """) { stmt, row in
            let (entryIdStr, record) = row
            guard let entryId = Int64(entryIdStr) else { return false }
            sqlite3_bind_int64(stmt, 1, entryId)
            sqlite3_bind_int(stmt, 2, Int32(record.accessCount))
            sqlite3_bind_int(stmt, 3, Int32(record.lastAccessTimestamp))
            sqlite3_bind_double(stmt, 4, record.totalScore)
            return true
        }
    }

    private func writeLocalFavorites(_ records: [(String, FavoriteRecord)]) throws {
        // user_favorites is UNIQUE(text) since schema v9, so REPLACE swaps the
        // word's single row instead of adding a second one next to it.
        try writeLocalRows(records, sql: """
            INSERT OR REPLACE INTO user_favorites
            (text, wubi_code, pinyin_code, added_timestamp, is_deleted)
            VALUES (?, ?, ?, ?, ?)
        """) { stmt, row in
            let (text, record) = row
            sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT_SYNC)
            if let wubi = record.wubiCode {
                sqlite3_bind_text(stmt, 2, wubi, -1, SQLITE_TRANSIENT_SYNC)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let pinyin = record.pinyinCode {
                sqlite3_bind_text(stmt, 3, pinyin, -1, SQLITE_TRANSIENT_SYNC)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int(stmt, 4, Int32(record.addedTimestamp))
            sqlite3_bind_int(stmt, 5, record.isDeleted ? 1 : 0)
            return true
        }
    }

    private func writeLocalFilterFreq(_ records: [(String, FilterFreqRecord)]) throws {
        try writeLocalRows(records, sql: """
            INSERT OR REPLACE INTO filter_user_freq
            (filter_type, code, word, frequency, last_used)
            VALUES (?, ?, ?, ?, ?)
        """) { stmt, row in
            let (key, record) = row
            guard let parts = FilterFreqRecord.parseKey(key) else { return false }
            sqlite3_bind_text(stmt, 1, parts.filterType, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_text(stmt, 2, parts.code, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_text(stmt, 3, parts.word, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_int(stmt, 4, Int32(record.frequency))
            sqlite3_bind_double(stmt, 5, record.lastUsed)
            return true
        }
    }

    private func writeLocalSuppressedWords(_ records: [(String, SuppressedWordRecord)]) throws {
        try writeLocalRows(records, sql: """
            INSERT OR REPLACE INTO user_suppressed_words
            (text, suppressed_timestamp, is_deleted)
            VALUES (?, ?, ?)
        """) { stmt, row in
            let (text, record) = row
            sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_int(stmt, 2, Int32(record.suppressedTimestamp))
            sqlite3_bind_int(stmt, 3, record.isDeleted ? 1 : 0)
            return true
        }
    }

    /// Open the local DB for a sync write. The input method's own connection
    /// writes user_learning on every selection; without a busy timeout a sync
    /// insert that hits its lock fails immediately with SQLITE_BUSY.
    private func openLocalDBForWriting() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(activeLocalDBPath.path, &db) == SQLITE_OK, let handle = db else {
            sqlite3_close(db)
            throw SyncError.databaseOpenFailed
        }
        sqlite3_busy_timeout(handle, 2000)
        return handle
    }

    /// Write `rows` in one transaction. `bind` fills the statement for a row
    /// and returns false to skip it. Any failed step rolls the whole batch
    /// back and throws, so the caller never uploads or marks synced a merge
    /// that didn't land locally.
    private func writeLocalRows<Row>(
        _ rows: [Row],
        sql: String,
        bind: (OpaquePointer, Row) -> Bool
    ) throws {
        let db = try openLocalDBForWriting()
        defer { sqlite3_close(db) }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            NSLog("MarmotIM: [E][sync] local write begin failed msg=\(String(cString: sqlite3_errmsg(db)))")
            throw SyncError.writeFailed
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(statement) }

        for row in rows {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard bind(statement, row) else { continue }
            let rc = sqlite3_step(statement)
            if rc != SQLITE_DONE {
                NSLog("MarmotIM: [E][sync] local write step failed rc=\(rc) msg=\(String(cString: sqlite3_errmsg(db)))")
                sqlite3_reset(statement)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw SyncError.writeFailed
            }
        }
        sqlite3_reset(statement)

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            NSLog("MarmotIM: [E][sync] local write commit failed msg=\(String(cString: sqlite3_errmsg(db)))")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw SyncError.writeFailed
        }
    }

    // MARK: - Write Remote (iCloud)

    private func writeRemoteLearning(_ records: [String: LearningRecord], to url: URL) throws {
        try writeRemoteRecords(records, to: url)
    }

    private func writeRemoteFavorites(_ records: [String: FavoriteRecord], to url: URL) throws {
        try writeRemoteRecords(records, to: url)
    }

    private func writeRemoteFilterFreq(_ records: [String: FilterFreqRecord], to url: URL) throws {
        try writeRemoteRecords(records, to: url)
    }

    private func writeRemoteSuppressedWords(_ records: [String: SuppressedWordRecord], to url: URL) throws {
        try writeRemoteRecords(records, to: url)
    }

    private func writeRemoteRecords<T: Codable>(_ records: [String: T], to url: URL) throws {
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

    // MARK: - iCloud Conflict Versions

    /// Fold every unresolved conflict version of the file into `base`.
    ///
    /// When two Macs write the same file before seeing each other's copy,
    /// iCloud keeps one as current and the other as a conflict version. Only
    /// reading the current one silently loses the other Mac's changes. The
    /// returned versions must be passed to `resolveConflictVersions` after
    /// the merged result has been written.
    private func foldConflictVersions<T: Codable>(
        _ base: [String: T],
        at url: URL,
        merge: ([String: T], [String: T]) -> [String: T]
    ) -> (records: [String: T], conflicts: [NSFileVersion]) {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url),
              !versions.isEmpty else {
            return (base, [])
        }
        var result = base
        for version in versions {
            do {
                let data = try Data(contentsOf: version.url)
                let file = try JSONDecoder().decode(SyncFile<T>.self, from: data)
                result = merge(result, file.records)
            } catch {
                NSLog("MarmotIM: [W][sync] conflict version unreadable file=\(url.lastPathComponent) error=\(error)")
            }
        }
        NSLog("MarmotIM: [I][sync] folded conflict versions file=\(url.lastPathComponent) count=\(versions.count)")
        return (result, versions)
    }

    private func resolveConflictVersions(_ versions: [NSFileVersion], at url: URL) {
        guard !versions.isEmpty else { return }
        for version in versions {
            version.isResolved = true
        }
        do {
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            NSLog("MarmotIM: [W][sync] removing resolved versions failed file=\(url.lastPathComponent) error=\(error)")
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when sync merged remote rows into the local user_learning table.
    /// Observers (AppDelegate) reload DictionaryEngine.userLearningCache.
    static let userLearningDidChange = Notification.Name("MarmotIMUserLearningDidChange")

    /// Posted by VocabularyDatabase after a local (non-sync) change to a
    /// synced user table, so iCloudSyncManager can upload it soon instead of
    /// waiting for the 30-minute timer.
    static let localSyncedDataDidChange = Notification.Name("MarmotIMLocalSyncedDataDidChange")

    /// Posted when suppressed words are updated via sync
    static let suppressedWordsDidChange = Notification.Name("MarmotIMSuppressedWordsDidChange")

    /// Posted when relative-ordering rules are updated via sync (spec-003).
    /// Observers (AppDelegate) should call
    /// `DictionaryEngine.updateRelativeOrderingCache()` so the ranker's
    /// in-memory rule cache stays fresh.
    static let relativeOrderingDidChange = Notification.Name("MarmotIMRelativeOrderingDidChange")
}
