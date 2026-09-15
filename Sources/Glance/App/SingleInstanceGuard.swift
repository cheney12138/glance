import AppKit

/// 单实例守卫:**多开一个 Glance 是灾难性的**,必须在碰触发层之前就拦住。
///
/// 病例(2026-09-14,用户实机排查一小时):Xcode 里 Run 了一个新实例,而旧实例还在跑 ——
/// 两个实例都装了 Carbon 热键与事件 tap,同一个 ⌘Tab 只有**先到**的那一个收得到;
/// 后到的那个照旧把面板画在自己的窗口里。于是用户看到:
///   · "app 周围一圈光晕" —— 其实是两块面板叠在一起,底色互相透;
///   · "Esc 要按两次才关" —— 第一发关了看不见的那一个,第二发才关看得见的这一个。
/// 单实例下完全不复现,所以这类现象极难从代码里读出来 —— 直接让它不可能发生。
///
/// 行为:发现同 bundle id 还有别的实例 → 打印一段能自解释的提示,然后 `exit(0)`。
/// 此时还没碰过 `NativeHotkeys` / 事件 tap(守卫在 `App.init` 里,装配之前),
/// 所以系统 ⌘Tab 一行没动,退出是干净的。
enum SingleInstanceGuard {
    static func enforce() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        guard let other = others.first else { return }

        let pid = other.processIdentifier
        print("""
        ────────────────────────────────────────────────
        [Glance] 已经有一个实例在跑(pid \(pid)),本次启动退出。
          两个 Glance 会抢同一组 ⌘Tab:先装触发层的那个收键,后到的那个照样画自己的面板 ——
          屏幕上会出现"两块面板叠在一起"的怪象(底色互相透、Esc 要按两次才关)。
          要换新构建:先退出旧实例(⌘Q,或 kill \(pid)),或在 Xcode 里 Stop 再 Run。
          确认还剩几个:`pgrep -fl Glance`
        ────────────────────────────────────────────────
        """)
        exit(0)
    }
}
