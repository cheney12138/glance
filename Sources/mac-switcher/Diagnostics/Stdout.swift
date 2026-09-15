import Foundation
import Darwin

/// 把 stdout 切成行缓冲 —— 必须在**进程最开始**做,晚一步就没意义。
///
/// 病:重定向到文件时 Swift 的 `print` 是全缓冲的,`GLANCE_TRACE=1 … > log` 会一个字都看不到
/// (实测:进程活着时 log 是 0 字节,启动那几行要等到缓冲区满或进程退出才吐出来),
/// 而 `docs/debugging.md` 里那套工作流的全部意义就是"边跑边 grep"。
///
/// 写法说明:全局 `let` 是惰性初始化的 —— 光声明不会执行,必须在 App 启动路径上**碰它一下**
/// (`MacSwitcherApp.init()` 里那句 `_ = stdoutIsLineBuffered`)。
let stdoutIsLineBuffered: Void = {
    if isTraceEnabled {
        setvbuf(stdout, nil, _IOLBF, 0)
    }
}()


/// 输入管线日志的**统一时间戳**(毫秒,相对进程启动)。
///
/// 为什么需要(2026-09-14):用户报"指针选窗大概有 0.5s 延迟",而日志里没有时间 ——
/// 这种"晚了多少毫秒"的毛病,没有时间戳就只能靠感觉争论(本仓库的老规矩:先让它可观测,再改)。
/// 只在事件级/选中级的几行上用;不要撒到所有日志上,否则真正的信号会被淹掉。
private let glanceLogStart = CFAbsoluteTimeGetCurrent()

func glog(_ line: String) {
    // **打印本身要花主线程**:trace 全开时导航期每次按键会打三五行,而输出端是 Xcode 控制台
    // (或管道)—— 写一行可能几毫秒。`[工] 键盘换选中` 里剩下的十几毫秒很可能就是它,
    // 而不是被量的那段代码。这里量一次(前 50 行),把这条账钉下来。
    let t0 = traceCostProbe ? CFAbsoluteTimeGetCurrent() : 0
    print(String(format: "[%7.0fms] %@", (CFAbsoluteTimeGetCurrent() - glanceLogStart) * 1000, line))
    if traceCostProbe { glogCostAccumulate(CFAbsoluteTimeGetCurrent() - t0) }
}

/// 前 50 行的总耗时(见 `glog`)。累加与统计都放文件级。
/// 注意:不做并发保护 —— 只在 trace 模式下计数,计数本身不影响正确性,漏几次也无所谓。
private let traceCostProbe = isTraceEnabled
nonisolated(unsafe) private var glogTotal: CFAbsoluteTime = 0
nonisolated(unsafe) private var glogCount = 0
private func glogCostAccumulate(_ dt: CFAbsoluteTime) {
    glogTotal += dt
    glogCount += 1
    if glogCount == 50 {
        print(String(format: "[工] 日志开销:前 50 行共 %.1fms(单行 %.2fms)—— 量 `[工]` 时把这部分减掉",
                     glogTotal * 1000, glogTotal / 50 * 1000))
    }
}

/// 事件级 / 帧级诊断的**总开关**(全 App 唯一来源)。两个入口:
///   ① 环境变量 `GLANCE_TRACE=1` —— 终端起 App 的常规姿势(见 `docs/debugging.md` §1),
///      也是 Xcode 里加 Run scheme 环境变量的写法;
///   ② `defaults write com.cheney12138.macswitcher debug.trace -bool true` —— **不想动 Xcode 时用**,
///      改完重开 App 生效。与仓库既有的几个调试旋钮(`debug.pinPanelOnRelease`、`switch.captureApps`)同一路子。
///
/// 之前这段判断在 7 个文件里各写一遍,而且**口径不一致**:多数是"变量存在即开",
/// `FrameProbe` 却是 `== "1"` —— 于是 `GLANCE_TRACE=yes` 会出现"事件流水账有、帧数据没有"的怪现象。
/// 现在收敛成一个,顺带把不一致治掉。
/// 全局 `let` 只求值一次:这些开关都在事件热路径上问,不能每次去读环境或 UserDefaults。
let isTraceEnabled: Bool = {
    if let v = ProcessInfo.processInfo.environment["GLANCE_TRACE"],
       !v.isEmpty, v != "0", v.lowercased() != "false" {
        return true
    }
    return UserDefaults.standard.bool(forKey: "debug.trace")
}()
