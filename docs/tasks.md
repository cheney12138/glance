# 任务索引(T 号)

> **为什么有这份文件**:T 号一直只活在**代码注释**(`// T6 起由面板控制器赋值`)、`README.md` 的二期清单、
> 和 commit message 里 —— 没有总表,拼不出来。这份文件是唯一索引。
>
> **约定**:一个 T = 一次**可验收的**行为改动或决策;编号一旦分配不再改;跨多轮的拆 `Tn.m`(如 T7.5)。
> 状态四态:`✅ 已落地` / `🚧 进行中(未提交)` / `👀 观望` / `❌ 撤回`。

## 一、已完成(T1–T17,有 commit 可追)

| T | 一句话 | 主要落点 | commit |
|---|---|---|---|
| T1 | 空壳:菜单栏 + 退出,⌘R 可跑 | `App/mac_switcherApp.swift` | ca87f10 |
| T2 | 权限引导:双门禁 + 自家窗口锚定光标屏 | `Permissions/`,`Panel/CursorScreenAnchor.swift` | 05a491c |
| T3 | 触发层:⌥Tab 状态机 + README 签名先决 | `Trigger/HotkeyTap.swift`,README | 3d7c5c7 |
| T4 | 语境 + 库存:双屏过滤 + 修 AppKit/Quartz 坐标系 | `Inventory/WindowEnumerator.swift` | 258802e |
| T5 | 预截 `Snapshotter` + cache 清场修复 | `Inventory/Snapshotter.swift` | 4b42024 |
| T6 | 面板 UI:图纸变实物 + 三处实机校准 | `Panel/` | 2809230 |
| T7 | 聚焦行为核:级联拉起死刑复核通过 | `Focus/WindowFocuser.swift` | 9052f24 |
| T7.5 | ⌘+click 补焦(二期功能因实机被咬提前) | `Focus/CmdClickFix.swift` | 3c14e51 |
| T8 | 联调 + 钉住模式三修复 + 权责冻结 | `Panel/PanelController.swift`,`design/brand-spec.md` | d7a8e43 |
| T9 | 设置面板:三节 + 录制式改键 + 开机启动(MVP 封板) | `Settings/` | c7a141d |
| T10 | 钉住毕业 + T13 ⌘Tab 篡位 | `Trigger/HotkeyTap.swift`,`Settings/SettingsView.swift` | 90f5eff |
| T11 | 选中项现拍:停留即重截当前组 | `Inventory/Snapshotter.swift` | f74ee55 |
| T12 | 面板内 Q/W/M + 指针仲裁修订 + 现拍卫生三连 | `Panel/`,`CONTEXT.md` | 906656d |
| T13 | ⌘Tab 篡位(见 T21:机制已换) | `Trigger/`,设置页开关 | 90f5eff → T21 |
| T14 | 面板 v1 样式(外部设计稿落地)+ 红绿灯功能化 + 处决即散场 | `Panel/`,`design/v4/` | 715d0a2 |
| T15 | 无窗应用 + 出发点修订 + v0.2 样式 + Glance 命名 | `Inventory/WindowEnumerator.swift` | 3671737 |
| T16 | 落点跟随(轮询 250→60ms)—— **做后撤回** | `Focus/WindowFocuser.swift` | 3671737 |
| T17 | 落点跟随(AX 诞生监听)—— **做后撤回** | `Focus/WindowFocuser.swift` | 3671737 |

无编号的两个提交(留档):`b671b6f` 设计图纸归档清理、`46d7b76` 面板 v1.10 动效三修。

## 二、本轮(T18–T22)

| T | 一句话 | 落点 | 证据 |
|---|---|---|---|
| T18 | 设置窗重构:纸面 + 棱镜边 + 玻璃舌头(照 demo) | `Settings/{SettingsView,SettingsControls,SettingsTheme}.swift`、`design/v4/Glance 设置 v1.html`、`design/settings-spec.md` | 真窗口自截(棱镜边 39pt、无蓝框、无白边);实机自截流程写进 `docs/debugging.md` §3.3 |
| T19 | 输入管线:⌘Tab 入场动效下线、枚举搬后台、退场拆迁单带世代号 | `Panel/{PanelView,PreviewPanelView,PanelController}.swift`、`Inventory/WindowEnumerator.swift` | `design-system.md` Changelog v1.12(主线程占用 110ms → 12ms) |
| T20 | 调试工具沉淀:注入器 / 按住器 / 窗口截图 / 原生热键开关 + 手册 | `Tools/{InjectChord,HoldChord,CaptureWindow,NativeHotkeys}.swift`、`docs/debugging.md` | 工具自身实测:A/B 验证 `程序坞` 出现与不出现 |
| T21 | ⌘Tab 接管改走系统 symbolic hotkey(私有 SkyLight API;**默认关闭、显式开关**) | `Trigger/{HotkeyTap,NativeHotkeyGuards}.swift`、`GlanceCore/NativeHotkeys.swift`、`docs/adr/0005` | 四步实机验收(接管 / 强杀后 ⌘Tab 确实死 / 启动自愈 / 归还原生)+ 单测 |
| T22 | 架构:模块化 + 纯核 `GlanceCore`(本地包)+ 可执行约定 | `Sources/mac-switcher/{App,Design,Diagnostics}/*`、`Packages/GlanceCore`、`Tools/check-architecture.swift`、`docs/architecture.md` | `check-architecture` ✅ / `swift test` 14 passed / 构建 ✅ / 真机 ⌥Tab 与 ⌘Tab 双路 |

> 本轮五件事**互相咬在同一个工作区**(pbxproj 被三段各自改过;`mac_switcherApp`、`HotkeyTap`、
> `design-system.md` 同属多个任务),按文件切出来的中间提交不可构建 —— 所以合成一笔提交,
> 分任务账记在本文件里。要重放成五段可以再说,先把账记清楚。

## 三、下一批(候选,按收益排序)

| 候选 | 为什么 | 参考 |
|---|---|---|
| 🚧 **输入状态机进核**(`GlanceCore.HotkeyStateMachine`:`(state, event, config, pinPanel) → (state, actions, swallow)`) | 本轮连修三个输入 bug(漏一颗 ⌘↓ 就整局失守 / 超时那颗粒放行 / Carbon 不重复投递导致 Tab 不动),全靠真机连按才发现。抽成纯函数后**全都能写成测试** | `docs/architecture.md` §6.1 |
| 🚧 **窗口归属几何进核**(`ownsByContextScreen` + `quartzFrame`) | 双屏/跨屏是最容易错的地方(T4 就翻过车),现在跟 AX/CGS 调用缠在一起,没法单独验 | §6.2 |
| 🚧 **MRU 排序进核**(`MruEvidence.ordered`) | 输入是 pid 序列、输出是顺序,天然纯函数 | §6.3 |
| 👀 应用黑名单 / Dock 悬停预览 | 被咬 ≥2 次再立项(README 观望项) | README |
| 👀 退场淡出(380ms)若仍嫌重 | 一个常量 `PanelMetrics.tFade`;入场已下线(T19) | `Design/PanelMotion.swift` |
| ❌ 同 App 窗互跳 | 原生 `⌘\`` 已覆盖,不重复造 | README |

## 四、纪律

1. **领新任务先在这里占一行**(编号顺延、不复用),完成时补 commit 与"证据"栏。
2. **证据只有三种**:代码注释里的病例(哪台机器、什么现象、量到的数字)、`docs/debugging.md` 的实测口径、
   或 `swift test` 的用例。**对话里的结论不算证据** —— 这条是本文件存在的理由。
3. 行为改动(输入管线、视觉)必须真机实测,"编译通过"不算(`docs/debugging.md` 第 7 节)。
