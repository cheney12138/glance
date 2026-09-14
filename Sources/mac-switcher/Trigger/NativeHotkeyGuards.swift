import AppKit
import GlanceCore

/// 原生热键的**恢复守卫**。开关本身与"该关哪些"的知识在 `GlanceCore.NativeHotkeys`
/// (纯逻辑、可单测);这里只负责"什么时候必须把它还回去" —— 需要 AppKit 的那些口子。
///
/// 医疗事故备忘:关掉的是**系统级**热键,且效果跨进程退出持久化。App 没来得及恢复就走,
/// 用户的 ⌘Tab 会一直死着 —— 所以四个口子一个都不能少(见 `docs/adr/0005`)。
enum NativeHotkeyGuards {

    /// 装恢复守卫。**必须做全**:关的是系统级热键,App 没来得及恢复就走,用户的 ⌘Tab 会一直死着。
    ///
    /// 覆盖面:正常退出 → `willTerminate`;ObjC 异常 → `NSSetUncaughtExceptionHandler`;
    /// 信号 → `DispatchSourceSignal`;启动自愈(在 `HotkeyTapCenter.start()`)疗上次 `SIGKILL` 留下的伤
    /// —— SIGKILL 谁也拦不住,只能靠下次启动。
    ///
    /// 为什么用 GCD signal source 而不是 `signal(sig, fn)`:后者的处理器跑在**信号上下文**里,
    /// 那里调 SkyLight(一次同步 IPC)和 `print` 都不是 async-signal-safe —— 实测:写了 `signal()` 版本,
    /// 发 SIGTERM 后处理器**根本没跑**(进程直接没了,原生 ⌘Tab 留在关闭状态)。
    /// `signal(sig, SIG_IGN)` + source 的组合把处理器换到普通队列上执行,那里什么都能干。
    static func install() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            print("[T13] 正常退出:归还原生切换器热键")
            NativeHotkeys.restoreAll()
        }

        NSSetUncaughtExceptionHandler(emergencyRestoreAfterException)

        for sig in [SIGTERM, SIGINT, SIGHUP, SIGTRAP] {
            // 先屏蔽默认处置(否则进程在我们有机会恢复之前就死了),再挂 GCD 源接管
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NativeHotkeys.restoreAll()
                print("[T13] 收到信号 \(sig),已归还原生热键后退出")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// source 不持有就永远不会触发 —— 必须是活到进程结束的存储
    private static var signalSources: [DispatchSourceSignal] = []
}

/// 兜底恢复的入口写成**全局函数**而不是闭包:转成 C 函数指针的闭包不能捕获上下文,
/// 而 `NSSetUncaughtExceptionHandler` 要的正是 C 函数指针。
private func emergencyRestoreAfterException(_ exception: NSException) {
    NativeHotkeys.restoreAll()
    print("[T13] 未捕获异常,已归还原生热键:\(exception)")
}
