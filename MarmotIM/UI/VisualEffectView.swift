import SwiftUI
import AppKit

/// NSVisualEffectView wrapper for SwiftUI
/// Provides system blur/vibrancy effect for the candidate window background
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

#if DEBUG
struct VisualEffectView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            // Background content to show blur effect
            LinearGradient(
                colors: [.blue, .purple, .pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Blurred panel
            VStack {
                Text("Terminal Hybrid Theme")
                    .font(.system(.body, design: .monospaced))
                Text("1.测试  2.候选词  3.演示")
                    .font(.system(.body, design: .monospaced))
            }
            .padding()
            .background(
                VisualEffectView(material: .hudWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            )
        }
        .frame(width: 400, height: 200)
    }
}
#endif
