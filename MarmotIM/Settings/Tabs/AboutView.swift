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

    /// Introduction text
    private let introductionText = """
五笔输入法作为一款小众的输入法，在很久以前（大约是我读小学的期间）曾经是拼音输入法的最强替换。它独特的优势在于短而精，用户只需要输出1-4个字符，就几乎可以保证想打的字在第一位而不需要去处理冲突的情况。 这一点和当时的拼音输入法对比，是无可比拟的优势。然而五笔的主要劣势也非常明显：1） 学习曲线陡峭，用户需要熟背和运用一套除了使用五笔以外毫无意义的词汇表；2） 初上手的用户必须知道这个字怎么写才知道怎么打出来。对比几乎0学习成本的拼音而言，又多了很大的学习障碍。

然而随着时代的变迁，使用拼音的用户群实在太大，五笔的群体实在太小。之后很多大厂开始推出更智能的排序和学习算法，几乎完美解决了拼音输入法的所有痛点：1） 输入长串的词句之后几乎不会出现冲突；2） 得益于海量的用户数据，智能排序和前缀学习算法更新使得拼音输入法不再累赘，可以采用极短的输入打出一大段文字。至此所有五笔曾经的引以为傲优势如今只剩下叹息。同时由于用户数量太少，大厂并没有为五笔同样建立智能排序算法。4符上码这个曾经的优势在大数据时代变成了劣势：由于4符上码的设定，五笔的上限非常低，并没有可以通过大数据获得额外的增长的空间。强行输出长串文字只会增加更多的冲突，降低效率。其实最痛苦的莫过于已经使用很多年五笔的我们，慢慢被时代所抛弃。

我尝试过放弃五笔，但在使用拼音的过程中，尤其是对于单字、短语的输出，让我无时无刻不认为单字或短语的最优解还是五笔。经过一些挣扎，我终于决定自行开发，于是就有了这个开源项目：土拨鼠五笔拼音混拼输入法。

这个项目的唯一目的就是让小众的我们还能有一个好用的输入法。既拥有五笔的短语输出速度，又能在不记得字怎么写的时候方便地使用拼音，同时还能根据用户的使用习惯智能调整排序。这个土拨鼠输入法仅当个人兴趣，开发时间仅一天，目前可设置的地方非常有限。但当前版本已经具备所有应有的功能。希望与同样小众的其他五笔使用者们分享共勉。这个版本的主要优势在于混拼、高效和排序自适应。 使用越久越顺手。虽然词库已经远远超越同类混拼产品在拼音输入上的词库量，但与纯拼音输入法相比词库还有点小。未来可以考虑定期自动更新词库。有兴趣的朋友也可以自行开发，让这个小众的圈子也能再焕发一点光芒。
"""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header: Icon + App name side by side
                HStack(spacing: 16) {
                    AppIconView()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("土拨鼠输入法")
                            .font(.title)
                            .fontWeight(.semibold)

                        Text("MarmotIM")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 20)

                Divider()
                    .padding(.horizontal, 20)

                // Introduction section
                VStack(alignment: .leading, spacing: 12) {
                    Text("开发初衷")
                        .font(.headline)

                    Text(introductionText)
                        .font(.body)
                        .lineSpacing(6)
                        .foregroundColor(.primary.opacity(0.9))
                }
                .padding(.horizontal, 24)

                Divider()
                    .padding(.horizontal, 20)

                // Version and Author at bottom
                VStack(spacing: 8) {
                    HStack {
                        Text("版本：")
                            .foregroundColor(.secondary)
                        Text("\(appVersion) (Build \(buildNumber))")
                    }
                    .font(.body)

                    HStack {
                        Text("作者：")
                            .foregroundColor(.secondary)
                        Text("Junjie Liang")
                    }
                    .font(.body)

                    Text("\u{00A9} 2024-2026 All rights reserved.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App Icon View

/// Displays the application icon from Assets
struct AppIconView: View {
    var body: some View {
        if let appIcon = NSImage(named: "AppIcon") {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        } else {
            // Fallback if AppIcon not found
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color.green.opacity(0.8), Color.green.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Text("M")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AboutView_Previews: PreviewProvider {
    static var previews: some View {
        AboutView()
            .frame(width: 600, height: 500)
    }
}
#endif
