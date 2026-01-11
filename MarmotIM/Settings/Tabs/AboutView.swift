import SwiftUI

/// About view showing app information
struct AboutView: View {
    /// App version from bundle
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    /// Build number from bundle
    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon
            AppIconView()

            // App name
            VStack(spacing: 4) {
                Text("土拨鼠输入法")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("MarmotIM")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            // Author
            HStack {
                Text("作者：")
                    .foregroundColor(.secondary)
                Text("Junjie Liang")
            }
            .font(.body)

            // Version info
            HStack {
                Text("版本：")
                    .foregroundColor(.secondary)
                Text("\(appVersion) (Build \(buildNumber))")
            }
            .font(.body)

            Spacer()

            // Copyright
            Text("\u{00A9} 2024-2026 All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App Icon View

/// Displays the application icon
struct AppIconView: View {
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color.green.opacity(0.8), Color.green.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 80, height: 80)

            // Marmot emoji or text
            Text("M")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Preview

#if DEBUG
struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
            .frame(width: 600, height: 400)
    }
}
#endif
