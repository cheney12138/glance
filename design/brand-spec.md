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
- 展开:选中停留即出(0ms 延迟,缩略图预截),长在本应用图标下方的**内嵌**预览行(v0 拍板,不采用 DockDoor 式独立浮条)
- 选中仲裁:鼠标 hover 与键盘 ←→ 皆为"谁最后动听谁的",hover 即选中不确认。**精确定义:静止的指针不发声**——面板在指针下方出现时,指针自出现起没位移(>1pt)就不算发言,键盘正常走;一旦位移,hover 立即夺回选中(实机修订:静止悬停曾把 ⌘Tab 拽死在原地)
- 上下文:鼠标光标所在屏 = 当前屏;窗口归属 = 与屏幕几何交集占比最大的屏,占比 <20% 不算数
- 首次高亮:最近访问窗口所属 App(MRU 语义)

## Token 冻结表(HTML ↔ 原生翻译表)

| 语义 | HTML 图纸值 | 原生等价物 |
|---|---|---|
| 背板材质 | `rgba(244,244,246,.62)` + `blur(40px) saturate(1.8)` | `NSVisualEffectView`,material `.underWindowBackground` 或 `.hudWindow`,state `.active`;深/浅色自动,**不要手写色** |
| 背板圆角 | 16px | `layer.cornerRadius = 16` |
| 背板阴影 | `0 12px 40px rgba(0,0,0,.18)` + 0.5px 发丝描边 | `NSShadow`(offset -12, blur 40, alpha .18)+ 半像素边框 layer |
| App 名 | 13px SF Pro、`.label` 色、背板顶中 | `NSTextField` font `.systemFont(ofSize:13)`,`.labelColor` |
| 图标 | 64×64,macOS squircle | `NSRunningApplication.icon`(真实图标,施工期注入) |
| 图标容器 | 80×80,圆角 12 | 同 |
| 选中块 | `rgba(255,255,255,.55)` 半透明 | SwiftUI `RoundedRectangle(12).fill(.white.opacity(0.35))`(深色下近似,施工时校准) |
| 缩略卡 | 宽 **320**、标题行 22px 高 11px 字、图片区 16:10(200pt)、圆角 8 | 同(宽度 240→320:T6 实机校准,240 在文字密集场景不可读) |
| 卡片选中 | 2px 白环 + 0.5px 外发丝 | `StrokeBorder` 双层;深色下用 `.white.opacity(0.9)` 主环 |
| 卡片标题 | 窗口标题(项目名 — 文件) | 单行行省略 `.truncatingTail` |
| 发丝线 | 0.5px `rgba(0,0,0,.06)` | `Color(.separatorColor)` |

## 动效(冻结,全部禁止回弹)

| 动作 | 时长 | 曲线 |
|---|---|---|
| 面板弹出 | 120ms | easeOut(近似 cubic-bezier(0.2,0.8,0.2,1)),scale .96→1 + 透明 |
| 预览行弹出 | 80ms | ease-out,translateY -5→0 |
| 选中切换 | 100ms | ease(块透明度过渡) |

`prefers-reduced-motion` 原生等价:`NSWorkspace.accessibilityDisplayShouldReduceMotion` → 三档动效全部降到 0。

## 不做清单(冻结,防范围蔓延)

- 不做实时流缩略(只预截单帧)
- 不做跨 Space / 不做挂死 App 抢救 / 不做注意力仲裁引擎
- 不做卡片上的关闭/最小化按钮(面板是切换器,不是窗口管理器)
- 不做皮肤系统与自定义主题(token 只有一份,深浅两态)
- 预览行超过 6 张时折出箭头——数量上限 6 为暂定值,施工期可以再调
