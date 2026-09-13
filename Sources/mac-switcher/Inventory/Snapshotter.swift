import AppKit
import ScreenCaptureKit

/// 预截(brand-spec「展开层 0ms」的前提):面板出现那一刻,截图必须已在手。
/// 时序:DebugSessionLogger 在 begin 即调用,T6 面板只读 cache,永不现截。
/// 画面规格:16:10 区域内按窗口真实比例缩放,高一律 320pt(2x 出图 ≈ 640px 宽内)。
@MainActor
final class Snapshotter: ObservableObject {
    static let shared = Snapshotter()
    private init() {}

    /// cache 与面板同呼吸:新一轮枚举必须清场,否则展开层会显示"昨天的窗"(T5 实机现形 19/13)
    @Published private(set) var cache: [CGWindowID: NSImage] = [:]

    func clear() {
        cache.removeAll()
        failedOnce.removeAll()
    }

    /// 同一扇窗的失败只报第一次(访达等 SCK 截不了的窗会屡败屡试;现拍风暴期曾刷屏)
    private var failedOnce: Set<CGWindowID> = []

    /// 对一批窗做预截。失败的(权限缺失/窗口中途消失)跳过,记日志,不阻塞其余。
    func precapture(_ windows: [WindowRecord]) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let byID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
            for w in windows {
                guard let scWindow = byID[w.wid] else {
                    print("[T5] \(w.ownerName) wid=\(w.wid) 已不在屏,跳过")
                    continue
                }
                let config = SCStreamConfiguration()
                // 出图规格:宽 720px(240pt 卡片 ≈3x retina 余量),高按窗口比例,
                // 上下封顶防极端形状(竖条/横幅)出 4000px 大图(T6 实机现形:320px 高糊成马赛克)
                let aspect = w.bounds.width / max(w.bounds.height, 1)
                config.width = 720
                config.height = min(max(Int(720 / aspect), 48), 1500)
                config.showsCursor = false
                config.scalesToFit = true
                do {
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                        configuration: config
                    )
                    let nsImage = NSImage(cgImage: image, size: NSSize(width: config.width, height: config.height))
                    cache[w.wid] = nsImage
                } catch {
                    if failedOnce.insert(w.wid).inserted {
                        print("[T5] \(w.ownerName) wid=\(w.wid) 截屏失败: \(error.localizedDescription)(此后静默)")
                    }
                }
            }
        } catch {
            print("[T5] SCShareableContent 获取失败: \(error.localizedDescription)(屏幕录制权限?)")
        }
    }
}
