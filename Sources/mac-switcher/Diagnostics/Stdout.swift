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
    if ProcessInfo.processInfo.environment["GLANCE_TRACE"] != nil {
        setvbuf(stdout, nil, _IOLBF, 0)
    }
}()
