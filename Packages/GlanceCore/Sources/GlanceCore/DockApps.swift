import Foundation

/// Dock 常驻应用名单的**纯解析**(kernel:不碰 AppKit,`swift test` 可测)。
///
/// 输入 = `com.apple.dock` 偏好域 `persistent-apps` 的原始值(经 CFPreferences/UserDefaults 读出,
/// IO 在 App target),输出 = 按用户钉住顺序排好的 app(bundle id + 显示名 + .app 路径)。
///
/// 结构事实(本机实测 + dockutil / DuckDuckGo DockCustomizer 先例):
///   每项 = `{ GUID, tile-type, tile-data }`;只认 `tile-type == "file-tile"`(app);
///   路径在 `tile-data.file-data._CFURLString`(percent-encoded 的 file URL);
///   `tile-data.bundle-identifier` = bundle id,`tile-data.file-label` = 显示名(个别 tile 可能缺)。
///
/// fail-closed:输入不是数组、item 形态不对、路径缺失/不是 .app —— 一律**跳过该格**,绝不让
/// 一个陌生的 Dock 项把整个名单弄挂(名单脏了顶多少几格,不能崩)。
public enum DockApps {
    public struct PinnedApp: Equatable, Sendable {
        public let bundleID: String?
        public let name: String?
        public let path: String

        public init(bundleID: String?, name: String?, path: String) {
            self.bundleID = bundleID
            self.name = name
            self.path = path
        }
    }

    /// 解析 persistent-apps。键不存在/形态变了 → 返回空数组(调用方按"没有启动区"处理)。
    public static func parse(persistentApps: Any?) -> [PinnedApp] {
        guard let items = persistentApps as? [[String: Any]] else { return [] }
        var out: [PinnedApp] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let tileType = item["tile-type"] as? String, tileType == "file-tile",
                  let tileData = item["tile-data"] as? [String: Any] else { continue }
            // 路径:file-data._CFURLString。系统写的是 percent-encoded 的 file URL;
            // 兜一层"裸路径"(_CFURLStringType != 15 的老数据),以 file: 开头才按 URL 解
            guard let raw = (tileData["file-data"] as? [String: Any])?["_CFURLString"] as? String,
                  !raw.isEmpty else { continue }
            let path: String
            if raw.hasPrefix("file:") {
                guard let url = URL(string: raw), url.isFileURL else { continue }
                path = url.path
            } else {
                path = raw
            }
            guard path.hasSuffix(".app") else { continue }
            let bundleID = tileData["bundle-identifier"] as? String
            let name = tileData["file-label"] as? String
            out.append(PinnedApp(bundleID: bundleID, name: name, path: path))
        }
        return out
    }
}
