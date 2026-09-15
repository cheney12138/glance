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

## 二·续、本轮增量(T23–T31,**未提交**)

| T | 一句话 | 落点 | 证据 |
|---|---|---|---|
| T23 | 托盘版式三改:去掉题头行 → 芯片移出卡片成为独立胶囊 → 选中芯片前加**圆点**(系统强调色,未选中留淡灰占位防文字跳动)→ 留白**调换**(上 20 / 下 12,原来上 12 / 下 18) | `Panel/{PreviewPanelView,PanelController}.swift`、`Design/PanelTokens.swift` | 用户实机三张自截定稿;留白依据用户实评"重心在顶部,留白跑到下面了" |
| T24 | ` 循环窗口(开关,默认关):**不碰系统热键**,靠会话期吞键(DockDoor 同法) | `Trigger/HotkeyTap.swift`、`Settings/SettingsView.swift` | DockDoor 源码实证(`KeybindHelper.swift`:`options: .defaultTap` + `return nil` + `guard isKeybindSessionActive`);用户"功能没问题" |
| T25 | 缩略图管线:保温器(激活/换屏事件,无定时器)+ **AX 幽灵窗过滤** + macOS 26 `captureScreenshot` + 单次超时/重试/跨会话缓存 | `Inventory/{ThumbnailRefresher,AXWindowList,Snapshotter,WindowEnumerator}.swift`、`docs/architecture.md` §7 | 实测 SCShareableContent 28ms / 每窗 26–52ms / 10 窗串行 346ms;幽灵窗探针零误伤(用户"ok,剔除了") |
| T26 | 事件日志加**毫秒时间戳**,hover 拆成"到达 / 接受"两行 —— 让"有多慢"变成数字,不再靠感觉争论 | `Diagnostics/Stdout.swift`、`Trigger/HotkeyTap.swift`、`Panel/PanelController.swift`、`Focus/WindowFocuser.swift` | 用户日志实据:每对 `hover 到窗`→`窗口选中` 相差 **0ms**,而 App 层选中到第一次卡片 hover 空着 **652ms** |
| T27 | 指针重定位:视图在指针底下**自己挪位**时 SwiftUI 不补发 hover(托盘换组换宽度,1 扇 288pt / 2 扇 540pt → 卡片平移 ~126pt)→ 尺寸变了就按指针位置重判卡片 | `Panel/PanelController.swift`(`resyncSelectionUnderPointer`) | 同 T26 的日志;修后应出现 `[T6] 视图挪位后指针重定位(卡片)` |
| T28 | 颜色外观:浅色 / 深色 / **自动(默认)**。一处 `NSApp.appearance` 管全套(面板取色全走按外观解析的动态色),设置窗一起换 | `Design/AppearancePreference.swift`、`Settings/{SettingsView,SettingsControls}.swift`(新 `BeamSegmented`)、`App/mac_switcherApp.swift` | 架构 ✅ / 构建 ✅;分段控件视觉复用 `SettingsTabRail` 的凹槽 + 会滑的实心舌 |
| T29 | 借鉴 AltTab 三件:**全局 AX 消息超时 0.5s**(AltTab:全局 1s / app 元素 0.25s)、**F 全屏 / H 隐藏 App**(AltTab 默认键)、**标题中段截断**(AltTab `titleTruncation`) | `Inventory/AXWindowList.swift`、`App/mac_switcherApp.swift`、`Trigger/HotkeyTap.swift`、`Panel/PanelController.swift`、`Focus/WindowFocuser.swift`、`Packages/GlanceCore/WindowTitle.swift`、`Tools/HoldChord.swift` | `swift test` 22 passed(含中段截断 5 例);`AXUIElementSetMessagingTimeout(systemWide, 0.5)` 实测 err=0;构建 ✅ / 架构 ✅;H 的两幕病例见下 |
| T30 | **一局之内顺序冻结**(`mergeRefreshed`):中途动作只改"窗"不改"位",MRU 只在**开局**排一次 | `Panel/PanelController.swift` | 由 T29 第二幕逼出来;核实行现在把顺序也打进日志,便于验证 |
| T31 | 入场动效**同步**:升起偏移的作用范围 = **托底 + 选中的那一格图标**(同一次 `withAnimation`、同一根弹簧 `PanelMotion.entrance`),其余图标一律不动 | `Panel/{PanelView,PanelController}.swift`、`Design/PanelMotion.swift` | 用户实评两轮:①「托底块还没滑上去,App 图标已经上去了……期望跟正常 Tab 切换一样,动效是同步的」→ 我第一版做成**整行**一起升 ✗ 被否(「你改成全部图标一起弹出来了」);② 正确范围就是"正常 Tab 切换"的范围 —— 动的永远只有托底与新选中的那个图标。命名同步对齐(设置 key 不动,偏好不丢) | · **第四轮(2026-09-15)**:「入场上浮」关闭时若托底**本来就停在同一格**(唤起即切换开着时每次都落第二格),就没得滑、又不上浮 = 面板像贴上去的 → 改成**滑与升互斥**:会滑就滑(承接上一格),不会滑就退回上浮(`lastLandedIndex` 判断,开局打 `[T6] 入场:…` 一行) · 速度同轮调整:`PanelMotion.entrance` response **0.28 → 0.20**(实评"这个上浮有点慢了") · **第五轮(同日,结构重做)**:用户口径「上浮是通用的,从 c 滑动到 a 这个是额外的动效」——把二选一改成**两层**:① 上浮(通用、永远在、无开关)② 从上一个 App 滑过来(额外、可关、默认关)。代码随之变成 `contentEntryRise` 永远摆起点 + `selectionArmed` 只由要不要滑决定;**key 换新**(`panel.slideFromLastApp`;旧 `panel.puckRiseFromBottom` 语义已反转,特意不迁移);设置行改为「从上一个 App 滑过来」(默认关,不写说明)

> T23–T31 都发生在同一个工作区(圆点 → 留白 → ` 开关 → 时间戳 → 重定位 → 外观 → AltTab 三件,
> 层层压在同一批文件上),按文件切出来的中间提交不可构建 —— 与 T18–T22 同一种情况:
> 合成一笔提交,分任务账记在这里。

### T29 病例(H 隐藏的两幕,同日)

**第一幕**:隐藏之后 App 还挂在 Switcher 栏上,松开 ⌥ 又把刚隐藏的 App 唤起来了。
根因不在 H 的语义,而在**时间**:`hide()` / 关闭 / 最小化都是**异步**的(隐藏与最小化有
0.2–0.3s 动画,App 忙时更久),而 `refreshAfterAction()` 只等 0.18s 重枚举 —— 那一刻系统里
那扇窗**还看得见**:分组没变、选中还停在它上面,松开 ⌥ 走 SLPS 前置 → 被隐藏的 App 又回来了。
修法:`PanelController.optimisticRemoval`(动作一发先按已知结果改本地列表,0.18s 后再核对)。
Q/W/M 保留这条;**zoom/fullscreen 不摘**(全屏是进出 Space,猜错方向会把窗摘没)。教训见
`docs/debugging.md` §4.2。

**第二幕**:改完用户再报「先是消失了,然后又出现了……整条应用栏的排序乱跳」,
期望「位置不变,只是窗口消失了」。两个叠加的错误:
① 第一幕的修法对 H 是"摘**整组**" → App 数变 → 图标数变 → 整条栏重排;0.18s 后核对把组带回来
→ 再排一次;隐藏动画放完 → 第三次;
② 核对时**又按 MRU 排了一遍**(动作之后 MRU 必变:刚碰过的 App 排最前)→ 每次动作都重排一次。

正确模型本来就在代码里:`WindowEnumerator` 的 **T15 无窗 App** —— 隐藏完的 App 会作为
"无窗 App"继续列着(macOS 原生也是如此:隐藏的 App 仍在 ⌘Tab 里,只是没有可预览的窗)。
所以 H 的正确做法是**留在原位、只把它的窗清空**(`hiddenPIDs` 压住系统还没隐完的那 0.2–0.3s);
顺带把这一条推广成 T30 的**顺序冻结**。第一幕的 `optimisticRemoval` 因此收窄为只服务 Q/W/M。

## 二·续二、本轮增量(T32–T33,**未提交**)

| T | 一句话 | 落点 | 证据 |
|---|---|---|---|
| T32 | 截图会话里的**回车让权**:取景框在屏幕上时,回车的**第一所有权**归截图工具 —— 面板只关、不聚焦,而且**不吞这一颗**(截图工具的"完成/复制"照旧);整套导航键(←→ / Esc / QWM)在截图会话里一并**放行**(此刻方向键是"微调选区",不是"换一扇窗") | `Packages/GlanceCore/CaptureSession.swift`(纯核裁决)、`Trigger/{CaptureSessionProbe,HotkeyTap}.swift`、`Panel/PanelController.swift`(新 Action `yieldToCapture`) | `swift test` **32 passed**(新增 10 例:三类证据各自让权 / 正常 App 与 IM 聊天**不许**误判 / 确定性);`check-architecture` ✅;构建 ✅。**真机验证待用户复现**(口径见 `docs/debugging.md` §9) | · **2026-09-15 病例(用户实报"`` ` `` 的功能失效了")**:通用判据"屏上有铺满屏的高层窗"在装了 **DLP 3.0** 的机器上**恒真**(`cn.cirrusgate.dlp.CGEData` 常驻两块 layer=2147483628、100% 铺满屏的窗)→ 裁决永久成立 → **所有导航键**(Tab/←→/Esc/Q/W/M/F/H/`)在会话期整套被放行。修法:判据**归因**(系统 UI / 已知截图 App / **前台 App 自己**的窗三种之一,否则不认)+ 证据改**复数**(那块常驻窗一直在,真截图时至少两块,取第一块会漏掉真取景框)。纯核用例补到 35 passed,含真机坐标回归;`CaptureSessionProbe` 改为**裁决变化时打一行**,下次这类永久误报一眼现形
| T33 | 窗口名**芯片去光饰**(v3):删掉"上缘高光唇 + 亮描边"这一对 Aqua 签名,底从 `slate(18) α .46` 收到 `slate(22) α .40` —— 它不再是"贴在玻璃上的牌子",而是"玻璃上的第二层雾" | `Design/PanelTokens.swift`、`Panel/PreviewPanelView.swift` | 用户实评"说白了,像是零几年的 macOS 系统那种玻璃质感太过时了";量出来的依据:旧版芯片底**恒为 L≈45**(`slate(44)` 实色)而四周玻璃在 L53…218 之间摆 → 新值浅底 L≈118 / 深底 L≈41。浅色 token 一格未动 |
| T34 | **唤起落点的环序**:「唤起即切换」开着时,列表**左旋一格**(当前 App 从队首沉到队尾),不是 `swapAt(0,1)` | `Packages/GlanceCore/LandingRule.swift`(纯核 + 6 例)、`Panel/PanelController.swift` | 用户实评"这个开关没生效,我还是能选中第一个"。对账:开关**确实**生效了,是**环走错了** —— 交换只动两格,把当前 App 留在第二格,于是按一下 Tab 就绕回自己(实机日志:唤起后第一发 Tab 落在 `[2/6]`,那一格正是当前 App)。左旋后:落点仍是队首(观感不变),正向下一站 = 更早的 App、绕完一圈才回到当前 App,反向 ⇧Tab 往回一格 = 当前 App —— 两个方向都与原生同序。`swift test` **38 passed**;顺带永久打了 `[T6] 落点:…` 一行(开关 × 正反向 × 顺序),以后不再靠猜 | · **2026-09-15 三修**:v2 的左旋把「第一眼版式」改错了(实评:「现在没有直接选中第二个 app,不符合预期」)→ 回到 MRU 原序 + 高亮落**第二格**,两个面同时成立(纯核 `LandingRule` 重写为 7 用例,含「交换」「左旋」两条反例护城河;判读口径见 `docs/debugging.md` §10)
| T35 | **光效总闸** `panel.sheen`(默认开):① 跟随指针的柔光 ② App 图标的静态反光(选中提亮 / 未选中压暗)—— **一起开一起关**。关掉时那层视图连同 TimelineView 一起不存在(零开销),图标回到本来的样子;选中态仍由放大 + 上浮 + 托底交代 | `Panel/PanelView.swift`(SheenOverlay 门 + IconCell 的 saturation/brightness)、`Settings/SettingsView.swift` | 用户口径两轮:「把高光晕染改成配置的吧,有人不一定喜欢这个光效」→「你只关了指针移动在背景上的反光,app 上的静态反光也要一起开关」;架构 ✅ / 构建 ✅ |
| T36 | **托盘窗口按整局最大布局开一次**:换选中只换内容不换窗框,消掉每次 Tab 的 14–26ms 同步窗口布局 | `Panel/PanelController.swift`(`trayMaxContentSize` / `previewContentSize` / `previewContentRect`)、`Panel/PreviewPanelView.swift`(底部对齐) | 实测量到 `[工] 托盘改尺寸 23.3ms` ↔ 外层 `键盘换选中 26.3ms`(89%);`[帧]` 证据:入场 0.2s 内 0 长帧,唯一长帧 @1.37s = 按 Tab 那一下 | · **同轮补两件**:① `precapture(_:force:)` —— 正在显示的那一组强制重拍(换主题这类**应用内部**画面变化系统不发任何事件,事件驱动刷新抓不到,只能靠「显示即重拍」);② 沉淀 `docs/adr/0006-window-size-is-a-session-invariant.md` + `docs/debugging.md` §11(括号归因法、窗口大于内容时的检查清单)
| T37 | **克制上浮幅度**(`iconLift` 14 → 8 基准):修"选中图标贴边"用的是砍幅度,不是加边距 | `Design/PanelTokens.swift` | 第一版给长条加上边距(+24pt)被否——"加上边距也太丑了,你要考虑没选中的时候啊";净边距 2.2 → **9.4pt**,视觉上移 24.2 → 17pt;弹簧(`PanelMotion.select`)与放大倍率(1.14)一格未动 |

### T32 病例(一次回车被两个主人收下,2026-09-14)

用户实报:「在截图的情况下,我按回车会同时触发截图的复制和选中的逻辑。但我期望的是,
如果是截图,按回车之后不要触发打开某一个 APP,glance 面板应该直接关闭。」

**病根不在我们的确认逻辑,而在"tap 的先后"这件偶然事实**:截图工具的取景框自己也在收回车
(`Return` = 完成/复制),而 navTap 是**后装**的 tap(headInsert 决定它是后到的那一环)——
同一颗回车两个主人各收一次。用户的观感就是"截图拷走了,App 也被拉起来了"。

**这一条为什么值得进核**:判断"这一颗归谁"本该靠**语境**,不靠谁的 tap 更靠前。
"屏幕上正等着完成"这一刻是可判的,而且判据能全部折算成布尔:
系统截图 UI 在跑 / 前台就是截图 App / **屏幕被一块铺满的高层窗盖着**(取景框的通用特征)。
最后一条是关键 —— 它让规则不依赖"用户装的是哪个工具"(QQ / 微信的截图模式与聊天模式同 bundle,
只能靠"取景框铺满屏"区分,而这一条是准的)。

**故意之恶(写在明处)**:名字含 `shot / snip / snap / grab / 截图` 的 App 一律让权 ⇒
视频剪辑器取名 Shotcut 之类会被误让(用例 `testNameKeywordOverreachIsKnownAndAccepted` 钉着)。
代价只在**钉住模式**下显形(回车只关面板、再按一次 ⌥Tab 就回来),换来的是"没听说过的截图工具也接得住"
——收窄的正确做法是加白名单(`defaults write com.cheney12138.macswitcher switch.captureApps -array …`),
不是把关键词删掉。

## 三、下一批(候选,按收益排序)


| 候选 | 为什么 | 参考 |
|---|---|---|
| 🚧 **输入状态机进核**(`GlanceCore.HotkeyStateMachine`:`(state, event, config, pinPanel) → (state, actions, swallow)`) | 本轮连修三个输入 bug(漏一颗 ⌘↓ 就整局失守 / 超时那颗粒放行 / Carbon 不重复投递导致 Tab 不动),全靠真机连按才发现。抽成纯函数后**全都能写成测试** | `docs/architecture.md` §6.1 |
| 🚧 **窗口归属几何进核**(`ownsByContextScreen` + `quartzFrame`) | 双屏/跨屏是最容易错的地方(T4 就翻过车),现在跟 AX/CGS 调用缠在一起,没法单独验 | §6.2 |
| 🚧 **MRU 排序进核**(`MruEvidence.ordered`) | 输入是 pid 序列、输出是顺序,天然纯函数 | §6.3 |
| 🎛️ **触摸板手势唤起**(T38 候选,2026-09-15 记) | 用户问"能不能识别触摸板手势、加一个唤起方式"。**能**:AltTab 有一等公民实现(`nextWindowGesture`:三/四指 × 横/竖滑,默认关),它同时是"唤起 + 前/后切一个 App"的路径。要照它的分层做:① 纯核 `GestureKernel`(触摸帧 → 方向 + 是否吸收,可单测);② **只读监听 tap**(常开)+ **吸收 tap**(仅会话期开)—— 绝不能挂进现有 navTap:活动 tap 会 gate 整条输入流,手指在板上期间光标发涩(AltTab #5911);③ 会话层加 `beginGesture(direction:)` + **停手 0.4s 自动确认**(手势没有"松手"事件,这是 ADR-0004 的正当例外);④ 设置默认**关**(抢系统手势)。坑:系统 Mission Control / App Exposé 也吃三/四指(AltTab 的 TODO:某些设置下底层内容仍会跟着滚),惯性事件(`momentumPhase`)必须滤 | AltTab `src/events/{TrackpadEvents,GestureTriggerKernel}.swift` | 最小可用版:只做**三指横滑** = 唤起并前/后切一个 App |
| 👀 **面板内搜索**(打字过滤 App) | **2026-09-14 用户判"先不做"**:不是刚需("不然我为什么不直接用 Raycast")。交互方案已想清,要做直接照做:面板起来**直接打字**即搜(吞键范围扩到 ASCII 可打印字符)、查询显示在图标行上方、只匹配 App 名子串、Esc 先清空再关闭、**不接 IME**(AltTab #5766 的输入法血案) | 本文 §五 |
| 👀 应用例外名单(黑名单/白名单) | 成本最低、人人会要的一件(借鉴清单第 1 条) | 本文 §五 |
| 👀 窗口排序可选(MRU / 标题 / 屏幕位置) | 纯函数进核 + 单测的正面案例 | 本文 §五 |
| 👀 多屏/全空间窗开关 | 会动到"本屏窗"这条冻结定义,要先拍板 | `CONTEXT.md` |
| 👀 应用黑名单 / Dock 悬停预览(DockDoor 看家功能) | 被咬 ≥2 次再立项(README 观望项);Dock 悬停预览要走监听 Dock 那一套,成本高 | README |
| ✅ 同 App 窗互跳 | 已做(T24):` 循环窗口开关。**不关系统热键**,靠会话期吞键 —— 与原生 `⌘\`` 只差"面板开着的那一瞬间"由谁接管 | 本文 T24 |
| ❌ 日历小组件 / Aero Shake / 自动滚动 / 钉控制条 | DockDoor 有,但那是"桌面工具";我们是"⌘Tab 切换器",定位不符 | 本文 §五 |

## 五、参考项目的可抄清单(2026-09-14 侦察)

源码都在本地:`~/alt-tab-macos`(设置页 = Appearance/Controls/Exceptions/General)、`~/DockDoor`(设置项 60+ 条)。
按"能不能拿到 Glance"筛过一遍,结论如下(细节与理由见 `docs/architecture.md` §7 与上面第三节):

| 值得拿 | 出处 | 备注 |
|---|---|---|
| 缩略图**事件驱动刷新** | AltTab `WindowCaptureEvents` | ✅ 已落地(`Inventory/ThumbnailRefresher.swift`,只用公开通知,无定时器) |
| 例外名单 | AltTab `Exceptions` / DockDoor `Blacklist` | 待做,成本最低 |
| 面板内搜索 | AltTab `Search` / DockDoor `searchFuzziness` | 用户判"先不做",方案已留档 |
| 窗口排序可选 | AltTab `Order windows by` | 顺手能做,纯核 |
| macOS 26 抓图 API 与并发闸 | AltTab `WindowCaptureEvents` 注释 | ✅ 已落地(见 §7) |
| **不拿**:Dock 悬停预览 / 日历 / Aero Shake / 自动滚动 / 钉控制条 / 接管 ⌘\` | DockDoor / AltTab | 定位不符或已被判过 |

## 四、纪律

1. **领新任务先在这里占一行**(编号顺延、不复用),完成时补 commit 与"证据"栏。
2. **证据只有三种**:代码注释里的病例(哪台机器、什么现象、量到的数字)、`docs/debugging.md` 的实测口径、
   或 `swift test` 的用例。**对话里的结论不算证据** —— 这条是本文件存在的理由。
3. 行为改动(输入管线、视觉)必须真机实测,"编译通过"不算(`docs/debugging.md` 第 7 节)。
