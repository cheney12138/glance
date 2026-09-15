import XCTest
@testable import GlanceCore

/// **截图会话里那颗回车归谁** —— 逐格钉住。
///
/// 这条规则唯一的验收场景是"真的去截一次图",而复现成本高(要先有个截图工具、有取景框、
/// 还要在面板钉住的状态下按回车)。所以把它压成纯函数 + 这几条用例:
/// 先证明"截图中会让权",再证明"这不是一张会越界的大网"——正常 App 上的回车仍然归面板。
final class CaptureSessionTests: XCTestCase {
    private func evidence(_ id: String? = nil,
                          _ name: String? = nil,
                          pid: pid_t? = 100,
                          systemUI: Bool = false,
                          overlay: Bool = false,
                          overlays: [CaptureSessionEvidence.ScreenWideOverlay] = []) -> CaptureSessionEvidence {
        let resolved = overlays.isEmpty
            ? (overlay ? [CaptureSessionEvidence.ScreenWideOverlay(ownerPID: pid ?? -1)] : [])
            : overlays
        return CaptureSessionEvidence(frontmostBundleID: id,
                                      frontmostName: name,
                                      frontmostPID: pid,
                                      systemCaptureUIRunning: systemUI,
                                      screenWideOverlays: resolved)
    }

    /// 真机上的常驻窗:公司 DLP(两块屏蔽级铺满屏,永远在)
    private let dlp = CaptureSessionEvidence.ScreenWideOverlay(
        ownerPID: 9495, ownerBundleID: "cn.cirrusgate.dlp.CGEData")

    // MARK: - 让权:三类证据各自都够,而且理由要说得出

    func testSystemScreenshotUIRunningYields() {
        let v = CaptureSessionRule.verdict(evidence("com.apple.Safari", "Safari", systemUI: true))
        XCTAssertTrue(v.isCapture)
        XCTAssertTrue(v.reason.contains("screencaptureui"), "理由要指向系统 UI,便于日志复盘")
    }

    /// ⇧⌘5 那一套:前台就是系统截图 UI —— 就算"它在跑"这个读数没拿到,也不许漏
    func testSystemUIFrontmostYields() {
        let v = CaptureSessionRule.verdict(evidence("com.apple.screencaptureui", "screencaptureui"))
        XCTAssertTrue(v.isCapture)
    }

    func testKnownCaptureAppFrontmostYields() {
        for (id, name) in [("pl.maketheweb.cleanshotx", "CleanShot X"),
                           ("com.Snipaste", "Snipaste"),
                           ("io.shottr.Shottr", "Shottr")] {
            XCTAssertTrue(CaptureSessionRule.verdict(evidence(id, name)).isCapture, id)
        }
    }

    /// 没听说过的工具:名字像就得让(白名单天生不全,这条是它的兜底)
    func testUnknownToolByNameYields() {
        for name in ["Screenshot Lite", "SnipGrab", "某某截图", "PicSnipper", "GrabIt"] {
            XCTAssertTrue(CaptureSessionRule.verdict(evidence("com.who.knows", name)).isCapture, name)
        }
    }

    /// **通用判据**:取景框铺满屏幕 + 属于**前台自己** —— 谁在取景不重要
    /// (QQ / 微信的截图模式靠的就是这一条:同进程同 bundle,只有"前台它自己"能把它与聊天模式分开)
    func testFrontmostAppsOwnOverlayYields() {
        let v = CaptureSessionRule.verdict(evidence("com.tencent.qq", "QQ", overlay: true))
        XCTAssertTrue(v.isCapture)
        XCTAssertTrue(v.reason.contains("前台 App 自己的窗"), v.reason)
    }

    /// 取景框属于**已知截图 App**(有些工具不抢前台,窗铺满屏但前台还是你的 App)
    func testKnownCaptureAppsOverlayYieldsEvenIfNotFrontmost() {
        let e = evidence("com.apple.Safari", "Safari",
                         overlays: [.init(ownerPID: 999, ownerBundleID: "pl.maketheweb.cleanshotx")])
        let v = CaptureSessionRule.verdict(e)
        XCTAssertTrue(v.isCapture)
        XCTAssertTrue(v.reason.contains("cleanshotx"), v.reason)
    }

    /// ★ 2026-09-15 病例(用户实报"`` ` `` 的功能失效了"):屏幕管理类软件常驻**屏蔽级铺满屏**的窗,
    /// 只问"有没有"会让裁决**永久为真** → 所有导航键整套放行。
    /// 判据必须归因:那块窗属于谁?不是前台、也不是截图 App → **不认**。
    func testPersistentOverlayFromUnrelatedProcessIsNotACaptureSession() {
        // 真实坐标:公司 DLP 的 CGEData,两块 layer=2147483628 铺满屏的常驻窗
        let withDLP = evidence("com.meituan.catpaw", "CatPaw IDE", pid: 100, overlays: [dlp])
        let v = CaptureSessionRule.verdict(withDLP)
        XCTAssertFalse(v.isCapture, "DLP 的常驻覆盖窗被误判成取景框:\(v.reason)")
        XCTAssertTrue(v.reason.contains("CGEData"), "理由要指向真凶,便于复盘")

        // 连 bundle id 都取不到(非 App 进程)时同样不许认
        let anonymous = evidence("com.apple.Safari", "Safari",
                                 overlays: [.init(ownerPID: 4242)])
        XCTAssertFalse(CaptureSessionRule.verdict(anonymous).isCapture)

        // 前台 pid 取不到(nil)时,不许因为两边都 nil 而误命中
        let noFront = CaptureSessionEvidence(frontmostBundleID: nil, frontmostName: nil,
                                             frontmostPID: nil, screenWideOverlays: [])
        XCTAssertFalse(CaptureSessionRule.verdict(noFront).isCapture)
    }

    /// ★ 同一病例的第二层:DLP 那块窗**一直在**,所以真在截图时屏上至少有两块 ——
    /// 裁决必须能从一堆里挑出**能归因**的那一块,否则"修完 DLP 之后截图又不再让权了"。
    func testCaptureOverlayIsFoundAlongsideThePersistentDLPOverlay() {
        // 微信截图(DLP + 前台自己的取景框)
        let wechat = evidence("com.tencent.xinWeChat", "微信", pid: 100,
                              overlays: [dlp, .init(ownerPID: 100)])
        XCTAssertTrue(CaptureSessionRule.verdict(wechat).isCapture)

        // CleanShot(DLP + 不抢前台的已知截图工具)
        let clean = evidence("com.apple.Safari", "Safari", pid: 100,
                             overlays: [dlp, .init(ownerPID: 999,
                                                   ownerBundleID: "pl.maketheweb.cleanshotx")])
        let v = CaptureSessionRule.verdict(clean)
        XCTAssertTrue(v.isCapture)
        XCTAssertTrue(v.reason.contains("cleanshotx"), v.reason)
    }

    /// 用户手工口径(不改代码的逃生口):名单里的 App 一律算截图 App
    func testExtraBundleIDsAreHonoured() {
        let e = evidence("com.example.paint", "Paint")
        XCTAssertFalse(CaptureSessionRule.verdict(e).isCapture)
        XCTAssertTrue(CaptureSessionRule.verdict(e, extraBundleIDs: ["com.example.paint"]).isCapture)
    }

    // MARK: - 不许越界:正常 App 上的回车仍然归面板

    func testOrdinaryFrontmostAppStillBelongsToPanel() {
        for (id, name) in [("com.apple.Safari", "Safari"),
                           ("com.apple.Terminal", "终端"),
                           ("com.microsoft.VSCode", "Visual Studio Code"),
                           ("com.apple.finder", "Finder"),
                           ("com.tinyspeck.slackmacgap", "Slack"),
                           // IM:截图模式与聊天模式**同 bundle** —— 聊天里的回车不许被判成截图
                           ("com.tencent.qq", "QQ"),
                           ("com.tencent.xinWeChat", "微信")] {
            let v = CaptureSessionRule.verdict(evidence(id, name))
            XCTAssertFalse(v.isCapture, "\(name) 被误判成截图会话:\(v.reason)")
        }
    }

    /// **已知并接受的越界**:名字里带 `shot` 的非截图 App(视频剪辑之类)会被一起让权。
    ///
    /// 为什么不修:关键词这一条的价值就是"用户装了我们没听说过的截图工具也接得住",
    /// 而它的代价只在**钉住模式**下显形(回车只关面板、不聚焦,再按一次 ⌥Tab 就回来了)。
    /// 要收窄的正确做法是**加白名单**(`extraBundleIDs`),不是把关键词删掉。
    /// 这条用例的作用是把它**钉在明面上**:哪天有人问"为什么 Shotcut 时回车不生效",答案在这里。
    func testNameKeywordOverreachIsKnownAndAccepted() {
        XCTAssertTrue(CaptureSessionRule.verdict(evidence("com.example.shotcut", "Shotcut")).isCapture)
    }

    func testEmptyEvidenceIsNotACaptureSession() {
        // 取不到前台 App(全屏 App / 前台是后台进程)时不许乱让权 —— 让权的代价是这一发回车白按
        XCTAssertFalse(CaptureSessionRule.verdict(evidence()).isCapture)
        XCTAssertFalse(CaptureSessionRule.verdict(evidence(nil, nil)).isCapture)
    }

    // MARK: - 确定性:同一份证据永远给同一个答案(集合/字典的迭代顺序不许漏进来)

    func testVerdictIsDeterministic() {
        let e = evidence("com.apple.Safari", "Safari", systemUI: true, overlay: true)
        let first = CaptureSessionRule.verdict(e)
        for _ in 0..<50 { XCTAssertEqual(CaptureSessionRule.verdict(e), first) }
    }
}
