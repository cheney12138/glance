# App Switcher 面板 · 设计规格冻结(v0 定案)

> 本文件是设计与原生施工之间的唯一契约。样式争议一律回到本文件,不回代码、不回 HTML。
> HTML 图纸:`design/v0/App Switcher 面板 v0.html`(验收:形态+动画节奏;毛玻璃质感以原生为准)
> 锚:macOS 原生 ⌘Tab / DockDoor CmdTab enhancement / apple-hig 配方

## Design Read(冻结)

```yaml
artifact: 系统级浮层面板
visual-language: macOS 原生 ⌘Tab
mode: greenfield
visual-variance: 2/10      # 不做风格变体
motion-intensity: 2/10     # 只有弹出与选中切换两种动效
information-density: 4/10
brand-fidelity: 9/10       # 违例即丑:禁渐变/禁品牌色/禁 emoji 图标
```

## 交互语义(冻结)

- 触发:`⌥` 按下只待命(不弹面板——裸按⌥是高频动作);**首次 `⌥+Tab` 击键才进入导航态**;此后 `Tab` 后移 / `⇧+Tab` 前移;释放 `⌥` = 确认聚焦;`Esc` = 放弃(T3 施工时修正:原稿"⌥按下即弹"会误伤所有 ⌥+拖拽/⌥+点击场景)
- 移动权责:`Tab`/指针移动在 **App 间**;`←→` 只在**展开层的窗之间**——组内 ≤1 窗时 `←→` 无语义,静默吞掉,绝不允许跨界滑到邻 App(实机评审拍板)
- 展开(v0.2 修订,推翻 v0 的"内嵌"决定):预览为**独立浮窗**,与 App 长条分容器;预览框中心**正对选中 App 图标头顶**,横向超界时收进语境屏;选中 App 只显示 App 图标,窗口≤0 组(无窗应用)不弹预览
- 无窗应用(v0.2):全系统零可见窗的已打开 App 纳入切换器,**不划分显示器分组**;确认 = 激活该 App(不级联窗口归它自己管)
- 选中仲裁:鼠标 hover 与键盘 ←→ 皆为"谁最后动听谁的",hover 即选中不确认。**精确定义:静止的指针不发声**——面板在指针下方出现时,指针自出现起没位移(>1pt)就不算发言,键盘正常走;一旦位移,hover 立即夺回选中(实机修订:静止悬停曾把 ⌘Tab 拽死在原地)
- 上下文:鼠标光标所在屏 = 当前屏;窗口归属 = 与屏幕几何交集占比最大的屏,占比 <20% 不算数
- 首次高亮:最近访问窗口所属 App(MRU 语义)

## Token 冻结表(HTML ↔ 原生翻译表)

| 语义 | HTML 图纸值 | 原生等价物 |
|---|---|---|
| 背板材质 | v0.2:更轻更亮(治"灰蒙蒙") | `NSVisualEffectView` material `.popover`,state `.active`,圆角 20;深/浅色自动 |
| 背板阴影 | 柔软的散开阴影 | SwiftUI `.shadow(radius: 25, y: 8, opacity 0.16)` |
| App 名 | **15px medium**,与图标层 20pt 呼吸 | 同左 |
| 图标 | **72×72**,macOS squircle + 柔软下落影 | `NSRunningApplication.icon`(真实图标) |
| 图标容器 | v0.2"无形容器":**84×84**,格距 **20** | 同左 |
| 选中托底 | **极轻灰**(light 黑 6% / dark 白 8%),不描边 | SwiftUI `RoundedRectangle(18).fill(.primary.opacity(0.08))` |
| 预览浮窗 | 独立 NSPanel,中心正对选中 App 头顶,语境屏内 clamp | 同左 |
| 缩略卡 | 宽 320、图片区 16:10(200pt)、圆角 12;**无标题文字**,左上角叠加 macOS 红绿灯(#FF5F57/#FEBC2E/#28C840) | 同左 |
| 卡片选中 | **原生聚焦蓝环**(白卡 + 白描边不可见的实机教训):accent 2px + 白 3.5px 衬底;未选 = 0.5px 发丝 | 同左 |
| 发丝线 | 0.5px `rgba(0,0,0,.06)` | `Color(.separatorColor)` |

## 动效(冻结,全部禁止回弹)

| 动作 | 时长 | 曲线 |
|---|---|---|
| 面板弹出 | **无(瞬现)** | — |
| 预览行弹出 | **无(瞬现)** | — |
| 选中切换 | 100ms | ease(块透明度过渡) |

**v1.12 裁决:入场动效全部下线。** 面板与预览托盘一律瞬现,只有退场保留淡出
(退场在动作之后,不在关键路径上)。理由 = 效率:⌘Tab 是高频动作,任何"登场"都是把
可用时间往后拖;实机量到入场每会期要多占主线程一截,而事件 tap 的 runloop 就挂在主线程上
(详见 `design/v4/design-system.md` Changelog v1.12)。

`prefers-reduced-motion` 原生等价:`NSWorkspace.accessibilityDisplayShouldReduceMotion` → 三档动效全部降到 0。

## 不做清单(冻结,防范围蔓延)

- 不做实时流缩略(只预截单帧)
- 不做跨 Space / 不做挂死 App 抢救 / 不做注意力仲裁引擎
- 不做卡片上的关闭/最小化按钮(面板是切换器,不是窗口管理器)
- 不做皮肤系统与自定义主题(token 只有一份,深浅两态)
- 预览行超过 6 张时折出箭头——数量上限 6 为暂定值,施工期可以再调
