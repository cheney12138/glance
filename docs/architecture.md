# 架构约定

> 本文是"代码放哪儿、谁能引用谁"的唯一约定。风格契约见 `design/`,决策见 `docs/adr/`,术语见 `CONTEXT.md`。
> **可执行**:`swift Tools/check-architecture.swift`(有违例非零退出)。

## 0. 一条主线:kernel 与 plumbing 分家

| | 是什么 | 住哪儿 | 怎么验证 |
|---|---|---|---|
| **kernel** | 不 import AppKit/SwiftUI 的纯逻辑(解析、裁决、几何、状态机) | `Packages/GlanceCore`(本地 SPM 包) | `swift test` |
| **plumbing** | 窗口、视图、事件 tap、观察者、AX/CGS 调用 | App target,越薄越好 | 真机实测(`docs/debugging.md`) |

**判据只有一句:这个文件 import AppKit 吗?要,它就不是 kernel。**

为什么值得这么分:本项目最贵的 bug 全在输入管线(病例见 `design-system.md` Changelog v1.12/v1.13),
而它们当时**一点都测不了** —— 只能真机连按 + 抓窗口清单 + 猜。分家之后,这类规则可以先写成测试:
`NativeHotkeysTests` 里那几条(不开开关不许动系统热键、配对规则、确定性)就是第一批。

## 1. 模块图(目录即模块)

| 模块 | 职责 | 一句话边界 |
|---|---|---|
| `App/` | 入口、场景、窗口装配 | 唯一允许把各模块绑在一起的地方 |
| `Design/` | 视觉 token(度量/色板/阴影/动效策略)+ UI 原语(玻璃、图标) | 规格唯一来源;**不碰业务** |
| `Diagnostics/` | 日志与事件流水账(`GLANCE_TRACE`) | 谁都能用,谁也不依赖 |
| `Trigger/` | 输入管线:Carbon 热键注册、事件 tap、把事件喂给核 | **不许碰面板/设置** —— 通过闭包接线 |
| `Inventory/` | 窗口与 App 的清点(枚举、MRU 证据、预截) | 只管"有什么" |
| `Panel/` | 切换器面板本体(控制器 + 主视图 + 预览托盘 + 语境屏) | 只管"怎么呈现与选择" |
| `Focus/` | 落点(聚焦窗口、⌘+点击补焦) | 只管"怎么把窗口拉起来" |
| `Settings/` | 设置窗(store + view + 控件 + 主题) | 只管偏好读写与呈现 |
| `Permissions/` | 权限门禁与引导 | 只管 TCC 两件事 |
| `Packages/GlanceCore/` | 纯核(见上) | 只许 Foundation/CoreGraphics/Carbon |

## 2. 依赖方向

```
App ──► Panel / Settings / Trigger / Permissions / Inventory / Focus / Design / Diagnostics
Panel ──► Design · Inventory · Focus · Trigger(仅 Action 词表)
Settings ──► Design · Permissions · GlanceCore
Trigger / Inventory / Focus / Permissions / Design / Diagnostics ──► GlanceCore(或自己)
```

两条硬规矩:

1. **只能向下**,`Design/` 与 `Diagnostics/` 谁都不许引(它们是叶子);
2. **跨模块协作走闭包或 App 层装配**,不许 type 级硬引。范例:`Trigger` 不认识 `Panel` ——
   面板在 `App/` 里把 `onAction` 闭包交给它(`mac_switcherApp.swift` 那几行就是全部接线)。
   这样输入管线可以单独测、单独换(我们刚换过一次:吞键 → 系统 symbolic hotkey)。

禁引表在 `Tools/check-architecture.swift` 里,**改边界要同时改那份表**。

## 3. 最常走的四条路

- **加面板特性** → `Panel/` 视图 + `PanelController` 状态;有纯逻辑就进 `GlanceCore` 并配测试。
- **加输入规则** → 先看 `GlanceCore` 里的裁决函数(`NativeHotkeys.plan` 是模板:纯函数、依赖显式传入、
  不读全局状态),改 kernel + 加测试,再让 `Trigger/` 的 plumbing 接上。
- **加设置项** → `Settings/`;UserDefaults 的键要明确三件事:**默认值**、谁有权改、旧值怎么迁移
  (范例:`TriggerConfig.takeoverEnabled` 默认 false + `HotkeyTapCenter.normalizeLegacyTakeoverState` 归一)。
- **加视觉 token** → 只进 `Design/PanelTokens.swift`;视图里不许出现裸数值。

## 4. 文件与命名

- 一个文件一个概念;文件内用 `// MARK:` 分节(度量 / 色板 / 动效 / 视图 / …)。
- 注释写 **为什么** 和 **病例**(哪台机器、什么现象、量到的数字),不写"这里做了什么" ——
  本仓库最值钱的东西就是这批病例。
- 新文件先问两句:*它 import AppKit 吗?*(→ 放哪个模块)*它属于本文的哪一行?*(→ 答不上来就别加)。

## 5. 改完必跑的三件事

```bash
swift Tools/check-architecture.swift                    # 边界
cd Packages/GlanceCore && swift test                     # 纯核
xcodebuild -project mac-switcher.xcodeproj -scheme mac-switcher -configuration Debug build
```

行为改动(输入管线、视觉)还要按 `docs/debugging.md` 实测 —— 编译通过不代表 ⌘Tab 还归你。

## 6. 迁移路线(下一个该抽的 kernel)

现在核里只有"配置解析"与"该关哪些系统热键"两块。按收益排序,接下来该抽的是:

1. **输入状态机**(`HotkeyTap.swift` 的 `machineState` 转移)→ `GlanceCore.HotkeyStateMachine`:
   `(state, event, config, pinPanel) → (新状态, 动作[], 吞不吞)`。这一轮连修的三个 bug
   (漏一颗 ⌘↓ 就整局失守 / 超时那颗粒放行 / Carbon 不重复投递导致 Tab 不动)全都能被它钉成测试。
2. **窗口归属几何**(`WindowEnumerator.ownsByContextScreen` + `quartzFrame`)→ 纯函数:双屏/跨屏是最容易错的地方,
   而且它现在跟 AX/CGS 调用缠在一起,没法单独验。
3. **MRU 排序**(`MruEvidence.ordered`)→ 纯函数(输入是 pid 序列,输出是顺序)。
