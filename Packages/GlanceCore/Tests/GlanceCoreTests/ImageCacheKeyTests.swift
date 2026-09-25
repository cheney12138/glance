import XCTest
@testable import GlanceCore

/// 缓存键规则的单测：把"键必须覆盖决定值的全部输入"钉住 ✓
final class ImageCacheKeyTests: XCTestCase {

    func testPixelSizeUsesTheSameRulerAsRendering() {
        // 207×122pt @2x ⇒ 414×244px（卡片尺寸 × 屏 scale ✓）
        let px = ImageCacheKey.pixelSize(target: CGSize(width: 207, height: 122), scale: 2)
        XCTAssertEqual(px.width, 414)
        XCTAssertEqual(px.height, 244)
    }

    func testPixelSizeNeverGoesBelowTwo() {
        // CGContext 不接受 0/1（老代码就是 max(2, …) —— 逐字保留 ✓）
        let px = ImageCacheKey.pixelSize(target: CGSize(width: 0, height: 0.2), scale: 1)
        XCTAssertEqual(px.width, 2)
        XCTAssertEqual(px.height, 2)
    }

    /// 病例：键只看窗 id ⇒ 卡片尺寸上限/缩放一变，永远命中旧尺寸那张 ✗
    func testCardKeyChangesWhenTargetSizeChanges() {
        let a = ImageCacheKey.card(windowID: 42, target: CGSize(width: 207, height: 122), scale: 2)
        let b = ImageCacheKey.card(windowID: 42, target: CGSize(width: 160, height: 94), scale: 2)
        XCTAssertNotEqual(a, b, "同一个窗、目标尺寸不同 ⇒ 必须是两把钥匙（否则拿到旧尺寸那张图 ✗）")
    }

    func testCardKeyChangesWhenScaleChanges() {
        let a = ImageCacheKey.card(windowID: 42, target: CGSize(width: 207, height: 122), scale: 2)
        let b = ImageCacheKey.card(windowID: 42, target: CGSize(width: 207, height: 122), scale: 1)
        XCTAssertNotEqual(a, b, "换屏(scale 变)⇒ 像素尺寸变 ⇒ 键也要变")
    }

    func testCardKeyStableForSameInputs() {
        let a = ImageCacheKey.card(windowID: 7, target: CGSize(width: 100, height: 60), scale: 2)
        let b = ImageCacheKey.card(windowID: 7, target: CGSize(width: 100, height: 60), scale: 2)
        XCTAssertEqual(a, b, "同样的输入必须命中同一把钥匙（不然缓存等于没有 ✓）")
    }

    // (testSeatKeyIsJustTheWindow 已删 —— 2026-09-24 深夜「座」随遮罩改静态雾檐退役,
    //   ImageCacheKey.seat 一并移除 ✓)
}
