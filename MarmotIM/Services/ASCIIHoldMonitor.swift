import Darwin
import Foundation

// MARK: - 纯判定

/// 目录里那些文件**意味着什么**。没有文件系统、没有 IMK、没有单例。
///
/// 和 `BehaviorLog.shouldRecord`、`SyncStatusPresenter` 同一个套路，理由也一样：
/// 消费方是 `InputController`，它是 `IMKInputController`，在测试进程里造不出来
/// （要一个真的 IMKServer）。留在里面的逻辑就是永远跑不到测试的逻辑 —— 而这里
/// 判错的症状是「整台机器的中文输入失效」，既响亮又完全看不出原因。
enum ASCIIHoldRules {

    /// 一个还活着的、正在请求英文直通的客户端。
    struct Holder: Equatable {
        /// 客户端 pid。只用来判活和打日志。
        let pid: pid_t
        /// 这条请求限定的 app。**空集表示不限 app。**
        let apps: Set<String>
    }

    struct Evaluation: Equatable {
        let holders: [Holder]
        /// 名字能解析成 pid、但进程已经没了的条目：可以安全删掉。
        let stale: [String]

        static let none = Evaluation(holders: [], stale: [])

        var isActive: Bool { !holders.isEmpty }

        /// 用户正在打字的那个 app，有没有被某条还活着的请求覆盖。
        ///
        /// - Parameters:
        ///   - bundleID: IMK 给出的客户端 bundle id。**不是每个 client 都给得出。**
        ///   - allowedApps: 用户在设置里勾的白名单。空表示不限。
        ///   - requireScope: 忽略没写明 `apps` 的请求。
        ///
        /// 两处「证明不了就不生效」：
        /// 1. 拿不到 bundleID 时，只有不限 app 的请求才算数 —— 写明了 app 的请求
        ///    不能在一个我们无法确认的 app 里生效，否则就是在用户没要求的地方
        ///    关掉中文，和输入法坏了分不出来。
        /// 2. 白名单非空时，请求必须落在白名单里。
        func covers(bundleID: String?, allowedApps: Set<String>, requireScope: Bool) -> Bool {
            if let bundleID, !allowedApps.isEmpty, !allowedApps.contains(bundleID) {
                return false
            }
            if bundleID == nil, !allowedApps.isEmpty {
                return false
            }
            for holder in holders {
                if holder.apps.isEmpty {
                    if requireScope { continue }
                    return true
                }
                if let bundleID, holder.apps.contains(bundleID) { return true }
            }
            return false
        }
    }

    /// 一个条目只有在名字**恰好**是一个正十进制 pid 时才算请求。
    ///
    /// `.DS_Store`、`54321.tmp`、`.54321.tmp`（客户端原子写到一半的临时文件）、
    /// `0`、`-1`、`01`、`" 54321"` 全部拒掉。证明不了是活进程的，既不能据此强制
    /// 英文，也不能删 —— 这个目录不是只有我们在用。
    static func pid(forEntry name: String) -> pid_t? {
        guard (1...10).contains(name.count),
              name.allSatisfy({ $0.isASCII && $0.isNumber }),
              name.first != "0",
              let value = Int32(name), value > 0
        else { return nil }
        return pid_t(value)
    }

    /// `entries` 是一次目录列表。`isAlive` 和 `scope` 注入进来，于是整条判定
    /// 不碰文件系统、不需要真进程就能跑。
    static func evaluate(entries: [String],
                         isAlive: (pid_t) -> Bool,
                         scope: (String) -> Set<String>) -> Evaluation {
        var holders: [Holder] = []
        var stale: [String] = []
        for name in entries.sorted() {
            guard let pid = pid(forEntry: name) else { continue }
            if isAlive(pid) {
                holders.append(Holder(pid: pid, apps: scope(name)))
            } else {
                stale.append(name)
            }
        }
        return Evaluation(holders: holders, stale: stale)
    }
}

// MARK: - 监视器

/// 让外部程序临时把输入法按成英文直通。
///
/// **协议。** `~/Library/Application Support/MarmotIM/ascii-hold/` 下，每个客户端
/// 建一个以自己 pid 命名的文件来请求，unlink 它来撤销。只要目录里有**任意一个**
/// 属于活进程的 pid 文件，输入法就按英文走。文件内容是可选的 JSON
/// `{"apps": ["com.github.wez.wezterm"]}`，限定这条请求对哪些 app 生效；空文件
/// 表示不限 app。
///
/// **为什么是目录里的文件，而不是一条 Darwin 通知。** 通知是边沿触发、不带状态的：
/// 输入法重启就把它忘了（输入法由系统反复拉起，这不是例外情况），而客户端崩在
/// 请求期间就**再也没有人发撤销** —— 症状是整台机器的中文输入永久失效，且没有
/// 任何线索。文件是状态：随时可读、启动即可读、客户端死了用 `kill(pid, 0)` 自己
/// 收尸，多个客户端天然是集合语义。
///
/// **为什么热路径不依赖 DispatchSource。** 目录被删掉再建出来之后，原来的 fd 指向
/// 一个已经死掉的 inode，事件再也不来 —— 这是文件系统监视器的经典坑。如果正确性
/// 挂在监视器上，故障长相是「用了一周之后不灵了」，没人查得出来。所以按键时走的是
/// 一次 `stat(2)`（命中 VFS 缓存约 1 µs，比 `handle()` 已经在做的一次候选检索低
/// 三个数量级），监视器只负责让反应提前到下一次按键**之前**发生，坏掉也只是慢一拍。
///
/// **线程。** 全部只在主线程上碰，DispatchSource 也挂在 `.main`。`handle()`、
/// IMK 菜单、`activateServer`、`ModeIndicator.show` 本来就都是主线程，于是没有锁、
/// 没有竞态，热路径上也不多付任何代价。
final class ASCIIHoldMonitor {

    static let shared = ASCIIHoldMonitor(directory: ASCIIHoldMonitor.defaultDirectory)

    /// 一次扫描最多看这么多条目。病态目录不能把打字卡住。
    private static let maxEntries = 64

    /// 目录没变化时，最多每这么久用 `kill(2)` 复查一次请求者还活着。
    /// 把「客户端崩了但文件还在」的窗口钉死在 1 秒。
    private static let livenessRecheckInterval: TimeInterval = 1.0

    /// 监视器装不上时的重试间隔。正确性不依赖它，所以慢一点无所谓。
    private static let rearmInterval: TimeInterval = 1.0

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarmotIM/ascii-hold", isDirectory: true)
    }

    let directory: URL

    /// 目录的「指纹」。inode 变了说明目录被删掉重建过；mtime 变了说明里面的条目动过。
    /// 部署目标是 macOS 13，系统盘必然是 APFS，mtime 是纳秒精度，所以「改了两次却
    /// 撞上同一个时间戳」在现实里不存在（HFS+ 的 1 秒精度才会）。
    private struct Fingerprint: Equatable {
        let ino: UInt64
        let mtimeSec: Int
        let mtimeNsec: Int
    }

    private var evaluation = ASCIIHoldRules.Evaluation.none

    /// 上一次有请求生效是什么时候。
    ///
    /// 设置页需要它：客户端在终端失去焦点时就会撤销请求，而用户为了看这个设置页
    /// 必须离开终端 —— 于是「现在有没有请求」在设置页里永远是「没有」，那一行就
    /// 成了废话。记一个时间戳，至少能说出「刚刚生效过」。
    private var lastActive: Date?

    private var fingerprint: Fingerprint?
    private var lastLivenessCheck: TimeInterval = 0
    private var source: DispatchSourceFileSystemObject?
    private var rearmScheduled = false
    private var loggedArmFailure = false
    private var started = false

    /// 请求取得/撤销时调一次。做成可替换的闭包，是为了测试里能把副作用摘掉。
    static var holdActivityDidChange: (_ active: Bool) -> Void = { active in
        InputController.externalASCIIHoldDidChange(active: active)
    }

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: 生产侧入口

    /// **热路径唯一的调用。** 没变化时就是一次 `stat(2)`。只在主线程调用。
    func isHolding(bundleID: String?) -> Bool {
        let config = AppDelegate.config.asciiHold
        guard config.enabled else { return false }
        refreshIfChanged()
        recheckLivenessIfStale()
        return evaluation.covers(bundleID: bundleID,
                                 allowedApps: Set(config.allowedApps),
                                 requireScope: config.requireAppScope)
    }

    /// 当前是否有任何请求（不分 app）。菜单项和设置页的状态行用。
    var isActiveAnywhere: Bool {
        guard AppDelegate.config.asciiHold.enabled else { return false }
        refreshIfChanged()
        recheckLivenessIfStale()
        return evaluation.isActive
    }

    /// 设置页那一行要显示的东西。
    struct Status: Equatable {
        /// 现在正在请求的程序，按进程名。
        let holders: [String]
        /// 上一次生效距今多久。没有生效过就是 nil。
        let secondsSinceActive: TimeInterval?

        var isActive: Bool { !holders.isEmpty }
    }

    var status: Status {
        guard AppDelegate.config.asciiHold.enabled else {
            return Status(holders: [], secondsSinceActive: nil)
        }
        refreshIfChanged()
        recheckLivenessIfStale()
        let names = evaluation.holders.map { holder in
            Self.processName(holder.pid).map { "\($0)（pid \(holder.pid)）" }
                ?? "pid \(holder.pid)"
        }
        return Status(holders: names,
                      secondsSinceActive: lastActive.map { -$0.timeIntervalSinceNow })
    }

    /// 进程名，拿不到就返回 nil。只给设置页显示用，不参与任何判定。
    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    /// 启动时调一次：建目录、读一遍现状、装上监视器。
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !started else { return }
        started = true
        arm()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        started = false
        disarm()
    }

    /// 把目录里所有请求删掉。设置页的「立即清除所有请求」。
    ///
    /// 这是给用户兜底的：如果某个客户端崩了、而它的 pid 又正好被别的进程复用，
    /// 请求就永远不会过期，而用户除了开终端之外没有别的办法。
    /// 不碰解析不出 pid 的条目 —— 那些不是我们写的。
    @discardableResult
    func clearAllHolds() -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where ASCIIHoldRules.pid(forEntry: name) != nil {
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        NSLog("MarmotIM: ascii-hold - 用户清除了 %d 条请求", removed)
        fingerprint = nil
        refreshIfChanged()
        return removed
    }

    // MARK: 扫描

    private func refreshIfChanged() {
        var info = stat()
        guard stat(directory.path, &info) == 0 else {
            // 目录不在：没有任何请求。下一次 arm() 会把它重新建出来。
            if evaluation.isActive { publish(.none) }
            fingerprint = nil
            return
        }
        let now = Fingerprint(ino: info.st_ino,
                              mtimeSec: info.st_mtimespec.tv_sec,
                              mtimeNsec: info.st_mtimespec.tv_nsec)
        guard now != fingerprint else { return }
        fingerprint = now
        rescan()
    }

    private func rescan() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let result = ASCIIHoldRules.evaluate(
            entries: Array(names.prefix(Self.maxEntries)),
            isAlive: Self.processIsAlive,
            scope: { Self.readScope(self.directory.appendingPathComponent($0)) })

        // 收尸。删除会再改一次 mtime，所以删完重新取一次指纹 —— 否则下一次按键
        // 会看到「又变了」再白扫一遍，每次按键都如此，直到目录自己安静下来。
        if !result.stale.isEmpty {
            for name in result.stale {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
                NSLog("MarmotIM: ascii-hold - 清掉已退出进程留下的 %@", name)
            }
            var info = stat()
            if stat(directory.path, &info) == 0 {
                fingerprint = Fingerprint(ino: info.st_ino,
                                          mtimeSec: info.st_mtimespec.tv_sec,
                                          mtimeNsec: info.st_mtimespec.tv_nsec)
            }
        }
        lastLivenessCheck = Date.timeIntervalSinceReferenceDate
        publish(result)
    }

    /// 目录没动，但请求者可能已经崩了。最多每秒一次 `kill(2)`。
    private func recheckLivenessIfStale() {
        guard evaluation.isActive else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastLivenessCheck >= Self.livenessRecheckInterval else { return }
        lastLivenessCheck = now
        guard evaluation.holders.contains(where: { !Self.processIsAlive($0.pid) }) else { return }
        rescan()  // 有人没了，顺便把文件删掉
    }

    private func publish(_ next: ASCIIHoldRules.Evaluation) {
        let was = evaluation.isActive
        evaluation = next
        if next.isActive { lastActive = Date() }
        guard was != next.isActive else { return }
        // 这条日志是现场唯一能解释「中文怎么打不出来」的东西，别删。
        let who = next.holders.map { String($0.pid) }.joined(separator: ",")
        NSLog("MarmotIM: ascii-hold %@（请求者 %@）",
              next.isActive ? "生效" : "撤销",
              who.isEmpty ? "无" : who)
        Self.holdActivityDidChange(next.isActive)
    }

    // MARK: 活着吗

    /// `kill(pid, 0)`：0 就是活着；`EPERM` 也是活着（进程属于别的用户）。
    /// 只有 `ESRCH` 才是真没了。
    static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: 作用域

    /// 读一条请求限定的 app。
    ///
    /// 空文件（`touch` 出来的）、读不动、不是 JSON、太大 —— 一律当作不限 app，
    /// **绝不因为解析失败而放弃整条请求**。反过来错的话，就是在一个没人指名的
    /// app 里关掉中文。
    static func readScope(_ url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              !data.isEmpty, data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = object["apps"] as? [String]
        else { return [] }
        return Set(apps.filter { !$0.isEmpty })
    }

    // MARK: 监视器（可坏，坏了只是慢一拍）

    private func arm() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            if !loggedArmFailure {
                loggedArmFailure = true
                NSLog("MarmotIM: ascii-hold - 打不开目录 (errno %d)，退回到按键时 stat", errno)
            }
            scheduleRearm()
            refreshIfChanged()
            return
        }
        loggedArmFailure = false

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main)
        // 事件处理器里不能捕获 src（source 持有 handler，会成环）；走 self.source。
        src.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            let flags = current.data
            if flags.contains(.write) { self.refreshIfChanged() }
            if !flags.isDisjoint(with: [.delete, .rename, .revoke]) {
                // fd 现在指着一个死 inode，事件再也不会来了：拆掉重装。
                self.disarm()
                self.fingerprint = nil
                self.refreshIfChanged()
                self.scheduleRearm()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        refreshIfChanged()
    }

    private func disarm() {
        source?.cancel()  // cancelHandler 负责 close(fd)
        source = nil
    }

    private func scheduleRearm() {
        guard started, !rearmScheduled else { return }
        rearmScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rearmInterval) { [weak self] in
            guard let self else { return }
            self.rearmScheduled = false
            guard self.started else { return }
            self.arm()
        }
    }
}
