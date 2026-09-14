import CoreGraphics
import XCTest
@testable import GlanceCore

/// 触发键配置的解析口径。这类"读 UserDefaults 拼一个值"的逻辑最容易悄悄变味
/// (默认值、键名映射、接管开关的默认值),所以它们必须钉在测试里。
final class TriggerConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.cheney12138.macswitcher.tests.triggerConfig"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 默认必须是 ⌥Tab —— "默认不接管、不动系统热键"这条约定从这里起步
    func testDefaultIsOptionTab() {
        let config = TriggerConfig.default
        XCTAssertEqual(config.keyCode, 0x30)
        XCTAssertEqual(config.modifierMask, .maskAlternate)
        XCTAssertEqual(config.display, "⌥Tab")
    }

    /// 没写过 keys → load() 回落到默认(而不是造出一个半截配置)
    func testLoadFallsBackToDefaultWhenUnset() {
        XCTAssertEqual(TriggerConfig.load(from: defaults), .default)
    }

    func testLoadCommandTab() {
        defaults.set(0x30, forKey: "trigger.keyCode")
        defaults.set("command", forKey: "trigger.modifier")
        let config = TriggerConfig.load(from: defaults)
        XCTAssertEqual(config.modifierMask, .maskCommand)
        XCTAssertEqual(config.display, "⌘Tab")
        XCTAssertEqual(config.modifierKeyCodes, [0x37, 0x36])
    }

    func testLoadControlAndOption() {
        defaults.set(0x31, forKey: "trigger.keyCode")
        defaults.set("control", forKey: "trigger.modifier")
        XCTAssertEqual(TriggerConfig.load(from: defaults).display, "⌃Space")
        defaults.set("option", forKey: "trigger.modifier")
        XCTAssertEqual(TriggerConfig.load(from: defaults).display, "⌥Space")
    }

    /// 认不出的修饰键不许造出"没有修饰键的裸键":回落默认
    func testLoadUnknownModifierFallsBack() {
        defaults.set(0x30, forKey: "trigger.keyCode")
        defaults.set("hyper", forKey: "trigger.modifier")
        XCTAssertEqual(TriggerConfig.load(from: defaults), .default)
    }

    /// 接管开关默认 **false**(默认不碰系统热键)
    func testTakeoverDefaultsOff() {
        XCTAssertFalse(TriggerConfig.takeoverEnabled(in: defaults))
    }

    func testKeyNameMapping() {
        XCTAssertEqual(TriggerConfig.keyName(of: 0x30), "Tab")
        XCTAssertEqual(TriggerConfig.keyName(of: 0x32), "`")
        XCTAssertEqual(TriggerConfig.keyName(of: 0x0C), "Q")
    }
}
