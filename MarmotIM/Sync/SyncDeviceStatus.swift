import Foundation
import CryptoKit

/// The kinds of user data that sync, in the order the settings page lists them.
enum SyncPayloadKind: String, CaseIterable, Codable {
    case favorites
    case suppressed
    case ordering
    case learning
    case filter

    var title: String {
        switch self {
        case .favorites:  return "用户词"
        case .suppressed: return "屏蔽词"
        case .ordering:   return "顺序规则"
        case .learning:   return "学习记录"
        case .filter:     return "筛选频率"
        }
    }
}

/// How many records a device holds for one kind of data, and a fingerprint of
/// their content. Two devices hold the same data for that kind exactly when
/// the fingerprints match.
struct PayloadSummary: Codable, Equatable {
    /// Active records (tombstones excluded); for learning, the number of words
    var count: Int
    var digest: String
}

/// What one Mac publishes about itself after each sync, to
/// `device-<deviceId>.json` in the iCloud container. Each Mac only ever
/// writes its own file, so these never conflict.
struct DeviceSyncStatus: Codable, Equatable, Identifiable {
    var deviceId: String
    var name: String
    var appVersion: String
    var lastSyncAt: TimeInterval
    var lastSyncOK: Bool
    var lastError: String?
    /// Keyed by SyncPayloadKind.rawValue
    var payloads: [String: PayloadSummary]

    var id: String { deviceId }

    func summary(_ kind: SyncPayloadKind) -> PayloadSummary? {
        payloads[kind.rawValue]
    }

    /// Kinds of data whose content differs between the two devices. A kind
    /// either side hasn't reported counts as different.
    func differences(from other: DeviceSyncStatus) -> [SyncPayloadKind] {
        SyncPayloadKind.allCases.filter { kind in
            guard let mine = summary(kind), let theirs = other.summary(kind) else { return true }
            return mine.digest != theirs.digest
        }
    }
}

/// This Mac's iCloud Drive state for one synced file
struct SyncFileCloudState: Equatable, Identifiable {
    var name: String
    var modified: Date?
    var isUploaded: Bool
    var isUploading: Bool
    var conflictCount: Int
    var uploadError: String?

    var id: String { name }

    /// Still not uploaded this long after it was written. iCloud reports no
    /// error in this state; the container is simply not syncing.
    static let stuckAfter: TimeInterval = 300

    func isStuck(now: Date = Date()) -> Bool {
        guard !isUploaded, let modified = modified else { return false }
        return now.timeIntervalSince(modified) > Self.stuckAfter
    }
}

/// Everything the iCloud settings page shows
struct SyncOverview: Equatable {
    var iCloudAvailable: Bool
    var containerFound: Bool
    var localDeviceId: String
    var devices: [DeviceSyncStatus]
    var files: [SyncFileCloudState]

    var localDevice: DeviceSyncStatus? {
        devices.first { $0.deviceId == localDeviceId }
    }

    var otherDevices: [DeviceSyncStatus] {
        devices.filter { $0.deviceId != localDeviceId }.sorted { $0.lastSyncAt > $1.lastSyncAt }
    }

    var stuckFiles: [SyncFileCloudState] {
        files.filter { $0.isStuck() }
    }
}

enum SyncDigest {
    /// Order-independent fingerprint of a set of record lines
    static func digest(_ lines: [String]) -> String {
        let joined = lines.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
