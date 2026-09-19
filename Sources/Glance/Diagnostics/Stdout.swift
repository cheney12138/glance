import Foundation
import Darwin

/// 把 stdout 切成行缓冲 —— 必须在**进程最开始**做,晚一步就没意义。
///
/// 病:重定向到文件时 Swift 的 `print` 是全缓冲的,`GLANCE_TRACE=1 … > log` 会一个字都看不到
/// (实测:进程活着时 log 是 0 字节,启动那几行要等到缓冲区满或进程退出才吐出来),
/// 而 `docs/debugging.md` 里那套工作流的全部意义就是"边跑边 grep"。
///
/// 写法说明:全局 `let` 是惰性初始化的 —— 光声明不会执行,必须在 App 启动路径上**碰它一下**
/// (`GlanceApp.init()` 里那句 `_ = stdoutIsLineBuffered`)。
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

/// 进程相对时刻(ms),与 glog 行首的 `[ NNNms]` 同一口径 —— 给探针类诊断做**对时**用:
/// 帧账里的长帧落在哪些毫秒,直接和事件流水账里的行对齐,谁在长帧那刻干活一目了然
func glanceUptimeMs() -> Double {
    (CFAbsoluteTimeGetCurrent() - glanceLogStart) * 1000
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

/// trace 开着时,把进程自己的 stdout 落到**固定文件** —— 不再依赖"它是怎么被启动的"。
///
/// 病例(2026-09-15):诊断期日志的落点一直取决于启动方式 ——
/// Xcode 起 → 在调试器控制台;终端起 → 绑在那个 tty 上(实测 `/dev/ttys011`)。
/// 后者别人读不到,只能人肉复制上千行;而用户用的终端是 Ghostty,**连 AppleScript 读 scrollback 这条后路都没有** ✗。
/// 于是干脆让进程自己写:只要 trace 开着,stdout 就重定向到
/// `~/Library/Logs/Glance/trace.log`(追加),终端那边只留一行提示 —— 提示走 stderr,不进这个文件。
///
/// 单文件上限 5MB:诊断日志是"最近一次测试"用的,不是档案
/// (同机另一个调试日志长到 164MB,没人看得动)。
func mirrorStdoutToLogFileIfTracing() {
    guard isTraceEnabled else { return }
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Glance", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("trace.log")
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int, size > 5_000_000 {
        try? FileManager.default.removeItem(at: url)
    }
    freopen(url.path, "a", stdout)
    setvbuf(stdout, nil, _IOLBF, 0)
    // 本地时间:上一版直接打 `Date()`,机器上打出来是 **09:47** 而实际是 **17:47** ——
    // 读日志的人会怀疑自己看错了 ✗(日志是给人读的,时间的时区不能让人去换算)
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "zh_CN"); fmt.dateFormat = "MM-dd HH:mm:ss"
    print("──────── 新一次启动 \(fmt.string(from: Date())) \(TimeZone.current.identifier) ────────")
    FileHandle.standardError.write("Glance trace 日志 → \(url.path)\n".data(using: .utf8)!)
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
