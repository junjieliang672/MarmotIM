import Cocoa
import SwiftUI

/// Controller for the settings window
class SettingsWindowController: NSWindowController {

    // MARK: - Singleton

    static let shared = SettingsWindowController()

    // MARK: - Properties

    private var settingsWindow: NSWindow?

    // MARK: - Initialization

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    /// Show the settings window
    func showSettings() {
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create the settings view
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "设置"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false

        // Set minimum size
        window.minSize = NSSize(width: 600, height: 450)

        self.settingsWindow = window
        self.window = window

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close the settings window
    func closeSettings() {
        settingsWindow?.close()
    }
}

// MARK: - Settings Tab Enum

/// Available tabs in the settings window
enum SettingsTab: String, CaseIterable, Identifiable {
    case basic = "基本"
    case userDict = "用户词库"
    case punctuation = "标点符号"
    case theme = "主题"
    case importExport = "导入导出"
    case about = "关于"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .basic: return "gearshape"
        case .userDict: return "doc.text"
        case .punctuation: return "number"
        case .theme: return "paintbrush"
        case .importExport: return "arrow.up.arrow.down.circle"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Main Settings View

/// Main settings view with tab navigation
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .basic
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            Group {
                switch selectedTab {
                case .basic:
                    BasicSettingsView(viewModel: viewModel)
                case .userDict:
                    UserDictView(viewModel: viewModel)
                case .punctuation:
                    PunctuationView(viewModel: viewModel)
                case .theme:
                    ThemeSettingsView(viewModel: viewModel)
                case .importExport:
                    ImportExportView()
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 450)
        .onDisappear {
            viewModel.saveIfNeeded()
        }
    }
}

// MARK: - Tab Button

/// A button for switching between tabs
struct TabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20))
                Text(tab.rawValue)
                    .font(.system(size: 11))
            }
            .frame(width: 70, height: 50)
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings View Model

/// View model for managing settings state
class SettingsViewModel: ObservableObject {
    @Published var config: AppConfig
    @Published var isDirty: Bool = false

    init() {
        do {
            self.config = try AppConfig.load()
        } catch {
            NSLog("MarmotIM: Failed to load config, using defaults: \(error)")
            self.config = .default
        }
    }

    /// Mark the config as changed
    func markDirty() {
        isDirty = true
    }

    /// Save configuration if there are changes
    func saveIfNeeded() {
        guard isDirty else { return }
        save()
    }

    /// Save configuration immediately
    func save() {
        do {
            config.validate()
            try config.save()
            isDirty = false
            NSLog("MarmotIM: Configuration saved")

            // Notify the app to reload config
            NotificationCenter.default.post(name: .configurationDidChange, object: nil)
        } catch {
            NSLog("MarmotIM: Failed to save config: \(error)")
        }
    }

    /// Reset to default configuration
    func resetToDefaults() {
        config = .default
        markDirty()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let configurationDidChange = Notification.Name("MarmotIMConfigurationDidChange")
}

// MARK: - Settings Section Component

/// A reusable section component for settings
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .frame(width: 700, height: 520)
    }
}
#endif
