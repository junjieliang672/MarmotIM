import XCTest
@testable import MarmotIM

/// 外部 ASCII 直通请求的判定。
///
/// `ASCIIHoldMonitor` 本身要文件系统和主线程，但「目录里这些名字意味着什么」是
/// 纯函数 —— 和 `BehaviorLog.shouldRecord` 同一个套路，理由也一样：判错的症状是
/// 「整台机器的中文输入失效」，而现场看不出原因。
final class ASCIIHoldTests: XCTestCase {

    // MARK: - 文件名解析

    func testOnlyBareDecimalPidsAreHolds() {
        XCTAssertEqual(ASCIIHoldRules.pid(forEntry: "54321"), 54321)
        XCTAssertEqual(ASCIIHoldRules.pid(forEntry: "1"), 1)
        XCTAssertEqual(ASCIIHoldRules.pid(forEntry: "999999"), 999999)
    }

    func testJunkEntriesAreNotHolds() {
        // `.54321.tmp` 是客户端原子写到一半的临时文件。认错它，就会把一条还没
        // 写完 apps 作用域的请求当成「不限 app」。
        for junk in ["", "0", "-1", "+1", "01", "54321.tmp", ".54321.tmp", ".DS_Store",
                     " 54321", "54321 ", "0x10", "1e3", "12a", "１２３", "12345678901"] {
            XCTAssertNil(ASCIIHoldRules.pid(forEntry: junk),
                         "\(junk) 不该被当成请求 —— 证明不了是活进程就绝不能强制英文")
        }
    }

    // MARK: - 判定

    private func evaluate(_ entries: [String],
                          alive: Set<pid_t>,
                          scopes: [String: Set<String>] = [:]) -> ASCIIHoldRules.Evaluation {
        ASCIIHoldRules.evaluate(entries: entries,
                                isAlive: { alive.contains($0) },
                                scope: { scopes[$0] ?? [] })
    }

    func testEmptyDirectoryIsNoHold() {
        XCTAssertFalse(evaluate([], alive: []).isActive)
    }

    func testOneLiveHolderHolds() {
        XCTAssertTrue(evaluate(["100"], alive: [100]).isActive)
    }

    func testDeadHolderIsStaleAndDoesNotHold() {
        let result = evaluate(["100"], alive: [])
        XCTAssertFalse(result.isActive)
        XCTAssertEqual(result.stale, ["100"],
                       "客户端崩在请求期间必须被收尸，否则中文输入永久失效且没有线索")
    }

    func testUnparseableEntriesAreNeverDeleted() {
        // 目录不是只有我们在写：看不懂的东西不许动。
        let result = evaluate([".DS_Store", "readme.txt", "0"], alive: [])
        XCTAssertTrue(result.stale.isEmpty)
        XCTAssertFalse(result.isActive)
    }

    func testAnyLiveHolderHoldsEvenWhenAnotherDied() {
        let result = evaluate(["100", "200"], alive: [200])
        XCTAssertTrue(result.isActive)
        XCTAssertEqual(result.stale, ["100"])
    }

    // MARK: - 作用域

    private func unscoped() -> ASCIIHoldRules.Evaluation {
        evaluate(["100"], alive: [100])
    }

    private func scopedToWezTerm() -> ASCIIHoldRules.Evaluation {
        evaluate(["100"], alive: [100], scopes: ["100": ["com.github.wez.wezterm"]])
    }

    func testUnscopedHoldCoversEveryApp() {
        let r = unscoped()
        XCTAssertTrue(r.covers(bundleID: "com.github.wez.wezterm", allowedApps: [], requireScope: false))
        XCTAssertTrue(r.covers(bundleID: "com.electron.lark", allowedApps: [], requireScope: false))
        XCTAssertTrue(r.covers(bundleID: nil, allowedApps: [], requireScope: false))
    }

    func testScopedHoldOnlyCoversNamedApps() {
        let r = scopedToWezTerm()
        XCTAssertTrue(r.covers(bundleID: "com.github.wez.wezterm", allowedApps: [], requireScope: false))
        XCTAssertFalse(r.covers(bundleID: "com.electron.lark", allowedApps: [], requireScope: false),
                       "程序留在后台标签页里继续请求时，别的 app 里必须还能打中文")
    }

    func testScopedHoldDoesNotCoverAnUnknownClient() {
        // IMK 不保证每个 client 都给得出 bundle id。证明不了匹配就不生效。
        XCTAssertFalse(scopedToWezTerm().covers(bundleID: nil, allowedApps: [], requireScope: false))
    }

    func testScopesUnionAcrossHolders() {
        let r = evaluate(["100", "200"], alive: [100, 200],
                         scopes: ["100": ["com.apple.Terminal"],
                                  "200": ["com.github.wez.wezterm"]])
        XCTAssertTrue(r.covers(bundleID: "com.apple.Terminal", allowedApps: [], requireScope: false))
        XCTAssertTrue(r.covers(bundleID: "com.github.wez.wezterm", allowedApps: [], requireScope: false))
        XCTAssertFalse(r.covers(bundleID: "com.electron.lark", allowedApps: [], requireScope: false))
    }

    // MARK: - 用户设置

    func testAllowListRestrictsWhereHoldsApply() {
        let allowed: Set<String> = ["com.github.wez.wezterm"]
        let r = unscoped()
        XCTAssertTrue(r.covers(bundleID: "com.github.wez.wezterm", allowedApps: allowed, requireScope: false))
        XCTAssertFalse(r.covers(bundleID: "com.electron.lark", allowedApps: allowed, requireScope: false),
                       "白名单之外的 app 里，任何请求都不该生效")
        XCTAssertFalse(r.covers(bundleID: nil, allowedApps: allowed, requireScope: false),
                       "认不出是哪个 app 时，非空白名单无法被满足")
    }

    func testEmptyAllowListMeansEveryApp() {
        // 空列表看起来像「什么都不许」，但它的意思是「不限」。设置页上那句
        // 「留空表示接受任何 App 的请求」说的就是这件事。
        XCTAssertTrue(unscoped().covers(bundleID: "com.electron.lark", allowedApps: [], requireScope: false))
    }

    func testRequireScopeIgnoresUnscopedHolds() {
        XCTAssertFalse(unscoped().covers(bundleID: "com.github.wez.wezterm",
                                         allowedApps: [], requireScope: true),
                       "打开严格模式后，touch 出来的空请求必须被忽略")
        XCTAssertTrue(scopedToWezTerm().covers(bundleID: "com.github.wez.wezterm",
                                               allowedApps: [], requireScope: true),
                      "写明了 app 的请求不受影响")
    }

    func testRequireScopeStillHonoursOneScopedHolderAmongMany() {
        let r = evaluate(["100", "200"], alive: [100, 200],
                         scopes: ["200": ["com.github.wez.wezterm"]])
        XCTAssertTrue(r.covers(bundleID: "com.github.wez.wezterm",
                               allowedApps: [], requireScope: true))
    }

    // MARK: - 真实进程

    func testSelfAndLaunchdAreAlive() {
        XCTAssertTrue(ASCIIHoldMonitor.processIsAlive(getpid()))
        XCTAssertTrue(ASCIIHoldMonitor.processIsAlive(1),
                      "launchd 属于 root：kill() 返回 EPERM，那也是活着")
    }

    func testObviouslyDeadPidsAreNotAlive() {
        XCTAssertFalse(ASCIIHoldMonitor.processIsAlive(0))
        XCTAssertFalse(ASCIIHoldMonitor.processIsAlive(-1))
        XCTAssertFalse(ASCIIHoldMonitor.processIsAlive(999_999))
    }

    // MARK: - 作用域文件解析

    func testScopeFileParsing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-ascii-hold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ body: String, _ name: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data(body.utf8).write(to: url)
            return url
        }

        XCTAssertEqual(ASCIIHoldMonitor.readScope(try write("", "empty")), [],
                       "touch 出来的空文件就是「不限 app」")
        XCTAssertEqual(ASCIIHoldMonitor.readScope(try write("{}", "nokey")), [])
        XCTAssertEqual(ASCIIHoldMonitor.readScope(try write("not json", "junk")), [],
                       "解析失败只能退回『不限 app』，绝不能因此放弃整条请求")
        XCTAssertEqual(ASCIIHoldMonitor.readScope(try write(#"{"apps":[]}"#, "emptyapps")), [])
        XCTAssertEqual(
            ASCIIHoldMonitor.readScope(try write(#"{"apps":["com.github.wez.wezterm"]}"#, "one")),
            ["com.github.wez.wezterm"])
        XCTAssertEqual(
            ASCIIHoldMonitor.readScope(
                try write(#"{"apps":["com.apple.Terminal","com.googlecode.iterm2"]}"#, "two")),
            ["com.apple.Terminal", "com.googlecode.iterm2"])
        XCTAssertEqual(ASCIIHoldMonitor.readScope(dir.appendingPathComponent("missing")), [])
    }

    // MARK: - 配置

    func testConfigDefaults() {
        let d = ASCIIHoldConfig.default
        XCTAssertTrue(d.enabled, "默认开：不开的话这个功能等于不存在")
        XCTAssertTrue(d.allowedApps.isEmpty, "空列表 = 不限 app")
        XCTAssertFalse(d.requireAppScope, "默认宽松，让 touch 出来的请求也能用")
        XCTAssertFalse(d.showIndicator, "文件管理器一分钟切好几次模式，默认别弹窗")
    }

    /// 逐字段解码：少一个键不能把整块设置打回默认值。
    /// 这正是 `AppConfig` 里那段长注释讲的坑。
    func testConfigDecodesPartialJSON() throws {
        let json = #"{"enabled":false}"#
        let decoded = try JSONDecoder().decode(ASCIIHoldConfig.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.allowedApps, ASCIIHoldConfig.default.allowedApps)
        XCTAssertEqual(decoded.requireAppScope, ASCIIHoldConfig.default.requireAppScope)
        XCTAssertEqual(decoded.showIndicator, ASCIIHoldConfig.default.showIndicator)
    }

    func testConfigSurvivesAnEmptyObject() throws {
        let decoded = try JSONDecoder().decode(ASCIIHoldConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, ASCIIHoldConfig.default)
    }

    func testAppConfigRoundTripsASCIIHold() throws {
        var config = AppConfig.default
        config.asciiHold.enabled = false
        config.asciiHold.allowedApps = ["com.github.wez.wezterm"]
        config.asciiHold.requireAppScope = true

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.asciiHold, config.asciiHold)
    }

    /// 老的 config.json 里没有 asciiHold 这一块，必须落到默认值而不是抛错。
    func testAppConfigWithoutASCIIHoldUsesDefaults() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.asciiHold, ASCIIHoldConfig.default)
    }

    // MARK: - 和真实客户端的对接

    /// 照 superfile 实际写出来的样子摆一个目录，整条链路跑一遍。
    ///
    /// 这个用例存在的理由很具体：协议的两端在两个仓库里，各自的单元测试都只能
    /// 验证自己那一半。真正会出事的是中间那层约定 —— 文件名是什么、内容长什么样、
    /// 临时文件会不会被误读。
    func testReadsWhatSuperfileWrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // superfile 的 scopeBody()：TERM_PROGRAM=WezTerm 时就是这一行。
        let pid = getpid()
        try Data(#"{"apps":["com.github.wez.wezterm"]}"#.utf8)
            .write(to: dir.appendingPathComponent(String(pid)))

        // 原子写留下的中间态：绝不能被当成请求。
        try Data().write(to: dir.appendingPathComponent(".\(pid).tmp"))

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let result = ASCIIHoldRules.evaluate(
            entries: names,
            isAlive: ASCIIHoldMonitor.processIsAlive,
            scope: { ASCIIHoldMonitor.readScope(dir.appendingPathComponent($0)) })

        XCTAssertEqual(result.holders.count, 1, "临时文件不是请求")
        XCTAssertEqual(result.holders.first?.pid, pid)
        XCTAssertEqual(result.holders.first?.apps, ["com.github.wez.wezterm"])
        XCTAssertTrue(result.stale.isEmpty)

        XCTAssertTrue(result.covers(bundleID: "com.github.wez.wezterm",
                                    allowedApps: [], requireScope: false),
                      "WezTerm 里要按英文走")
        XCTAssertFalse(result.covers(bundleID: "com.electron.lark",
                                     allowedApps: [], requireScope: false),
                       "别的 App 里不受影响")
        XCTAssertTrue(result.covers(bundleID: "com.github.wez.wezterm",
                                    allowedApps: ["com.github.wez.wezterm"],
                                    requireScope: true),
                      "superfile 写了 apps，所以严格模式下也算数")
    }

    /// superfile 撤销请求 = 把文件删掉。
    func testReleaseIsJustRemovingTheFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmotim-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent(String(getpid()))
        try Data().write(to: file)

        func evaluateNow() throws -> ASCIIHoldRules.Evaluation {
            ASCIIHoldRules.evaluate(
                entries: try FileManager.default.contentsOfDirectory(atPath: dir.path),
                isAlive: ASCIIHoldMonitor.processIsAlive,
                scope: { ASCIIHoldMonitor.readScope(dir.appendingPathComponent($0)) })
        }

        XCTAssertTrue(try evaluateNow().isActive)
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(try evaluateNow().isActive)
    }
}
