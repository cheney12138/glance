# ADR-0010:分发接受"首次手动放行",不买 $99 公证

**状态**:已采纳(2026-09-16)
**相关**:ADR-0002(私有 API 隔离与降级)、README「Download / Installing / Updating」、`Tools/make-cask.sh`、tap:`cheney12138/homebrew-tap`

## 背景

App 签名但**未公证**(没有 Apple Developer 账号,$99/年)。用户实测首次打开被拦两次:
1. 弹窗「**未打开"Glance"**」——只有「完成」与「移到废纸篓」两个按钮
   (macOS 15 起已移除右键 ▸ 打开);
2. 真正的放行入口在 **系统设置 ▸ 隐私与安全性 ▸ 「仍要打开」**。

曾寄望"换一条免费的分发渠道就能绕开",**实测全部失败**(Homebrew 7.0.1):
- `brew install --cask` 装出来的 app **带** `com.apple.quarantine`(agent = `Homebrew Cask`);
- `--no-quarantine` 选项**已不存在**(`Error: invalid option`);
- `HOMEBREW_NO_QUARANTINE` 环境变量**无效**(help 中 0 处提及,设置后仍带标记);
- `spctl -a -t exec -vv` ⇒ `rejected`。

⇒ quarantine + rejected = **必然拦截**。渠道无关,它由签名决定。

## 决定

**接受首次安装需要用户手动放行一次**,并把这一步写在用户一定会看到的地方
(README「Installing」+ cask 的 `caveats`,brew 装完会自动打印)。**不买公证**。

## 后果

- 痛**只有一次**:Sparkle 自更新走的是 App 自己下载的文件,不会被隔离
  ⇒ 第二次起与正常 App 无异。
- 我们因此**不追求**"陌生用户零摩擦安装"。若哪天需要零摩擦(公开推广、进 `homebrew/cask`
  官方仓库),触发重新评估的条件是:**$99 的成本 < 摩擦造成的流失**。届时应重新评估本 ADR,
  而不是继续在分发渠道上找技巧 —— 那个方向已经实测走死。
- 教训(值得记住):**"换个渠道就能绕过系统策略"是一个常见幻觉**。这类问题要先问
  "拦住我的到底是什么机制",而不是"别人是怎么装的"。
