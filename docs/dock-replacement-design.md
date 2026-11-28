# Glance Dock 替代功能 · 设计与并行实现上下文

> 本文是分支 `feat/dock-replacement` 上所有并行实现任务的**唯一共享上下文与接口契约**。
> 读完本文即可直接编码，无需重复全仓调研。决策依据见 `docs/adr/0018-dock-replacement-isolation.md`。

---

## 0. 红线纪律（所有 agent 必须遵守）

1. **严禁实机打扰**（见 `AGENTS.md`）：
   - **绝对不要**运行 `Tools/run.sh`；
   - **绝对不要**在开发/测试期间调用 `killall Dock` 或改写宿主机的真实 `com.apple.dock` 偏好（单元测试只测纯逻辑或注入内存存储，**严禁碰宿主机真实 Dock**）；
   - **绝对不要**运行 `screencapture` 或注入 HID 事件。
2. **严禁提前 `git commit`**（见 `AGENTS.md`）：所有改动留在工作区，等用户实机验收后再提交。
3. **硬隔离红线**：
   - **不修改 `Sources/Glance/Panel/` 下任何文件**（除非协调器明确授权，正常零改动）；
   - `Sources/Glance/Dock/` 禁止引用 `PanelController` / `PanelView` / `PreviewPanelView` / `HotkeyTapCenter` / `SettingsStore` / `SettingsView` / `PermissionMonitor` / `NativeHotkeyGuards`；
   - `Packages/GlanceCore` 严禁 `import AppKit` / `SwiftUI` / `Cocoa` / `Combine`（只允许 `Foundation` / `CoreGraphics` / `Carbon` / `Darwin`）；
   - **`Dock/` 严禁修改 `PanelMetrics.sessionCap`、`PanelMetrics.trayCap`、`PanelMetrics.trayZoom`** 这些静态可变全局量（它们是 `PanelController` 私有会期状态），Dock 自己按局部 `scale` 计算；
   - **不要动 `Glance.xcodeproj/project.pbxproj`**（除非任务明确指派；统一由协调器登记新文件，防并发冲突）。
4. **配置单一来源**：所有 UserDefaults 键在 `Sources/Glance/App/Keys.swift`，默认值在 `KeyDefaults`。且每个新键必须被非 UI 运行时代码读取（`Tools/check-architecture.swift` 规矩 ④ 强制检查）。

---

## 1. 产品决策摘要（已与用户全部敲定）

- **形态**：V1 做**自动隐藏式**（隐藏原生 Dock + 边缘贴边唤起），支持 **左 (`left`) / 下 (`bottom`) / 右 (`right`)** 三种位置。常驻占屏已于 2026-11-25 评估完毕：方案 C（强制占屏留白）平台不可行，若 V2 做常驻只走方案 A（悬浮常驻 + 全屏避让），详见 ADR-0018。
- **原生 Dock 劫持**：默认关闭（opt-in）。开启后写 `com.apple.dock` `autohide = true` + `autohide-delay = 1000.0` 并重载；备份原始值（区分 `nil` 与显式值），接入四重恢复守卫 + 脏标记自愈 + 应急 CLI `Tools/NativeDock.swift`。不拦截 `⌥⌘D`。
- **内容与排序**：
  - 按屏归属（鼠标在哪块屏贴边，就在哪块屏唤起、只列该屏窗口）；
  - 沿用 **MRU 排序**；
  - **兼容最小化窗口**：Dock 调用 `WindowEnumerator.enumerate(owning: screen, includeMinimized: true)`，不影响 ⌘Tab 自己的开关；
  - **未启动 App**：环尾固定放一枚**纯点击的 2×2 未启动文件夹入口**（液态玻璃圆角方块内嵌 2×2 真实缩略图标；`Button` / `onTapGesture`，**严禁 hover 触发**），点击在「已启动 App 段 ↔ 未启动 App 段」之间切换（复用 `DockAppsProvider`）；未启动段图标休眠态降饱和 0.38 + 压暗 0.07（与 ⌘Tab 未启动环同一语义），悬停唤醒回满彩；入口内迷你图标同用休眠语义，悬停入口时整体唤醒，进入未启动段后同一枚按钮变为返回箭头（详见 §5.2）；
  - **两个独立尺寸档**：`dock.iconSize`（条带图标，36…96pt，默认 56）与 `dock.previewScale`（预览托盘，80…150%，默认 120）互不影响，各自再按本屏可用空间自动收紧；
  - **预览卡片位置**：默认相对程序坞**居中**（`dock.centerTray` 默认开，与 ⌘Tab 一致）；关闭后跟随悬停图标的中心滑动；
  - **侧边叠卡**：`left` / `right` + 芯片轨道多窗时，托盘 = 上「选中窗预览卡」+ 下「macOS 通知式芯片叠卡」（收起露 2 层底边，悬停错峰滑出展开，芯片宽组内恒定）；
  - **窗口预览托盘**：无论横向还是纵向，**均跟随全局 `WindowLayout.current`**（`.row` 卡片行 / `.rail` 芯片轨道）；按位置向内展开：`bottom → 上方`、`left → 右侧`、`right → 左侧`；Live 预览多窗只跑**一条流**（选中窗）；
  - **纯鼠标交互**：贴边 dwell 后唤起，hover 选 App 弹出托盘，斜向移入托盘不误串隔壁 App，点击窗卡落焦（含最小化恢复），点击未启动图标启动 App，移出「条带 ∪ 托盘 ∪ 触发带」联合区域超过宽限时间自动收起；hover 与点击均由 **60Hz 几何命中**分发，滑入滑出为 **120Hz 零重绘**（详见 §5.3–§5.5）；
  - **视觉**：条带与 ⌘Tab 主环共用 **`RingGlassSurface`**（macOS 26 原生 `.glassEffect(.clear)`；macOS 14–25 光学补偿降级），详见 §5.7；
  - **V1 不做**：常驻占屏、废纸篓、文件夹栈、拖文件到图标、右键菜单。

---

## 2. 现有可复用模块与精确签名

### 2.1 `Sources/Glance/Design/`（可直接复用，严禁逆向依赖业务）
- `PanelGlass.swift`:
  - `RingGlassSurface<Content>(cornerRadius:size:epoch:compactShadow:content:)`（**程序坞条带与 ⌘Tab 主环、舌头滑块共用的统一玻璃面**，V1 定稿，见 §5.7）
  - `GlassBackground(cornerRadius: CGFloat)`（SwiftUI `NSViewRepresentable`，macOS 26 自动用 `NSGlassEffectView`）
  - `GlassRim(cornerRadius: CGFloat)`（柔和反光边缘）
  - `ClickThroughHostingView<Content: View>`（`pad: CGFloat`, `padTop: CGFloat?`，点击穿透非内容区）
  - `.glassEdge(cornerRadius: CGFloat)`
- `PanelTokens.swift`:
  - `PanelMetrics.fixedScale` (`1.2`), `PanelMetrics.iconScale` (`1.14`), `PanelMetrics.rPanel`, `PanelMetrics.rThumb`, `PanelMetrics.shadowPadStrip`, `PanelMetrics.shadowPadPop`, `PanelMetrics.thumbSize(real:aspect:)`, `PanelMetrics.chipRailWidth`, `PanelMetrics.thumbGap`, `PanelMetrics.trayPadX/Top/Bottom`
  - ⚠️ 注意：`PanelMetrics.icon` / `rowPadX` / `pitch` 等计算属性读的是静态 `scale`（会受 `sessionCap` 影响）。Dock 侧建议定义独立的 `DockMetrics(scale: CGFloat, trayScale: CGFloat)` 使用相同基准数值（如 icon base 88, rowPadX 26, rowPadY 22, iconLift 8, puckPad 22），**永不写 `PanelMetrics.sessionCap` / `trayCap` / `trayZoom`**。
  - `PanelColors`: `glassVeil`, `thumbBg`, `ghostTile`, `ghostTileBorder`, 等视觉色板
  - `PanelMotion`: 动效弹簧曲线
- `AppIconProvider.swift`:
  - `IconProvider.art(for pid: pid_t, bundleID: String? = nil) -> IconProvider.Art`（`Art.image: NSImage`, `Art.fill: CGFloat`）
  - `IconProvider.iconCacheDidFill`（异步补图通知）

### 2.2 `Sources/Glance/Inventory/`
- `WindowEnumerator.swift`:
  - `struct WindowRecord { let wid: CGWindowID; let pid: pid_t; let ownerName: String; let title: String; let bounds: CGRect; let isMinimized: Bool; var aspect: CGFloat }`
  - `struct AppGroup { let pid: pid_t; let appName: String; let bundleID: String?; var windows: [WindowRecord] }`
  - 修改后的签名：`WindowEnumerator.enumerate(owning screen: NSScreen?, includeMinimized: Bool = Keys.includeMinimized) -> [AppGroup]`
- `DockApps.swift`:
  - `DockAppsProvider.LaunchableApp { let id: String; let name: String; let path: String; let icon: NSImage; let fill: CGFloat }`
  - `DockAppsProvider.runningSet() -> Set<String>`
  - `DockAppsProvider.launchables(excluding runningBundleIDs: Set<String>) -> [LaunchableApp]`
  - `DockAppsProvider.launch(at path: String)`
- `Snapshotter.swift`:
  - `Snapshotter.shared`（`@Published var cache: [CGWindowID: NSImage]` — 读 `Snapshotter.shared.cache[wid]`，触发抓图用 `Snapshotter.shared.precapture(windows, force: false)`）

### 2.3 `Sources/Glance/Focus/`
- `WindowFocuser.swift`:
  - `WindowFocuser.focus(window w: WindowRecord)`（内置 `w.isMinimized` 还原 + 单窗落焦 + 降级核验）
  - 无窗 App 激活：`NSRunningApplication(processIdentifier: group.pid)?.activate()`（或复用 `WindowFocuser.activateApp` 若已有，请先查看 `WindowFocuser.swift` 确认）

### 2.4 `Sources/Glance/App/Keys.swift`
- 现有 `WindowLayout.current`（`.row` / `.rail`）
- 新增键（由 M5-1 统一定义）：
  - `Keys.dockEnabled = "dock.enabled"` / `KeyDefaults.dockEnabled = false`
  - `Keys.dockPosition = "dock.position"` / `KeyDefaults.dockPosition = DockPosition.bottom.rawValue`
  - `Keys.dockDwellMs = "dock.dwellMs"` / `KeyDefaults.dockDwellMs = 100`（设置页四档：50 / 100 / 180 / 280ms）
  - `Keys.dockIconSize = "dock.iconSize"` / `KeyDefaults.dockIconSize = 56`（Double，设置页范围 36…96，读取时夹紧；`DockMetrics.scale = iconSize / 88`）
  - `Keys.dockPreviewScale = "dock.previewScale"` / `KeyDefaults.dockPreviewScale = 120`（Double，设置页范围 80…150，读取时夹紧为 0.80…1.50；独立于图标尺寸）
  - `Keys.dockCenterTray = "dock.centerTray"` / `KeyDefaults.dockCenterTray = true`（预览卡片是否始终相对程序坞居中；false = 跟随悬停图标中心）
  - `Keys.dockSavedSnapshot = "dock.nativeSnapshot"`（内部持久化用户原生 Dock 快照的 JSON，不暴露在设置页，由 `NativeDockTakeover` 读写；注意规矩 ④ 要求在非 UI 文件被读）
  - 新增静态便利读取：`Keys.isDockEnabled`, `Keys.currentDockPosition`, `Keys.dockDwellMsValue` / `Keys.dockDwellSeconds`, `Keys.dockIconSizePt`（夹紧 36…96）, `Keys.dockPreviewScaleRatio`（夹紧 0.80…1.50）, `Keys.isDockTrayCentered`

---

## 3. GlanceCore 纯核 API 契约（M0 实现，M1/M2/M3/M4 消费）

所有文件放在 `Packages/GlanceCore/Sources/GlanceCore/Dock/`，全部 `public` 以便 App target 使用。

### 3.1 `DockPosition.swift`
```swift
public enum DockPosition: String, CaseIterable, Codable, Sendable, Equatable {
    case left
    case bottom
    case right

    public var isVertical: Bool { self != .bottom }
    public var label: String { ... } // "左侧" / "底部" / "右侧"
}
```

### 3.2 `DockTakeoverPlan.swift`
```swift
public struct DockPreferencesSnapshot: Codable, Equatable, Sendable {
    public let autohide: Bool?
    public let autohideDelay: Double?
    public init(autohide: Bool?, autohideDelay: Double?)
}

public enum DockPreferenceMutation: Equatable, Sendable {
    case setBool(String, Bool)
    case setDouble(String, Double)
    case remove(String)
}

public enum DockTakeoverPlan {
    public static let hiddenAutohideDelay: Double = 1000.0
    /// 需要接管时应写入的变更清单
    public static func takeoverMutations() -> [DockPreferenceMutation]
    /// 归还原生 Dock 时应写入的恢复清单（精准还原 nil vs 显式值）
    public static func restoreMutations(from snapshot: DockPreferencesSnapshot) -> [DockPreferenceMutation]
    /// 判断当前读取到的系统值是否仍是“我们接管态”（防止二次覆盖原值快照！）
    public static func looksLikeOurTakeover(autohide: Bool?, autohideDelay: Double?) -> Bool
}
```

### 3.3 `DockEdgeGeometry.swift`
坐标系约定：**AppKit 屏幕全局坐标系（左下为原点，Y 向上，与 `NSScreen.frame` 一致）**。
```swift
public struct DockDisplayRect: Equatable, Sendable {
    public let id: UInt32          // CGDirectDisplayID
    public let frame: CGRect       // NSScreen.frame
    public let visibleFrame: CGRect // NSScreen.visibleFrame
    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect)
}

public struct DockSensorStrip: Equatable, Sendable {
    public let displayID: UInt32
    public let rect: CGRect        // 1~2pt 厚、排除跨屏公共边与四角热角后的传感矩形
    public init(displayID: UInt32, rect: CGRect)
}

public enum DockEdgeGeometry {
    /// 计算所有屏的有效外边缘传感条（自动剔除与其他屏相接的共享边段 + 两端热角留白）
    public static func sensorStrips(
        displays: [DockDisplayRect],
        position: DockPosition,
        thickness: CGFloat = 2,
        cornerInset: CGFloat = 20,
        adjacencyTolerance: CGFloat = 2
    ) -> [DockSensorStrip]
}
```

### 3.4 `DockTriggerMachine.swift`
纯状态机（依赖时间以参数 `now: Double` 传入，纯函数/值类型可 100% 单测）：
```swift
public enum DockTriggerState: Equatable, Sendable {
    case idle
    case dwelling(displayID: UInt32, enteredAt: Double)
    case open(displayID: UInt32)
    case leaving(displayID: UInt32, leftAt: Double)
}

public enum DockTriggerEffect: Equatable, Sendable {
    case none
    case scheduleDwellCheck(after: Double)
    case openDock(displayID: UInt32)
    case scheduleLeaveCheck(after: Double)
    case closeDock
}

public struct DockTriggerMachine: Equatable, Sendable {
    public private(set) var state: DockTriggerState
    public var dwellDuration: Double      // 默认 0.10
    public var leaveGraceDuration: Double // 默认 0.26

    public init(dwellDuration: Double = 0.10, leaveGraceDuration: Double = 0.26)
    public mutating func edgeEntered(displayID: UInt32, mouseButtonsPressed: Bool, suppressed: Bool, now: Double) -> DockTriggerEffect
    public mutating func edgeExited(displayID: UInt32, now: Double) -> DockTriggerEffect
    public mutating func pointerEnteredSurface(displayID: UInt32, now: Double) -> DockTriggerEffect
    public mutating func pointerLeftSurface(displayID: UInt32, now: Double) -> DockTriggerEffect
    public mutating func tick(now: Double, mouseButtonsPressed: Bool, suppressed: Bool) -> DockTriggerEffect
    public mutating func forceClose() -> DockTriggerEffect
}
```

### 3.5 `DockLayoutGeometry.swift`
同样使用 AppKit 全局坐标（Y 向上），纯几何计算：
```swift
public enum DockLayoutGeometry {
    /// 计算 Dock 条带玻璃内容矩形（贴对应屏幕边、另一轴居中，并留边缘呼吸距 edgeMargin）
    public static func stripContentRect(
        contentSize: CGSize,
        position: DockPosition,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        edgeMargin: CGFloat = 12
    ) -> CGRect

    /// 计算托盘玻璃内容矩形（按 bottom→上 / left→右 / right→左 展开，中心对齐 anchorPoint 并夹紧在屏内）
    public static func trayContentRect(
        traySize: CGSize,
        stripRect: CGRect,
        anchorCenterAlongAxis: CGFloat, // bottom 时为图标中心 X；left/right 时为图标中心 Y
        position: DockPosition,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        gap: CGFloat = 14,
        screenEdgePad: CGFloat = 12
    ) -> CGRect

    /// 判断点是否处于「条带 ∪ 托盘 ∪ 二者之间过渡桥」的保活区内（防止鼠标从条带滑向托盘途中误判离开）
    public static func isPointInInteractiveRegion(
        point: CGPoint,
        stripRect: CGRect,
        trayRect: CGRect?,
        position: DockPosition,
        slop: CGFloat = 14
    ) -> Bool

    /// Safe-Triangle：点是否落在「以 anchor 为顶点、以托盘面向条带那条边（两端各外扑 edgeSlop）为底边」的三角形内，
    /// 且相对于 anchor 已沿「条带 → 托盘」法向推进 > 0.5pt。退化三角形不命中（详见 §5.5）。
    public static func isPointInTrayApproachTriangle(
        point: CGPoint,
        anchor: CGPoint,
        trayRect: CGRect,
        position: DockPosition,
        edgeSlop: CGFloat = 14
    ) -> Bool
}
```

---

## 4. 模块分工与校验命令

- **Wave 1（并行）**：
  - `dock-core`：M0（`Packages/GlanceCore/Sources/GlanceCore/Dock/*` + `Tests/GlanceCoreTests/Dock*Tests.swift`）
  - `dock-tools`：M1-3（`Tools/NativeDock.swift`）+ M3-1（`WindowEnumerator.swift` 加 `includeMinimized` 默认参数）+ M5-1（`Keys.swift` 注册键与 `KeyDefaults`）
- **Wave 2（并行，依赖 Wave 1）**：
  - `dock-trigger`：M1-1/M1-2（`Trigger/NativeDockTakeover.swift` + 接入 `Trigger/NativeHotkeyGuards.swift`）+ M2（`Trigger/DockEdgeSensor.swift`）
  - `dock-ui`：M3-2..4 + M4（`Dock/DockController.swift`、`Dock/DockStripView.swift`、`Dock/DockTrayView.swift`、`Dock/DockMetrics.swift`）
  - `dock-settings`：M5-2（`Settings/SettingsView.swift` 新增独立「Dock」分节）
- **Wave 3（协调器收口）**：
  - 登记新文件到 `Glance.xcodeproj/project.pbxproj`；
  - `App/GlanceApp.swift` 装配与 `PanelController` 双向互斥；
  - `Tools/check-architecture.swift` 与 `docs/architecture.md` 补全 `Dock` ↔ `Panel` 双向禁引；
  - 跑齐三道门禁：
    1. `swift Tools/check-architecture.swift`
    2. `cd Packages/GlanceCore && swift test`
    3. `xcodebuild -project Glance.xcodeproj -scheme Glance -configuration Debug build`

---

## 5. V1 定稿细节（2026-11-25 落地后回填）

### 5.1 尺寸：条带与托盘是两个独立设置

- 条带比例 `DockMetrics.scale = Keys.dockIconSizePt / 88`（默认 56/88 ≈ 0.636）；托盘比例 `trayScale = Keys.dockPreviewScaleRatio`（默认 1.20）。两者互不影响。
- `DockMetrics.fitted(visibleSize:…)` 再按本屏 `visibleFrame` 自动收紧：条带横向长 ≤ 88% 宽、纵向长 ≤ 82% 高（厚度分别 ≤ 28% / 25%），下限 0.32；托盘按内容实测尺寸解析求上限，下限 0.45。
- 设置页「程序坞」分节 7 行：替代系统程序坞 / 屏幕位置 / 图标尺寸 / 预览窗口尺寸 / 贴边触发延迟（50·100·180·280ms）/ 预览卡片居中 / 还原系统程序坞。任一改动 → `GlanceApp.syncDockSubsystem(dismissIfVisible: true)`，重装接管与边缘传感并收起在场条带。

### 5.2 环尾 2×2 未启动文件夹入口

- 条带尾部一枚 `DockLauncherFolderTile`：液态玻璃圆角方块（边长 = 0.90 × 图标，圆角 = 边长 × 0.225）+ 内嵌 2×2 真实未启动 App 迷你图标（`launchables.prefix(4)`，`app.fill` 边距补偿），类比 macOS「App 资源库」；无未启动 App 时退化为四点阵列兜底。
- **休眠低饱和语义与 ⌘Tab 未启动环统一**：未悬停降饱和 0.38 + 压暗 0.07，悬停回满彩（`glow` 开时 1.12）；入口内迷你图标用同一组参数，悬停入口时整体唤醒。
- **严格纯点击**：`Button` 触发 `toggleLaunchSegment()`，**严禁 hover 触发切换**（规避 ADR-0013 扫过误触）；hover 只改视觉（`hoveredTailToggle`）。进入未启动段后同一枚按钮显示返回箭头 `arrow.uturn.backward`。
- 几何独立成段：占据 `toggleGap + 分隔缝 + toggleGap + toggleButtonSize`（`DockMetrics.toggleSectionAxisSpan`），在 60Hz 命中里是独立的 `.tailToggle` 目标。

### 5.3 120Hz 零重绘滑入滑出

- 条带登/退场由 120Hz `Timer` 逐帧改 `NSPanel.frame` 与 `alphaValue`（`DockController.animateStrip`）：入场 0.22s `1-(1-t)^3.4`（ease-out，起手敏捷落地柔顺），退场 0.16s `t^1.55`（起手即动、收尾干脆）；托盘淡入 120Hz 0.11s（`animateTrayFadeIn`）。
- **零重绘**：动画帧只动窗口 frame / alpha，不写任何 `@Published` 视觉状态（尺寸、名单、选中态、托盘内容都不参与）；`glassEpoch` 只在开局与收局各 +1（重建玻璃一次），不在动画途中跳变。
- **可打断**：退场途中再次贴边 ⇒ `resumingFromExit` 从当前帧原地滑回，不重新从屏外进入；入场途中后台枚举回流只更新落点（`animTargetFrame`），不重启动画。

### 5.4 60Hz 几何 hover / 点击分发

- `DockFloatingPanel` 是非激活 `NSPanel`（`canBecomeKey = false`），SwiftUI `.onHover` 在帧移动 / 淡入后会失灵 ⇒ **条带** hover 不用 `.onHover`，改 60Hz `Timer` 读 `NSEvent.mouseLocation` 做几何命中（`startHoverPolling` → `pollHover`）。托盘内的卡片 / 芯片仍用 `.onHover`，另有几何兜底（见下文）。
- `stripHitTarget(at:)` 是条带命中的**唯一来源**（hover 轮询与 `handleStripMouseDown` 共用），返回 `.tailToggle` / `.runningApp(i)` / `.launchApp(i)` / `.none`；坐标系为 AppKit 全局坐标（左下原点，Y 向上）。
- 点击同样走几何：`NSEvent` 本地监视器里 `handleStripMouseDown` 命中即 `confirmApp` / `launchApp` / `toggleLaunchSegment` 并消费事件（不回给 SwiftUI），杜绝非激活面板内 `.onTapGesture` 被吞或同一次点击跑两遍。
- 另有一条 60Hz click gate：指针在托盘内且不在条带内容区时，把条带窗口的透明呼吸区设为 `ignoresMouseEvents`，避免它拦住托盘点击。
- 侧边叠卡展开后有独立几何兜底 `expandedSideChipHitIndex(at:)`（与 `DockSideChipStack` 同源），因为 `setFrame` 撑高后 tracking area 会滞后 / 丢事件；需滚动的极端情形（芯片总高超出展开高度）交 `ScrollView` 自己处理，几何层不硬算滚动偏移。

### 5.5 Safe-Triangle：斜向移入托盘不误串隔壁图标

- 现象：托盘贴着当前 hover 图标居中展开后，指针从条带一侧斜向移往托盘，途中必然压过隔壁图标的命中格 ⇒ 60Hz 轮询当场切格、托盘跳走，手感像「误串 / 发木」。
- 判据（`GlanceCore.DockLayoutGeometry.isPointInTrayApproachTriangle`）：以「指针最后一次落在当前 hover 图标自身时」的位置为顶点（`lastSafeAnchorPoint`），以托盘面向条带那条边（两端各外扩 `edgeSlop = 14`）为底边构成三角形。必须**同时**满足：
  1. 沿「条带 → 托盘」法向推进 > 0.5pt（纯沿条带横扫、或远离托盘恒为 false ⇒ 保持 0ms 瞬时切格，绝不发木）；
  2. 落在三角形内（叉积同号，含边界；退化三角形一律不命中）。
- 落地：宽限态 `diagonalHoldStartedAt`。指针仍在推进（本帧位移 ≥ 0.4pt 且方向朝托盘）⇒ 一直保持；已停住 ⇒ 只给 0.18s（`diagonalHoldGraceLimit`）后放行切格，避免用户真停在隔壁图标上却被冻住。
- 清理：开局 / 收局 / 收起托盘（`hideTray`，`toggleLaunchSegment` 亦经此）/ 指针进入托盘内，统一 `resetDiagonalGuard()`，避免跨局残留顶点。

### 5.6 侧边 macOS 通知式芯片叠卡（`left` / `right` + `.rail` 多窗）

- 形态：上「选中窗预览卡」（水平居中）+ 下「一列真芯片叠卡」。收起态同一批真芯片叠在顶层芯片后方（最多露 2 层，94% / 88% 宽），悬停叠卡区向下展开；展开后移回预览卡不收起。
- 展开由参数 `fan: 0 → 1` 驱动逐枚弹簧滑出，**不走** `.transition`（规避系统 `reduceMotion` 吃掉过渡，同 `PanelMotion` 2026-10-08 结论）。错峰 = 每 rank `response 0.30 + 0.028 × min(rank, 5)`，damping 0.84（顶层先动、后层顺次跟进）；切窗用独立弹簧 `selF`（response 0.30 / damping 1.0）。
- **自适应组内恒定宽度**：芯片宽 = `clamp(卡组最大宽, 136 × trayScale, 204 × trayScale)`（窄竖窗收紧、宽窗封顶），同一组内恒定 ⇒ 切窗不跳位；列宽取 `max(卡宽, 芯片宽)`。
- 命中层必须挂在 `.scaleEffect` / `.offset` **之前**（2026-11-25 病例：挂在其后的 `.contentShape` / `.onHover` / `.onTapGesture` 会在未偏移的布局框上判定 ⇒ 滑到下方的第 2/3/4 枚芯片视觉与命中错位，hover 与点击全落空）。
- 竖直空间不足时列高夹到 `maxListH`，内容交给 `ScrollView(.vertical)`（`scrollDisabled(!expanded)`）。
- 展开 / 收起几何统一在 `DockMetrics.sideRailGeometry(windows:maxHeight:expanded:)`（`SideRailGeometry`），由 `DockTrayView` 与 `DockController` 共用同一个源。

### 5.7 统一液态玻璃 `RingGlassSurface`

- 条带改用 `Design/PanelGlass.swift` 的 `RingGlassSurface`（与 ⌘Tab 主环、舌头滑块同源），程序坞不再有独立玻璃配方：
  - **macOS 26+**：原生 `.glassEffect(.clear, in: shape)` 提供真实边缘光学折射，内叠稳态微渐层 + 顶受光唇 + 8pt 底弧内影 + 0.75pt 折光发丝边，外叠 1.8pt 接触影 + 14pt 抬升影；
  - **macOS 14–25**：`NSVisualEffectView` 真实桌面毛玻璃 + 同源稳态层 + 光学补偿降级（上半弧穹顶柔光 + 对角菲涅尔折光棱 + 柔和内焦散边），零私有 API、零崩溃。
- 颜色全走 `PanelColors.dynamic(...)`（`NSColor(name:)`），不读 `@Environment(\.colorScheme)` ⇒ 预热过的离屏 ⌘Tab 面板与程序坞在浅 / 深模式切换后像素级对齐。
- `epoch: glassEpoch` 作为 `.id` 重建玻璃（开局 / 收局各一次），托盘用同一个 `glassEpoch`；预览托盘沿用 2026-09-21 裁定：**无最外层玻璃背板**，只保留悬浮卡片阴影与芯片胶囊。

### 5.8 Live 预览：多窗只跑一条流

- `.rail` 多窗（含侧边叠卡）：场上只挂**一条** Live 流，严格绑定当前选中窗；其余窗口只显示快照（`LivePreviewPool.shared.sync([选中窗], selected:)`）。
- `.row` 卡片行与单窗各组按可见窗口逐张同步；最小化窗不申请 Live（走遗照灰），开播前先用 `cachedFrame` 回填热帧减少快照 → 实时首帧闪烁。
- `hideTray` / 收起条带 / 切到未启动段时 `LivePreviewPool.shared.stopAll(reason:)`，不在后台留流。
