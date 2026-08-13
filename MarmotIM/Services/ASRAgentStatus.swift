import Foundation

/// 本机 ASR 服务的**安装**状态 —— 与"跑没跑起来"是两回事。
///
/// 设置页原先只有一个健康探测，于是三种完全不同的处境被压成同一句「未安装」：
/// 服务根本没装、装了但没在跑、在跑但没设成开机启动。三者的处理办法完全不同，
/// 却给了同一句提示。这个类型把前两者从文件系统里读出来，跑没跑仍旧由
/// `ASRHealthMonitor` 的 HTTP 探测回答 —— 两个来源各答各的那一半。
///
/// **决策 15 在这里的落点：本类型只读文件，不启动任何进程。**
/// 没有 `Process`、没有 `launchctl`、不写 `~/Library/LaunchAgents`。设置页因此只能
/// *告诉*用户该跑哪条命令，不能替他跑 —— 这是刻意的：输入法进程不做进程管理。
/// 想要一个"开机自动启动"开关，就得让输入法去 bootstrap/bootout launchd 作业，
/// 那会把这条边界推翻，需要人来决定，而不是在这里顺手做掉。
struct ASRAgentStatus: Equatable {

    /// LaunchAgent 的 plist 在不在。在 ＝ 装过了。
    let isInstalled: Bool
    /// plist 里 `RunAtLoad` 是不是 true。装了但没有这一项，就是"要手动起"。
    let startsAtLogin: Bool

    /// plist 路径。`install_asr.sh` 写的就是这里，两边必须一致。
    static let plistPath = NSString(string: "~/Library/LaunchAgents/com.marmotim.asr.plist")
        .expandingTildeInPath

    static let notInstalled = ASRAgentStatus(isInstalled: false, startsAtLogin: false)

    /// 读一次当前状态。
    ///
    /// 任何异常都收敛成 `.notInstalled`：plist 不存在、读不动、不是合法 plist、
    /// 结构不是字典 —— 从用户的角度这些都是"这台机器上没有一个能用的服务"，
    /// 分别报错只会把一句能照做的提示换成一句看不懂的错误。
    static func read(at path: String = plistPath) -> ASRAgentStatus {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil),
              let dict = plist as? [String: Any]
        else {
            return .notInstalled
        }
        // 只认真正的布尔真值。缺这一项 ＝ 装了但不会自己起来，这正是要区分出来的情形。
        let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
        return ASRAgentStatus(isInstalled: true, startsAtLogin: runAtLoad)
    }

    /// 设置页要显示的一句话，以及它对应的那条命令（可复制）。
    ///
    /// `isRunning` 由健康探测提供 —— 本类型自己不知道，也不该知道。
    func advice(isRunning: Bool) -> (summary: String, command: String?) {
        switch (isInstalled, isRunning) {
        case (false, _):
            return ("未安装。听写需要一个本机语音服务，安装后才能使用。",
                    "bash scripts/build_and_install.sh --all")
        case (true, false):
            // 装了却没应答：KeepAlive 会一直重启它，所以多半是起不来而不是被停掉了。
            return ("已安装，但没有在运行。服务可能启动失败，可查看日志或重新安装。",
                    "tail -20 ~/Library/Logs/MarmotIM/asr-server.err.log")
        case (true, true) where !startsAtLogin:
            return ("正在运行，但没有设置为开机自动启动，重启后需要手动启动。",
                    "bash scripts/install_asr.sh --reinstall")
        case (true, true):
            return ("正在运行，并会在登录时自动启动。", nil)
        }
    }
}
