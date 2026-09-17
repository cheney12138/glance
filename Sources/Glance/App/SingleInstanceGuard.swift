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
        // **路径必须打出来**(2026-09-15):装过 DMG 之后再从 Xcode ⌘R,新实例会静默退出 ——
        // 用户只看到「Run 了但没反应」。写明是 /Applications 那份还是 DerivedData 那份,
        // 一眼就知道该退谁(两份 bundle id 相同,所以互相视为同一个 App)。
        let path = other.bundleURL?.path ?? "(路径未知)"

        // **时间也要打出来**(2026-09-17 用户报"没修好"):
        // 实测屏幕上那份是 **15 分钟前**的旧进程 —— Xcode 里按 ⌘R 起的新实例被这里挡掉、
        // 静默退出,于是"测试"跑的是旧代码。而原来的提示只有**路径**没有**时间**,
        // 日志里对不出这一点(我从这行旁边走过去两趟都没停 —— 有输出 ≠ 被读到)。
        // 现在直接给判决:旧实例比本次构建还早 ⇒ 屏幕上那份不是你刚改的。
        let stamp = DateFormatter()
        stamp.dateFormat = "MM-dd HH:mm:ss"
        let launchLine = "  旧实例起于: \(other.launchDate.map { stamp.string(from: $0) } ?? "(未知)")"
        var buildLine = "  本次二进制构建于: (未知)"
        if let exe = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
           let mtime = attrs[.modificationDate] as? Date {
            buildLine = "  本次二进制构建于: \(stamp.string(from: mtime))"
            if let launched = other.launchDate, launched < mtime {
                buildLine += "\n  ⚠️ 旧实例比本次构建还早 ⇒ 屏幕上跑的是**旧代码**,你刚改的东西没有上屏"
            }
        }
        print("""
        ────────────────────────────────────────────────
        [Glance] 已经有一个实例在跑(pid \(pid)):
          \(path)
        本次启动退出。
        \(launchLine)
        \(buildLine)
          两个 Glance 会抢同一组 ⌘Tab:先装触发层的那个收键,后到的那个照样画自己的面板 ——
          屏幕上会出现"两块面板叠在一起"的怪象(底色互相透、Esc 要按两次才关)。
          要换新构建:先退出旧实例(⌘Q,或 kill \(pid)),或在 Xcode 里 Stop 再 Run。
          确认还剩几个:`pgrep -fl Glance`
        ────────────────────────────────────────────────
        """)
        exit(0)
    }
}
