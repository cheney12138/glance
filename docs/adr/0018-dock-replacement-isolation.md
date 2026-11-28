# ADR-0018:Dock 替代方案与 ⌘Tab 面板硬隔离

状态:已采纳(2026-11-24,分支 `feat/dock-replacement`);V1 定稿 2026-11-25(见「常驻模式评估结论」「V1 视觉定稿」)
相关:ADR-0005(系统态接管四重恢复)、ADR-0008(候选集永不跨屏)、ADR-0013(未启动段)、ADR-0017(芯片轨道)、`docs/dock-replacement-design.md`

## 背景

部分用户习惯通过鼠标贴边使用 Dock 切窗与启动常用 App,但 macOS 原生 Dock 存在两个与 Glance 核心定位冲突的问题:
1. 点击原生 Dock 图标会触发跨屏级联拉起;
2. 原生 Dock 全局跨屏展示,多屏下无法按语境屏隔离且切换成本高。

我们需要用与 ⌘Tab 同款液态玻璃面板形态重构 Dock,同时严格保护现有 ⌘Tab / 三指 / `⌘\`` 体验不受回归。

## 决策

1. **原生 Dock 接管(仅隐藏、不杀进程)**:
   - 沿用 ADR-0005 纪律:**默认关闭(opt-in)**;
   - 开启时将 `com.apple.dock` 写为 `autohide = true` + `autohide-delay = 1000.0` 并重载,杜绝双 Dock 同屏;
   - 开启前持久化备份用户原始 `autohide` 与 `autohide-delay`(区分 `nil` 与显式数值),接入四重恢复守卫(正常退出 / 信号 / 异常 / 脏标记启动自愈)+ 独立 CLI 应急脚本 `Tools/NativeDock.swift`;
   - 保留系统 `⌥⌘D` 作为原生 Dock 应急逃生舱,V1 不做废纸篓与文件夹栈。
2. **V1 形态 = 自动隐藏 + 三向位置(下 / 左 / 右)**:
   - 支持 `bottom` / `left` / `right`,每块屏独立边缘传感(自动剔除多屏拼接公共交界边,避开四角热角与鼠标拖拽期间);
   - 常驻占屏留作后续评估,不在 V1 范围(2026-11-25 已评估:方案 C 平台不可行,见下文)。
3. **内容、排序与窗口预览布局**:
   - 沿用 **MRU** 排序与「按屏归属」(ADR-0008);
   - 兼容**最小化窗口**:通过 `WindowEnumerator.enumerate(owning:includeMinimized: true)` 显式收录,不改动 ⌘Tab 自身的最小化开关;
   - 窗口预览托盘无论横向还是纵向均**遵循全局 `WindowLayout.current`**(用户选卡片行即卡片行,选芯片轨道即芯片轨道);
   - 未启动 App 不与主环拼接,在条带尾部放一枚**纯点击切换入口**(2×2 未启动文件夹缩略;严禁 hover 触发,规避 ADR-0013 扫过误触),点击在已启动/未启动两段间切换。
4. **模块硬隔离(`Dock/` 与 `Panel/` 互不可见)**:
   - 新建独立模块 `Sources/Glance/Dock/`,与 `Sources/Glance/Panel/` 平级;
   - 仅共享叶子层(`Design/`、`Inventory/`、`Focus/`、`GlanceCore`);
   - `Tools/check-architecture.swift` 增设 `Dock` ↔ `Panel` 双向禁引规则;
   - `Dock/` 不修改 `PanelMetrics.sessionCap` / `trayCap` / `trayZoom` 等全局静态状态,也不开启任何破坏性键盘/鼠标 tap;
   - 唯一交叉口在 `App/GlanceApp.swift` 做双向互斥(打开一方时自动收起或静默另一方)。

## 常驻模式评估结论(2026-11-25)

V1 只做自动隐藏。「常驻占屏(永不隐藏)」三案评估后裁定:

- **方案 C(强制占屏留白)——平台不可行**:macOS 没有公开接口让第三方 App 为自己预留一段屏幕工作区。`NSScreen.visibleFrame` 是**只读**的系统派生值,原生 Dock 的预留由 WindowServer 内部完成;让其它 App 的窗口绕开我们的条带只能改窗口几何或走私有 API —— 后者违反 ADR-0002(私有 API **圈禁一处 + 失效降级**)的判据:这里没有等价降级路径,失败面是用户窗口被条带永久遮挡。⇒ 不实现。
- **方案 B(智能避让:条带随前台窗口位置挪到不遮挡的一侧)——不做**:不能保证不遮挡(全屏窗口没有避让空间),且需要持续跟踪前台窗几何 = 常态化 AX 轮询成本,收益不明。
- **若 V2 做常驻,只走方案 A(悬浮常驻 + 全屏避让)**:条带常驻悬浮、不做工作区预留;本屏有窗口进入全屏(或前台处于全屏 Space)时自动隐藏,退出全屏再出现。前置改造两项:
  1. **拆分 `isVisible` 语义** —— 现在它同时表示「面板在场」与「会话进行中」(入场/退场动画、托盘、hover 轮询、缓存续鲜都挂在它上面);常驻需要把「常驻可见但无会话」与「会话活跃」拆成两个状态,否则常驻即等于常开会话。
  2. **近场门控轮询** —— 60Hz hover 轮询与 60Hz click gate 目前只在会话期运行;常驻后必须改成指针进入条带近场才启动,离开即停,不得常驻长跑定时器。

## V1 视觉与性能定稿(2026-11-25 ~ 2026-11-28 落地)

- **自动隐藏 / 常驻悬浮双模式**:除自动隐藏(边缘贴边唤起)外，已按「方案 A(悬浮常驻 + 全屏避让)」落地常驻模式(`DockDisplayMode.alwaysOn` + `DockFullscreenProbe` + `DockWindowReserveGuard`)，支持按屏幕位置(下 / 左 / 右)独立配置，且保持与 `Panel` 模块硬隔离。
- **统一液态玻璃 `RingGlassSurface`**:条带与 ⌘Tab 主环、舌头滑块共用 `Design/PanelGlass.swift` 的同一实现 —— macOS 26+ 原生 `.glassEffect(.clear, in:)`;macOS 14–25 回退 `NSVisualEffectView` + 同源稳态层 + 光学补偿层。程序坞不再有独立玻璃配方,浅/深模式走同一套 `PanelColors.dynamic(...)` ⇒ 两处像素级对齐。预览托盘沿用 2026-09-21 裁定:无外层玻璃背板,只留卡片阴影与芯片胶囊。
- **侧边通知式不透明阶梯叠卡**:`left` / `right` + 芯片轨道多窗时,托盘 = 上「选中窗预览卡」+ 下「一列真芯片叠卡」;收起态露 2 层底边，采用不透明阶梯灰阶 + 阶梯发丝边 + 层间接触阴影(`PanelColors.chipStackBg/Border/Shadow`)消除深/浅模式透穿，悬停按参数 `fan: 0 → 1` 逐枚错峰弹簧滑出，芯片宽在组内恒定、切窗不跳位。
- **点击落焦极速交接**:条带悬停采用 120ms 驻留去抖后再起 `SCStream` 与抓图（0ms 先垫缓存帧与预热 `AXUIElement`）；点击确认时立即摘屏 `trayPanel`/`stripPanel`、延后 250ms 拆系统级 `SCStream` 并延迟 450ms 续鲜后台枚举；单可见窗 App 走纯 `(wid: 0, mode: 0x100)` SLPS 前置路径，实测 Dock 落焦 AX 中位数由 79ms 降至 36ms、消除 500ms 级主线程卡顿。

## 后果

- 现有 ⌘Tab / 三指 / `⌘\`` 代码路径回归面收敛到 `GlanceApp` 互斥与 `WindowEnumerator` 带默认值参数;
- 程序坞模块可在 `Sources/Glance/Dock/` 内持续独立演进,不触碰切换器核心。
