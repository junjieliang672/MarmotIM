import Cocoa
import InputMethodKit

// MARK: - Global instances
// These must be global variables for InputMethodKit to work correctly
// AppDelegate must be stored globally to prevent it from being deallocated
var server: IMKServer?
var appDelegate: AppDelegate?

// MARK: - Application Entry Point
autoreleasepool {
    // Create and store the application delegate globally
    let delegate = AppDelegate()
    appDelegate = delegate
    NSApplication.shared.delegate = delegate

    // Initialize the IMKServer with the connection name from Info.plist
    // Connection name must match InputMethodConnectionName in Info.plist exactly
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.marmotim.inputmethod.MarmotIM"
    let connectionName = "MarmotIM_1_Connection"

    NSLog("MarmotIM: Starting with bundle ID: \(bundleIdentifier), connection: \(connectionName)")

    server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)

    if server == nil {
        NSLog("MarmotIM: Failed to create IMKServer with connection name: \(connectionName)")
    } else {
        NSLog("MarmotIM: IMKServer created successfully")
    }

    // Run the application
    NSApplication.shared.run()
}
