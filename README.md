# Glance

macOS 窗口级 App 切换器(产品名与工程名均为 Glance;bundle id 仍是 `com.cheney12138.macswitcher`——它是授权与偏好的锚,故意不改):
鼠标在哪块屏,就只看哪块屏的窗;选中哪扇窗,就只拉起哪扇窗。
术语见 `CONTEXT.md`,样式契约见 `design/brand-spec.md`(交互语义)与 `design/v4/design-system.md`
(面板视觉)、`design/settings-spec.md`(设置窗),决策见 `docs/adr/`。

任务索引(T 号、状态、证据):`docs/tasks.md`。

结构约定(模块怎么分、谁能引用谁、kernel 与 plumbing):`docs/architecture.md`,
校验器 `Tools/check-architecture.swift`;纯核在 `Packages/GlanceCore`(`swift test` 可跑)。

两套排查工具与手册:输入管线(事件 tap/合成按键)与视觉验证 —— `docs/debugging.md` + `Tools/`。

⚠️ **⌘Tab 接管用私有 SkyLight API 关系统 symbolic hotkey**(见 `docs/adr/0005`):这是**系统级**状态,
且跨进程退出持久化。动触发层时**必须保留** `NativeSwitcherHotkeys` 的四个兜底恢复口与启动自愈,
否则用户的 ⌘Tab 会被弄死;手动保险 = `Tools/NativeHotkeys.swift restore`。

## 开发

- Xcode 26+,macOS 14+ 部署目标。Personal Team 签名即可,不需要付费开发者账号。
- 调试循环:改代码 → `⌘R` → 双屏实测。日志在 `⇧⌘Y` 控制台。

### 签名先决(一次性,否则每次 ⌘R 都要重新授权)

TCC 授权锚在签名证书上。若 Team 为空,Xcode 会静默退到 ad hoc 裸签(cdhash 每次
编译都变 → 每次重新要权限)。先登录账号选上 Personal Team:

1. Xcode → `⌘,` → Accounts → `+` → 登录免费 Apple ID(证书自动生成到钥匙串)
2. 项目 → Glance target → Signing & Capabilities → Team → 选 Personal Team

## 权限重置(状态乱了时用)
```bash
tccutil reset Accessibility com.cheney12138.macswitcher
tccutil reset ScreenCapture com.cheney12138.macswitcher
```

两条都跑完重启 App,会重新走一遍授权引导。

## ⌘Tab 失灵了?(接管开关的副作用)
接管系统切换器关掉的是**系统级**热键,状态跨进程退出持久化。App 被强杀(Xcode 的 Stop、强制退出)时
来不及还原,⌘Tab 就会一直死着(此时 App 多半没在跑,`pgrep -fl Glance` 为空 —— **不是残留进程**)。
一条命令救回来:`swift Tools/NativeHotkeys.swift restore`。细节与开发纪律见 `docs/debugging.md` §13。
停 App 请用 `pkill -TERM Glance`,别用 Xcode 的 Stop(那是 SIGKILL,所有兜底都失效)。

## 二期决定(2026-09-13,从 AltTab/DockDoor 取所长)

- ✅ 做:T10 钉住毕业 → T11 选中项现拍 → T12 面板内 Q/W/M 窗口操作
- ❌ 撤:同 App 窗互跳(macOS 原生 `⌘\`` 已覆盖,不重复造)
- 👀 观望:应用黑名单、Dock 悬停预览(被咬计数积累,≥2 再立项)
- ✅ 补做:T13 ⌘Tab 篡位(用户答案曾被误读为"维持现状",实意=批准接管;tap HID 抢先,零系统副作用,App 退出原生即复活)
