import Foundation

/// 预览卡标题该显示什么 —— 纯规则,可测(不 import AppKit)。
///
/// 病例(用户实评,2026-09-14,四张截图):
///   · CatPaw IDE 卡片显示 `search.js (W…` / `Saga.ts — tr…` —— **当前打开的文件名对他没用**,
///     他要的是工程目录名(`tab-group-search` / `train_mrn_app_orderdetail`);
///   · Ghostty 卡片显示 `π - tab-grou…` —— 终端里 tab 名就是全部信息,只是被 12 字符先斩了
///     (现在 `PanelMetrics.titleCharLimit` 已提到 28,宽度截断兜底)。
///
/// 关键难点:同一件事在不同 App 里**排版位置不同**——
///   · VSCode 系:`<文件> (Working Tree) (文件) — <工程>`  工程在**后**
///   · Xcode :`<工程> — <工程>.xcodeproj`                   工程在**前**
///   · JetBrains:`<工程> – <文件>.java`                    工程在**前**
/// 所以不写"取前/取后",而写**取不含扩展名的那一段**:文件那一段天然带 `.java`/`.xcodeproj`,
/// 自己就被排掉了;工程名一般不带扩展名。两段都带扩展名 → 原样回退,绝不显示空标题。
public enum WindowTitle {
    /// 编辑器家族(工程型 App):命中才做抽工程名,其他一律原样显示。
    /// 用前缀而非整表:VSCode 的 fork 家族(CatPaw / Cursor / Windsurf / VSCodium)共用同一套标题排版。
    private static let editorPrefixes: [String] = [
        "com.microsoft.vscode",     // + Insiders
        "com.vscodium",
        "com.meituan.catpaw",       // 美团 CatPaw IDE(VSCode 内核)
        "com.todesktop.",           // Cursor
        "com.exafunction.windsurf",
        "com.jetbrains.",           // IntelliJ / DataGrip / GoLand / PyCharm …
        "com.google.android.studio",
        "com.apple.dt.xcode",
        "com.sublimetext.",
        "dev.zed.",
    ]

    /// 这个 App 的窗口标题里是否"同时含文件与工程"
    public static func showsProjectName(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return editorPrefixes.contains { id.hasPrefix($0) }
    }

    /// 分隔符只认破折号(em 破折 U+2014 / en 短破折 U+2013)。
    /// **绝不认普通连字符** —— Ghostty 的 tab 名 `π - tab-group-search` 里的 ` - ` 是人手写的,
    /// 拆了就毁(实拍用例)。
    private static let separators: Set<Character> = ["\u{2014}", "\u{2013}"]

    /// 显示名 = 原样,或编辑器家族抽出的工程名
    public static func display(raw: String, bundleID: String?) -> String {
        guard showsProjectName(bundleID: bundleID) else { return raw }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let parts = trimmed
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return raw }

        // 多段都不像文件名时取**最后一段**:VSCode 系把工程放在最后,而 Xcode/JetBrains 的文件段
        // 带扩展名、已被自然排掉,剩下的就是工程
        let projectLike = parts.filter { !looksLikeFileName($0) }
        guard let picked = projectLike.last else { return raw }
        return picked
    }

    /// 结尾像 `.<扩展名>` 吗(≤12 字符的字母数字,`xcodeproj` 也要认)
    private static func looksLikeFileName(_ s: String) -> Bool {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return false }
        let ext = s[s.index(after: dot)...]
        return !ext.isEmpty && ext.count <= 12 && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
