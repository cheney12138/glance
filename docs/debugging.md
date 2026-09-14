# 调试手册:输入管线与视觉验证

本项目的两类问题都不在"读代码就能看出来"的范围里:一类发生在**事件 tap 层**(看不见摸不着),
一类只有**真窗口合成之后**才显形。本文是这两类问题的复现与取证手册,工具在 `Tools/`。

## 0. 三条纪律(不遵守就会得到假结论)

1. **只留一个 Glance 实例**。多个实例会抢同一组 ⌘Tab(先装 tap 的那个吞掉,另一个什么都收不到),
   症状就是"时好时坏、像掉回系统切换器"。`pgrep -fl` 先数一遍,`Tools/InjectChord.swift` 每跑一次也会自动体检。
   ⚠️ Xcode 起的实例在调试器下 **`SIGTERM` 杀不掉**,要 `kill -9`。
2. **日志从终端拿,不要只看 Xcode 控制台**:`GLANCE_TRACE=1 <app 二进制> > /tmp/log 2>&1 &`
   —— 关键是能 `grep/awk` 统计("20 次连按丢了几次"就是这么数出来的)。
3. **改前/改后用同一节奏对比**(相同轮数 + 相同间隔),否则测的是噪声。

## 1. 输入管线:事件流水账

`GLANCE_TRACE=1` 打开事件级 trace(v1.13 起行缓冲,可以边跑边 grep):

```
[tap] flagsChanged kc=55 down=true state=idle          ← ⌘ 按下(只读 tap)→ armed
[tap] hotkey forward pressed state=armed               ← Carbon 热键收下 ⌘Tab → 开面板
[tap]   → emit begin
[tap] navKey kc=53                                     ← 导航期 Esc(会话期才开的 navTap)
[tap]   → emit cancel
```
三类来源要分清:**`hotkey …` = Carbon 触发键**(前台 App 收不到,不需要吞)、
**`flagsChanged` = 只读 tap 听修饰键**(hold 语义)、**`navKey` = 唯一有吞键权的 navTap**。
另有一条独立日志 `[T13] 原生热键:关 [1, 2] / 开 [6]` —— 记录系统 symbolic hotkey 的开/关状态。

两把尺子:

- **丢没丢**:`grep -c 'emit begin'` 对比你注入的轮数;`grep -c 'keyDown kc=48'` 看事件本身有没有到 tap(两者不一致 = 事件在到达前就没了)。
- **卡没卡**:两颗事件之间的 Δ 突然变大 = 主线程被占住(事件 tap 的 runloop 挂在主线程上)。

```bash
# 每颗事件与上一颗的间隔,超过 60ms 的打出来
grep '\[tap\] +' log | awk '{t=$3+0; if (prev && t-prev>60) printf "卡 %.0fms\n", t-prev; prev=t}'
```

## 2. 合成输入:`Tools/InjectChord.swift`

```bash
swift -target arm64-apple-macos14.0 Tools/InjectChord.swift 20 300          # 20 轮,间隔 300ms
swift -target arm64-apple-macos14.0 Tools/InjectChord.swift 10 200 --mod opt --key space
```
它做的事:在 **HID 层**(`.cghidEventTap`)注入 `修饰键↓ → 主键↓↑ → Esc↓↑ → 修饰键↑`。
对我们自己的 tap 来说,这与真键盘**完全同构** —— 这就是它能复现"用户连按"的原因。

- **每轮用 Esc 收尾**而不是松修饰键:Esc = 放弃,不聚焦任何窗,所以测完不会偷偷切走你的前台窗口。
- **需要给发起进程「辅助功能」权限**(终端/pi 通常已有)。没权限时 `post` 静默失效、什么都不发生。
- 注意:注入的事件**会堆在系统队列里**。杀掉实例后,队列里剩下的那几十颗会喂给**下一个**实例
  ——所以"上一个人测的余波"很容易被误读成本次的症状。测完等几秒,或先对着无人运行的窗口跑一次清队。
- **反复交互验证时,先把工具编成二进制**(2026-09-14 真实教训):`swift Tools/X.swift` 每次都要
  走一遍编译器启动(实测 **2~3 秒/次**)。一个"按 Tab → 查窗口 → 移动鼠标 → 截图"的循环里
  夹着五六个这种调用,十几秒就没了 —— 而长按开面板的寿命只有 30~40s,于是截图全部落在
  "面板已经退场"之后,还很容易误判成"改动没生效"。编一次、后面毫秒级:
  ```bash
  swiftc -O -target arm64-apple-macos14.0 Tools/CaptureWindow.swift -o /tmp/cw
  ```
- **算鼠标坐标不如量鼠标坐标**:托盘的卡片位置一旦用"内容原点 + 内边距"手算,很容易差一两粒
  灯的位置(我为此错了三轮)。可靠做法:限定在托盘窗口框内**扫像素找系统色圆点**(红 #FF5F57 /
  黄 #FEBC2E / 绿 #28C840),重心就是点击点。扫整屏会被终端里的 ANSI 彩色文字污染,必须
  先用 `CaptureWindow list` 拿托盘帧(`layer=100`)把范围卡住。
- **注入突然全面失灵,先查锁屏/安全输入**(2026-09-14 真实跳过一小时):屏幕锁住或任何 App 开了
  Secure Input 时,系统会**丢掉合成键盘事件**(鼠标移动仍然有效,所以很容易误判成"注入坏了但权限还在"):
  ```bash
  ioreg -l -w 0 | grep -o '"CGSSessionScreenIsLocked"=[A-Za-z]*'   # 锁屏
  screencapture -x /tmp/probe.png                                   # 锁屏时直接失败(最快的判据)
  ```
  当时的现象:我们的 flags tap 照样收得到注入的 ⌥ 按下/松开,**但 Carbon 热键一发不响**,
  连系统原生 ⌘Tab 也不再弹出「程序坞」—— 两个观察一串就定位到"事件根本没到输入系统",
  而不是 Glance 的注册坏了。顺带说:合成 ⌘Tab **能**打进 Carbon 热键(已验证),
  所以之前那次"合成按键进不了 Carbon"的结论是错的,错因就是锁屏。

## 3. 视觉验证:四种手段,各自能干什么

| 手段 | 能验 | 验不了 | 权限 |
|---|---|---|---|
| **离屏渲染**(`ImageRenderer` / `NSView.cacheDisplay`) | 布局、token 落地、明暗两态 | ① AppKit 单独画的**焦点环**;② `ImageRenderer` 把 `ScrollView` 渲成**空白** | 无 |
| **per-window 截图**(`CaptureWindow shot`) | 普通窗(终端/编辑器)内容完整 | **玻璃面截出来是全空的**(见下) | 无(自己的窗口) |
| **整屏裁剪**(`shot --screen`) | 玻璃 + 它背后的内容,所见即所得 | 依赖录屏权限;窗口被别的窗遮住就截到遮挡物 | 需要「屏幕录制」 |
| **进程内自截探针**(App 内临时代码) | **唯一**能验 `isKey`、焦点环这类"只有真窗口有"的东西 | 要改代码,必须删干净 | 无(截自己) |

### 3.1 玻璃面 per-window 截图是全空的(实测)

```
$ swift -target arm64-apple-macos14.0 Tools/CaptureWindow.swift shot --owner Glance --out /tmp/panel.png
窗口: id=182301  Glance layer=101 alpha=1.00 1257x314 @(291,398)
写出: /tmp/panel.png  2514x628px(2.0x,即 1257x314pt)
⚠️  1024 个探测点全透明:要么发起进程缺「屏幕录制」权限,要么这是玻璃面(玻璃在进程外合成)
```
这不是权限问题,是**物理事实**:玻璃由窗口服务器在**进程外**合成,不在我们的层树里 ——
与 `design-system.md` v1.11 那条"glass 混不进进程外合成"是同一件事,只是这次显形在截图路径上。
同一个命令截终端窗口就有内容(采样能读到 `#1F3125` 这种真颜色)。
**玻璃面要 `--screen`**,走 `screencapture -R`,拿到的是合成后的屏幕:

```bash
swift -target arm64-apple-macos14.0 Tools/CaptureWindow.swift shot --owner Glance --screen --out /tmp/glass.png --sample 120,150
```

### 3.2 采样像素:验"设计 token 到底落地没有"

`--sample x,y`(单位 pt,量的是**窗口内容**坐标,原点是窗口左上)直接读回颜色。
实际用它定过两件事:棱镜边确实在 `y=39..41pt`;窗口底部那条白边在 `y≥480pt` 之后(即内容区只有 480,窗口 512)。

### 3.3 进程内自截探针(用完必须删)

只有它能验"key window 才画的东西"。写法:`CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution])`,
由 App 自己在 `onAppear` 之后延时调一次,写 PNG 后 `NSApp.terminate`。
**注意**:该 API 在 macOS 15 起被标为 obsoleted(编译期报错),但 App 的部署目标是 14.0,仍然可用。

## 4. 进程与窗口侧的小抄

- **诡异现象先数实例数**(2026-09-14 用户实机踩一小时):两个 Glance 会抢同一组 ⌘Tab ——
  先装触发层的那个收键,后到的那个**照样画自己的面板**。于是症状是"两块面板叠在一起":
  底色互相透(看起来像"app 在发光")、Esc 要按两次才关(第一发关了看不见的那个)。
  单实例下完全不复现,所以从代码里读不出来。现在 `App/SingleInstanceGuard.swift` 会在
  `App.init`(早于任何触发层装配)拦住第二个实例并打印原因;诊断时用
  `pgrep -fl mac-switcher` 确认。

```bash
pgrep -fl 'mac-switcher.app/Contents/MacOS/mac-switcher'   # 数实例;带 NSDocumentRevisionsDebugMode 的是 Xcode 那个
kill -9 <pid>                                              # 调试器下 SIGTERM 无效
swift -target arm64-apple-macos14.0 Tools/CaptureWindow.swift list Glance   # 面板:owner=Glance,layer=101(长条)/100(托盘)
```
菜单栏那枚图标在窗口清单里挂在 **"控制中心"** 名下(layer=25),不是 Glance —— 找它是找不到的。

## 5. 三个真实病例(这套工具怎么用)

| 病例 | 用到的工具 | 结论 |
|---|---|---|
| ⌘Tab 用着用着变成 macOS 原生切换器 | `GLANCE_TRACE` + `InjectChord` | `begin` 后主线程被占 ~110ms(枚举压在 tap 回调里),tap 被判超时停用,而停用时交回的那颗事件被原样放行 → 修复见 design-system Changelog v1.12 |
| 设置窗左上角一个蓝框 | 进程内自截探针 | 离屏渲染永远干净(焦点环抓不到),真窗口一截就现形:SwiftUI 把第一个可聚焦控件点成聚焦态 |
| 设置窗比 demo 高 32pt、底部一条白边 | 探针 + `--sample` | 窗口 = 内容 480 + 系统标题栏 32;纸只铺了内容区 |

## 6. 与 Xcode 自带工具的分工

| 想干的事 | Xcode/Apple 路线 | 本手册路线 |
|---|---|---|
| 看 UI 长什么样 | SwiftUI `#Preview` | 离屏渲染 / 真窗口截图(Preview 没有真窗口,白边、焦点环这类验不了) |
| 驱动输入 | XCUITest | `Tools/InjectChord.swift`(不用搭 test target,且专门打全局热键这一层) |
| 看日志 | Console.app / `log stream` | `GLANCE_TRACE=1` + grep/awk(能统计,不是只能眼看) |
| 看卡在哪 | LLDB / Instruments | 事件间隔 Δ(先判断"是不是我们的回调在卡"),再上 Instruments 细剖 |

## 7. "⌘Tab 现在归谁" —— 唯一可信的实测口径

接管走的是系统 symbolic hotkey(`docs/adr/0005`),这个开关**没有 getter**,所以只能看行为:

```bash
# 终端 A:按住 ⌘Tab 三秒(用 Esc 收尾,不切走前台窗口)
swift -target arm64-apple-macos14.0 Tools/HoldChord.swift 3

# 终端 B:期间反复抓窗口清单 —— 有没有「程序坞」那一个
swift -target arm64-apple-macos14.0 Tools/CaptureWindow.swift list | grep 程序坞
```

**默认态就是"热键开着、⌘Tab 归系统"**(接管要用户在设置里显式开启,见 `docs/adr/0005`);
只有在设置里打开了"接管系统切换器"之后,下面这几条才有意义:

- 出现 `程序坞 layer=20 1920x1080`(全屏那个)= **原生切换器在**,即热键是开着的;
- 只有 `Glance layer=101/100` = 热键被我们关着,⌘Tab 归 Glance;
- 两个都没有 = 热键被关着但 Glance 没接住(App 没跑 / 权限没给)。

手动保险与 A/B 工具:

```bash
swift -target arm64-apple-macos14.0 Tools/NativeHotkeys.swift restore   # 全部打开:把 ⌘Tab 还给系统
swift -target arm64-apple-macos14.0 Tools/NativeHotkeys.swift disable   # 只关 ⌘Tab+⌘⇧Tab(A/B 用)
```

**为什么需要手动保险**:App 关的是**系统级**热键,效果**跨进程退出持久化**。App 走完兜底
(正常退出 / 信号 / 异常)会自己还原,但 `SIGKILL` 谁也拦不住 —— 那种情况下 ⌘Tab 会一直死着,
直到下次启动 App(它启动时先自愈)。这条命令是最后的保险。

## 8. 参考:成熟项目(AltTab)的做法

同一条问题,他们的解 = 本项目的 v1.13 架构,原始出处:

| 事项 | AltTab | 我们 |
|---|---|---|
| 屏蔽原生 ⌘Tab | `CGSSetSymbolicHotKeyEnabled(1, false)`,配对关 `2`;⌘` 是 `6` | 同(`Trigger/NativeSwitcherHotkeys.swift`) |
| 触发键 | Carbon `RegisterEventHotKey`(`GetEventDispatcherTarget()`,免权限) | 同(含 ⇧ 反向那一发) |
| 主 tap | `.cgSessionEventTap` + `.listenOnly` + **只订阅 `flagsChanged`** | 同(听修饰键,撑 hold 语义) |
| 会吞键的 tap | 只有一个,只吞 Esc,且**创建即禁用**、仅会话期开启(#5766:常开的 HID keyDown tap 弄坏过越南语 EVKey) | 同思路,吞的是 Esc/←→/Q/W/M |
| 恢复责任 | 退出 + `SIGTERM/SIGTRAP/SIGINT/SIGHUP` + `NSSetUncaughtExceptionHandler` + `_exit`;启动自愈 | 同(`DispatchSourceSignal`,见 ADR-0005 里"信号处理器为什么不能用 `signal()`") |
| 主线程纪律 | `CGSCallScheduler` 等三条后台车道 + `src/main-thread-ipc.md` 审计 + `AGENTS.md` 硬规矩 | 我们只把**枚举**搬了后台(`PanelController.begin`),没有配套车道与审计 |
| kernel 测试 | 58 个 `*Tests.swift` + 每个 kernel 一份 `Specs.md` | **0 个测试**(欠账) |
