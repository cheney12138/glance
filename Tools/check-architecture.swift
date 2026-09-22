// 架构约定的**校验器**。约定写在 docs/architecture.md,这里是它的牙齿。
//
//   swift Tools/check-architecture.swift          # 过一遍,有违例就非零退出
//
// 四条规矩:
//   ① GlanceCore 是纯核 —— 不许 import AppKit / SwiftUI / Cocoa / Combine;
//   ② 模块依赖只能**向下**:App → Panel/Settings/Trigger/Permissions/Inventory/Focus/Design → GlanceCore;
//   ③ 每个模块有一份"禁引符号表",碰了就报(注释不算);
//   ④ **界面能改的键,必须真有运行时读取点** —— 防"设置说了话却做不到"。
//      (2026-09-22 病例两起:「保持面板打开」绑的是 `debug.pinPanelOnRelease`,而那一层
//       读的还是旧调试键 ⇒ 菜单/设置里打开的开关**只管一半** ✗;
//       另一起更早:那一行设置绑调试键、而 App 每次启动清它 ⇒ 设置**永远存不住** ✗)
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

/// **已知违例(账本)** —— 只许**变短**,不许变长 ✗
///
/// 为什么留这个口子:门禁如果常年是红的,就没人看它了(等于没有 ✗)。把"已经知道、
/// 暂时不修"的写在这里 ⇒ ① 门禁保持可用 ✓ ② 债是**可见的**、下次顺手还 ✓
/// 逐条都带出处与理由;新增一条必须先在这儿写清"为什么现在不修" ✓
let knownViolations: [(module: String, symbol: String, why: String)] = [
    ("Trigger", "WindowEnumerator",
     "双击 ⌥ 跳另一块屏(2026-09-17)要判'窗口归哪块屏' ⇒ 直接用清点模块的纯函数。"
     + "正解与本次同款:改成 App 层装配的闭包(±30 行)。**未修**,因为它是既有的、与本轮无关的一笔债"),
    ("Trigger", "WindowFocuser",
     "同上那支还负责'把那扇窗抬起来' ⇒ 用了落点模块。同一笔债,一起还 ✓"),
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
            if knownViolations.contains(where: { $0.module == module && $0.symbol == symbol }) { continue }
            violations.append("② \(module) 越界:\(file) 引用了 \(symbol)\n"
                              + "      依赖只能向下(App → 面板/设置/输入/权限/清点/落点/设计 → GlanceCore);"
                              + "跨模块协作走闭包或 App 层装配")
        }
    }
}

// 规矩 ④:界面能改的键,必须有运行时读取点
//
// 判据(够用就好,不是形式化证明):
//   · 键名在 `App/Keys.swift` 里声明(`static let x = "..."` 或 `= 某个 Core 里的键名` ✓)
//   · **读取点** = App 侧**非界面文件**里出现 `Keys.<x>` 或那个字面量;或 Core 里出现该字面量
//   · 「界面文件」= 声明键的、画设置的、画菜单的、以及调试开关表 —— 它们只会**写**,
//     不能算"有人读" ✓
//   · Core 拥有键名的那些(如触感):声明处必须**至少出现两次**(声明 + 真正读一次)——
//     启发式,但足以挡住"声明了却没人读" ✗
let uiOnlyFiles: Set<String> = [
    "Sources/Glance/App/Keys.swift",
    "Sources/Glance/App/DebugFlags.swift",
    "Sources/Glance/App/GlanceApp.swift",
    "Sources/Glance/Settings/SettingsView.swift",
    "Sources/Glance/Settings/SettingsControls.swift",
]

func appSourceFiles() -> [String] {
    swiftFiles(in: "Sources/Glance").filter { !uiOnlyFiles.contains($0) }
}

let keyDeclPattern = try NSRegularExpression(pattern: #"static let (\w+) = (\"[^\"]+\"|[A-Za-z_][\w.]*)"#)
let keysPath = "Sources/Glance/App/Keys.swift"
let keysCode = stripCommentsAndStrings(try String(contentsOfFile: keysPath, encoding: .utf8))
var declaredKeys: [(name: String, literal: String?, alias: String?)] = []
for line in keysCode.split(separator: "\n") {
    let s = String(line)
    guard let m = keyDeclPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let nameRange = Range(m.range(at: 1), in: s) else { continue }
    let name = String(s[nameRange])
    var literal: String?
    if let litRange = Range(m.range(at: 2), in: s) {
        let lit = String(s[litRange])
        if lit.hasPrefix("\"") {
            literal = String(lit.dropFirst().dropLast())
        } else if !lit.contains(".") {
            continue      // `KeyDefaults.xxx = true` 这种**默认值**声明不是键名 ✗(第一版把它也当键了)
        }
    }
    var alias: String?
    if literal == nil, let litRange = Range(m.range(at: 2), in: s) { alias = String(s[litRange]) }
    declaredKeys.append((name, literal, alias))
}

// App 侧所有非界面文件的代码(注释与字面量之外的部分)+ Core 的代码
let appCode = appSourceFiles().map { stripCommentsAndStrings((try? String(contentsOfFile: $0, encoding: .utf8)) ?? "") }
    .joined(separator: "\n")
let coreCodeRaw = swiftFiles(in: coreRoot).map { (try? String(contentsOfFile: $0, encoding: .utf8)) ?? "" }
    .joined(separator: "\n")

for (name, literal, alias) in declaredKeys.sorted(by: { $0.name < $1.name }) {
    let usedInApp = appCode.contains("Keys.\(name)")
    // ⚠️ 字面量要在**两边**找:App 侧有(如面板直接读),Core 侧也有
    //    (如 `TriggerConfig` 按字面量读 `trigger.takeoverSystemSwitcher` ✗ 第一版只找了 App ⇒ 假阳性)
    let usedByLiteral = literal.map { appCode.contains("\"\($0)\"") || coreCodeRaw.contains("\"\($0)\"") } ?? false
    if usedInApp || usedByLiteral { continue }
    // Core 拥有键名的那些(形如 `= HapticPolicy.defaultsKey`):
    //   判据 = 那个**别名**在 Core 里出现 ≥2 次(声明一次 + 真读一次)✓
    //   (第一版按"字面量出现两次"判 ⇒ 漏了"Core 内部用别名读"⇒ 假阳性 ✗)
    //   ⚠️ 别名要去掉类型前缀(`HapticPolicy.defaultsKey` ⇒ `defaultsKey`):
    //      声明与读取都在**那个类型内部**,不会写成 `HapticPolicy.defaultsKey` ✗(假阳性来源 ✓)
    if let alias {
        let bare = alias.split(separator: ".").last.map(String.init) ?? alias
        if coreCodeRaw.components(separatedBy: bare).count - 1 >= 2 { continue }
    }
    violations.append("④ 键没人读:`Keys.\(name)`\(literal.map { " (\($0))" } ?? "")\n"
                      + "      界面(设置/菜单)能改它,但**运行时没有任何地方读** ⇒ 用户改了不生效 ✗\n"
                      + "      要么接线到真正读它的地方,要么把这个键与那一行界面一起删掉")
}

// MARK: - 汇报

print("架构校验:纯核 \(swiftFiles(in: coreRoot).count) 个文件 + \(forbiddenSymbols.count) 个模块的禁引符号表"
      + " + 键名联动检查" + (knownViolations.isEmpty ? "" : "(已知账 \(knownViolations.count) 条)"))
if violations.isEmpty {
    print("✅ 无违例")
    exit(0)
}
print("❌ \(violations.count) 条违例:")
for violation in violations { print("   - \(violation)") }
exit(1)
