# Changelog

本文件记录 Glance 的版本演进与未发版开发分支改动（格式参考 Keep a Changelog，每条重要缺陷修复都会同时在代码注释、[调试病例库](docs/debugging.md) 与 [开发手册](docs/开发手册-面板与窗口生命期.md) 留下判读口径）。

## [v1.2.0] - 2026-11-22

### Added
- **数字键直达 App / 窗口**：导航态按 `1–9` 直达环上第 N 个 App（未启动环内直达未启动 App），`⇧+数字` 选当前 App 第 N 扇窗，并在设置「快捷键」页支持开关。
- **快速上手引导与快捷键速查窗**：新增 3 步交互配置引导页（[OnboardingView.swift](file:///Users/qianyuchen/work/glance/Sources/Glance/Settings/OnboardingView.swift)）与快捷键速查页（[ShortcutCheatSheetView.swift](file:///Users/qianyuchen/work/glance/Sources/Glance/Settings/ShortcutCheatSheetView.swift)，面板内按 `?` 或 `/` 呼出）。
- **脱敏诊断转储与环形缓冲**：新增 [DiagnosticReport.swift](file:///Users/qianyuchen/work/glance/Packages/GlanceCore/Sources/GlanceCore/DiagnosticReport.swift)、[DiagnosticCollector.swift](file:///Users/qianyuchen/work/glance/Sources/Glance/App/DiagnosticCollector.swift) 与 [DiagnosticRingBuffer.swift](file:///Users/qianyuchen/work/glance/Sources/Glance/Diagnostics/DiagnosticRingBuffer.swift)，支持一键复制 JSON 或导出环境、帧账、卡死与脱敏崩溃栈摘要。
- **设置面板互动玩具与趣味细节**：新增 [SettingsToys.swift](file:///Users/qianyuchen/work/glance/Sources/Glance/Settings/SettingsToys.swift)（外观条形预览、芯片轨道/多卡布局示意、3D 键帽组合、Koala 头像微交互与时辰问候彩蛋），分组标题图标与光束标记、行悬浮高亮及触感实时试震反馈。

### Changed
- **超快切静默延迟上屏（默认 130ms）**：新增 `debug.summonRevealDelayMs`（默认 `130`，可设为 `0` 关闭）；短于阈值松手直接静默切换聚焦、零窗体创建与上屏，等待期内连按二次导航键立即取消定时器并显影。
- **最小化窗口卡片纯展示 App Logo 占位，不启动实时流**：最小化窗口在 `PreviewPanelView`、`PanelTrayWindow` 与 `Snapshotter` 中均跳过 live 流与缓存画面预填，避免无效功耗与旧帧误现。
- **跨屏送窗与单窗取消最小化加固**：`WindowFocuser.move` 改为分步读回验证与渐进平滑定位；`unminimize` 仅恢复目标单窗。

### Fixed
- **彻底修复快速切换 / 截图退出后切换 / 从引导页或设置窗 `⌘Tab` 切走后的坦克形残帧与面板卡死**（[病例 #21](docs/debugging.md#21-坦克形残帧与面板卡死收场后异步回拉--切焦未-flush2026-11-22)）：
  - `ClickThroughHostingView` 禁用 `sizingOptions` 自适应回推尺寸，修正 `PreviewPanelView` 顶部阴影边距（`padTop = 0`）与 `contentMinSize = .zero`，消除托盘窗首帧 `317 → 412pt` 拉伸透穿。
  - 每局退场改为 `alpha = 0 → orderOut → close()` 销毁旧窗并异步预建下一局全新离屏 `NSPanel`，`scheduleAfterDisplayCommit` 等 CA 渲染提交完成后再入场显影，彻底断绝跨局复用 `CGWindowID` 残留旧帧。
  - 加固 `begin` / `showPanel` / `fadeInWindow` / `updatePreview` 代际锁与 `teardownPanel` 同步 `CATransaction.flush()`。
- **修复设置面板操作时被三指自愈误杀重启的问题**：`ThreeFingerTap.reviveIfFramesDead()` 改为必须“静默之后确实执行过投递死亡重挂（`reviveAttachAt > frameAt`）且 `>= 3s` 仍零新帧”才判死，且前台激活/任意可见窗口打开期间及冷启动 `60s` 内绝不自动重启；同步消除 `ContentBottomKey` 同帧多次回写及 `didResize` `-layoutSubtreeIfNeeded` 告警。
- **修复设置 / 引导 / 快捷键速查 / 权限窗口打开时先偏右再往左跳回屏幕中心的问题**：开窗前预居中、首帧在 `alpha = 0` 下完成 `.contentSize` 定框后显影，并在 `SettingsWindowChrome` 监听 `didResize` 保持相对整块屏幕居中。
- **修复单个 App 全部窗口最小化后的位置跳跃与图标消失**：最后一个可见窗口被最小化时保持原位、仅切换为最小化样式，其余最小化窗口移至尾部并保持相对顺序。
- **三指轻点重量门与多指账本隔离**：`TapRound` 最低接触门限由 `0.6` 调优至 `0.45`，按硬件 `MTDeviceGetDeviceID` 独立分账，避免多块触控板/掌缘相互污染。

---

## [v1.1.1] - 2026-11-10

### Fixed / Added
- 权限门禁加固：辅助功能授权被删后安全停用，不再同步卡死。
- 首轮残帧对策（`glassEpoch` 递增与首帧门禁）。
- IDE 窗口标题显示工程名与芯片退场动画。
