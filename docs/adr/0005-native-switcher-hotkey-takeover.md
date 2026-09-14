# ADR-0005:⌘Tab 接管改用系统 symbolic hotkey,不再靠事件 tap 吞键

状态:已采纳(2026-09-14,v1.13)
相关:`design/v4/design-system.md` Changelog v1.12 / v1.13、`docs/debugging.md`、`Sources/mac-switcher/Trigger/`

## 背景

T13 的"接管系统切换器(⌘Tab)"一直是在**事件层**实现的:装一个 destructive 的 HID `keyDown` tap,
把所有 ⌘Tab 吞掉,让系统原生切换器收不到。

这条路的失败模式很贵(实机病例见 Changelog v1.12):tap 的回调挂在主 runLoop 上,主线程一忙
(枚举窗口、建面板、首帧)回调就被推后;超过系统阈值会被判超时停用 tap,而**停用那一瞬交回来的
那颗事件一旦放行,⌘Tab 就落到 macOS 原生切换器手里** —— 用户看到的就是"用着用着变成原生那个"。

为了守住"一颗都不漏",我们陆续加了:枚举搬后台、超时那颗粒吞掉、开启判定改用事件 flags、
退场拆迁单带世代号、tap 挪独立线程……每一层都对,但**防线本身就是那个 tap**,
所以任何一层失效都会退化成"⌘Tab 不是我的了"。

## 决定

**前置裁决(用户评审):这个禁用逻辑只能是用户显式开启的,默认不许用。**
触发键默认仍是 ⌥Tab,一行系统设置都不碰。实现上分两层:

- 新增显式开关 `trigger.takeoverSystemSwitcher`(默认 false),设置页那个"接管系统切换器(⌘Tab)"
  开关读写它 —— **不再由"触发键恰好是 ⌘Tab"反推**;
- `NativeSwitcherHotkeys.plan(for:takeover:)` 要求 **①开关为真 且 ②触发键与系统热键真的重叠** 才动手;
- 老版本的遗留状态(键写成 ⌘Tab 但没有这个开关)在启动时**归一**:清掉触发键、回到 ⌥Tab、系统热键还回去
  (`HotkeyTapCenter.normalizeLegacyTakeoverState`);
- 反过来,在设置里**录制**到与系统热键重叠的和弦(⌘Tab / ⌘`)时,自动把开关置位 —— 否则原生那条会在
  Dock/WindowServer 层就把事件吃掉,我们注册的 Carbon 热键根本收不到。开关会跟着亮起来,用户看得见。


参考 AltTab(生产环境多年、同一个问题的成熟解),改成**在系统快捷键注册表层解决**:

1. **用私有 SkyLight API 关掉原生 symbolic hotkey**:
   `CGSSetSymbolicHotKeyEnabled(kCGSymbolicHotKeyCommandTab = 1, false)`,并按配对规则
   连 `commandShiftTab = 2` 一起关(不关它,原生反向切换器照旧会弹);⌘`(`commandKeyAboveTab = 6`)
   在键位重叠时才关。见 `NativeSwitcherHotkeys.plan`(纯函数,确定性)。
2. **触发键改走 Carbon `RegisterEventHotKey`**:系统直接把这一和弦交给我们,前台 App 收不到
   —— 于是**根本不需要吞**(`GetEventDispatcherTarget()` 还免掉了辅助功能权限这一道)。
3. **tap 收缩成三块各司其职的**:
   - `flagsTap`:`.cgSessionEventTap` + `.listenOnly` + `flagsChanged` —— 只听修饰键,撑 hold 语义,
     永不吞键(AltTab 的主 tap 就是这个配置;#5766 的血案是"常开的 HID keyDown tap 弄坏了第三方输入法");
   - `mouseTap`:`.listenOnly` + `leftMouseDown` —— ⌘+点击补焦的耳朵,只听不吞;
   - `navTap`:`.cghidEventTap` + `.defaultTap` + `keyDown` —— **唯一有吞键权的那个**,创建即禁用,
     只在导航态打开(吞 Esc/←→/Q/W/M)。它的生死与"⌘Tab 归谁"**无关**,所以它被系统停用也不会
     再引发原生切换器登场。

## 代价二:触发键的"循环移动"不能靠 Carbon 热键

实机病(用户第一轮反馈):⌘Tab 唤起了面板,但**继续按 Tab 不动**。

病因:同一个和弦按住期间,系统**不会重复投递** `kEventHotKeyPressed` —— 按住 ⌘ 连按 Tab 只来第一发。
所以:

- Carbon 热键只负责**开局那一发**(`handleHotKey` 里 `guard state != .navigating`);
- 导航期的"继续按 Tab / ⇧Tab"循环移动归 **navTap**(它本来就在会话期收 keyDown);
- 这样也顺手避免了"Carbon 重复投递 + navTap 各动一次"的双跳。

## 后果

**赚**:v1.12 那一整类"漏键 → 原生切换器接管"的失败模式在结构上消失;tap 只剩一块破坏性面,
而且只在几百毫秒的会话里存在;输入法兼容性跟着变好。

**赔(必须兜住)**:我们接管了**系统级**状态,而且这个状态**跨进程退出持久化**
(AltTab 注释原话:"the effect of enabling/disabling persists after the app is quit")。

- 恢复责任做全:`applicationWillTerminate`(正常退出)、`NSSetUncaughtExceptionHandler`(ObjC 异常)、
  `DispatchSourceSignal`(SIGTERM/SIGINT/SIGHUP/SIGTRAP)、**启动自愈**(疗上次 `SIGKILL` 留下的伤);
- `SIGKILL` 谁也拦不住 —— 那种情况下用户的 ⌘Tab 会一直死着,**直到下次启动 Glance**
  (或跑一次 `Tools/NativeHotkeys.swift restore`,那是手动保险);
- 私有 API:`SkyLight` 未公开、可能随时变。判断:AltTab 用了这么多年没坏,
  坏了的退路是把 git 历史里的 v1.12 吞键方案拿回来(代码与病例都还在);
- 信号处理器改用 GCD signal source 而不是 `signal(sig, fn)`:后者跑在信号上下文里,
  调 SkyLight(同步 IPC)不安全,而且**日志会丢**——实测 `signal()` 版本恢复成功了却一行都没打出来,
  害我误判成"处理器根本没跑"。

**遗留简化**:三块 tap 仍挂在主 runLoop(参考实现把 tap 挪到了独立线程)。v1.13 之后这个差别的
代价只剩"回调晚一点" —— 不再影响 ⌘Tab 归属(触发走 Carbon),所以先不搬;真要再压输入延迟再说。

**开发纪律(改触发层的人必读)**:
1. 别删 `restoreAll()` 与四个兜底口 —— 删了就是把用户的 ⌘Tab 弄死;
2. 别在会话之外新增 destructive tap,也别把 `navTap` 改成常开;
3. 验证按 `docs/debugging.md` 第 7 节做:"按住 ⌘Tab 看有没有「程序坞」窗口"是这件事唯一的实测口径。
