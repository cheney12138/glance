import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// 把 AI 定稿裁成"只有玻璃方块"的 App 图标资产:
//   ① 沿中线扫最强的亮度跳变,自动找出玻璃方块的四边(背景是渐变,所以只能找"边"不能找"色差")
//   ② 按 Apple 图标网格把这个方块摆到画布 82%,四周留透明
//   ③ 圆角遮罩(半径略大于 Apple 的 22.4%,确保把圈外那点背景/水印切干净)
//   ④ 出一整套尺寸 + 预览对照(浅底/深底)

let src = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "chosen.png"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/glance-icon"
// 遮罩圆角占边长的比例。默认 0.29;可作第三个参数传入以便**扫参**(衡量方法见 design/icon/README.md 坑六)
let cornerRatio = CommandLine.arguments.count > 3 ? (Double(CommandLine.arguments[3]) ?? 0.29) : 0.29
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let isrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil)!
let W = img.width, H = img.height
var buf = [UInt8](repeating: 0, count: W*H*4)
let bctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W*4,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
func luma(_ x: Int, _ y: Int) -> Double {
    let x = min(max(x, 0), W-1), y = min(max(y, 0), H-1)
    let i = ((H-1-y)*W + x)*4
    return (0.299*Double(buf[i]) + 0.587*Double(buf[i+1]) + 0.114*Double(buf[i+2]))/255
}
/// 从**外侧向里**扫,找第一条亮度跳变超阈值的位置 —— 这样找到的是**最外层**的边(玻璃方块的外缘),
/// 而不是"最强的边"(中线竖扫时最强的是里面那层磨砂头,外壳顶边是柔和渐变、强度反而低)。
func outerEdge(_ from: Int, _ to: Int, step: Int, _ at: (Int) -> (Int, Int)) -> Int {
    let dir = to > from ? 1 : -1
    var i = from
    while (dir > 0 && i < to - 10) || (dir < 0 && i > to + 10) {
        var sum = 0.0
        for k in -6...6 {   // 三条平行线取平均,抗噪
            let p1 = at(i), p2 = at(i + dir * 6)
            sum += abs(luma(p1.0 + k * step, p1.1 + k * step) - luma(p2.0 + k * step, p2.1 + k * step))
        }
        if sum / 13 > 0.012 { return i }
        i += dir
    }
    return from
}
let yMid = H/2, xMid = W/2
let left   = outerEdge(6, W/2, step: 2) { ($0, yMid) }
let right  = outerEdge(W-7, W/2, step: 2) { ($0, yMid) }
let top    = outerEdge(6, H/2, step: 2) { (xMid, $0) }
let bottom = outerEdge(H-7, H/2, step: 2) { (xMid, $0) }
// 用**宽度**同时当高:玻璃方块是近似正方形,而底边扫到的是投影会偏大(拉高会把图形拉长)
// 外接方:取**较长的那条边**,四边以中心对齐。
//
// 2026-09-15 病例(满幅改版第一次翻车):原来 `side0 = right-left`(宽度当高)——
// 宽度扫到 1457、高度扫到 1514(两轴"第一条边"的阈值落点不同),方框比玻璃**矮 57px**;
// 满幅放大后玻璃顶边被切掉 ≈21px,图标上面是**平的一条** ✗。
// 取 max → 方框是玻璃的外接方(四边各多出一点背景,由下面的内缩收掉)。
//
// 2026-09-15 病例(第二次翻车,用户报"app 图标的边没清理干净"):上面那条 max 修好了"顶边被切",
// 但**引入了米色边框** ✗。实测四条边的米色带(源图底色 #F1EDE2 的残留):
//     左 1.76% ✗   右 1.76% ✗   上 0.00% ✓   下 1.17% ✗
// 原因:max 取的是高度,而**底边扫到的是投影**(注释里自己写过)⇒ 方框被撑大;
// 又因为外接方是**居中**放的 ⇒ 多出来的尺寸左右各溢出 ~1.8% ⇒ 玻璃外面带一圈米色底。
// 顶边干净恰恰证明了这条:**上边扫到的才是玻璃自己的边** ✓。
// 所以不信 max,回到"宽度当边长 + 以左上为锚":水平中线不扫到投影(可信),上边也实测干净(可信)。
let side0 = right - left
let cx = CGFloat(left) + CGFloat(side0) / 2, cy = CGFloat(top) + CGFloat(side0) / 2
// 内缩:从外向内扫到的第一条边是**外层泛光**的起点,不收就会带出一圈背景光 ✗。
//
// 内缩量是**量出来的**,不是调出来的:四条扫描线都会先扫到玻璃**外面那层柔光**,
// 所以 bbox 比玻璃本体大约一圈柔光。遮罩自己还有 0.4% 的内缩(见下面 mask 的 insetBy),
// 能吸收掉左/右两侧的误差(实测已干净 ✓),但下边的误差更大(实测 1.17% ✗),
// 因为方框以左上为锚 ⇒ 误差全挤到最后一条边上。
// 取 1.8%:足够盖住柔光(实测该量级下四边全干净),而 512 上只啃掉玻璃 9px,
// 与"满幅、和 DockDoor/Ghostty 一样大"这个目标无冲突。
// (82% 时代的那段"沿四边比背景色"扫描的结论恰好也是 1.75%,两次独立测量互相印证。)
let sideC = CGFloat(side0)          // Int/CGFloat 混算会让类型检查器超时,先转干净
// 第四个参数:裁切内缩比例(默认 0.018)。可扫参 —— 见 design/icon/README.md「坑六」
let insetRatio = CommandLine.arguments.count > 4 ? (Double(CommandLine.arguments[4]) ?? 0.018) : 0.018
let inset0 = sideC * CGFloat(insetRatio)
let boxOriginX = cx - sideC / 2 + inset0
let boxOriginY = cy - sideC / 2 + inset0
let box = CGRect(x: boxOriginX, y: boxOriginY,
                 width: sideC - inset0 * 2, height: sideC - inset0 * 2)
print("画布 \(W)x\(H) | 玻璃方块 bbox: \(left),\(top) \(right-left)x\(bottom-top)")

// 目标:1024 画布,**方块满幅**(2026-09-15 改)
//
// 原来按 Apple 老网格只占 82%,结果在 Dock / 登录项列表里**比别人的图标小一圈**
// (用户实拍:DockDoor / Ghostty 都是满幅)。macOS 26 的图标画法就是满幅 —— 系统不给
// macOS 应用图标加遮罩,PNG 里留多少透明边就小多少。圆角由我们自己的遮罩给,与方块同Radius。
func make(_ px: Int) -> CGImage {
    let S = CGFloat(px)
    let side = S * 1.0
    let target = CGRect(x: (S-side)/2, y: (S-side)/2, width: side, height: side)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.saveGState()
    let mask = CGPath(roundedRect: target.insetBy(dx: side*0.004, dy: side*0.004),
                      cornerWidth: side*CGFloat(cornerRatio), cornerHeight: side*CGFloat(cornerRatio), transform: nil)
    ctx.addPath(mask); ctx.clip()
    // 源图按 box → target 缩放后绘制
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)   // 目标翻转(左上原点)
    let sx = target.width / box.width, sy = target.height / box.height
    ctx.translateBy(x: target.minX, y: target.minY)
    ctx.scaleBy(x: sx, y: sy)
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)  // 源图翻回
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
    ctx.restoreGState()
    return ctx.makeImage()!
}
func write(_ cg: CGImage, _ name: String) {
    let u = URL(fileURLWithPath: "\(outDir)/\(name)")
    let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
}
for px in [1024, 512, 256, 128, 64, 32, 16] { write(make(px), "icon_\(px).png") }
// 预览:浅底 / 深底各一版 512
for (bgName, bg) in [("light", CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1)),
                     ("dark",  CGColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 1))] {
    let ctx = CGContext(data: nil, width: 560, height: 560, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: 560, height: 560))
    let c = make(512)
    ctx.draw(c, in: CGRect(x: 24, y: 24, width: 512, height: 512))
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "/tmp/koala/icon/preview-\(bgName).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
}
print("导出完成 → \(outDir)/  (圆角 \(cornerRatio) · 内缩 \(insetRatio))")
