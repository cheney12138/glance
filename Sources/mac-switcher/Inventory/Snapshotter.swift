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

    func clear() { cache.removeAll() }

    /// T5 验收产物目录;T6 起取消落盘只留内存
    let dumpDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-switcher-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

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
                config.height = 320
                let aspect = w.bounds.width / max(w.bounds.height, 1)
                config.width = max(Int(320 * aspect), 48)
                config.showsCursor = false
                config.scalesToFit = true
                do {
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                        configuration: config
                    )
                    let nsImage = NSImage(cgImage: image, size: NSSize(width: config.width, height: config.height))
                    cache[w.wid] = nsImage
                    dump(nsImage, label: "\(w.ownerName)-\(w.wid)")
                } catch {
                    print("[T5] \(w.ownerName) wid=\(w.wid) 截屏失败: \(error.localizedDescription)")
                }
            }
        } catch {
            print("[T5] SCShareableContent 获取失败: \(error.localizedDescription)(屏幕录制权限?)")
        }
    }

    private func dump(_ image: NSImage, label: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let safe = label.replacingOccurrences(of: "/", with: "-")
        try? png.write(to: dumpDir.appendingPathComponent("\(safe).png"))
    }
}
