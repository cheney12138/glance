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
let outDir = "/tmp/koala/icon"
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
let side0 = right-left
// 再往里收 1.6%:从外向内扫到的第一条边是**外层泛光**的起点,不收就会带出一圈背景光 ✗
let inset0 = CGFloat(side0) * 0.016
// —— 边缘洁净度扫描:沿四条边取样,量"还像不像背景",取最小的刚好切干净的内缩量 ——
// (背景是渐变的暖米色,所以判据是"与**该边中点处的背景色**的距离",不是与单一背景色比)
func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
    let x = min(max(x,0),W-1), y = min(max(y,0),H-1)
    let i = ((H-1-y)*W + x)*4
    return (Double(buf[i])/255, Double(buf[i+1])/255, Double(buf[i+2])/255)
}
func dist(_ a:(Double,Double,Double), _ b:(Double,Double,Double)) -> Double {
    abs(a.0-b.0)+abs(a.1-b.1)+abs(a.2-b.2)
}
/// 采样某条边"往里 probe 像素"处有多少比例的样本仍然像背景
func dirtiness(_ inset: CGFloat) -> (top: Double, bottom: Double, left: Double, right: Double) {
    let r = CGRect(x: CGFloat(left)+inset, y: CGFloat(top)+inset,
                   width: CGFloat(side0)-inset*2, height: CGFloat(side0)-inset*2)
    let n = 24, probe = 3.0
    func frac(_ pts: [(Double, Double)]) -> Double {
        var bad = 0.0
        for (x, y) in pts {
            let p = rgb(Int(x), Int(y))
            // 该点正外侧 20px 处当作"本地背景"
            let bx = Int(x + (x < r.midX ? -20 : 20)), by = Int(y + (y < r.midY ? -20 : 20))
            if dist(p, rgb(bx, by)) < 0.045 { bad += 1 }
        }
        return bad / Double(pts.count)
    }
    return (frac((0..<n).map { (r.minX + r.width * Double($0) / Double(n-1), r.minY + probe) }),
            frac((0..<n).map { (r.minX + r.width * Double($0) / Double(n-1), r.maxY - probe) }),
            frac((0..<n).map { (r.minX + probe, r.minY + r.height * Double($0) / Double(n-1)) }),
            frac((0..<n).map { (r.maxX - probe, r.minY + r.height * Double($0) / Double(n-1)) }))
}
print("内缩%   上     下     左     右")
// 判据只用**上边**:它偏绿,与暖米色背景差得开,指标可信;
// 另外三条边的玻璃本身近似背景色,这个指标会误报,所以不参与决策,只打印看趋势。
var chosenPct = 2.0
for pct in stride(from: 1.0, through: 3.0, by: 0.25) {
    let ins = CGFloat(side0) * CGFloat(pct) / 100
    let d = dirtiness(ins)
    print(String(format: " %.2f%%  %.2f   %.2f   %.2f   %.2f", pct, d.top, d.bottom, d.left, d.right))
    if d.top == 0 { chosenPct = pct + 0.25; break }
}
let chosenInset = CGFloat(side0) * CGFloat(chosenPct) / 100
print(String(format: "-> 采用内缩 %.2f%% (%.0fpx)", chosenPct, Double(chosenInset)))
let box = CGRect(x: CGFloat(left) + chosenInset, y: CGFloat(top) + chosenInset,
                 width: CGFloat(side0) - chosenInset*2, height: CGFloat(side0) - chosenInset*2)
print("画布 \(W)x\(H) | 玻璃方块 bbox: \(left),\(top) \(right-left)x\(bottom-top)")

// 目标:1024 画布,方块占 82%(Apple 网格),圆角 23.5% 的边长
func make(_ px: Int) -> CGImage {
    let S = CGFloat(px)
    let side = S * 0.82
    let target = CGRect(x: (S-side)/2, y: (S-side)/2, width: side, height: side)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.saveGState()
    let mask = CGPath(roundedRect: target.insetBy(dx: side*0.004, dy: side*0.004),
                      cornerWidth: side*0.315, cornerHeight: side*0.315, transform: nil)
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
print("导出完成 → /tmp/koala/icon/")
