import XCTest
@testable import GlanceCore

/// 「生效后要不要撤回来」的判据（病例见 `TapUndoPolicy` 头注 ✓）
///
/// 关键的一条是 **hover 不能被误伤**：那正是这套逻辑以前被否掉的原因 ✓
final class TapUndoPolicyTests: XCTestCase {

    /// 实报的形状：250ms 时指针已动 152pt、板上手指还在 ⇒ 撤 ✓
    func testUndoesDragLikeDrift() {
        let v = TapUndoPolicy.standard.verdict(drift: 152, sinceFire: 0.25, fingersDown: 3)
        guard case .undo(let why) = v else { return XCTFail("应当撤销,实际 \(v)") }
        XCTAssertTrue(why.contains("152"), "理由里要有量到的数字: \(why)")
    }

    /// ★ hover 选 App：指针在动，但**手已经离开触控板** ⇒ 绝不撤 ✓（这条是整套逻辑能不能存在的前提 ✓）
    func testKeepsWhenFingersAlreadyLifted() {
        let v = TapUndoPolicy.standard.verdict(drift: 152, sinceFire: 0.25, fingersDown: 0)
        guard case .keep(let why) = v else { return XCTFail("手离板时不该撤,实际 \(v)") }
        XCTAssertTrue(why.contains("手已离板"), why)
    }

    /// 真轻点之后指针基本不动（实测 <1pt ✓）⇒ 不撤 ✓
    func testKeepsOnNormalTap() {
        guard case .keep = TapUndoPolicy.standard.verdict(drift: 0.8, sinceFire: 0.25, fingersDown: 0) else {
            return XCTFail("正常轻点不该被撤")
        }
        guard case .keep = TapUndoPolicy.standard.verdict(drift: 5, sinceFire: 0.25, fingersDown: 3) else {
            return XCTFail("位移低于下限不该撤(抖动而已 ✓)")
        }
    }

    /// 窗口外不看 ⇒ 不撤（老的那条 1.2s 拖拽撤销仍在,各管一段 ✓）
    func testKeepsOutsideWindow() {
        guard case .keep = TapUndoPolicy.standard.verdict(drift: 400, sinceFire: 1.2, fingersDown: 3) else {
            return XCTFail("超出窗口不该由这条管")
        }
    }

    /// 档位设 0 = 关掉这条（可试档位必须有"关"那一档 ✓）
    func testCanBeTurnedOff() {
        var p = TapUndoPolicy.standard
        p.minDrift = 0
        guard case .keep = p.verdict(drift: 400, sinceFire: 0.1, fingersDown: 3) else {
            return XCTFail("关掉之后不该撤")
        }
    }
}
