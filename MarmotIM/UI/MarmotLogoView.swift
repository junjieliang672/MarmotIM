import SwiftUI

/// Hand-drawn outline marmot logo for Terminal Hybrid theme
/// Uses foregroundColor for automatic light/dark adaptation
struct MarmotLogoView: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 18.0

            // Helper to scale points
            func s(_ value: CGFloat) -> CGFloat {
                return value * scale
            }

            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                return CGPoint(x: s(x), y: s(y))
            }

            // Stroke style
            let thinStroke = StrokeStyle(lineWidth: s(0.8), lineCap: .round, lineJoin: .round)
            let normalStroke = StrokeStyle(lineWidth: s(1.0), lineCap: .round, lineJoin: .round)
            let thickStroke = StrokeStyle(lineWidth: s(1.2), lineCap: .round, lineJoin: .round)

            // Head outline
            var headPath = Path()
            headPath.addEllipse(in: CGRect(x: s(2), y: s(3.5), width: s(14), height: s(13)))
            context.stroke(headPath, with: .foreground, style: thickStroke)

            // Ears
            var leftEar = Path()
            leftEar.addEllipse(in: CGRect(x: s(2), y: s(3.5), width: s(4), height: s(3)))
            context.stroke(leftEar, with: .foreground, style: normalStroke)

            var rightEar = Path()
            rightEar.addEllipse(in: CGRect(x: s(12), y: s(3.5), width: s(4), height: s(3)))
            context.stroke(rightEar, with: .foreground, style: normalStroke)

            // Cheeks (subtle - drawn with reduced opacity)
            var cheeksContext = context
            cheeksContext.opacity = 0.4
            var leftCheek = Path()
            leftCheek.addEllipse(in: CGRect(x: s(2), y: s(9), width: s(4), height: s(4)))
            cheeksContext.stroke(leftCheek, with: .foreground, style: thinStroke)

            var rightCheek = Path()
            rightCheek.addEllipse(in: CGRect(x: s(12), y: s(9), width: s(4), height: s(4)))
            cheeksContext.stroke(rightCheek, with: .foreground, style: thinStroke)

            // Eyes (filled)
            var leftEye = Path()
            leftEye.addEllipse(in: CGRect(x: s(5.2), y: s(7.7), width: s(2.6), height: s(2.6)))
            context.fill(leftEye, with: .foreground)

            var rightEye = Path()
            rightEye.addEllipse(in: CGRect(x: s(10.2), y: s(7.7), width: s(2.6), height: s(2.6)))
            context.fill(rightEye, with: .foreground)

            // Nose
            var nose = Path()
            nose.addEllipse(in: CGRect(x: s(7.7), y: s(11.1), width: s(2.6), height: s(1.8)))
            context.stroke(nose, with: .foreground, style: normalStroke)

            // Teeth
            var teeth = Path()
            teeth.addRoundedRect(in: CGRect(x: s(8), y: s(13.5), width: s(2), height: s(1.8)), cornerSize: CGSize(width: s(0.3), height: s(0.3)))
            context.stroke(teeth, with: .foreground, style: thinStroke)

            // Tooth divider
            var divider = Path()
            divider.move(to: point(9, 13.5))
            divider.addLine(to: point(9, 15.3))
            context.stroke(divider, with: .foreground, style: StrokeStyle(lineWidth: s(0.6), lineCap: .round))
        }
    }
}

#if DEBUG
struct MarmotLogoView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Light mode
            HStack {
                MarmotLogoView()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color(white: 0.1))
                Text("Light mode")
            }
            .padding()
            .background(Color(white: 0.96))

            // Dark mode
            HStack {
                MarmotLogoView()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color(white: 0.9))
                Text("Dark mode")
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color(white: 0.1))

            // Larger size
            MarmotLogoView()
                .frame(width: 64, height: 64)
                .foregroundColor(.blue)
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
