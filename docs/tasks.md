# 任务索引(T 号)

> **为什么有这份文件**:T 号一直只活在**代码注释**(`// T6 起由面板控制器赋值`)、`README.md` 的二期清单、
> 和 commit message 里 —— 没有总表,拼不出来。这份文件是唯一索引。
>
> **约定**:一个 T = 一次**可验收的**行为改动或决策;编号一旦分配不再改;跨多轮的拆 `Tn.m`(如 T7.5)。
> 状态四态:`✅ 已落地` / `🚧 进行中(未提交)` / `👀 观望` / `❌ 撤回`。

## 一、已完成(T1–T17,有 commit 可追)

| T | 一句话 | 主要落点 | commit |
|---|---|---|---|
| T1 | 空壳:菜单栏 + 退出,⌘R 可跑 | `App/GlanceApp.swift` | ca87f10 |
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
| T22 | 架构:模块化 + 纯核 `GlanceCore`(本地包)+ 可执行约定 | `Sources/Glance/{App,Design,Diagnostics}/*`、`Packages/GlanceCore`、`Tools/check-architecture.swift`、`docs/architecture.md` | `check-architecture` ✅ / `swift test` 14 passed / 构建 ✅ / 真机 ⌥Tab 与 ⌘Tab 双路 |

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
| T28 | 颜色外观:浅色 / 深色 / **自动(默认)**。一处 `NSApp.appearance` 管全套(面板取色全走按外观解析的动态色),设置窗一起换 | `Design/AppearancePreference.swift`、`Settings/{SettingsView,SettingsControls}.swift`(新 `BeamSegmented`)、`App/GlanceApp.swift` | 架构 ✅ / 构建 ✅;分段控件视觉复用 `SettingsTabRail` 的凹槽 + 会滑的实心舌 |
| T29 | 借鉴 AltTab 三件:**全局 AX 消息超时 0.5s**(AltTab:全局 1s / app 元素 0.25s)、**F 全屏 / H 隐藏 App**(AltTab 默认键)、**标题中段截断**(AltTab `titleTruncation`) | `Inventory/AXWindowList.swift`、`App/GlanceApp.swift`、`Trigger/HotkeyTap.swift`、`Panel/PanelController.swift`、`Focus/WindowFocuser.swift`、`Packages/GlanceCore/WindowTitle.swift`、`Tools/HoldChord.swift` | `swift test` 22 passed(含中段截断 5 例);`AXUIElementSetMessagingTimeout(systemWide, 0.5)` 实测 err=0;构建 ✅ / 架构 ✅;H 的两幕病例见下 |
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
| T38 | **日志收敛:一次唤起 ≤ 2 行**。逐键/逐像素/逐帧/每次鼠标移动的账全部收进 trace;三行开局账合并成 `[唤起] …`;`[尺寸]`/`[动效]`/`[幽灵窗滤除]` 只在**变化时**打;删掉"整局只 setFrame 一次"那条验证账与死代码 `glassConstrainedX` | `Panel/PanelController.swift`、`Panel/PanelView.swift`、`docs/debugging.md` §12 | 用户口径:「清理一下现在无用的日志输出,内容太多了」;规则写进 `docs/debugging.md` §12(按"能回答什么问题"分类) |

| T40 | **App 图标定稿 + 工程改名 `mac-switcher` → `Glance`**。图标只留玻璃方块(外圈泛光 / 底部阴影 / 生成水印全部切在遮罩外),十档进 `AppIcon.appiconset`;工程名、target、scheme、源码目录、源文件与全部路径引用一并改名,**bundle id 故意不动**(`com.cheney12138.macswitcher`——TCC 授权与用户偏好都锚在它上面,改了要重新授权 + 偏好清零) | `Tools/Iconify.swift`(新增,确定性裁切)、`Sources/Glance/Assets.xcassets/AppIcon.appiconset/*`、`Glance.xcodeproj`、`Sources/Glance/`、`README.md` 等路径引用 | 构建 ✅ / `swift test` ✅ / `check-architecture` ✅ / 产物 `Glance.app` 内 `AppIcon.icns` 与 `CFBundleName=Glance` 已核对。裁切的**数字是量出来的**:沿四边取样比背景色,顶边到 **1.75%** 内缩才干净(原 1.6% 时仍有 12% 样本是背景 —— 即肉眼看到的那一点点);取 2.00%(+0.25% 余量),另三边同值。口径与坑写进 `design/icon/README.md` | · 改名踩到的坑:scheme 里 `BuildableName` 替换后**漏了引号** → XML 非法 → scheme 加载失败,xcodebuild 报「Scheme Glance is not currently configured for the build action」(真因是 XML 不是配置);target 名在 pbxproj 里是 `name = "mac-switcher"` **带引号**,第一次替换没命中 → target 与 scheme 指向不一致 |

| T41 | **⌘Tab 死亡的可见化**:接管期间落标记文件,恢复时删除;下次启动若标记还在 → 打一行「上次退出没来得及归还原生热键(强杀)——本次启动已自愈」+ 自愈。拦不住 SIGKILL(Xcode Stop),但能让"⌘Tab 为什么死了"从不可见变成一行日志 | `Packages/GlanceCore/Sources/GlanceCore/NativeHotkeys.swift`(标记的落/读/清 + 目录可注入)、`Sources/Glance/Trigger/HotkeyTap.swift`(启动处消费标记并提示)、`Packages/GlanceCore/Tests/GlanceCoreTests/NativeHotkeysTests.swift`(2 例) | `swift test` **37 XCTest + 7 swift-testing 全过**;构建 ✅;实测 `swift Tools/NativeHotkeys.swift restore` 三个热键全 ok,用户实测确认 ⌘Tab 恢复 | · **2026-09-15 病例**:改工程名期间 Xcode Stop(SIGKILL)把系统 ⌘Tab 留死,用户以为是残留进程(`pgrep` 为空 ✗)。口径与救法写进 `docs/debugging.md` §13 与 ADR-0005 |
| T42 | **点面板周围的空白 = 关面板**:补一个**本地**点击监听(全局监听看不见自己家的事件) | `Packages/GlanceCore/Sources/GlanceCore/OutsideClickRule.swift`(新增,纯核判据 + 6 例)、`Sources/Glance/Panel/PanelController.swift`(双监听共用一条判据 + `panelContentRect()`) | `swift test` **43 XCTest + 7 swift-testing 全过**;构建 ✅;`check-architecture` ✅ | · **2026-09-15 病例(用户实报「点非窗口/预览窗之外的空白区域无法关闭」)**:`ClickThroughHostingView.hitTest` 在透明呼吸区返回 nil —— 只是**不吃点击**,但 AppKit 里这**不会**把事件转给下层 App ✗;面板又是 nonactivating,事件也不进任何 view ✗ → 这一格点击既不属于"别的 App"(全局监听收不到)、也没人处理,直接掉在地上。判据仍是**内容矩形**(ADR-0006 的推论),顺手修掉托盘呼吸区被当成"里"的老账 |
| T43 | **窗数记号改记账法(圆点=1 / 短横=5)+ 自适应收窄兜底** | `Packages/GlanceCore/Sources/GlanceCore/WindowTally.swift`(新增,纯核裁量 + 10 例)、`Sources/Glance/Panel/PanelView.swift`(`windowDots` 换形状)、`Sources/Glance/Design/PanelTokens.swift`(`tally` token)、`design/v4/design-system.md` | `swift test` **53 XCTest + 7 swift-testing 全过**(新增 10 例:记号序列、进位跳变有意保留、现实窗数不收窄、极端窗数不溢出、摘记号先摘尾部);构建 ✅;`check-architecture` ✅ | · **2026-09-15 病例(用户实报「窗口太多的时候怎么优化下面的圆点」)**:逐窗一粒点 13 扇铺满格子、20 扇 164.4pt = 1.56 倍格子(溢出到邻格),且同色点只能默数。方案由用户提出(记账法),我补了数字与兜底口径:到**第 36 扇**才开始收窄 —— 现实中到不了(横 12pt 时 35 扇正好铺满一格),所以收窄只是保险。**我实现时的 bug 被单测当场揭出**:摘记号只摘了圆点(999 扇是 199 个横,光摘 4 个点放不下),改成从尾部摘 |
| T44 | **设置窗排版:组标题升为主标题 + 行字号提半档**。组标题 11pt 灰+圆点 → **13pt 半粗 + 墨色 + 发丝边框胶囊**;行说明 11.5→12、行数值 12.5→13 且等宽数字;组间距 20→26、行内边距 13→12(抵账,净高度持平);**去掉「构建」一行** | `Settings/SettingsTheme.swift`(token)、`Settings/SettingsControls.swift`(`SettingsGroup`/`RowValue`)、`Settings/SettingsView.swift`(版本信息组)、`design/settings-spec.md`、`design/settings-typography-lab.py` + 设置排版实验台(新增) | 构建 ✅;对照图见 `design/设置排版实验台.html`(改前/改后两张纸窗) | · **2026-09-15 病例(用户实拍)**:「本来字体就小,没有主标题的感觉」—— 量出来是**层级反了**:组标题 11pt 灰比它管着的行标题 13pt 墨还轻。用户另外点名「构建」不要显示。顺带确认:这一页 8 组 21 行本来就滚 2.5 屏,所以新增的组间距用行内边距抵掉,不加剧滚动 |
| T45 | **图标改满幅 + 裸反引号包成键位胶囊** | `Tools/Iconify.swift`(side 0.82→1.0、外接方、内缩 0.8%、圆角 29%)、`Assets.xcassets/AppIcon.appiconset/*`、`Settings/SettingsControls.swift`(`SettingsRow.key`)、`Settings/SettingsView.swift`、`docs/assets/icon.png` | 构建 ✅;对照图:128px 列表行里 改前 vs 改后 | · **2026-09-15 病例**:① 用户实拍 Dock/登录项列表「我的 app 图标没有撑满」—— 量出来是 `side = S*0.82`(Apple 老网格),而 macOS 26 是满幅且系统不加遮罩;改满幅后**当场暴露第二个旧账**:`side0 = right-left`(宽度当高)比玻璃矮 57px,放大后顶边被切平 ≈21px → 改外接方(取较长边 + 中心对齐)。② 裸反引号像手抖多打的字符 → 挂 KeyChip |
| T46 | **设置文案去术语**:「图标呼吸感」→「App 间距」;「循环窗口」→「App 内切换窗口」(说明改为「在同一个 App 的窗口之间移动。」);「循环切换」→「切换 App」 | `Settings/SettingsView.swift`、`design/settings-spec.md` | 构建 ✅ | · **2026-09-15 病例(用户实评)**:「呼吸感也太术语了…直接叫 app间距之类的」「用户哪知道什么是循环,应该叫切换,说明可以解释是在 app 窗口间移动」。口径写进 settings-spec:键位对照表用大白话,按键交给胶囊,说明只在行为不显然时写一句 |
| T47 | **键位胶囊分两副相貌**:只读说明(无边框 + `ink2` + 底色减半 = 禁用)vs 可改的触发键(常驻强调色描边,录制时打满) | `Settings/SettingsControls.swift`(`KeyChip.editable`)、`Settings/SettingsView.swift`(触发键那枚) | 构建 ✅ | · **2026-09-15 病例(用户实拍)**:「这些不能修改设置的快捷键,都做成禁用的样式…不然跟触发键一样,用户点上去没反应,会以为是 bug」—— 两枚芯片原本一模一样。语言定成:描边在 = 能改,描边满 = 正在录 |
| T48 | **正式 DMG 脚本**(Release + `-destination generic/platform=macOS` 出 universal + 标准布局 App 与 /Applications 软链) | `Tools/make-dmg.sh`(新增) | 产物 `~/Desktop/Glance-0.1.0.dmg`(2.9M);核对:版本 0.1.0 / bundle id 未变 / TeamIdentifier 5WV78K89UP / `lipo -archs` = x86_64 arm64 | · **2026-09-15 病例**:第一次出的包只有 arm64 —— `xcodebuild` 不加 `-destination` 会挑"第一个匹配的目标"(= 本机架构);脚本里踩到的两个坑也记着:变量紧邻全角括号必须写 `${DMG}`(否则 bash 把中文当变量名),提交信息里别用反引号(会被 shell 执行) |
| T49 | **可更新性:先把手动更新路径说清 + 守卫报出「另一个实例在哪」** | `README.md`(新增 Updating 一节)、`App/SingleInstanceGuard.swift`(打印另一实例路径) | 构建 ✅ | · **2026-09-15 用户提问**:「用户安装之后怎么更新,这个功能忘记做了」「本地装了 release 和 dev 包会冲突吗,怕装了 dmg 后不方便调试」。查证三条:① 两份同 bundle id → 只可能跑一个(守卫按 bundle id 判定,第二个静默退出);② 但 `DEVELOPMENT_TEAM` 相同(5WV78K89UP)→ TCC 授权与 UserDefaults **共享**,Release/Debug 来回切换不用重新授权,偏好也是同一份;③ 自动更新(Sparkle + appcast)需要先定「包放哪」(仓库是公开的,可走 GitHub Releases),留作下一轮 |
| T50 | **发版链路**:`Tools/release.sh`(构建 universal DMG → `sign_update` 出 EdDSA 签名 → 自写 appcast.xml → 打印上传步骤) | `Tools/release.sh`(新增)、`README.md`(Releasing 一节)、`docs/debugging.md` §14 | 实测:`sign_update` 出签名 ✓ · 自写 appcast **XML 合法且六个必需字段齐** ✓ · `sign_update --verify` 公钥验过 ✓ | · **2026-09-15 病例**:`generate_appcast` **静默**生成没有 `sparkle:edSignature` 的 appcast(退出码 0、无警告),后果是"发布成功但用户永远看不到更新"。改成显式两步。另踩两坑:`sign_update` 输出已含 `length`(重复即非法 XML);`$(xcodebuild …)/Glance.app` 失败时退化成 `/Glance.app`,PlistBuddy 会在根目录**真的创建**空壳 |
| T51 | **玻璃边复刻原生**:删掉长条与托盘那两条画上去的 1px 硬线,改成内阴影式**受光唇**(1.5pt / blur 1.0 / 白 10%–16%),一处定义两处共用 | `Design/PanelGlass.swift`(`GlassEdge` + `glassEdge(cornerRadius:)`)、`Design/PanelTokens.swift`(`glassLip`)、`Panel/PanelView.swift`、`Panel/PreviewPanelView.swift`、`design/v4/design-system.md`(契约修改备案)、`docs/debugging.md` §15 | 构建 ✅;依据是两张截图的**亮度剖面实测**(原生 2–3px 柔和过渡 / 我们一条暗阶 + 硬台阶) | · **2026-09-15 病例(用户实拍对比原生 ⌘Tab)**:结论反直觉 —— 原生边之所以自然是因为**它没有边**(只有玻璃柔边 + 软投影);我们画了线,所以像贴上去的。做不到的部分如实记:原生在圆角弧上还有一次边缘折射(私有 API),我们只近似到柔边 + 受光唇 |
| T52 | **玻璃边做成一个总闸**(`PanelEdgeStyle.drawsEdge`,当前 **false** = 一丝边都不画) | `Design/PanelGlass.swift`(总闸 + `GlassEdge` 挂闸)、`Panel/PanelView.swift`(顶缘内阴影挂闸)、`Panel/PreviewPanelView.swift`(顶缘受光边 + 内阴影挂闸) | 构建 ✅ | · **2026-09-15 用户口径**:「还是有边框看着,能完全去掉我看下吗」—— 长条与托盘上其实有**四处**"边"(受光唇 / 顶缘内阴影 ×2 / 顶缘受光边),散在三个文件里;收进一个 bool,一次只动一个变量。关掉后形状完全由"填充与背景的对比"交代 —— 与原生 ⌘Tab 的做法一致(见 T51) |
| T53 | **白底上"边框被模糊"的真因是投影,不是缺边线**:浅色投影 alpha `strip .22→.06` / `tray .17→.05`(只动一个变量) | `Design/PanelTokens.swift`(`PanelElevation.shadow`) | 构建 ✅;依据是白底上的边缘剖面实测 | · **2026-09-15 病例(用户实拍白底)**:「去掉边线之后,白色背景下边框就被模糊了,不好」「那我们这个玻璃设计的有问题」。量完发现**填充的对比是够的**(内部 1.000 vs 背景 0.914 = ΔL 0.086,与原生同级 0.08),真正糊住边界的是那圈投影:我们 ΔL **0.118**、原生几乎为 0。所以这不是"玻璃设计有问题",是把"浮起"画得太重。下一个旋钮(y/radius)留着没动,一次只改一个 |
| T54 | **浅色投影归零**(strip/tray `.02`):原生在浅底上的边界靠"把背景压暗 0.027 + 不投影"定形,我们却在提亮的同时套着 ΔL 0.118 的暗晕 —— 模糊感就是它 | `Design/PanelTokens.swift` | 构建 ✅;依据是原生白底剖面实测 | · **2026-09-15 病例(用户追问「看下原生为什么不会有这种问题」)**:量了两条(y=180/y=300)确认原生 1–2px 干脆一步、无暗晕。**待验证的下一步**:我们的填充在浅底上是**提亮**(+0.086)而原生是**压暗**(−0.027)—— 若暗晕归零后白底上仍不够定形,下一步是给浅色玻璃加一道**极淡的中性 tint**(α≈0.08–0.10,注意与当年被否的"灰骨玻璃 α .55"差 5–6 倍,那个是把折射一起压平了) |
| T55 | **投影改成朝下的紧贴影**(底边强化,顶边归零):`strip y30/blur30/α.22 → y8/blur10/α.13`、`tray → y6/blur8/α.11` | `Design/PanelTokens.swift`(`PanelElevation.shadow`) | 构建 ✅ | · **2026-09-15 病例(用户实拍)**:「底部还是不够明显,加点阴影强化?整体白值跟透明度我觉得 ok 了」—— 所以填充与玻璃透明度**一格未动** ✓,只改投影的**方向与紧度**:offset 把影子推到下方,blur 收到 10,顶边因为 offset 抵消而几乎为零,底边得到一条接触影。口径:浅底靠"底边接触影 + 填充色阶"定形,不再用四周均匀的暗晕(那是 T53/T54 两轮量出来的"糊") |
| T56 | **托底加高一点点**:`puckHeight` `icon + k(16)` → `icon + k(22)`(上下各 8 → 11);宽度一格未动 | `Design/PanelTokens.swift`(`PanelMetrics.puckHeight`) | 构建 ✅ | · **2026-09-15 用户口径**:「优化一下托底,我觉得有点小了,高度稍微的加长一点点」。实得 @1.2:124.8 → **132pt**(+7.2);长条内容高 158.4pt,托底仍在里面,上下各余 13.2pt(不会顶到长条边) |
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
| 🎛️ **触摸板手势唤起**(T39 候选,2026-09-15 记) | 用户问"能不能识别触摸板手势、加一个唤起方式"。**能**:AltTab 有一等公民实现(`nextWindowGesture`:三/四指 × 横/竖滑,默认关),它同时是"唤起 + 前/后切一个 App"的路径。要照它的分层做:① 纯核 `GestureKernel`(触摸帧 → 方向 + 是否吸收,可单测);② **只读监听 tap**(常开)+ **吸收 tap**(仅会话期开)—— 绝不能挂进现有 navTap:活动 tap 会 gate 整条输入流,手指在板上期间光标发涩(AltTab #5911);③ 会话层加 `beginGesture(direction:)` + **停手 0.4s 自动确认**(手势没有"松手"事件,这是 ADR-0004 的正当例外);④ 设置默认**关**(抢系统手势)。坑:系统 Mission Control / App Exposé 也吃三/四指(AltTab 的 TODO:某些设置下底层内容仍会跟着滚),惯性事件(`momentumPhase`)必须滤 | AltTab `src/events/{TrackpadEvents,GestureTriggerKernel}.swift` | 最小可用版:只做**三指横滑** = 唤起并前/后切一个 App |
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
