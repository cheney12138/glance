# mac-switcher

macOS 窗口级 App 切换器:鼠标在哪块屏,就只看哪块屏的窗;选中哪扇窗,就只拉起哪扇窗。
术语见 `CONTEXT.md`,样式契约见 `design/brand-spec.md`,决策见 `docs/adr/`。

## 开发

- Xcode 26+,macOS 14+ 部署目标。Personal Team 签名即可,不需要付费开发者账号。
- 调试循环:改代码 → `⌘R` → 双屏实测。日志在 `⇧⌘Y` 控制台。

### 签名先决(一次性,否则每次 ⌘R 都要重新授权)

TCC 授权锚在签名证书上。若 Team 为空,Xcode 会静默退到 ad hoc 裸签(cdhash 每次
编译都变 → 每次重新要权限)。先登录账号选上 Personal Team:

1. Xcode → `⌘,` → Accounts → `+` → 登录免费 Apple ID(证书自动生成到钥匙串)
2. 项目 → mac-switcher target → Signing & Capabilities → Team → 选 Personal Team

## 权限重置(状态乱了时用)
```bash
tccutil reset Accessibility com.cheney12138.macswitcher
tccutil reset ScreenCapture com.cheney12138.macswitcher
```

两条都跑完重启 App,会重新走一遍授权引导。

## 二期决定(2026-09-13,从 AltTab/DockDoor 取所长)

- ✅ 做:T10 钉住毕业 → T11 选中项现拍 → T12 面板内 Q/W/M 窗口操作
- ❌ 撤:同 App 窗互跳(macOS 原生 `⌘\`` 已覆盖,不重复造)
- 👀 观望:应用黑名单、Dock 悬停预览(被咬计数积累,≥2 再立项)
- ✅ 补做:T13 ⌘Tab 篡位(用户答案曾被误读为"维持现状",实意=批准接管;tap HID 抢先,零系统副作用,App 退出原生即复活)
