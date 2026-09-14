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
                          systemUI: Bool = false,
                          overlay: Bool = false) -> CaptureSessionEvidence {
        CaptureSessionEvidence(frontmostBundleID: id,
                               frontmostName: name,
                               systemCaptureUIRunning: systemUI,
                               screenWideOverlay: overlay)
    }

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

    /// **通用判据**:取景框铺满屏幕 = 谁在取景不重要(QQ / 微信的截图模式靠的就是这一条)
    func testScreenWideOverlayYieldsWithoutKnowingTheTool() {
        let v = CaptureSessionRule.verdict(evidence("com.tencent.qq", "QQ", overlay: true))
        XCTAssertTrue(v.isCapture)
        XCTAssertTrue(v.reason.contains("覆盖窗"))
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
