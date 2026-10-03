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
    private let favoritesFileName = "user_favorites.json"
    // Counter payloads (format v2, see CounterRecord). New file names so an
    // older build on the other Mac never tries to decode them as v1. The v1
    // files are still read, never written, to pick up history and any Mac
    // that hasn't been updated yet.
    private let learningV2FileName = "user_learning_v2.json"
    private let filterFreqV2FileName = "filter_user_freq_v2.json"
    private let learningFileName = "user_learning.json"
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

    // MARK: - Per-Mac Sync Switch

    /// Whether this Mac takes part in iCloud sync. A local marker file next
    /// to the database, deliberately not part of any synced data: it is a
    /// property of the machine (a work Mac that must not sync), not of the
    /// user's dictionary.
    var isSyncEnabled: Bool {
        Self.isSyncEnabled(inDirectory: localDBPath.deletingLastPathComponent())
    }

    private var syncDisabledMarkerURL: URL {
        Self.syncDisabledMarkerURL(inDirectory: localDBPath.deletingLastPathComponent())
    }

    static func syncDisabledMarkerURL(inDirectory directory: URL) -> URL {
        directory.appendingPathComponent(".marmotim.sync-disabled")
    }

    /// Enabled unless the marker file exists, so a fresh install syncs
    static func isSyncEnabled(inDirectory directory: URL) -> Bool {
        !FileManager.default.fileExists(atPath: syncDisabledMarkerURL(inDirectory: directory).path)
    }

    /// Turn sync on or off for this Mac. Off: nothing is read from or written
    /// to iCloud any more, local data stays as it is, and this Mac's status
    /// file is removed so the other Macs stop listing it. On: syncs at once.
    func setSyncEnabled(_ enabled: Bool) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            if enabled {
                try? FileManager.default.removeItem(at: self.syncDisabledMarkerURL)
                NSLog("MarmotIM: [I][sync] sync enabled on this Mac")
                self.performSync()
            } else {
                FileManager.default.createFile(atPath: self.syncDisabledMarkerURL.path, contents: nil)
                self.pendingLocalSync?.cancel()
                self.removeOwnDeviceStatus()
                self.lastSyncError = nil
                self.lastSyncSuccess = true
                NSLog("MarmotIM: [I][sync] sync disabled on this Mac")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .syncOverviewDidChange, object: nil)
                }
            }
        }
    }

    private func removeOwnDeviceStatus() {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            return
        }
        let url = container.appendingPathComponent("Documents")
            .appendingPathComponent("\(Self.deviceStatusPrefix)\(localDeviceId()).json")
        removeCloudFile(url)
    }

    @discardableResult
    private func removeCloudFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var coordinatorError: NSError?
        var removed = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { coordURL in
            do {
                try FileManager.default.removeItem(at: coordURL)
                removed = true
            } catch {
                NSLog("MarmotIM: [W][sync] cloud file not removed file=\(url.lastPathComponent) error=\(error)")
            }
        }
        return removed
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
        // Device status files are rewritten by every sync on every Mac. Syncing
        // in response to them would make the Macs trigger each other forever;
        // they only need the settings page refreshed.
        if Self.changesAreOnlyDeviceStatusFiles(notification) {
            NotificationCenter.default.post(name: .syncOverviewDidChange, object: nil)
            return
        }

        // Remote file changed, trigger sync
        syncQueue.async { [weak self] in
            NSLog("MarmotIM: iCloud file changed, syncing...")
            self?.performSync()
        }
    }

    private static func changesAreOnlyDeviceStatusFiles(_ notification: Notification) -> Bool {
        let keys = [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey,
                    NSMetadataQueryUpdateRemovedItemsKey]
        let items = keys.flatMap { notification.userInfo?[$0] as? [NSMetadataItem] ?? [] }
        guard !items.isEmpty else { return false }
        return items.allSatisfy { item in
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return false }
            return isDeviceStatusFile(url.lastPathComponent)
        }
    }

    // MARK: - Core Sync Logic

    private func performSync() {
        // Every trigger (launch, timer, iCloud change, local edit, menu) comes
        // through here, so this one check keeps a sync-disabled Mac off iCloud.
        guard isSyncEnabled else { return }

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
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .syncOverviewDidChange, object: nil)
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
        entryTextCache = [:]  // Per database, per round
        adoptLegacyRetirement(documentsURL: documentsURL)
        defer {
            localDBPathOverride = savedPath
            entryTextCache = [:]
        }

        // Each payload is independent: a corrupt or unreadable file must not
        // stop the other four from syncing. The first error is rethrown at
        // the end so the menu still reports the failure.
        let payloads: [(String, (URL) throws -> Void)] = [
            (learningV2FileName, syncLearningData),
            (favoritesFileName, syncFavoritesData),
            (filterFreqV2FileName, syncFilterFreqData),
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
        // Published even after a failure: the other Macs' settings page should
        // show that this one tried and what went wrong.
        writeDeviceStatus(documentsURL: documentsURL, error: firstError)

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
        let localChanged = try syncCounterPayload(CounterPayload(
            name: "learning",
            fileName: learningV2FileName,
            legacyFileName: learningFileName,
            readTotals: readLocalLearningTotals,
            readLegacy: readLegacyLearning,
            writeLocal: writeLocalLearningTotals
        ), documentsURL: documentsURL)

        if localChanged {
            // The ranker reads userLearningCache, which is only filled at
            // preload. Without a reload the synced rows never reach ranking,
            // and the next selection writes the stale cached score back.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .userLearningDidChange, object: nil)
            }
        }
    }

    // MARK: - Device Status (settings → iCloud page)

    /// `device-<deviceId>.json`, next to the payload files. Not in a
    /// subfolder: two Macs creating the same folder name independently makes
    /// iCloud rename one to "devices 2". A per-device file name can't collide.
    private static let deviceStatusPrefix = "device-"

    static func isDeviceStatusFile(_ name: String) -> Bool {
        name.hasPrefix(deviceStatusPrefix) && name.hasSuffix(".json")
    }

    /// Counts and content fingerprints of the local synced tables. After a
    /// successful sync the local tables equal the merged result, so two Macs
    /// that have both synced the same state publish the same fingerprints.
    private func localPayloadSummaries() throws -> [String: PayloadSummary] {
        var result: [String: PayloadSummary] = [:]

        let favorites = try readLocalFavorites()
        result[SyncPayloadKind.favorites.rawValue] = PayloadSummary(
            count: favorites.values.filter { !$0.isDeleted }.count,
            digest: SyncDigest.digest(favorites.map {
                "\($0.key)|\($0.value.wubiCode ?? "")|\($0.value.pinyinCode ?? "")|\($0.value.addedTimestamp)|\($0.value.isDeleted)"
            }))

        let suppressed = try readLocalSuppressedWords()
        result[SyncPayloadKind.suppressed.rawValue] = PayloadSummary(
            count: suppressed.values.filter { !$0.isDeleted }.count,
            digest: SyncDigest.digest(suppressed.map {
                "\($0.key)|\($0.value.suppressedTimestamp)|\($0.value.isDeleted)"
            }))

        // createdAt is left out: the local write keeps the earlier of the two
        // sides' values, so it can differ between Macs holding the same rules.
        let ordering = try readLocalRelativeOrdering()
        result[SyncPayloadKind.ordering.rawValue] = PayloadSummary(
            count: ordering.values.filter { !$0.isDeleted }.count,
            digest: SyncDigest.digest(ordering.map {
                "\($0.key)|\($0.value.updatedAt)|\($0.value.isDeleted)"
            }))

        for (kind, payload) in [(SyncPayloadKind.learning, "learning"), (SyncPayloadKind.filter, "filter")] {
            let known = try readCounterState(payload).known
            result[kind.rawValue] = PayloadSummary(
                count: known.count,
                digest: SyncDigest.digest(known.map { key, counts in
                    key + "|" + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                }))
        }
        return result
    }

    private func writeDeviceStatus(documentsURL: URL, error: Error?) {
        do {
            let status = DeviceSyncStatus(
                deviceId: localDeviceId(),
                name: Host.current().localizedName ?? "Mac",
                appVersion: Self.appVersionString(),
                lastSyncAt: Date().timeIntervalSince1970,
                lastSyncOK: error == nil,
                lastError: error.map { ($0 as? LocalizedError)?.errorDescription ?? String(describing: $0) },
                payloads: try localPayloadSummaries(),
                legacyRetired: isLegacyRetired ? true : nil
            )
            let url = documentsURL.appendingPathComponent("\(Self.deviceStatusPrefix)\(status.deviceId).json")
            let data = try JSONEncoder().encode(status)

            var coordinatorError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordURL in
                do { try data.write(to: coordURL, options: .atomic) } catch { writeError = error }
            }
            if let failure = coordinatorError ?? writeError { throw failure }
        } catch {
            // Status is informational; never fail a sync over it
            NSLog("MarmotIM: [W][sync] device status not written error=\(error)")
        }
    }

    private static func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Every device's published status file in `documentsURL`
    internal func readDeviceStatuses(documentsURL: URL) -> [DeviceSyncStatus] {
        let directory = documentsURL
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        // A not-yet-downloaded file shows up as ".<name>.json.icloud"
        let names = Set(urls.map { url -> String in
            var name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            }
            return name
        }).filter { Self.isDeviceStatusFile($0) }

        return names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            // Read-only and purely informational: this is the settings page's
            // view of the other Macs, never merged and never written back. Every
            // Mac rewrites its own status file on every sync, so these flicker
            // out of `.current` constantly; waiting 30 s for one to settle hung
            // the page for up to 30 s per device while the data on disk was
            // already fine to show. Take what is here, within a short grace
            // period for a file that has genuinely never been downloaded.
            guard ensureFileDownloaded(at: url, timeout: 2.0, acceptStale: true) == .ready else { return nil }
            var coordinatorError: NSError?
            var status: DeviceSyncStatus?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordURL in
                if let data = try? Data(contentsOf: coordURL) {
                    status = try? JSONDecoder().decode(DeviceSyncStatus.self, from: data)
                }
            }
            return status
        }
    }

    /// Snapshot for the settings page. Reads files; call off the main thread.
    func loadOverview() -> SyncOverview {
        let deviceId = localDeviceId()
        guard isSyncEnabled else {
            // Sync is off here: don't touch the container at all
            return SyncOverview(syncEnabled: false, iCloudAvailable: false, containerFound: false,
                                localDeviceId: deviceId, devices: [], files: [])
        }
        let available = FileManager.default.ubiquityIdentityToken != nil
        guard available,
              let container = FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            return SyncOverview(iCloudAvailable: available, containerFound: false,
                                localDeviceId: deviceId, devices: [], files: [])
        }
        let documentsURL = container.appendingPathComponent("Documents")
        let fileNames = [favoritesFileName, suppressedWordsFileName, relativeOrderingFileName,
                         learningV2FileName, filterFreqV2FileName, learningFileName, filterFreqFileName]
        let files = fileNames.compactMap { cloudState(of: documentsURL.appendingPathComponent($0)) }
        return SyncOverview(iCloudAvailable: true, containerFound: true,
                            obsoleteFiles: obsoleteFiles(documentsURL: documentsURL).map { url in
                                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
                                return SyncObsoleteFile(name: url.lastPathComponent, bytes: size?.intValue ?? 0)
                            },
                            localDeviceId: deviceId,
                            devices: readDeviceStatuses(documentsURL: documentsURL), files: files)
    }

    private func cloudState(of url: URL) -> SyncFileCloudState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [
            .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
            .ubiquitousItemUploadingErrorKey, .contentModificationDateKey,
        ])
        return SyncFileCloudState(
            name: url.lastPathComponent,
            modified: values?.contentModificationDate,
            isUploaded: values?.ubiquitousItemIsUploaded ?? false,
            isUploading: values?.ubiquitousItemIsUploading ?? false,
            conflictCount: NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.count ?? 0,
            uploadError: values?.ubiquitousItemUploadingError?.localizedDescription
        )
    }

    // MARK: - Retiring the v1 Files

    private static let legacyRetiredMarker = "legacy-retired"

    /// True once the v1 files have been retired for this database: by the
    /// user here, or adopted from another Mac's status file.
    internal var isLegacyRetired: Bool {
        hasPayloadEverSynced(Self.legacyRetiredMarker)
    }

    private func adoptLegacyRetirement(documentsURL: URL) {
        guard !isLegacyRetired else { return }
        if readDeviceStatuses(documentsURL: documentsURL).contains(where: { $0.legacyRetired == true }) {
            markPayloadSynced(Self.legacyRetiredMarker)
            NSLog("MarmotIM: [I][sync] v1 files retired by another Mac, adopted")
        }
    }

    /// v1 payload files and manual backups present in `documentsURL`
    internal func obsoleteFiles(documentsURL: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documentsURL.path)) ?? []
        return names
            .filter { $0 == learningFileName || $0 == filterFreqFileName || $0.contains(".json.bak") }
            .sorted()
            .map { documentsURL.appendingPathComponent($0) }
    }

    /// Fold whatever the v1 files still hold into the v2 data, then delete
    /// them and the manual backups. Nothing is deleted unless that last merge
    /// succeeds. Returns the removed file names.
    internal func retireLegacyFiles(documentsURL: URL, dbPath: URL) throws -> [String] {
        // The sync inside reads the v1 files (and their conflict versions)
        // one last time; it throws if any payload failed.
        try syncOnce(documentsURL: documentsURL, dbPath: dbPath)

        let savedPath = localDBPathOverride
        localDBPathOverride = dbPath
        defer { localDBPathOverride = savedPath }

        markPayloadSynced(Self.legacyRetiredMarker)
        let removed = obsoleteFiles(documentsURL: documentsURL).filter { removeCloudFile($0) }
        // Announce it, so the other Macs stop reading v1 files as well
        writeDeviceStatus(documentsURL: documentsURL, error: nil)
        return removed.map { $0.lastPathComponent }
    }

    /// Settings entry point; `completion` runs on the main queue.
    func retireLegacyFiles(completion: @escaping (Result<[String], Error>) -> Void) {
        syncQueue.async { [weak self] in
            guard let self = self else { return }
            let result: Result<[String], Error>
            if !self.isSyncEnabled {
                result = .failure(SyncError.iCloudNotAvailable)
            } else if let container = FileManager.default.url(forUbiquityContainerIdentifier: self.containerIdentifier) {
                result = Result {
                    try self.retireLegacyFiles(documentsURL: container.appendingPathComponent("Documents"),
                                               dbPath: self.localDBPath)
                }
            } else {
                result = .failure(SyncError.containerNotFound)
            }
            DispatchQueue.main.async {
                completion(result)
                NotificationCenter.default.post(name: .syncOverviewDidChange, object: nil)
            }
        }
    }

    // MARK: - Counter Payloads (v2): user_learning, filter_user_freq

    private struct CounterPayload {
        /// Key in sync_counter_state
        let name: String
        let fileName: String
        let legacyFileName: String
        let readTotals: () throws -> [String: (count: Int, lastUsed: Double)]
        /// Decodes one v1 file (or one conflict version of it)
        let readLegacy: (Data) throws -> [String: CounterRecord]
        /// Returns the number of rows written
        let writeLocal: ([String: CounterRecord]) throws -> Int
    }

    /// One sync round for a counter payload. Returns whether the local table changed.
    private func syncCounterPayload(_ payload: CounterPayload, documentsURL: URL) throws -> Bool {
        let remoteURL = documentsURL.appendingPathComponent(payload.fileName)
        let deviceId = localDeviceId()

        let totals = try payload.readTotals()
        let state = try readCounterState(payload.name)
        let local = CounterSync.localRecords(totals: totals, known: state.known,
                                             deviceId: deviceId, baselineDone: state.baselineDone)

        var remote: [String: CounterRecord] = [:]
        var remoteFolded: [String: CounterRecord] = [:]
        var conflicts: [NSFileVersion] = []
        switch ensureFileDownloaded(at: remoteURL) {
        case .ready:
            remote = try readRemoteRecords(from: remoteURL)
            (remoteFolded, conflicts) = foldConflictVersions(remote, at: remoteURL, merge: CounterSync.merge)
        case .notFound:
            break  // Treated as empty; the merge below only ever adds
        case .downloadFailed:
            // Writing now would replace a cloud file we couldn't read
            NSLog("MarmotIM: [W][sync] \(payload.fileName) download failed action=skip")
            return false
        }

        let legacyURL = documentsURL.appendingPathComponent(payload.legacyFileName)
        // Once retired, a v1 file that reappears (a Mac still on an old build
        // re-uploading it) is ignored rather than merged again.
        let legacy = isLegacyRetired
            ? (records: [String: CounterRecord](), stamp: String?.none, conflicts: [NSFileVersion]())
            : readLegacyIfChanged(payload, at: legacyURL)

        // "<name> 2.json": iCloud's rename when two Macs each created the file
        // before seeing the other's. Its records belong in the merge too.
        var duplicates: [URL] = []
        for url in duplicateFiles(of: remoteURL) {
            guard ensureFileDownloaded(at: url) == .ready,
                  let records: [String: CounterRecord] = try? readRemoteRecords(from: url) else {
                continue  // Unreadable now; left in place for a later sync
            }
            remoteFolded = CounterSync.merge(remoteFolded, records)
            duplicates.append(url)
        }

        let merged = CounterSync.merge(CounterSync.merge(local, remoteFolded), legacy.records)

        var changed: [String: CounterRecord] = [:]
        for (key, record) in merged {
            let current = totals[key]
            if record.total != (current?.count ?? 0) || record.lastUsed > (current?.lastUsed ?? 0) {
                changed[key] = record
            }
        }
        var written = 0
        if !changed.isEmpty {
            written = try payload.writeLocal(changed)
            NSLog("MarmotIM: [I][sync] \(payload.fileName) updated local rows=\(written) changed_keys=\(changed.count)")
        }
        try writeCounterState(payload.name, merged)

        // Nothing local and nothing in the cloud: don't create an empty file
        // (spec-004 decision 012 — a fresh device has no standing to)
        if !merged.isEmpty && (merged != remote || !conflicts.isEmpty || !duplicates.isEmpty) {
            try writeRemoteRecords(merged, to: remoteURL)
        }
        resolveConflictVersions(conflicts, at: remoteURL)
        // Their counts are in `merged`, which is now local and in iCloud
        resolveConflictVersions(legacy.conflicts, at: legacyURL)
        // Only after the merged file is written: every record of a duplicate
        // is in it by then, so removing the copy loses nothing.
        removeMergedDuplicates(duplicates)
        if let stamp = legacy.stamp {
            markLegacyRead(payload, stamp: stamp)
        }
        markPayloadSynced(payload.fileName)
        return written > 0
    }

    /// Stable id for this device, stored next to the DB so test harness
    /// devices each get their own. Never synced.
    private func localDeviceId() -> String {
        let url = activeLocalDBPath.deletingLastPathComponent().appendingPathComponent(".marmotim.device-id")
        if let data = try? Data(contentsOf: url),
           let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return id
        }
        let id = UUID().uuidString
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    // MARK: Counter state (sync_counter_state)

    private static let baselineDeviceId = "__baseline__"

    private func readCounterState(_ payload: String) throws -> (known: [String: [String: Int]], baselineDone: Bool) {
        let db = try openLocalDBForWriting()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT key, device_id, count FROM sync_counter_state WHERE payload = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, payload, -1, SQLITE_TRANSIENT_SYNC)

        var known: [String: [String: Int]] = [:]
        var baselineDone = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(cString: sqlite3_column_text(stmt, 0))
            let device = String(cString: sqlite3_column_text(stmt, 1))
            let count = Int(sqlite3_column_int64(stmt, 2))
            if device == Self.baselineDeviceId {
                baselineDone = true
            } else {
                known[key, default: [:]][device] = count
            }
        }
        return (known, baselineDone)
    }

    private func writeCounterState(_ payload: String, _ records: [String: CounterRecord]) throws {
        var rows: [(key: String, device: String, count: Int)] = [("", Self.baselineDeviceId, 1)]
        for (key, record) in records {
            for (device, count) in record.counts {
                rows.append((key, device, count))
            }
        }
        // `payload` is one of two literals ("learning", "filter"), never user input
        try writeLocalRows(rows, before: "DELETE FROM sync_counter_state WHERE payload = '\(payload)'", sql: """
            INSERT INTO sync_counter_state (payload, key, device_id, count) VALUES ('\(payload)', ?, ?, ?)
        """) { stmt, row in
            sqlite3_bind_text(stmt, 1, row.key, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_text(stmt, 2, row.device, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_int64(stmt, 3, Int64(row.count))
            return true
        }
    }

    // MARK: Legacy (v1) files

    /// What the v1 file contributes to this sync, as `legacy` counters:
    /// - the file itself, if it changed since it was last folded in (`stamp`
    ///   identifies the version read; store it only after the sync succeeds);
    /// - every unresolved conflict version of it. v1 builds never resolved
    ///   conflicts, so the file accumulated up to 100 losing versions from the
    ///   other Macs, each possibly holding counts the winner lacks. They are
    ///   merged here and resolved by the caller once the merge is written.
    private func readLegacyIfChanged(_ payload: CounterPayload, at url: URL)
        -> (records: [String: CounterRecord], stamp: String?, conflicts: [NSFileVersion]) {
        guard ensureFileDownloaded(at: url) == .ready,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else {
            return ([:], nil, [])
        }

        var records: [String: CounterRecord] = [:]
        func fold(_ data: Data) throws {
            for (key, incoming) in try payload.readLegacy(data) {
                if var existing = records[key] {
                    for (device, count) in incoming.counts {
                        existing.counts[device] = max(existing.counts[device] ?? 0, count)
                    }
                    existing.lastUsed = max(existing.lastUsed, incoming.lastUsed)
                    records[key] = existing
                } else {
                    records[key] = incoming
                }
            }
        }

        var stamp: String? = "\(modified.timeIntervalSince1970)-\((attrs[.size] as? NSNumber)?.intValue ?? 0)"
        let markerURL = syncStateMarkerURL(for: payload.legacyFileName + ".v1-read")
        if let previous = try? String(contentsOf: markerURL, encoding: .utf8), previous == stamp {
            stamp = nil
        } else {
            do {
                var coordinatorError: NSError?
                var readError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordURL in
                    do { try fold(try Data(contentsOf: coordURL)) } catch { readError = error }
                }
                if let failure = coordinatorError ?? readError { throw failure }
            } catch {
                NSLog("MarmotIM: [W][sync] legacy file unreadable file=\(payload.legacyFileName) error=\(error) action=ignore")
                stamp = nil
            }
        }

        var folded: [NSFileVersion] = []
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            do {
                try fold(try Data(contentsOf: version.url))
                folded.append(version)
            } catch {
                // Left unresolved so a later sync can try again
                NSLog("MarmotIM: [W][sync] legacy conflict version unreadable file=\(payload.legacyFileName) error=\(error)")
            }
        }
        if !folded.isEmpty {
            NSLog("MarmotIM: [I][sync] folded legacy conflict versions file=\(payload.legacyFileName) count=\(folded.count)")
        }
        return (records, stamp, folded)
    }

    private func markLegacyRead(_ payload: CounterPayload, stamp: String) {
        let markerURL = syncStateMarkerURL(for: payload.legacyFileName + ".v1-read")
        try? stamp.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    /// First id of the user tier (DictionaryEngine.userDictStartId)
    private static let userEntryStartId: Int64 = 0x8000_0000

    /// v1 learning is keyed by the WRITER's entry_id. System-dictionary ids
    /// match across Macs built from the same vocab, so they are mapped
    /// through this Mac's entries table. User-entry ids are numbered per Mac
    /// (0x80000000 is a different word on each), so those rows are skipped
    /// rather than credited to whatever word holds that id here.
    private func readLegacyLearning(_ data: Data) throws -> [String: CounterRecord] {
        let file = try JSONDecoder().decode(SyncFile<LearningRecord>.self, from: data).records

        var wanted: [(id: Int64, record: LearningRecord)] = []
        for (idString, record) in file {
            guard let id = Int64(idString), id < Self.userEntryStartId, record.accessCount > 0 else { continue }
            wanted.append((id, record))
        }
        let texts = try lookupTexts(forEntryIds: wanted.map { $0.id })

        var result: [String: CounterRecord] = [:]
        for (id, record) in wanted {
            guard let text = texts[id] else { continue }
            let existing = result[text]
            result[text] = CounterRecord(
                counts: [CounterSync.legacyDeviceId: max(existing?.counts[CounterSync.legacyDeviceId] ?? 0, record.accessCount)],
                lastUsed: max(existing?.lastUsed ?? 0, Double(record.lastAccessTimestamp)))
        }
        return result
    }

    private func readLegacyFilterFreq(_ data: Data) throws -> [String: CounterRecord] {
        let file = try JSONDecoder().decode(SyncFile<FilterFreqRecord>.self, from: data).records
        return file.compactMapValues { record in
            record.frequency > 0
                ? CounterRecord(counts: [CounterSync.legacyDeviceId: record.frequency], lastUsed: record.lastUsed)
                : nil
        }
    }

    // MARK: Local tables

    /// user_learning by text. A word can have several entries (system entry +
    /// user entry); they are written the same total, so MAX recovers it and a
    /// selection on either id shows up as an increase.
    private func readLocalLearningTotals() throws -> [String: (count: Int, lastUsed: Double)] {
        let db = try openLocalDBForWriting()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT e.text, MAX(ul.access_count), MAX(ul.last_access_timestamp)
            FROM user_learning ul JOIN entries e ON e.id = ul.entry_id
            GROUP BY e.text
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        var totals: [String: (count: Int, lastUsed: Double)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(stmt, 0))
            totals[text] = (Int(sqlite3_column_int64(stmt, 1)), Double(sqlite3_column_int64(stmt, 2)))
        }
        return totals
    }

    private func writeLocalLearningTotals(_ records: [String: CounterRecord]) throws -> Int {
        let ids = try entryIdsForLearning(texts: Array(records.keys))

        var rows: [(id: Int64, count: Int, lastUsed: Int, score: Double)] = []
        for (text, record) in records {
            guard let textIds = ids[text] else {
                continue  // Word not in this Mac's dictionary; kept in sync_counter_state
            }
            let lastUsed = Int(record.lastUsed)
            let score = FrecencyScore.calculate(accessCount: UInt32(clamping: record.total),
                                                lastAccessTimestamp: UInt32(clamping: lastUsed),
                                                baseFrequency: 0)
            for id in textIds {
                rows.append((id, record.total, lastUsed, score))
            }
        }
        guard !rows.isEmpty else { return 0 }

        try writeLocalRows(rows, sql: """
            INSERT INTO user_learning (entry_id, access_count, last_access_timestamp, total_score)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(entry_id) DO UPDATE SET
                access_count = excluded.access_count,
                last_access_timestamp = MAX(user_learning.last_access_timestamp, excluded.last_access_timestamp)
        """) { stmt, row in
            sqlite3_bind_int64(stmt, 1, row.id)
            sqlite3_bind_int64(stmt, 2, Int64(row.count))
            sqlite3_bind_int64(stmt, 3, Int64(row.lastUsed))
            sqlite3_bind_double(stmt, 4, row.score)
            return true
        }
        return rows.count
    }

    /// Entry ids to write a word's learning to: every id that already has a
    /// learning row for that text, otherwise the lowest entry id with that
    /// text (the system entry when there is one).
    private func entryIdsForLearning(texts: [String]) throws -> [String: [Int64]] {
        let db = try openLocalDBForWriting()
        defer { sqlite3_close(db) }

        var result: [String: [Int64]] = [:]
        let wanted = Set(texts)

        var stmt: OpaquePointer?
        let existingSQL = "SELECT ul.entry_id, e.text FROM user_learning ul JOIN entries e ON e.id = ul.entry_id"
        guard sqlite3_prepare_v2(db, existingSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(stmt, 1))
            if wanted.contains(text) {
                result[text, default: []].append(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)

        let missing = wanted.subtracting(result.keys)
        guard !missing.isEmpty else { return result }

        // entries has no index on text (1.5M rows). Put the wanted texts in a
        // temp table and scan entries once (CROSS JOIN keeps entries as the
        // outer loop) instead of one full scan per word.
        sqlite3_exec(db, "CREATE TEMP TABLE sync_wanted_texts (text TEXT PRIMARY KEY)", nil, nil, nil)
        defer { sqlite3_exec(db, "DROP TABLE IF EXISTS temp.sync_wanted_texts", nil, nil, nil) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO sync_wanted_texts (text) VALUES (?)", -1, &stmt, nil) == SQLITE_OK {
            for text in missing {
                sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT_SYNC)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        let lookupSQL = """
            SELECT t.text, MIN(e.id) FROM entries e CROSS JOIN sync_wanted_texts t
            WHERE e.text = t.text GROUP BY t.text
        """
        guard sqlite3_prepare_v2(db, lookupSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(stmt, 0))
            result[text] = [sqlite3_column_int64(stmt, 1)]
        }
        return result
    }

    /// id -> text for one sync round. Up to 100 legacy conflict versions each
    /// reference the same ~10k ids; looking them up once keeps that pass short.
    private var entryTextCache: [Int64: String?] = [:]

    private func lookupTexts(forEntryIds ids: [Int64]) throws -> [Int64: String] {
        let missing = ids.filter { entryTextCache[$0] == nil }
        if !missing.isEmpty {
            for (id, text) in try queryTexts(forEntryIds: missing) {
                entryTextCache[id] = text
            }
            for id in missing where entryTextCache[id] == nil {
                entryTextCache[id] = .some(nil)  // Known absent
            }
        }
        var result: [Int64: String] = [:]
        for id in ids {
            if let text = entryTextCache[id] ?? nil { result[id] = text }
        }
        return result
    }

    private func queryTexts(forEntryIds ids: [Int64]) throws -> [Int64: String] {
        let db = try openLocalDBForWriting()
        defer { sqlite3_close(db) }

        var result: [Int64: String] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT text FROM entries WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_bind_int64(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result[id] = String(cString: sqlite3_column_text(stmt, 0))
            }
            sqlite3_reset(stmt)
        }
        return result
    }

    private func readLocalFilterFreqTotals() throws -> [String: (count: Int, lastUsed: Double)] {
        let db = try openLocalDBForWriting()
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT filter_type, code, word, frequency, last_used FROM filter_user_freq"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SyncError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        var totals: [String: (count: Int, lastUsed: Double)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = FilterFreqRecord.makeKey(filterType: String(cString: sqlite3_column_text(stmt, 0)),
                                               code: String(cString: sqlite3_column_text(stmt, 1)),
                                               word: String(cString: sqlite3_column_text(stmt, 2)))
            totals[key] = (Int(sqlite3_column_int64(stmt, 3)), sqlite3_column_double(stmt, 4))
        }
        return totals
    }

    private func writeLocalFilterFreqTotals(_ records: [String: CounterRecord]) throws -> Int {
        try writeLocalRows(Array(records), sql: """
            INSERT OR REPLACE INTO filter_user_freq
            (filter_type, code, word, frequency, last_used)
            VALUES (?, ?, ?, ?, ?)
        """) { stmt, row in
            let (key, record) = row
            guard let parts = FilterFreqRecord.parseKey(key) else { return false }
            sqlite3_bind_text(stmt, 1, parts.filterType, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_text(stmt, 2, parts.code, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_text(stmt, 3, parts.word, -1, SQLITE_TRANSIENT_SYNC)
            sqlite3_bind_int64(stmt, 4, Int64(record.total))
            sqlite3_bind_double(stmt, 5, record.lastUsed)
            return true
        }
        return records.count
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
        _ = try syncCounterPayload(CounterPayload(
            name: "filter",
            fileName: filterFreqV2FileName,
            legacyFileName: filterFreqFileName,
            readTotals: readLocalFilterFreqTotals,
            readLegacy: readLegacyFilterFreq,
            writeLocal: writeLocalFilterFreqTotals
        ), documentsURL: documentsURL)
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
    ///
    /// - timeout: how long to wait for a download to land. The default suits a
    ///   payload read, where the caller is about to merge and write back.
    /// - acceptStale: treat an out-of-date local copy as good enough. Only for
    ///   read-only callers that never write the file back; see the `.downloaded`
    ///   case below for why the merging callers must not set it.
    private func ensureFileDownloaded(at url: URL,
                                      timeout: TimeInterval = 30.0,
                                      acceptStale: Bool = false) -> FileDownloadStatus {
        let fileManager = FileManager.default

        // First check if the file is an iCloud ubiquitous item or exists locally
        guard fileManager.isUbiquitousItem(at: url) || fileManager.fileExists(atPath: url.path) else {
            // Check for .icloud placeholder (indicates file is in cloud but not downloaded)
            let placeholderName = "." + url.lastPathComponent + ".icloud"
            let placeholderURL = url.deletingLastPathComponent().appendingPathComponent(placeholderName)

            if fileManager.fileExists(atPath: placeholderURL.path) {
                // Placeholder exists - file is in iCloud but not downloaded
                return triggerDownloadAndWait(at: url, timeout: timeout)
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
                    // overwrite the other Mac's changes, so a merging caller has
                    // to wait. A read-only caller does not: it can show the copy
                    // it has and pick up the newer one next time.
                    if acceptStale { return .ready }
                    return triggerDownloadAndWait(at: url, timeout: timeout)
                case .notDownloaded:
                    return triggerDownloadAndWait(at: url, timeout: timeout)
                default:
                    // Handle any future cases by attempting download
                    return triggerDownloadAndWait(at: url, timeout: timeout)
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
    private func triggerDownloadAndWait(at url: URL, timeout: TimeInterval) -> FileDownloadStatus {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            NSLog("MarmotIM: Triggered download for iCloud file: \(url.lastPathComponent)")

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
        before: String? = nil,
        sql: String,
        bind: (OpaquePointer, Row) -> Bool
    ) throws {
        let db = try openLocalDBForWriting()
        defer { sqlite3_close(db) }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            NSLog("MarmotIM: [E][sync] local write begin failed msg=\(String(cString: sqlite3_errmsg(db)))")
            throw SyncError.writeFailed
        }
        if let before = before, sqlite3_exec(db, before, nil, nil, nil) != SQLITE_OK {
            NSLog("MarmotIM: [E][sync] local write prelude failed msg=\(String(cString: sqlite3_errmsg(db)))")
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
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

    private func writeRemoteFavorites(_ records: [String: FavoriteRecord], to url: URL) throws {
        try writeRemoteRecords(records, to: url)
    }

    private func writeRemoteSuppressedWords(_ records: [String: SuppressedWordRecord], to url: URL) throws {
        try writeRemoteRecords(records, to: url)
    }

    private func readRemoteRecords<T: Codable>(from url: URL) throws -> [String: T] {
        var coordinatorError: NSError?
        var readError: Error?
        var records: [String: T] = [:]

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { coordURL in
            do {
                let data = try Data(contentsOf: coordURL)
                records = try JSONDecoder().decode(SyncFile<T>.self, from: data).records
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

    // MARK: - iCloud Duplicate Files

    /// Siblings named "<stem> <n>.<ext>" of a payload file
    private func duplicateFiles(of url: URL) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        guard let siblings = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return siblings.filter { sibling in
            guard sibling.pathExtension == ext else { return false }
            let name = sibling.deletingPathExtension().lastPathComponent
            guard name.hasPrefix(stem + " ") else { return false }
            let suffix = name.dropFirst(stem.count + 1)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
        }
    }

    private func removeMergedDuplicates(_ urls: [URL]) {
        for url in urls where removeCloudFile(url) {
            NSLog("MarmotIM: [I][sync] merged duplicate removed file=\(url.lastPathComponent)")
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

    /// Posted when a sync finishes or another Mac's device status file
    /// changes; the settings iCloud page reloads its overview.
    static let syncOverviewDidChange = Notification.Name("MarmotIMSyncOverviewDidChange")

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
