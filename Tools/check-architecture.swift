// 架构约定的**校验器**。约定写在 docs/architecture.md,这里是它的牙齿。
//
//   swift Tools/check-architecture.swift          # 过一遍,有违例就非零退出
//
// 三条规矩:
//   ① GlanceCore 是纯核 —— 不许 import AppKit / SwiftUI / Cocoa / Combine;
//   ② 模块依赖只能**向下**:App → Panel/Settings/Trigger/Permissions/Inventory/Focus/Design → GlanceCore;
//   ③ 每个模块有一份"禁引符号表",碰了就报(注释不算)。
//
// 为什么要有这个:文件夹是拆不出模块的 —— 只有"能报错"的边界才算数。改完代码跑一遍,
// 比在 PR 里争论"这算不算越界"便宜得多。

import Foundation

// MARK: - 约定(改这里就等于改约定,记得同步 docs/architecture.md)

let coreRoot = "Packages/GlanceCore/Sources"

/// 纯核只许这些 import
let coreAllowedImports: Set<String> = ["Foundation", "CoreGraphics", "Carbon", "Carbon.HIToolbox", "Darwin"]

/// 模块 → 不许出现的符号。留空 = 只在顶层(App)才允许碰全部
let forbiddenSymbols: [String: [String]] = [
    "Design": ["PanelController", "PanelView", "PreviewPanelView", "SettingsStore", "SettingsView",
               "PermissionMonitor", "PermissionGuideView", "HotkeyTapCenter", "NativeHotkeyGuards",
               "WindowEnumerator", "Snapshotter", "MruEvidence", "WindowFocuser", "CmdClickFix"],
    "Diagnostics": ["PanelController", "PanelView", "PreviewPanelView", "SettingsStore", "SettingsView",
                    "PermissionMonitor", "PermissionGuideView", "HotkeyTapCenter", "NativeHotkeyGuards",
                    "WindowEnumerator", "Snapshotter", "MruEvidence", "WindowFocuser", "CmdClickFix",
                    "AppIconProvider", "PanelMetrics", "PanelColors", "PanelMotion", "MotionPolicy"],
    // 输入管线不许反向依赖 UI:面板通过闭包(onAction)接线,不通过类型
    "Trigger": ["PanelController", "PanelView", "PreviewPanelView", "SettingsStore", "SettingsView",
                "PermissionMonitor", "PermissionGuideView", "WindowEnumerator", "Snapshotter",
                "MruEvidence", "WindowFocuser", "CmdClickFix", "AppIconProvider", "PanelMetrics",
                "PanelColors", "PanelMotion", "MotionPolicy"],
    "Inventory": ["PanelController", "PanelView", "PreviewPanelView", "SettingsStore", "SettingsView",
                  "PermissionMonitor", "PermissionGuideView", "HotkeyTapCenter", "NativeHotkeyGuards",
                  "WindowFocuser", "CmdClickFix", "AppIconProvider", "PanelMetrics", "PanelColors",
                  "PanelMotion", "MotionPolicy"],
    "Focus": ["PanelController", "PanelView", "PreviewPanelView", "SettingsStore", "SettingsView",
              "PermissionMonitor", "PermissionGuideView", "HotkeyTapCenter", "NativeHotkeyGuards",
              "WindowEnumerator", "Snapshotter", "MruEvidence", "AppIconProvider", "PanelMetrics",
              "PanelColors", "PanelMotion", "MotionPolicy"],
    // 面板可以要 Design/Inventory/Focus 与 Trigger 的 Action 词表;不许碰设置与权限
    "Panel": ["SettingsStore", "SettingsView", "PermissionMonitor", "PermissionGuideView", "NativeHotkeyGuards"],
    // 设置窗可以要 Design/Permissions 与核;不许碰面板与清点
    "Settings": ["PanelController", "PanelView", "PreviewPanelView", "HotkeyTapCenter", "WindowEnumerator",
                 "Snapshotter", "MruEvidence", "WindowFocuser", "CmdClickFix"],
    "Permissions": ["PanelController", "PanelView", "PreviewPanelView", "SettingsStore", "SettingsView",
                    "HotkeyTapCenter", "NativeHotkeyGuards", "WindowEnumerator", "Snapshotter",
                    "MruEvidence", "WindowFocuser", "CmdClickFix", "AppIconProvider", "PanelMetrics",
                    "PanelColors", "PanelMotion", "MotionPolicy"],
]

// MARK: - 扫描

/// 去掉注释与字符串字面量:约定管的是**代码**,不是文档里提到谁
func stripCommentsAndStrings(_ source: String) -> String {
    var out = ""
    let chars = Array(source)
    var i = 0
    var inBlockComment = false
    var inLineComment = false
    var inString = false
    while i < chars.count {
        let c = chars[i]
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        if inLineComment {
            if c == "\n" { inLineComment = false; out.append(c) }
        } else if inBlockComment {
            if c == "*", next == "/" { inBlockComment = false; i += 1 }
        } else if inString {
            if c == "\\" { i += 1 } else if c == "\"" { inString = false }
        } else if c == "/", next == "/" {
            inLineComment = true; i += 1
        } else if c == "/", next == "*" {
            inBlockComment = true; i += 1
        } else if c == "\"" {
            inString = true
        } else {
            out.append(c)
        }
        i += 1
    }
    return out
}

func swiftFiles(in directory: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
    return enumerator.compactMap { $0 as? String }
        .filter { $0.hasSuffix(".swift") }
        .map { "\(directory)/\($0)" }
        .sorted()
}

var violations: [String] = []

// 规矩 ①:纯核不许碰 AppKit / SwiftUI
for file in swiftFiles(in: coreRoot) {
    let code = stripCommentsAndStrings(try String(contentsOfFile: file, encoding: .utf8))
    for line in code.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("import ") else { continue }
        let module = trimmed.replacingOccurrences(of: "import ", with: "").trimmingCharacters(in: .whitespaces)
        if !coreAllowedImports.contains(module) {
            violations.append("① 纯核越界:\(file) 里 `import \(module)`\n"
                              + "      GlanceCore 只许 \(coreAllowedImports.sorted().joined(separator: " / "))"
                              + " —— 碰了 AppKit 的东西请留在 App 侧,见 docs/architecture.md")
        }
    }
}

// 规矩 ②③:模块禁引符号表
for (module, forbidden) in forbiddenSymbols.sorted(by: { $0.key < $1.key }) {
    for file in swiftFiles(in: "Sources/Glance/\(module)") {
        let code = stripCommentsAndStrings(try String(contentsOfFile: file, encoding: .utf8))
        for symbol in forbidden where code.contains(symbol) {
            violations.append("② \(module) 越界:\(file) 引用了 \(symbol)\n"
                              + "      依赖只能向下(App → 面板/设置/输入/权限/清点/落点/设计 → GlanceCore);"
                              + "跨模块协作走闭包或 App 层装配")
        }
    }
}

// MARK: - 汇报

print("架构校验:纯核 \(swiftFiles(in: coreRoot).count) 个文件 + \(forbiddenSymbols.count) 个模块的禁引符号表")
if violations.isEmpty {
    print("✅ 无违例")
    exit(0)
}
print("❌ \(violations.count) 条违例:")
for violation in violations { print("   - \(violation)") }
exit(1)
