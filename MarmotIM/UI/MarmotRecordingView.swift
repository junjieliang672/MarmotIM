import SwiftUI

/// 录音中 HUD 的土拨鼠标记 —— "Broadcast" 版。
///
/// 由 `logo/marmot_option4.svg`（kawaii 填色土拨鼠）派生：脸、肚皮、耳朵、亮眼、
/// 腮红、门牙全部保留原样，只把**闭着的笑嘴换成张开的嘴**，并在左右各画两道声波。
/// 换句话说，它和 logo 是同一只土拨鼠，区别只在"正在叫"。
///
/// 为什么是张嘴而不是加一支麦克风：土拨鼠的招牌行为就是示警的哨声（whistle-pig），
/// 让图标做这只动物真会做的事，比借一支别家产品的麦克风更贴。
/// 张开的嘴是**浅色肚皮上的一块深色**，这是这张脸上对比度最高的改动，所以它在 14pt
/// 下仍然读得出来 —— HUD 里就是这个尺寸。
///
/// 坐标沿用 SVG 的 viewBox `-4 0 26 18`：脸在 0…18 的格子里，左右各留 4 个单位给声波。
/// 颜色是写死的（不跟随 foregroundColor）：这只土拨鼠有自己的配色，和 `MarmotLogoView`
/// 那个跟随前景色的描线版本不是一回事。
struct MarmotRecordingView: View {

    // MARK: - 调色板（与 logo/marmot_option4.svg 一致）

    private static let fur     = Color(red: 0.804, green: 0.522, blue: 0.247)  // #CD853F
    private static let belly   = Color(red: 1.000, green: 0.937, blue: 0.835)  // #FFEFD5
    private static let innerEar = Color(red: 1.000, green: 0.714, blue: 0.757) // #FFB6C1
    private static let eye     = Color(red: 0.102, green: 0.102, blue: 0.102)  // #1a1a1a
    private static let cheek   = Color(red: 1.000, green: 0.600, blue: 0.600)  // #FF9999
    private static let nose    = Color(red: 0.545, green: 0.271, blue: 0.075)  // #8B4513
    private static let mouth   = Color(red: 0.420, green: 0.204, blue: 0.063)  // #6B3410

    var body: some View {
        Canvas { context, size in
            // viewBox −4 0 26 18 → 画布。x 方向整体右移 4，让左侧声波落在画布内。
            let scale = min(size.width / 26.0, size.height / 18.0)
            func s(_ v: CGFloat) -> CGFloat { v * scale }
            func x(_ v: CGFloat) -> CGFloat { (v + 4) * scale }

            /// 以 (cx, cy) 为心、rx/ry 为半径的椭圆
            func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
                var p = Path()
                p.addEllipse(in: CGRect(x: x(cx) - s(rx), y: s(cy) - s(ry),
                                        width: s(rx) * 2, height: s(ry) * 2))
                return p
            }

            /// 声波弧。`center` 是圆心，`half` 是张角的一半（度）。
            /// mirrored 时把角度绕竖直轴翻过去，左右两侧就完全对称。
            func wave(centerX: CGFloat, radius: CGFloat, half: CGFloat, mirrored: Bool) -> Path {
                var p = Path()
                let start = mirrored ? 180 - half : -half
                let end   = mirrored ? 180 + half : half
                p.addArc(center: CGPoint(x: x(centerX), y: s(11)),
                         radius: s(radius),
                         startAngle: .degrees(start),
                         endAngle: .degrees(end),
                         clockwise: false)
                return p
            }

            // 脸与肚皮
            context.fill(ellipse(9, 10, 7.5, 7), with: .color(Self.fur))
            context.fill(ellipse(9, 12, 4, 3.5), with: .color(Self.belly))

            // 耳朵（Broadcast 版稍微立起来一点：cy 4 → 3.8）
            context.fill(ellipse(3, 3.8, 2.2, 2.1), with: .color(Self.fur))
            context.fill(ellipse(15, 3.8, 2.2, 2.1), with: .color(Self.fur))
            context.fill(ellipse(3, 3.8, 1.2, 1.1), with: .color(Self.innerEar))
            context.fill(ellipse(15, 3.8, 1.2, 1.1), with: .color(Self.innerEar))

            // 腮红在眼睛之前画，免得盖住高光
            var blush = context
            blush.opacity = 0.5
            blush.fill(ellipse(3.5, 11, 1.5, 1), with: .color(Self.cheek))
            blush.fill(ellipse(14.5, 11, 1.5, 1), with: .color(Self.cheek))

            // 亮眼 + 两点高光（这两点高光是这只土拨鼠可爱的主要来源，不要省）
            context.fill(ellipse(6, 9, 2, 2.2), with: .color(Self.eye))
            context.fill(ellipse(12, 9, 2, 2.2), with: .color(Self.eye))
            context.fill(ellipse(6.8, 8.3, 0.8, 0.8), with: .color(.white))
            context.fill(ellipse(5.5, 9.5, 0.4, 0.4), with: .color(.white))
            context.fill(ellipse(12.8, 8.3, 0.8, 0.8), with: .color(.white))
            context.fill(ellipse(11.5, 9.5, 0.4, 0.4), with: .color(.white))

            // 鼻子
            context.fill(ellipse(9, 11.4, 0.8, 0.5), with: .color(Self.nose))

            // 张开的嘴 —— 与 logo 的唯一实质区别
            context.fill(ellipse(9, 13.9, 1.8, 1.6), with: .color(Self.mouth))

            // 两颗门牙挂在嘴的上缘
            for teethX in [CGFloat(8.15), CGFloat(9.1)] {
                var tooth = Path()
                tooth.addRoundedRect(in: CGRect(x: x(teethX), y: s(12.5),
                                                width: s(0.75), height: s(0.9)),
                                     cornerSize: CGSize(width: s(0.2), height: s(0.2)))
                context.fill(tooth, with: .color(.white))
            }

            // 声波：内圈实、外圈淡，左右对称
            let inner = StrokeStyle(lineWidth: s(1.3), lineCap: .round)
            let outer = StrokeStyle(lineWidth: s(1.1), lineCap: .round)
            var faint = context
            faint.opacity = 0.5

            context.stroke(wave(centerX: 16.1, radius: 3, half: 60, mirrored: false),
                           with: .color(Self.fur), style: inner)
            faint.stroke(wave(centerX: 16, radius: 5.8, half: 46.4, mirrored: false),
                         with: .color(Self.fur), style: outer)
            context.stroke(wave(centerX: 1.9, radius: 3, half: 60, mirrored: true),
                           with: .color(Self.fur), style: inner)
            faint.stroke(wave(centerX: 2, radius: 5.8, half: 46.4, mirrored: true),
                         with: .color(Self.fur), style: outer)
        }
        .accessibilityLabel(Text("录音中"))
    }
}

#if DEBUG
struct MarmotRecordingView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 18) {
            // HUD 里的真实尺寸
            HStack(spacing: 7) {
                MarmotRecordingView().frame(width: 20, height: 14)
                Text("录音中").font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.15)))
            .foregroundColor(.white)

            MarmotRecordingView().frame(width: 130, height: 90)
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
#endif
