# Tools 工具目录说明

`Tools/` 存放 Glance 的架构校验、构建发版、日志启动、玻璃测量与真机冒烟脚本。
> ⚠️ 真机纪律：用户在用机器期间**禁止跑 `run.sh` / `ab.sh` / `Smoke*.swift` / `InjectChord.swift`**，避免顶掉工作进程或注入 HID 事件抢焦点（见 [../AGENTS.md](../AGENTS.md)）。

## 一、门禁与发版

| 脚本 | 用途 |
|---|---|
| `check-architecture.swift` | 校验 `GlanceCore` 纯核边界、模块禁引表与设置键名规范（`swift -module-cache-path /tmp/glance-mc Tools/check-architecture.swift`） |
| `regress.sh` | 三道自动回归门：`GlanceCore` 单测（存在时） + 架构检查 + `xcodebuild` |
| `make-dmg.sh` | Release 构建并生成标准 `Glance-<ver>.dmg` 包 |
| `make-cask.sh` | 生成 Homebrew Cask 更新清单 |
| `release.sh` | 发版主流程（版本号、tag、`gh release` 与 Homebrew Cask 更新） |

## 二、启动与日志 / 界面取证

| 工具 | 用途 |
|---|---|
| `run.sh` | 杀干净旧进程 → 启动 DerivedData 最新 Debug 构建 → 自证二进制 mtime |
| `trace-run.sh` | 带 `GLANCE_TRACE=1` 后台启动，日志固定写入 `~/Library/Logs/Glance/trace.log` |
| `ab.sh` | 快速切换 `debug.*` UserDefaults 开关并调用 `run.sh` 重启做 A/B 对照 |
| `GlassBench.swift` | 玻璃材质测光台：纯色可控背景（`bg`）与 PNG 采样对比（`sample`/`profile`/`compare`） |
| `CaptureWindow.swift` | 按窗口/区域抓图及采样工具（`list`/`shot`） |
| `whiteboard.swift` | 全屏纯净背景板（`.statusBar` 层级，低于 Glance `.popUpMenu` 面板，截图/录屏时遮挡桌面杂物） |

### `whiteboard.swift` 用法与退出

```sh
swiftc -O Tools/whiteboard.swift -o /tmp/whiteboard && /tmp/whiteboard &
```

- **4 重退出出口**：`Esc`（本地+全局双监听，全局路径需输入监听权限）/ 双击任意处 / 600s 自动退出 / `pkill -f whiteboard`。
- **历史病例（2026-11-14）**：v1 用 `.prohibited` 激活策略且未重写 `canBecomeKey = true`，导致无边框窗永远成不了 key、`Esc` 失效；v2 改为 `.accessory` + `KeyWindow(canBecomeKey = true)` + `NSEvent` 双监听。

## 三、输入注入、热键复原与资产脚本

| 工具 | 用途 |
|---|---|
| `InjectChord.swift` | HID 层注入连按热键（如 `⌘Tab`），以 `Esc` 收尾 |
| `HoldChord.swift` | HID 层按住修饰键若干秒（方便观察原生/Glance 面板） |
| `SmokeHover.swift` / `SmokeRingHover.swift` / `SmokeRingCross.swift` / `SmokeTabSwitch.swift` | 真实窗口下鼠标横扫、换环、Tab 切换冒烟测试 |
| `NativeHotkeys.swift` | 手动恢复或禁用系统原生 `⌘Tab` / `⌘⇧Tab` / ``⌘` ``（`restore` / `disable`） |
| `Iconify.swift` | 将设计稿图标按 Apple 图标网格裁切并生成 `AppIcon` 多尺寸资源 |
