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

/// A view modifier that adds a visual effect background
struct VisualEffectBackground: ViewModifier {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                VisualEffectView(material: material, blendingMode: blendingMode)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
    }
}

extension View {
    /// Apply a visual effect (blur) background to the view
    func visualEffectBackground(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        cornerRadius: CGFloat = 0
    ) -> some View {
        modifier(VisualEffectBackground(
            material: material,
            blendingMode: blendingMode,
            cornerRadius: cornerRadius
        ))
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
            .visualEffectBackground(material: .hudWindow, cornerRadius: 4)
        }
        .frame(width: 400, height: 200)
    }
}
#endif
