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
| T57 | **打卡器 `SessionMarks`**:一局的环节时间轴(枚举 / 落点 / 开窗 / 首帧 / 首图上屏),trace 下全打一行、平时只在有环节 >16.7ms 时打一行 | `Diagnostics/SessionMarks.swift`(新增)、`Panel/PanelController.swift`(4 处打卡)、`Inventory/Snapshotter.swift`(规模计数 + 首图打卡)、`docs/debugging.md` §16 | 构建 ✅ | · **2026-09-15 用户口径**:「还是有掉帧啊老师…要不加一个你说的打卡器,看看各个环节?」并补了一条体感线索:**从内键屏切到外接屏(那个屏 App 多)时掉帧更明显** —— 于是除了时间轴,另埋两个**规模计数器**(`预截 要拍 N 窗 → 回填 M 窗`、`首图上屏 +Nms(本批 M 张)`),直接检验"开销随窗口数增长"这条假说。形状取自 AltTab `MainThreadStall`(扁平步骤、阈值 16.0ms) |
| T58 | **第一次实测一份真机日志**:锁定两条真异常(开窗 20–37ms、键盘换选中 17–38ms,均随格子数增长);修掉打卡器自身一个 bug;装一个免编译的实验开关 | `Diagnostics/SessionMarks.swift`(首图打卡不再被 finish 吃掉)、`Design/PanelTokens.swift`(`debug.noElementShadows` 开关)、`docs/debugging.md` §16.1 | 构建 ✅ | · **结论**:先排除"窗口过大"(误读 `[尺寸]` 的「玻璃 x/y」——那是"按上限算的长条宽/可用宽")与"日志开销"(`[工]` 已自证单行 0.07ms)。头号嫌疑 = SwiftUI 逐元素 `.shadow()`(整棵子树离屏光栅化,随元素数线性长):用 `debug.noElementShadows` 开关对比两行量值即可证伪/证实 |
| T59 | **第二份日志 + 一次"我自己翻车"的归因** | `Diagnostics/SessionMarks.swift`(首图打卡用 `lastSessionStart`)、`App/GlanceApp.swift`(实验开关自己报状态) | 构建 ✅ | · **⚠️ 更正**:我先前写"逐元素投影被证实是热路径大头"是**错的** ✗ —— 查了 `defaults read … debug.noElementShadows` → **从未设置过**,那个开关一次都没生效。两份日志之间真正变的是 **T53–T55 的投影返工**:`strip` 从 `y30/blur30/α.22` 收到 `y8/blur10/α.13` —— 一次全宽的 30pt 模糊阴影在**每次换选中**时都会被重新光栅化,收到 10pt 后这项代价大致降到 1/3。于是"键盘换选中 17–38ms → 几乎都 <2ms"最可能归因于此,而不是那个没开的开关。· **量具自身的局限(重要)**:`traceCost("键盘换选中")` 只包住**状态写入**那一小段,不包含随后那次 SwiftUI 重绘 —— 所以它下降**不能**直接说明"重绘变快了",只能说明包住的那段变快了。要量重绘得看 `[帧]` 与 `[打卡] 开窗`。· **仍未验证**:逐元素 `.shadow()` 的代价(开关未设 ⇒ 假设未被检验) |
| T60 | **第三份日志的三处异常**:① 幽灵窗日志每局重印(去重写成了"和上一条比",而两条日志交替出现);② `didChangeScreenParameters` 通知被 macOS 滥用 ⇒ 无切屏也会整块作废缓存(下一局重拍 10 窗);③ 切屏后第一局 `开窗` 55–138ms,且**内键屏(2× Retina)明显比外接屏贵**(像素面积 4 倍) | `Inventory/WindowEnumerator.swift`(幽灵窗改"见过就不再印")、`Inventory/ThumbnailRefresher.swift`(屏幕指纹过滤 + 作废日志常开) | 构建 ✅ | · **2026-09-15**:整份日志长帧 0–5%(多数 0%)、`开窗` 稳态 11–27ms、`键盘换选中` 13ms —— **每次唤起那条路径已在帧内**;剩下的三项如下。③ 属"每屏切一次"的固有代价(窗口后备存储 + 玻璃层重建),不是每次唤起,记为已知项 |
| T61 | **第四份日志(重建后)**:幽灵窗去重**生效**(两条各只打一次);但"缓存作废"那条**从未出现** ⇒ 我 T60 的归因又错了 ✗ —— 图不是被删的。给 `precapture` 加上**原因分账**(无图 / 过期 / 强制) | `Inventory/Snapshotter.swift`(分账计数进日志) | 构建 ✅ | · **2026-09-15 病例**:`[T5] 预截 要拍 10/11 窗` 依然每局都来,而 `[保温] … 缓存作废` 一次没打 ⇒ 排除"整块作废";两个 `prune` 调用点读过了,都保留**全部**窗口(`allWindows` / `live`),也不是元凶。剩下的两种可能(压根没存进去 / TTL 60s 过期)对应完全不同的修法,故直接量出来 —— 本次会话已经因为"推理代替测量"翻过两次车(T59 归因给没开的开关、T60 归因给没触发的作废) |
| T62 | **投影:只给选中的那颗图标**(帧率优先);`←→` 补记账;`Tools/trace-run.sh` 把日志固定落盘 | `Design/PanelTokens.swift`(`elevation(_:active:)` 参数归零而不是条件包裹)、`Panel/PanelView.swift`、`Panel/PanelController.swift`(窗口选中记账)、`Tools/trace-run.sh`(新增)、`docs/debugging.md` §17 | 构建 ✅ | · **依据(A/B 实测)**:同一台机器同一块屏,只改投影一处 —— `[打卡] … 开窗`(首帧渲染)从典型 **18–30ms** 降到 **10–13ms**,由"超过一帧"进到"一帧以内" ✓。用"参数归零"而不是 `if` 包裹:修饰符链保持同一条,否则每次 Tab 改选中态都会改视图身份、打断选中弹簧 ✗。· 另:出现过的 `长帧 4(6%)` 全部落在连按 `←→` 的 3 秒里,而该路径没有括号 ⇒ 补上 `[工] 窗口选中`。· 顺带查明一份崩溃报告:`Debug` 用 `-destination generic/platform=macOS` 构建会让 SPM 动态框架落点错位 ⇒ 启动期 `Library not loaded: Sparkle.framework`,规矩记进 §17 |
| T63 | **日志不再依赖启动方式**:trace 开着时进程自己把 stdout 落到 `~/Library/Logs/Glance/trace.log` (5MB 上限,终端留一行 stderr 提示) | `Diagnostics/Stdout.swift`(`mirrorStdoutToLogFileIfTracing`)、`App/GlanceApp.swift`、`Tools/trace-run.sh`(去掉自己的重定向)、`docs/debugging.md` §17 | 构建 ✅ | · **2026-09-15 病例**:第一版只给了脚本,用户没用脚本 ⇒ 日志仍绑在 tty 上;而用户的终端是 Ghostty,**连 AppleScript 读 scrollback 这条后路都没有** ⇒ 真正的解法是"进程自己写文件",而不是"要求用户换一种启动方式" |
| T64 | **缓存悬案定案 + 修**：`prune` 无条件 `session &+= 1` ⇒ 开局发出的预拍在回程被判成上一局、整批丢掉 ✗；改成"只有真的移除过窗口才作废在途批次"。另加量具:miss 分账里区分**"曾经拍到过"** | `Inventory/Snapshotter.swift`(`prune` 条件化、`everCaptured`、missLost 分账) | 构建 ✅ | · **日志证据(第 5 份)**:所有 miss **全是「无图」、零个「过期」** ⇒ 图不是过期是压根没留下;另外确认 **帧率优先的改动生效**:同一块屏再唤起 `开窗` **6–12ms**(改前 18–30ms),剩余 24–70ms **全部落在切屏或冷启那一局** —— 与用户"切到外接屏那一下卡"的体感吻合 | · 用户"肉眼看到好几次掉帧"在日志里也**对得上**:有一局 `长帧 11(6%)`,五点挤在 0.77–1.48s ✗ |
| T66 | **回答"跟外接屏刷新率有关吗" + 修量具的刷新率假设**:长帧阈值原来写死 `1.5/60 = 25ms` ✗ (120Hz 屏上会漏报 12–25ms 的卡顿);改成按面板所在屏的 `maximumFramesPerSecond` 判定,非 60Hz 时在日志里标出基准。另:`指针换选中` 的第一轮拆账(拍图 / 托盘更新)**两笔都没超 2ms** ⇒ 钱不在这两处,补第三笔"写状态" | `Diagnostics/FrameProbe.swift`、`Panel/PanelController.swift` | 构建 ✅ | · **实测**:外接 LEN T27p-10 = 3840×2160 (4K) @ **60.00Hz**(UI 1920×1080),内键 XDR 3456×2234 Retina;日志里两块屏 `P50` **都是 16.7ms** ⇒ 两块屏同为 60Hz 节拍 ⇒ **刷新率不是变量**;81 局数据里真正的变量仍是 **App 数**(7 App: 长帧 0–2 ✓;11 App: 尾巴 25/58 ✗) |
| T67 | **量具的两处修正**:① 子账(`↳…`)在 trace 下**无条件打** —— 上一轮拆 `指针换选中`(外层 12ms)时三笔子账一笔没露面,因为各自都 <2ms 门槛,而"外层 12ms、子账加起来不到 2ms"本身就是线索 ✗;② `prune` 作废在途批次时**打一行**(日志里 miss 绝大多数是"曾拍到过"= 拍到又丢,要和时间对齐) | `Panel/PanelController.swift`(`traceCost`)、`Inventory/Snapshotter.swift` | 构建 ✅ | · 同轮**重大修正**:按屏的实际刷新率判定 + 屏的实测数据说明——用户某块屏跑 **120Hz**,而入场那几帧是 **12.5–25ms** ⇒ 每两帧掉一帧 ✗;"内键屏长帧全 0"是**旧量具漏报**(阈值写死 60Hz)。目标因此变得具体:**`开窗` 要压到 12.5ms 以下** |
| T70 | **屏蔽系统权限弹窗**:辅助功能/屏幕录制提示由**后台进程**渲染,没有 Dock 图标,在面板里就是"齿轮状空白" ✗。主路(`CGWindowList`)原来**不查激活策略**(那份系统进程名单只用在了"无窗应用"支线上),现按 `activationPolicy == .prohibited` 过滤,并把被丢掉的宿主名字打一次(便于复现时确认) | `Inventory/WindowEnumerator.swift` | 构建 ✅ | · **2026-09-15 用户报**:"glance 要权限的时候那个系统弹窗也会被识别到,但是没有 app 图标,是一个齿轮状空白"。判据用**系统自己维护的事实**(有没有常规激活策略),不用 bundle id 名单 —— 名单随系统版本漂(tccd / UserNotificationCenter / CoreServicesUIAgent …)。`.accessory`(菜单栏型 App)不动:它们可以有正当窗口 |
| T71 | **点名屏蔽系统提示框宿主**:`universalAccessAuthWarn`(辅助功能警告窗)✦ —— T70 那条"按激活策略过滤"的通用规则**没挡住它** ✗,因为它的激活策略是 `.regular`;改成"通用规则(prohibited)+ 点名名单(5 个系统提示框宿主)" | `Inventory/WindowEnumerator.swift` | 构建 ✅ | · **2026-09-15 病例(用户第二报"还是有")**:从 `[T6] 落点顺序` 那一行抓到名字 `universalAccessAuthWarn`,并用一次性探针确认当前所有 layer0 窗口的归属**清一色 regular** ⇒ 激活策略这条通用规则对它无效。名单能存在的前提写进注释:只收系统提示框宿主(极小),且名单外的闯入者会直接出现在落点顺序那一行里 |
| T72 | **修 Sparkle 启动失败**:`SUPublicEDKey` 手抄时**少了一个字符**(43/44)✦ —— Sparkle 判定公钥非法,**在启动阶段就失败**;从钥匙串还原真公钥后修好 | `Sources/Glance/Info.plist` | 构建 ✅ · 构建产物公钥 44 字符 ✅ | · **2026-09-15 病例(用户截图)**:弹窗只说"updater failed to start",**不含原因** ✗;Console(`process == "Glance"`)才写着 `The provided EdDSA key could not be decoded.`。私钥未变 ⇒ 已签的 appcast 不用重签。纪律:公钥永远 `generate_keys -p` 取,禁止手抄 |
| T73 | **修图标米色边框**:`side0 = max(宽,高)` 的方框被**底边投影**撑大,又因居中放置而左右各溢出 ~1.8% ⇒ 源图底色 `#F1EDE2` 被裁进画面(左/右 1.76% ✗、下 1.17% ✗,顶边 0 ✓ = 锚点错的反证)。改成"边长用宽度(不扫投影)+ 左上为锚 + 内缩 0.8%→1.8%" | `Tools/Iconify.swift` · `Assets.xcassets/AppIcon.appiconset/*` · `docs/assets/icon.png` · `design/icon/README.md` | 构建 ✅ · 四边脏带 1.76/1.76/0/1.17% → **0/0/0/0.39%** ✅ · 放大对比图目视确认 ✅ | · **2026-09-15 病例(用户报)**:「app 图标的边没清理干净」。量法:探针沿四条中线统计"暖色背景像素"带宽(源底暖、玻璃绿灰,判据分得开)。纪律:边缘脏**不靠眼睛调参**,写探针把脏带打成百分比,改完再打一次 |
| T74 | **图标边缘再收(A 方案)**:内缩 1.8%→3.0% + 遮罩圆角 0.29→0.305(两者都做成可传参数)✦ —— 修的不是"抠图残留"(四边中线实测早已是 0 ✓,且 raw.githubusercontent 的字节与本地一致 ⇒ 排除 CDN 缓存 ✓),而是**渲染自带的柔边**(半透明玻璃 + 暖调,112px 下呈现为一圈浅色) | `Tools/Iconify.swift` · `Assets.xcassets/AppIcon.appiconset/*` · `docs/assets/icon.png` · `design/icon/README.md` | 构建 ✅ · 下边/右下角残留归零(2→0 · 5→1)✅ · 与 Ghostty 同尺寸同底色并排对照目视确认 ✅ | · **方法论(写进 design/icon/README.md 坑六)**:判"边缘干不干净",**同尺寸+同底色+有原生基线**的并排图比任何像素指标都可靠 ✓;而这次八条线的探针在左上角给出**假信号**(量到的是渲染自己的暖色受光 ✗,换任何参数都不动)—— 印证 ≠ 正确 |
| T75 | **图标内缩回退到折中值 2.2%**:T74 的 3.0% 让左上角出现灰斑 + 硬斜边(遮罩切过渲染自身的角落阴影)✦ | `Tools/Iconify.swift` · `Assets.xcassets/AppIcon.appiconset/*` · `docs/assets/icon.png` · `design/icon/README.md` | 构建 ✅ · 左上角 1.8/2.2/3.0% 三方案并排放大对照,2.2% 最干净 ✅ | · **2026-09-15 用户报**:"左上角给我改的脏脏的,本地 app icon 里面的就没事"。我上一轮是拿 **112px 缩略图**判断的 ⇒ 漏掉了角落细节 ✗。纪律:整体观感看实际显示尺寸,角落干不干净**必须放大看局部**,两者不可互替。另注:改图标后 **Dock 显示的是缓存** ✗,这正是"本地看着没事"的可能原因 |
| T76 | **预截批次推迟(后被 T79 修正为"两批分流",此处保留当时的全推迟版本与数据)**:开局立刻发的截图批(30–50ms/窗的 GPU/WindowServer 活)是整批拍完**一次性**回主线程合并的,实测落点 **+80–279ms**,与入场弹簧(60ms 起跑)的窗口整个重叠;病例:某局"其余组要拍 4 窗(曾拍到过)"在 +175ms 合并,那局 `[帧]` max **140.7ms** ✗。改成世代守卫的 `asyncAfter(0.45)`(dismiss 自己会把 beginGeneration +1,"面板已关"自动作废,不用另判 isVisible);"显示即重拍"的契约不动、只挪时机,卡片在头 0.45s 显示缓存旧图 | `Panel/PanelController.swift`(`finishBegin` / `recaptureDelay`) | 构建 ✅ · 真机注入 6 轮对比:`首图上屏` +72–279ms → **+569–592ms**;`[帧]` max 28–36ms → **≤18.1ms**;A 组 2/6 局"节奏抖动"→ C 组 **0/6** ✅ | · 同轮 A/B **证伪**一个假设:`debug.noGlass`(换 `NSVisualEffectView`)后内建屏照样 16.7ms P50 ⇒ 内建屏的 60Hz 节奏与 `NSGlassEffectView` **无关**;开关按"验证完的开关不留代码"撤掉,结论与判读口径进 debugging.md §18 |
| T77 | **玻璃 tint 等值守卫**:`updateNSView` 里 cornerRadius 早有等值守卫、tintColor 却每次**无条件重写**(还每次新建一个动态 NSColor)—— 入场弹簧经 `@Published` 逐帧驱动两棵根视图重算,这里逐帧被进一次;若 AppKit 不做等值短路,玻璃被逐帧标脏 | `Design/PanelGlass.swift`(`Coordinator.lastTint`) | 构建 ✅ | · 为什么存 `lastTint` 对账而不是比 `glass.tintColor` getter:getter 返回的对象不保证与写入的相等,存"自己写过的那份"才是可靠依据 |
| T79 | **预截两批分流:显示组立刻、其余组推迟**(T76 的修正,用户裁决:"针对当前唤起选中的 app 实时填充,别的走异步替换"):T76 把两批一起推迟了 0.45s,代价是**落点组**(用户第一眼看的就是它)头 0.5s 显示旧图 —— 恰恰是"显示即重拍"最该准的那张。改成:显示组恢复**立刻重拍**(与 Tab"选中即重拍"同一契约;它天然小,按屏归属后一组通常 1–3 扇窗,实测从未单独造成可见长帧);其余组保持 0.45s 推迟(140.7ms 病例的元凶就是它) | `Panel/PanelController.swift`(`finishBegin`) | 构建 ✅ · C′ 组注入复测(2026-09-16,8 轮):显示组合并回到 **+68–112ms**(第一局 +346ms 是冷枚举),其余组大批量回填(17 窗!)落在动画结束后,`[帧]` max **15.3ms**、无抖动 ✅ | · C′ 组的意外发现:**P50 8.3ms = 内建屏跑出真 120Hz** —— 当时外接屏已断开(仅剩内建 120Hz),对照此前 20+ 局 16.7ms,钉住 60Hz 的相关变量是**「60Hz 外接 + 120Hz 内建」混合刷新率拓扑**,不是代码(详见 debugging.md §18;※ 当日复测:D 组(外接屏接回)内建屏 6/6 局立刻钉回 16.7ms、外接屏 4 局无回归 —— 拓扑相关性坐实,记已知环境项,详见 debugging.md §18) | · 顺带口径更一致了:开局落点组与中途 Tab 换到的组,现在走同一条"看着谁就重拍谁" |
| T78 | **ProMotion 60Hz 结论与 `[帧]` 判读口径补记**:内建 XDR(120Hz)上面板内容节奏恒 16.7ms(前后 20+ 局 P50 全 16.7,无一段稳定 8.3)⇒ 显示自适应跟随**内容**节奏,玻璃/无玻璃一样;肉眼可见的"卡"对应的是"节奏抖动 ±P90"那行(8.3/16.7 混拍),不是"长帧 N(100%)" | `docs/debugging.md` §18 | — | · 判读口径:均匀 16.7 = 顺(60Hz 扫描下每拍都有内容);混拍 = 卡;`长帧 117(100%) [按 120Hz 判定]` 这种行**不能**读成卡 —— 它只说明内容在按 60Hz 节奏走 |
| 👀 **上膛点改首帧驱动** | 唤起后 +60ms 固定延迟上膛,若首帧渲染(开窗+首帧 6–60ms)撞上同一拍,入场第一拍会迟到。第 0 步实测:暖局 开窗+首帧 6–20ms 够不着 16.7ms 预算,**证据不足未做**;若未来"切屏后第一局"仍报卡,把 `showPanel` 的上膛块挪进已有的首帧 async 回调即可 | — |

| T80 | **卡面方案 D:统一底色 + 非选中截图压色**(讨论起于"用户不喜欢预览窗/LumaRing 对比",用户自评"乱" = **截图内容异质**:每张卡是各窗真实画面,一排过去深浅乱跳;主观、无外部病例,对照图三案并排后拍板方案 D)。非选中卡的截图与毛玻璃条压到 **30%**(`PanelMetrics.thumbWash`),统一底色(**实色** 浅 `#eceff3`/深 `#2b3037` —— 半透会透壁纸,"统一"会漏)接管卡面;选中/悬停恢复原样,压色挂同一条选中弹簧。卡壳(尺寸/圆角/描边/红绿灯/芯片)一行未动;"认窗"靠画面结构、"哪个 App"靠图标层、"哪一扇"靠芯片 | `Design/PanelTokens.swift`(`thumbBg` 改实色底、`thumbWash`)、`Panel/PreviewPanelView.swift`(两处 opacity) | 对照图 `design/卡面实验台.html`(用户自制并拍板) · 构建 ✅ · **真机实评通过**(2026-09-16 用户四张截图:深浅双外观 × 多组,"看着还行";非选中卡统一灰底、选中卡全彩、卡壳无变化) | · **不立 ADR**:一个修饰符量级的改动,可逆;裁决与对照图都在本行与实验台里。· 词汇表同步:CONTEXT.md「展开层」补"非选中压色/选中恢复"的分工 |
| T81 | **缓存内存账**:`[唤起]` 行附带 `缓存 X.XMB/N 张`(逐张按位图字节数累加)。起因:用户问"LumaRing 悬停才预览的懒加载是不是就不会掉帧" —— ① 掉帧根因是开局整批合并爆发(T76/T79 已修),不是"预览常驻";② 懒加载省不掉截图成本(30–50ms/窗),只是挪到 hover 时刻(要么 hover 顿、要么出图晚);③ 唯一真值是**内存**。裁决:**先量后议**,交互一毫米不动 | `Inventory/Snapshotter.swift`(`cacheMemoryBytes`)、`Panel/PanelController.swift`(`[唤起]` 行) | 构建 ✅ · 账随 `[唤起]` 天天可见 | · 日志预算仍守"一次唤起 ≤ 2 行":内存账**并进** `[唤起]` 行,不另起一行 |

| T82 | **手势唤起(三指轻点)** —— **🚧 已裁决未实施**,占行:**① 手势 = 3 指轻点**(v1 只做轻点;按压检测是设备差异重灾区,留观察);② **默认开启**(用户裁决 2026-09-16,推翻"默认关"的保守推荐;探子证实与系统"查询&数据检测器/三指拖移"可能撞车 ⇒ 处置是**设置页提示冲突**,不改默认);③ **手势会话 = 钉住语义**(无修饰键可松,面板停留不自动消失,确认只靠点击/回车/Esc —— 复用 `pinPanelOnRelease` 状态机,不造新状态);④ 手势**只当第二触发键**(唤起后全复用现有交互;AltTab 式"停手自动确认"是融合操作,ADR-0007 雷区,否)。技术路线(探子事实):**MultitouchSupport 私有框架只读监听** —— 零 TCC 权限、不在事件流内、机制上免疫 AltTab #5911 的光标门控;判定照抄 LumaRing 已验证包络(3 指:落齐 0.15s / 时长 0.42s / 位移 <0.035 / 冷却 0.35s,丢帧即 reject);冲突检测读 `TrackpadThreeFingerTapGesture` / `TrackpadThreeFingerDrag`;健壮性三件套 = IOKit 插拔重连 + 睡眠/锁屏 suspend + noDevice 可视化 | 待落:`TrackpadInput` C 目标 + 设置页(冲突提示)+ 唤起接线 | — | · 上一轮侦察(tasks.md §三 T39 行)与本次探子报告互相印证 |
| T83 | **启动区(方案 E「入口槽」)**:Dock 常驻且未启动的 App 进面板。第一版"第二行"被用户否(「数量反转不和谐 / 缩一号不明显 / 两层厚重」),改**入口槽**:主环尾部一道可被选中的分隔缝,选中/hover 时**托盘**弹出启动图标行 —— 托盘的定义从"选中 App 的窗口卡"泛化为"选中格的内容"(CONTEXT.md 已同步)。样式动效与现有完全同源(同一卡壳/托底/弹簧,无割裂感);确认 = 启动并激活,面板即关,**无提示弹窗**。名单 = Dock 常驻 − 在跑的(CFPreferences 读,按钉住顺序);解析进纯核(`GlanceCore.DockApps`)+ 8 例单测;每局同步取(长条宽/托盘最大布局依赖它,晚到 = 中途改尺寸)。主环尺寸数学零冲击(入口槽只占 ~0.72 格宽) | `Packages/GlanceCore/Sources/GlanceCore/DockApps.swift` + Tests、`Inventory/DockApps.swift`、`Panel/PanelController.swift`(cursorPos/entrySelected/launchIndex)、`Panel/PanelView.swift`(入口槽+托底)、`Panel/PreviewPanelView.swift`(启动行)、`Design/PanelTokens.swift`、`Settings/SettingsView.swift`(「展示 Dock 常驻应用」开关,默认开) | 设计稿 `design/启动区实验台.html` v2(用户拍板"也可以") · 单测 8 例 ✅ · 构建 ✅ · **真机待用户实测**(助手注入自验两度撞上用户真实输入,按纪律停手移交) | · 已知边界:本屏零窗时不出现面板(沿用旧卫兵),此时启动区也不可达 —— 病理场景,先不接。· 词汇表:新增「入口槽」「未启动 App」,「展开层」泛化。· **v2 重做(同日真机实评)**:v1 两处被否 —— ① 借窗口卡的壳(「丑的要死」:大灰卡里浮一枚小图标,空得难受)→ v2 **整行复用主环视觉语言**(同一图标尺寸/格距/托底胶囊/选中态,托盘即"第二条主环"),名字不显示(Dock 心智);② Tab 语法被否(「tab 只能是切换 app 的语义,` 才是切换窗口」)→ **启动区彻底退出 Tab 环**,只 hover/点击到达;在启动区按 Tab = 回主环照常切换。· **v4(同日第三轮实评)**:① **报错两连修** —— `pollLaunchHover` 在 Canvas 绘制闭包里直接写 `@Published` ⇒ Runtime "Publishing changes from within view updates" + `-layoutSubtreeIfNeeded` 布局递归;改成绘制闭包只算下标、`Task { @MainActor }` 异步一跳落账(本帧不生效、下一跳生效,视觉不可分辨)。② 选中语言改**凸透镜**(用户口径「凸透镜放大的那种凸起会比较好看」):槽底升起与主环托底同配方的板子(受光唇+底缘内阴影),点阵坐板上放大 1.25 —— 与主环"图标在托底上放大"同一套物理;描边+强调色方案(v3)废弃。③ 附注:控制台 `AFIsDeviceGreyMatterEligible Missing entitlements` 为 macOS 系统噪音,与本 App 无关。· **v5(同日第四轮实评)**:① 板子收轻 —— 高度收到与图标同高、去掉 puck 级投影(受光唇+底缘内阴影足够);② **槽滑入必出、方向恒定** —— 板子常驻层级由 sel 显式驱动(透明度/底部锚点缩放/上浮),废弃条件插入的 `transition`(v3 偶发"从左边滑过来"= transition 某些时序没进动画事务),方向恒为自槽底向上浮;③ **入场弹簧 0.20 → 0.16**(用户:「唤起面板 app 上浮的速度太慢了」),且**入口槽滑入改用同一根 entrance 弹簧** —— 两处同速,不会各走各的。· **v6(同日第五轮实评)**:v5 的"从槽底浮起"实测**没有滑入感**(用户:「没有滑入…从右滑入的动效没了」)⇒ 滑入方向定稿 = **从右**:板子常驻层级,由 sel 显式驱动 `offset(x: sel ? 0 : +20pt)` + 透明度 —— 每次选中从右侧滑入就位,必出、方向唯一;槽在环尾,从右滑入与"还有一页"的语义同向。· **v7 定稿(用户终裁)**:「不要从右滑入的动效了,保留选中动效就行」—— 方向性滑动全撤(左/右/底三案皆否),选中态 = **板子淡入 + 点阵放大 1.22**,无任何位置搬运;板子仍常驻层级由 sel 驱动透明度。· **v8 选中互斥**(用户裁定「他俩不能同时选中…只是 tab 移动不允许选中槽而已」):槽被占住时**主环选中退场** —— 图标去放大/上浮、托底淡出,一局只有一个"选中";回到主环(hover/Tab)即恢复。Tab 不进槽的裁定不变。· **v9 悬停回退**(用户裁定:「主环 app 选中后鼠标移开保持现状没问题,但槽连带启动行,指针移开就回到最后选中的 app」)——主环 hover 保持**粘性**,启动区改**悬停预览**:指针离开槽+启动行 0.3s(迟滞)未回两块玻璃,就回退到最后选中的主环 app。为什么迟滞:槽(长条窗)与启动行(托盘窗)隔着一道缝,跨窗路上 onHover(false) 先到,立即回退会把启动行在指针脚下拆掉(永远够不着)。· **v10 提速**(用户:「大概要半秒才回到,有点慢」):迟滞 0.3s → **0.12s**,同时判"还在启动区"的区域加入**缝间走廊**(两块玻璃之间 y 向空当,x 取两者横向范围)—— 收紧后慢速跨缝也不会被拦腰截断 |
| T84 | **幽灵贴**:未启动 App 的「壳」,一处几何、两处共用 —— 主环入口槽选中态与托盘启动行的容器。用户实评两问:「选中的背景优化一下」「未启动 APP 的容器要不要也优化,一致性有点不太好」。病理:v7 凸透镜板是一块 `entrySlotWidth×icon` 的**圆角矩形板**,与邻居(一枚枚 app 图标)不同几何,读起来"多了一块板";启动行裸图标则悬浮无座位。定案 **GhostTile**:app 图标同尺寸 + macOS 图标同圆角比例(`ghostTileRadius = icon×0.225`),材质比 puck 收一档(`ghostTile` 白 .42 / 板岩 .62)—— 壳是座位不是主角。入口槽选中 = 壳淡入(0.88→1)+点阵只换色不放大;启动行 = 图标收到壳的 76% 坐进去。一致性韵脚:**入口槽 = 还没装图的壳,启动行 = 装了图的壳**。v7 的"无方向性滑动"裁定沿用(壳淡入不搬运位置);v2"启动行不要托底"的裁定被本次用户提问重开并以"同一枚壳"的形式落地。**v9 补(同晚二轮实评「没选中时点阵又太空」)**:两态从"有壳 vs 裸点"改为**同一枚壳的两个强度** —— 常态淡座(α .30,hover .45),选中点亮(α 1,几何不动);点阵 2×3→3×3、点径提一档 `entryDot=dot×1.3`(见 design-system v1.17);选中态经用户复核认可不动。**v10 终审(同晚三轮「还是太挤了,干脆用 macOS 原生的分割线方式表达」)**:入口槽改为一根 1px 发丝竖线(icon×0.52 高),占一整格(icon+iconGap)与普通 App 同节奏、独立参数(entrySlotWidth/entryDot/entryDotOnPlate)全部废除;颜色浅=黑 .30/深=白 .34(见 design-system v1.18)。**v11 纠偏(同晚「分割线之后的槽呢??只是让你加个分割线,不是让你把入口删了」)**:启动区 = 分割线(gap 格,浅黑/深白)+ 入口槽两件套;入口槽 = v9 淡座点阵原样回归,格子扩成一整格(icon+iconGap)—— 挤的病根是槽比格子窄、壳溢进邻居间隙,间距有保证后壳并不挤(见 design-system v1.19)。**v12 瓷贴(同晚「浅色太不明显,有点廉价,设计的高级一点」)**:常态从"整枚壳乘 .30 透明"(线脚一起被洗掉=廉价感的来源)改为**瓷贴淡座** —— ghostTileFaint(浅白 .55/深板岩 .32)打底,发丝边/受光唇/贴身软影(黑 .07 r3)全部不透明强度;点阵点改微渐变(entryDotTop/Bottom 顶亮底沉)。GhostTile 加 faint 参数(启动行选中壳同步获得软影)(见 design-system v1.20)。**v13 闪烁根除(同晚「滑动上去会有闪烁,只期望做凸透镜的点阵放大」)**:座恒定不动(永远瓷贴,材料/缩放零翻转),选中唯一语言 = 点阵放大 1→1.18;entryHovered 状态与 entryDotOnPlate 换色废除(见 design-system v1.21)。**v14(2026-09-17 凌晨「去掉选中的白色底边,右边的位置压缩,不然太像一个 APP 窗口」)**:GhostTile 删受光唇,发丝边深色改透明(ghostTileBorder);瓷贴与占格压缩回 icon×0.72 方形窄格(entrySlotWidth 复活,PanelController 记账同改);选中动效不变(点阵 1→1.18)(见 design-system v1.22)。**v15 终审(同晚「不要边框,不要底色,收窄右边」)**:入口槽 = 纯点阵,瓷贴(底色/边框/软影)全部退场,幽灵贴退守托盘启动行;占格收窄 icon×0.5(记账同改);ghostTileFaint 删除(见 design-system v1.23)。**v16(同晚「做2排六个点,高度跟未选中的 app 一样」)**:点阵 3×3 → 2排×3列,两行在 icon 高度内摊开(spacing = icon-2d),记号与 App 同高(见 design-system v1.24;随即纠偏:「竖着排?」—— 两行扯到上下边缘是误读,改回紧凑 2×3、行距=列距、块居中;再纠偏(v17):「竖着是三个,横着是两个」= **3 行 × 2 列**竖向点阵)。**v18(同晚「太宽了」)**:占格改 = 记号宽(3.5×entryDot)+gap+4pt —— App→竖线≈gap、竖线→点阵≈gap+2,与两个 App 间距同族(entrySlotWidth 公式重定义)。**v18(同晚「太宽了」)**:占格改 = 记号宽(3.5×entryDot)+gap+4pt —— App→竖线≈gap、竖线→点阵≈gap+2,与两个 App 间距同族(entrySlotWidth 公式重定义) | `Panel/PanelView.swift`(GhostTile + entrySlot v8→v9)、`Panel/PreviewPanelView.swift`(launchCell 座位)、`Design/PanelTokens.swift` | 构建 ✅ · check-architecture:2 条 Trigger 越界为 T83 遗留(HotkeyTap→WindowEnumerator/WindowFocuser),非本轮引入 · 离屏对照 `/tmp/glance_ghost_tile.swift`、`/tmp/glance_entry_v9.swift` · **真机待用户实测** | · 通用教训:自适应/新增元素的"形状语言"优先于"材质语言" —— 板 vs 贴的一字之差就是"格格不入"与"本来就是一套"的差别;状态两态该是"同一形状的两个强度",不是"出现 vs 消失" |

| T85 | **首局唤起卡顿的观测定案**(用户:「体感上还是有掉帧…首次打开的时候,唤起会有一丝卡顿。不知道最重的地方是不是在拍照,还是在填充快照」)。冷热对照注入实测(HoldChord 3s × 冷/热各一发):**冷启动首局上屏 353ms(枚举 273ms + 开窗 80.4ms + 缓存 0 张/首图 +416ms),热局 34ms 全绿;两局 `[帧]` 长帧均为 0**。结论:体感的"一丝卡顿"主体不是动画掉帧,而是**上屏本身慢** —— 冷枚举管线首跑(256ms)+ 面板窗首建(80ms)+ 空缓存,三笔都在首局。据此定 T86 的主修是"冷启动预拍"(用户的两条提议都保留,另补一条),而不是继续抠动画 | `Tools/HoldChord.swift`、trace.log(`[唤起]`/`[打卡]`/`[T5]` 对账) | 真机注入实测,数字见本行与本表 T86 备注 | 冷启动首局的"开窗 80ms"只此一次且预暖后仍有 ~40ms 首次上屏成本(orderIn/首帧提交),记为已知固有项 |
| T86 | **拍照全链路挪出唤起热路径**(用户提案两条 + 补两条,裁决:"拍图跟唤起面板渲染能彻底做成异步的吗"):① **冷启动预拍** —— 启动后空闲 2.5s 对语境屏全量枚举+预截(once 闸,onAppear 双跑防重),把冷枚举管线与空缓存整体暖掉;② **唤起零拍** —— `finishBegin` 删开局 force 单,"显示即重拍"契约整体挪到 +0.45s(显示组 force + 其余组 TTL,入场沉降之后,只挪时机不砍);③ **关面板预拍** —— `teardownPanel` 后 0.25s 全量预截(TTL 过滤),下次唤起 0.45s 批基本空转;④ **失焦拍** —— `ThumbnailRefresher` 记 `lastActivatedPID`,App 被切走瞬间补拍它的窗(`maxAge: 2s` 防快速切换风暴;先记账再走节流,被节流的切换说明前任只上台 <1s、激活拍还新)—— 堵上"激活拍"的最后盲区(当前 App 用多久图就旧多久),而失焦者恰好是下次唤起的"显示组";⑤ **逐张回主** —— Snapshotter 整批合并改每拍一张回主一张(`publish`,单次 <1ms),消除"一批图同时到"的爆发(T76 前掉帧真身的残余形态);⑥ **面板窗预热** —— 启动后 `prewarmPanels()`(只建不显示),首局开窗 80ms 不占唤起那一拍。**取舍(已向用户说明并同意)**:内容自变的窗(视频/终端)唤起第一帧显示的是切走瞬间的图,0.45s 后自动换真图。**首轮实评修两处**:sweep 全屏改**仅语境屏**(面板「本屏窗」是单屏语义,别屏的窗拍了就被 prune 扔,曾每局白拍 7 扇并引发"在途批次作废");冷启动 sweep 加 once 闸(onAppear 在 SwiftUI 双跑,曾白拍两遍) | `Inventory/Snapshotter.swift`(逐张回主+maxAge)、`Inventory/ThumbnailRefresher.swift`(失焦拍+sweepPanelScreen)、`Panel/PanelController.swift`(唤起零拍/关面板预拍/预热)、`App/GlanceApp.swift`(scheduleWarmup) | 构建 ✅(零警告)· GlanceCore 单测 7+8 例 ✅ · **真机实测**:冷启动预拍 2.9s 落地(枚举 227ms 挪到没人看时),首次唤起上屏 353→**84ms**(缓存 0→14 张),日常真机唤起 37–90ms(11 次真实 ⌘Tab),0.45s 批近乎全命中,`[帧]` 长帧 0–3 帧(≤40.6ms,1–2%) | · 已知残留:系统忙时首帧提交偶发 99–138ms(对照旧日志 T86 前已有同型 121ms 一例,同局 `[帧]` max 仅 27ms —— 非拍照回归,观察);· `[打卡] 首图上屏` 语义已变:热局第一帧就有缓存图,这行现在量的是"第一张重拍图落地时刻"(+0.45s 那批),不是用户第一次看见图 |

| T87 | **跳屏触发键 ⌃ → ⌥**(用户:「double control 跟 IDEA 快捷键冲突了,改成 double option 吧」)。`DoubleControlTap` → `DoubleOptionTap`:判定从 `contains(.control)` 换 `contains(.option)`,dirty 名单同步换防(⌘/⌃/⇧ 算夹键、⌥ 是触发键不算);UserDefaults key 换名 `pointer.doubleControlJumps/LandsFocus` → `pointer.doubleOptionJumps/LandsFocus`,**不做旧值迁移**(语义未变但 key 说谎比丢开关状态更糟,且该开关默认关——先例:panel.puckRiseFromBottom);设置面板两行标题与注释同步;ADR-0007 补修正注记(核心决策不动,只换"第一步"的按键)。⌥ 的按住出音标是"按住"(一次 down),凑不出双击,无新冲突面 | `Trigger/HotkeyTap.swift`、`Settings/SettingsView.swift`、`App/GlanceApp.swift`、`docs/adr/0007` | 构建 ✅ | · **用户须知:key 换名 ⇒ 开关状态重置,需到 设置 → 快捷键 重新打开**(原开关是开着的才撞上 IDEA 冲突)· 真机待用户实测 · **v2(同日)**:落焦子开关「顺带把键盘也带过去」废除 —— 用户裁定「移动过去不落焦那移动的意义是什么」,落焦成为跳屏的固定语义(ADR-0007 同日追加注记);设置面板合并回一行,`landsFocusKey` 与 `wantFocus` 判断整个删除 · **v3(同日,用户报「等启动的时候…换屏唤起闪截图中」)**:病根有两层 —— ① T86 首轮把 sweep 收成"仅光标屏";② 更深一层,**开局剪枝本来就只保语境屏的窗**,别屏窗的图拍了也被 `prune` 扔掉。修法:`Snapshotter.reapAlive()`(后台 bare-CGWindowList 全量保活剪枝,死窗条目本就不会被展示,剪枝只服务内存与在途批次作废,无需同步)替换 finishBegin/applyList 的同步语境屏剪枝;sweep 恢复全屏(启动+关面板)。实测:冷启动预拍 21 窗(两屏,原 14)、首次唤起缓存 25.8MB/21 张(原 14)、「在途批次作废」不再每局出现、关面板预拍 21 窗 |

| T88 | **卡片随窗自适应 + 截图去影子**(用户实拍微信登录窗:「非横置矩形窗口的,会显示成这样。怎么处理呢,根据窗口自适应?」)。病是两层:① **截图默认带窗口阴影** —— 一圈透明像素撑大画面、内容缩小浮中间,卡底色从透明区透出来 = 自绘窗四圈"大灰边"(运行时探得 `SCScreenshotConfiguration.ignoreShadows`(macOS 15+),在 macOS 26 截图路径置 true);② **卡是定尺** 196×122(1.61:1 横卡),竖窗必被裁或留边。修法:**卡高定死(122 基准),卡宽 = 122 × 窗口比例**,夹 [96, 264] 防极端竖条/横幅(`PanelMetrics.thumbWidth(aspect:)`,`thumbW` 退役)—— 卡片比例与截图比例按构造相等,`fill` 不再裁内容;连带改五处口径:`WindowRecord.aspect`(单一来源)、WindowThumb 四处宽度(卡/模糊层/芯片/文字截断)、`trayLayout`/`trayFitScale`/`previewContentSize` 从 count 定尺改为按**每张卡实际宽**(`maxRowWidth` 走查,分布与 thumbGrid 的 HStack 同一逻辑)、`resyncSelectionUnderPointer` 命中数学从定尺节距改累计宽走查(启动行顺带修正为真实格距 icon+iconGap)。trayMax 按"最宽组"预留的机制不变,只是数字来源变了 | `Inventory/Snapshotter.swift`(ignoreShadows)、`Inventory/WindowEnumerator.swift`(aspect)、`Design/PanelTokens.swift`(thumbWidth/夹限)、`Panel/PreviewPanelView.swift`、`Panel/PanelController.swift` | 构建 ✅ · **真机待用户实测**(微信登录窗为验收样张:应 = 竖卡满幅无灰边) | · 缩放口径坑:`trayFitScale` 的基准宽必须在 sessionCap=∞ 窗口**内**由 aspect 推,传入外部算好的宽会带着上一局的缩放 · 无窗 App 选中时 previewContentSize 仍返回 .zero(沿用旧卫兵)· **v2(同日真机实评「倒是适应了形状,但是这个留白的阴影边框是怎么回事」)**:形状适应了但右/下仍有留白 —— `ignoreShadows` 只关**系统**影子,自绘窗(微信登录窗)窗体 backing 本身比可见内容大一圈(圆角外圈/自绘影是画在窗里的透明像素)。修法 = **拍完做透明衬边裁切** `trimTransparentEdges`:8× 缩采样画进 RGBA 位图、扫 alpha(阈值 96,内容边缘全不透明 255 远高于烤进图里的软影)找内容包围盒、按盒裁原图;普通窗四边都有不透明内容 ⇒ 包围盒 = 全图,原样返回零开销;一切失败路径返回原图(宁可有边不裁错)。卡宽随之改**优先用截图自身比例**(占位中退回窗框比例,图与宽度同帧微调)。若实测发现衬边是不透明白像素(非透明),裁切会空转 —— 那就要换"边缘均色检测"的路子,待验 |

| T89 | **启动区尾格对称化**(用户实拍问「启动槽这个位置,边界合适吗」)。实测旧两格结构(分割线格 + 槽格)的三段间距:App→线 24pt / 线→点阵 38pt / 点阵→面板右缘 40pt(左缘才 26)—— 一路变宽,点阵视觉上漂向右缘,分割线没站在它分隔的两块的正中间。修法:分割线与点阵**合并为一整格尾格**(`entryTailWidth`),格内显式定位 `[半格][线][整格][点阵][半格]` ⇒ App→线 = 线→点 = iconGap(24),点阵右缘经负 padding 收边后恰贴 rowPadX(26 = 左缘);整格即悬停/点击目标,原分割线上那条"划过什么都不选中"的死区一并消失。`entrySlotWidth` 退役 | `Design/PanelTokens.swift`、`Panel/PanelView.swift`(entryTail)、`Panel/PanelController.swift`(contentSize) | 构建 ✅ · 真机截屏(HoldChord 按住 + screencapture 裁尾部放大)目视对称 ✅(像素级扫描因 stride/AA 噪声弃用,以构造保证为准) | 验证工具备忘:Tools/CaptureWindow.swift 在 macOS 15+ 编译失败(CGWindowListCreateImage 废弃),改用 `screencapture -x` + `sips -c` 裁切 · **v2(同日用户实拍「左右不对称」)**:v1 的点阵右缘 = 尾格尾半格 + rowPadX = 35.6pt,比线到两边(19.2)宽一档 —— 且真正数值口径是 iconGap = iconClearance(13)+ selectionOverflow(≈6.2)≈ 19.2,不是拍脑袋的 24。修法 = **尾部三点同距**:App→线 = 线→点 = 点→玻璃边 = iconGap;连带重构 padding 归属 —— 负 padding 收进 App 区内层 HStack(原先吃在整条上,连尾格右半格一起吃),水平内边距收进 iconStrip(左 rowPadX / 右随启动区 iconGap 或 rowPadX),body 只留竖直 padding(否则双重左边距),puck 挂在水平 padding **之前**(对齐第一枚图标而非玻璃边),contentSize 同步(尾格 + iconGap 右缘) |

| T90 | **⌘Q 退出 App 的"尾部诈尸"**(用户报:「cmd q 退出的应用,移除之后,会冒出在尾部,再重新唤起面板就没有了」)。病理:⌘Q 之后、进程真正退出之前的**善后期**,窗已关、进程还在,`rawGroups` 的"无窗应用"分支(T15)把这种 App 当成合法成员挂上条带尾部;下次唤起进程死透才消失。**NSWorkspace 没有"将要退出"的通知可订**(只有 did 系列,那时已死透;`NSRunningApplication` 也无 `isTerminating` 属性),所以用**窗口消失的时限豁免**:每次枚举记下"哪些 pid 此刻还有窗"(`lastWindowedAt`,锁 + 文件级全局,同幽灵窗日志模式);无窗分支里,距上次有窗不足 `windowlessProbation`(10s)的 pid 本局不进面板——覆盖 ⌘Q 善后期;真·无窗应用(启动就没窗)从没进过账本,照常即时出现,T15 语义不变。代价:手动关光所有窗的 App,入列晚 ~10s | `Inventory/WindowEnumerator.swift` | 构建 ✅ · 真机待用户实测(⌘Q 一个 App 后立刻唤起,尾部不应出现该 App) | 途中试错留档:曾用 `TerminatingApps` 通知记账方案,发现 willTerminate 通知不存在后废弃;`NSRunningApplication.isTerminating` 属性不存在 |
| T89 v3 | **尾格探索收尾(用户叫停:「就这样吧,你已经改了半个小时了,相关改动都撤回吧」)**。撤回 = **调试探针全部移除**(`T89Probe` GeometryReader 打点,临时代码不留);几何保持用户在 #42 截图里看到并接受的状态(探针实测:App→线 = 线→点 = 点→玻璃边 = k(iconGap),构造上三点同距)。这半小时的教训两条:① **远程截屏像素取证不可靠** —— 抗锯齿 + 半透明玻璃 + 背景干扰,同一布局两次测量能差 1 倍,布局真伪要用 **SwiftUI 自己报账**(GeometryReader 探针)或构造保证,不要跟像素较劲;② **重启必须验证进程代际** —— trace-run 后要核对 `ps` 的进程启动时间 > 构建时间,否则旧二进制会让你对着幻影调样式(#25/#26/#27/#40 四轮"不对称"全部来自 13:28 的僵尸进程) | `Panel/PanelView.swift`(探针移除)、`docs/tasks.md` | 构建 ✅ · 探针最终值:前距 7.3 / 线 1.0 / 后距 14.6 / 点阵 21.8(可见 16.4 居中)——半格修复后三点同距成立 | 用户口径:面板**整体**对称协调即可,不追单点像素;若用户仍觉得尾部不协调,下一步是加大点阵与玻璃边的视觉呼吸(设计题,不是几何题) |

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

## 2026-09-18 深夜:模型 C + 同根变形(0.18s)整体性能盘点(自动分析,数据来自真实使用)

范围:13:16 构建(v1.1,双系统 0.18s + 轻推淡切)上线后的真实使用 —— **29 次唤起、19 次 Tab 跨段**。

- **基线无一例外 P50 = 16.7ms**(所有会话满帧 60);
- 单次跨段主线程成本:中位 **15.6ms** / P90 22.7 / max 25.1 —— 一帧以内,动画本体是 CA 异步的;
- 长帧:集中在**唤起瞬间**(0.00–0.08s,改动前就有的账)+ **每次跨段 1–2 帧**(60–110ms);
  长会话长帧占比 3–6%,max 56–124ms;
- **无新崩溃**(13:16:05 那份 .ips 是"根部弹性 frame"方案的遗骸,该方案已回退封死);App 存活。

**结论**:同根变形对整体帧率无实质影响 —— 基线满帧,跨段尖峰可测但不累积、不恶化。
若要更省:① 时长 0.18 → 0.15;② FrameProbe 目前只打前 5 个长帧时间戳,无法把每帧归因,
深究前先给它加全量时间戳。
**未完成**:合成按键压测被 TCC 拦(辅助功能授权需人点),自动驱动没跑成 —— 授权后可补
长时压测(脚本思路:osascript ⌘Tab + debug.pinPanelOnRelease + Tab/↓/↑/Esc 循环)。

## 2026-09-18 深夜(续):自动化压测 —— 12 局 × 每局 2 次跨段 + ↓/↑ 跳段

方法:授权辅助功能后,CGEvent 合成按键真实驱动(⌘Tab 钉住 → 10×Tab → ↓ → ↑ → Esc),非模拟。

- **12 局全部完整走完**,无意外收场(12×「面板关闭」),P50 **全部 16.7ms**,P95 16.7–17.2ms;
- 长帧占比 **1–2%**(此前真实使用 3–6%)—— 轻推淡切(纯 transform)比整排横滑便宜一半;
- 单次跨段主线程:**中位 5.7ms / P90 9.2 / max 15.0**(横滑版是 15.6/22.7/25.1,近乎省 3 倍);
- 残余长帧 = ①唤起瞬间(固有)+ ②每次跨段 1–2 帧(玻璃材质逐帧重合成,固有);
  个别 max 尖峰 100–173ms,单发、不成串。

**结论**:同根变形 v1.1(0.18s + 轻推淡切)在自动化长压测下无帧率回归,越用越稳的担忧排除。
