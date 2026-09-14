import XCTest
@testable import GlanceCore

/// 用例全部来自**实机窗口清单**(`Tools/CaptureWindow.swift list`),不是编的字符串。
final class WindowTitleTests: XCTestCase {

    // MARK: - 编辑器家族:抽工程名

    func testVSCodeFamilyKeepsProjectNotFile() {
        // CatPaw IDE 实机标题:`search.js (Working Tree) (search.js) — tab-group-search`
        XCTAssertEqual(
            WindowTitle.display(raw: "search.js (Working Tree) (search.js) — tab-group-search",
                                bundleID: "com.meituan.catpaw"),
            "tab-group-search"
        )
        // 同一个 IDE 的第二扇窗:`Saga.ts — train_mrn_app_orderdetail`
        XCTAssertEqual(
            WindowTitle.display(raw: "Saga.ts — train_mrn_app_orderdetail",
                                bundleID: "com.meituan.catpaw"),
            "train_mrn_app_orderdetail"
        )
        XCTAssertEqual(
            WindowTitle.display(raw: "PanelView.swift — glance",
                                bundleID: "com.microsoft.VSCode"),
            "glance"
        )
    }

    func testXcodeProjectComesFirst() {
        // Xcode 实机标题:`mac-switcher — mac-switcher.xcodeproj`(工程在前,但要靠"不像文件名"选中)
        XCTAssertEqual(
            WindowTitle.display(raw: "mac-switcher — mac-switcher.xcodeproj",
                                bundleID: "com.apple.dt.Xcode"),
            "mac-switcher"
        )
    }

    func testJetBrainsProjectComesFirstWithEnDash() {
        // IntelliJ 实机标题:`trade-galaxy-server – TrainXProductOrderServiceImpl.java`
        XCTAssertEqual(
            WindowTitle.display(raw: "trade-galaxy-server – TrainXProductOrderServiceImpl.java",
                                bundleID: "com.jetbrains.intellij"),
            "trade-galaxy-server"
        )
    }

    // MARK: - 终端家族:tab 名原样保留

    func testTerminalTabNameIsKeptVerbatim() {
        // Ghostty 实机标题(用户第四张截图就是这条 tab):`π - tab-group-search`
        // 这里的 ` - ` 是普通连字符,**不是**分隔符 —— 拆了就毁
        XCTAssertEqual(
            WindowTitle.display(raw: "π - tab-group-search", bundleID: "com.mitchellh.ghostty"),
            "π - tab-group-search"
        )
        XCTAssertEqual(
            WindowTitle.display(raw: "grill-with-docs skill 安装", bundleID: "com.mitchellh.ghostty"),
            "grill-with-docs skill 安装"
        )
    }

    // MARK: - 非编辑器:一律原样(浏览器标题里也有破折号,不许动)

    func testBrowserTitleUntouched() {
        // Chrome 实机标题:`CatPaw Studio - AI Agent 配置管理`;再看一个真用 em 破折的站点标题
        XCTAssertEqual(
            WindowTitle.display(raw: "CatPaw Studio - AI Agent 配置管理",
                                bundleID: "com.google.Chrome"),
            "CatPaw Studio - AI Agent 配置管理"
        )
        XCTAssertEqual(
            WindowTitle.display(raw: "如何评价 — 知乎", bundleID: "com.google.Chrome"),
            "如何评价 — 知乎"
        )
        XCTAssertEqual(
            WindowTitle.display(raw: "Visio — 微信", bundleID: "com.tencent.xinWeChat"),
            "Visio — 微信"
        )
    }

    // MARK: - 抽不出来就原样回退(绝不显示空标题)

    func testFallsBackToRaw() {
        // 编辑器但没有分隔符
        XCTAssertEqual(WindowTitle.display(raw: "欢迎", bundleID: "com.apple.dt.Xcode"), "欢迎")
        // 两段都像文件名
        XCTAssertEqual(
            WindowTitle.display(raw: "a.swift — b.swift", bundleID: "com.apple.dt.Xcode"),
            "a.swift — b.swift"
        )
        // 空串 / 只有分隔符
        XCTAssertEqual(WindowTitle.display(raw: "", bundleID: "com.apple.dt.Xcode"), "")
        XCTAssertEqual(WindowTitle.display(raw: " — ", bundleID: "com.apple.dt.Xcode"), " — ")
    }

    // MARK: - 家族判定

    func testEditorFamilyDetection() {
        XCTAssertTrue(WindowTitle.showsProjectName(bundleID: "com.meituan.catpaw"))
        XCTAssertTrue(WindowTitle.showsProjectName(bundleID: "com.jetbrains.goland"))
        XCTAssertTrue(WindowTitle.showsProjectName(bundleID: "COM.APPLE.DT.XCODE"))
        XCTAssertFalse(WindowTitle.showsProjectName(bundleID: "com.mitchellh.ghostty"))
        XCTAssertFalse(WindowTitle.showsProjectName(bundleID: nil))
        XCTAssertFalse(WindowTitle.showsProjectName(bundleID: ""))
    }
}
