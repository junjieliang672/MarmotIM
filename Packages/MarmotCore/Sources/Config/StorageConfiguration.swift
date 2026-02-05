import Foundation
import os.log

/// Logging utility for MarmotCore
/// Uses os.log for cross-platform structured logging
public enum MarmotLogger {
    private static let subsystem = "com.marmotim.core"
    
    public static let dictionary = Logger(subsystem: subsystem, category: "Dictionary")
    public static let ranking = Logger(subsystem: subsystem, category: "Ranking")
    public static let sync = Logger(subsystem: subsystem, category: "Sync")
    public static let storage = Logger(subsystem: subsystem, category: "Storage")
    public static let config = Logger(subsystem: subsystem, category: "Config")
}

/// Configuration for storage paths
/// Allows different paths for macOS app vs iOS keyboard extension
public struct StorageConfiguration {
    public let databaseDirectory: URL
    public let configDirectory: URL
    public let iCloudContainerIdentifier: String
    
    public init(
        databaseDirectory: URL,
        configDirectory: URL,
        iCloudContainerIdentifier: String = "iCloud.com.marmotim.inputmethod.MarmotIM"
    ) {
        self.databaseDirectory = databaseDirectory
        self.configDirectory = configDirectory
        self.iCloudContainerIdentifier = iCloudContainerIdentifier
    }
    
    /// Standard configuration for macOS input method
    public static func forMacOS() -> StorageConfiguration {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("MarmotIM")
        
        return StorageConfiguration(
            databaseDirectory: appSupport,
            configDirectory: appSupport
        )
    }
    
    /// Configuration for iOS keyboard extension using App Group
    /// - Parameter appGroupIdentifier: The App Group identifier (e.g., "group.com.marmotim")
    public static func forIOSKeyboard(appGroupIdentifier: String) -> StorageConfiguration {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            // Fallback to documents directory if App Group not available
            MarmotLogger.config.error("App Group container not available, using fallback")
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            return StorageConfiguration(
                databaseDirectory: docs,
                configDirectory: docs
            )
        }
        
        return StorageConfiguration(
            databaseDirectory: containerURL,
            configDirectory: containerURL
        )
    }
    
    /// Path to the main dictionary database
    public var databasePath: URL {
        databaseDirectory.appendingPathComponent("dictionary.db")
    }
    
    /// Path to the configuration JSON file
    public var configPath: URL {
        configDirectory.appendingPathComponent("config.json")
    }
}
