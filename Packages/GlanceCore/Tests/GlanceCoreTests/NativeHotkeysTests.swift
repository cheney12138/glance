import CoreGraphics
import XCTest
@testable import GlanceCore

/// 该关哪些系统热键 —— 这是"⌘Tab 归谁"的唯一裁决点,必须逐格钉住。
///
/// 参考实现(AltTab #5653)在这个 kernel 上翻过车:他们用 `.first { }` 遍历字典挑匹配,
/// 而 Swift 字典迭代顺序跨进程不稳定 → 一个和弦同时匹配两个谓词时随机丢一个,
/// 整个会话原生 ⌘⇥ 没被关掉。所以这里有两个专门的测试:**确定性**与**配对规则**。
final class NativeHotkeysTests: XCTestCase {
    private func config(_ keyCode: Int64, _ mask: CGEventFlags) -> TriggerConfig {
        TriggerConfig(keyCode: keyCode, modifierMask: mask, modifierKeyCodes: [],
                      modifierSymbol: "?", keyName: TriggerConfig.keyName(of: keyCode))
    }

    private var optionTab: TriggerConfig { .default }
    private var commandTab: TriggerConfig { config(0x30, .maskCommand) }
    private var commandShiftTab: TriggerConfig { config(0x30, [.maskCommand, .maskShift]) }
    private var commandGrave: TriggerConfig { config(0x32, .maskCommand) }
    private var commandSpace: TriggerConfig { config(0x31, .maskCommand) }

    // MARK: - 门禁:不开开关,一行系统设置都不动

    func testNeverTouchesSystemHotkeysWithoutExplicitTakeover() {
        for trigger in [optionTab, commandTab, commandShiftTab, commandGrave, commandSpace] {
            let plan = NativeHotkeys.plan(for: trigger, takeover: false)
            XCTAssertTrue(plan.disable.isEmpty, "未显式开启接管时不许关任何系统热键")
            XCTAssertEqual(plan.enable, NativeHotkeys.Key.allCases)
        }
    }

    func testOptionTabNeverOverlaps() {
        XCTAssertFalse(NativeHotkeys.overlapsNativeHotkey(optionTab))
        XCTAssertFalse(NativeHotkeys.overlapsNativeHotkey(config(0x30, .maskAlternate)))
        XCTAssertFalse(NativeHotkeys.overlapsNativeHotkey(config(0x30, .maskControl)))
        // ⌘Space 不是我们要动的系统热键(Spotlight 由系统自己管,不在这三条里)
        XCTAssertFalse(NativeHotkeys.overlapsNativeHotkey(commandSpace))
    }

    // MARK: - 接管态:重叠才关,且配对

    func testCommandTabDisablesBothTabHotkeysAndKeepsGrave() {
        let plan = NativeHotkeys.plan(for: commandTab, takeover: true)
        XCTAssertEqual(plan.disable, [.commandTab, .commandShiftTab])
        XCTAssertEqual(plan.enable, [.commandKeyAboveTab])
    }

    /// 配对规则:光绑 ⌘⇧⇥ 也要把正向那条让出来(否则原生正向切换器照旧会弹)
    func testCommandShiftTabAlsoDisablesThePair() {
        let plan = NativeHotkeys.plan(for: commandShiftTab, takeover: true)
        XCTAssertEqual(plan.disable, [.commandTab, .commandShiftTab])
    }

    /// ⌘` 只动它自己,不许顺带把 ⌘⇥ 关了
    func testCommandGraveDisablesOnlyItself() {
        let plan = NativeHotkeys.plan(for: commandGrave, takeover: true)
        XCTAssertEqual(plan.disable, [.commandKeyAboveTab])
        XCTAssertEqual(plan.enable, [.commandTab, .commandShiftTab])
    }

    /// #5653 的教训:结果不许依赖字典/集合的迭代顺序
    func testPlanIsDeterministic() {
        let first = NativeHotkeys.plan(for: commandTab, takeover: true)
        for _ in 0..<50 {
            let again = NativeHotkeys.plan(for: commandTab, takeover: true)
            XCTAssertEqual(again.disable, first.disable)
            XCTAssertEqual(again.enable, first.enable)
        }
    }

    /// disable 与 enable 必须互补且不重叠 —— 否则会漏一条热键永远回不来
    func testDisableAndEnableAreAlwaysComplementary() {
        for trigger in [optionTab, commandTab, commandShiftTab, commandGrave, commandSpace] {
            for takeover in [true, false] {
                let plan = NativeHotkeys.plan(for: trigger, takeover: takeover)
                XCTAssertEqual(Set(plan.disable).union(plan.enable), Set(NativeHotkeys.Key.allCases))
                XCTAssertTrue(Set(plan.disable).isDisjoint(with: Set(plan.enable)))
            }
        }
    }

    // MARK: - "脏退出"标记(2026-09-15 病例:Xcode Stop 把 ⌘Tab 留死)

    /// 标记必须能"落 → 读走 → 再读为空",而且目录可注入(否则测试会写到用户真实的 App Support 里)
    func testTakeoverMarkerRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glance-marker-test-\(UUID().uuidString)", isDirectory: true)
        let saved = NativeHotkeys.supportDirectory
        NativeHotkeys.supportDirectory = tmp
        defer { NativeHotkeys.supportDirectory = saved; try? FileManager.default.removeItem(at: tmp) }

        XCTAssertFalse(NativeHotkeys.consumeTakeoverMarker(), "没落过标记时必须是 false")

        NativeHotkeys.markTakeoverActive()
        XCTAssertTrue(NativeHotkeys.consumeTakeoverMarker(), "落过标记后必须读到 true")
        XCTAssertFalse(NativeHotkeys.consumeTakeoverMarker(), "标记是**读走**(读一次就清),第二次必须 false")

        NativeHotkeys.markTakeoverActive()
        NativeHotkeys.clearTakeoverMarker()
        XCTAssertFalse(NativeHotkeys.consumeTakeoverMarker(), "恢复后必须读不到 —— 否则每次启动都误报'上次被强杀'")
    }

    /// 标记路径的命名口径(改它等于改"下次启动能不能认出脏退出")
    func testTakeoverMarkerPathNaming() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        XCTAssertEqual(NativeHotkeys.takeoverMarkerURL(in: dir).lastPathComponent, "native-takeover.active")
        XCTAssertEqual(NativeHotkeys.takeoverMarkerURL(in: dir).deletingLastPathComponent().path, "/tmp/x")
    }
}
