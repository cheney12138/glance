import CoreGraphics
import Foundation

/// **图片缓存的键规则**（纯函数，可单测）—— 重构清单第 5 条的余项。
///
/// ## 为什么键要算，不能"一个窗 id 就完事"
///
/// 病例（2026-09-22 抽这条时发现）：`CardImageCache` 的键只有 `wid` ✗，
/// 而缓存值里带着**按当时的卡片尺寸与屏 scale 缩好的位图** ✓。
/// 于是"卡片尺寸上限"或缩放一变，同一扇窗**永远命中旧尺寸那张图** ✗ ——
/// 键相同、值却该换，是缓存最典型的错法 ✓（挪窗口大小反而不受影响：那时 `wid` 会变 ✓）。
///
/// ⇒ 口径：**键必须覆盖"决定了那个值长什么样"的全部输入** ✓。
///   卡片图 = 窗 id + 像素尺寸（尺寸里已经含了 scale ✓）。
///
/// （"座图"的键曾只有窗 id —— 2026-09-24 深夜「座」随遮罩改静态雾檐整体退役，
///   键与缓存一并删除，此处留一行案底。）
public enum ImageCacheKey {

    /// 卡片图（`CardImageCache.Prepared`）的键
    public struct Card: Hashable {
        public let windowID: UInt32
        public let pixelWidth: Int
        public let pixelHeight: Int
        public init(windowID: UInt32, pixelWidth: Int, pixelHeight: Int) {
            self.windowID = windowID
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    /// 目标 pt 尺寸 + 屏 scale ⇒ **实际像素尺寸**（与渲染路径同一把尺子 ✓）。
    ///
    /// 下限 2px：`CGContext` 不接受 0/1 ✓（老代码就是 `max(2, …)` ✓，这里逐字保留 ✓）。
    public static func pixelSize(target: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let w = max(2, Int((target.width * scale).rounded()))
        let h = max(2, Int((target.height * scale).rounded()))
        return (w, h)
    }

    /// 卡片图的键
    public static func card(windowID: UInt32, target: CGSize, scale: CGFloat) -> Card {
        let px = pixelSize(target: target, scale: scale)
        return Card(windowID: windowID, pixelWidth: px.width, pixelHeight: px.height)
    }
}
