import Foundation

/// Errors that can occur during iCloud sync operations
enum SyncError: Error, LocalizedError {
    case containerNotFound
    case databaseOpenFailed
    case queryFailed
    case encodingFailed
    case decodingFailed
    case writeFailed
    case networkUnavailable
    case iCloudNotAvailable
    case fileCoordinationFailed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .containerNotFound:
            return "iCloud container not found"
        case .databaseOpenFailed:
            return "Failed to open database"
        case .queryFailed:
            return "Database query failed"
        case .encodingFailed:
            return "Failed to encode data to JSON"
        case .decodingFailed:
            return "Failed to decode JSON data"
        case .writeFailed:
            return "Failed to write data"
        case .networkUnavailable:
            return "Network unavailable"
        case .iCloudNotAvailable:
            return "iCloud is not available"
        case .fileCoordinationFailed(let underlying):
            if let error = underlying {
                return "File coordination failed: \(error.localizedDescription)"
            }
            return "File coordination failed"
        }
    }
}
