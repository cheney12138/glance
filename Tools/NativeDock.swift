// 原生 Dock 自动隐藏状态的只读检查、手动接管模拟与应急复原。
//
//   swift Tools/NativeDock.swift status    # 只读查看当前 com.apple.dock 的 autohide 与 autohide-delay
//   swift Tools/NativeDock.swift restore   # 归还原生 Dock（优先按备份快照精确还原，否则取消 autohide 并删除 delay）
//   swift Tools/NativeDock.swift hide      # 手动模拟接管（autohide=true, autohide-delay=1000.0 并重启 Dock）
//
// 为什么需要这个工具：App 接管原生 Dock 时写入的是持久化系统偏好（com.apple.dock）。
// 若 App 被 SIGKILL 或极端异常退出而未能走到兜底恢复，原生 Dock 会一直保持 1000s 延迟隐藏 ——
// 这条命令是最后的手动应急保险（详见 ADR-0018）。

import Foundation

private let dockDomain = "com.apple.dock" as CFString
private let appDomain = "com.cheney12138.macswitcher" as CFString
private let autohideKey = "autohide" as CFString
private let autohideDelayKey = "autohide-delay" as CFString
private let snapshotKey = "dock.nativeSnapshot" as CFString
private let takeoverDelaySeconds: Double = 1000.0

private struct DockSnapshot: Codable {
    let autohide: Bool?
    let autohideDelay: Double?
}

private func readDockAutohide() -> Bool? {
    guard let raw = CFPreferencesCopyAppValue(autohideKey, dockDomain) else { return nil }
    if let b = raw as? Bool { return b }
    if let n = raw as? NSNumber { return n.boolValue }
    return nil
}

private func readDockAutohideDelay() -> Double? {
    guard let raw = CFPreferencesCopyAppValue(autohideDelayKey, dockDomain) else { return nil }
    if let n = raw as? NSNumber { return n.doubleValue }
    return nil
}

private func readSavedSnapshot() -> (rawPresent: Bool, snapshot: DockSnapshot?) {
    guard let raw = CFPreferencesCopyAppValue(snapshotKey, appDomain) else {
        return (false, nil)
    }
    let data: Data?
    if let d = raw as? Data {
        data = d
    } else if let s = raw as? String {
        data = s.data(using: .utf8)
    } else {
        data = nil
    }
    guard let data else { return (true, nil) }
    return (true, try? JSONDecoder().decode(DockSnapshot.self, from: data))
}

private func formatOptional<T>(_ value: T?) -> String {
    value.map { "\($0)" } ?? "<未设置 (nil)>"
}

private func printStatus() {
    let autohide = readDockAutohide()
    let delay = readDockAutohideDelay()
    let (hasRawSnapshot, snapshot) = readSavedSnapshot()
    let looksTakenOver = (autohide == true) && ((delay ?? 0) >= 999.0)

    print("com.apple.dock 当前状态:")
    print("  autohide       = \(formatOptional(autohide))")
    print("  autohide-delay = \(formatOptional(delay))")
    print("  接管态判定     = \(looksTakenOver ? "疑似已被 Glance 接管隐藏" : "正常")")
    if let snapshot {
        print("  备份快照       = 存在 (autohide=\(formatOptional(snapshot.autohide)), autohideDelay=\(formatOptional(snapshot.autohideDelay)))")
    } else if hasRawSnapshot {
        print("  备份快照       = 存在但无法解析")
    } else {
        print("  备份快照       = 无")
    }
}

private func restartDock() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    task.arguments = ["Dock"]
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            fputs("警告: killall Dock 退出码 \(task.terminationStatus)\n", stderr)
        }
    } catch {
        fputs("错误: 无法重启 Dock: \(error.localizedDescription)\n", stderr)
    }
}

private func restoreDock() {
    let (hasRawSnapshot, snapshot) = readSavedSnapshot()
    if let snapshot {
        if let autohide = snapshot.autohide {
            CFPreferencesSetAppValue(autohideKey, autohide ? kCFBooleanTrue : kCFBooleanFalse, dockDomain)
        } else {
            CFPreferencesSetAppValue(autohideKey, nil, dockDomain)
        }
        if let delay = snapshot.autohideDelay {
            CFPreferencesSetAppValue(autohideDelayKey, NSNumber(value: delay), dockDomain)
        } else {
            CFPreferencesSetAppValue(autohideDelayKey, nil, dockDomain)
        }
        CFPreferencesAppSynchronize(dockDomain)
        CFPreferencesSetAppValue(snapshotKey, nil, appDomain)
        CFPreferencesAppSynchronize(appDomain)
        restartDock()
        print("已按备份快照精确还原原生 Dock: autohide=\(formatOptional(snapshot.autohide)), autohide-delay=\(formatOptional(snapshot.autohideDelay))")
    } else {
        if hasRawSnapshot {
            fputs("警告: 发现 dock.nativeSnapshot 但无法解码，改用默认恢复策略。\n", stderr)
        }
        CFPreferencesSetAppValue(autohideDelayKey, nil, dockDomain)
        CFPreferencesSetAppValue(autohideKey, kCFBooleanFalse, dockDomain)
        CFPreferencesAppSynchronize(dockDomain)
        restartDock()
        print("未找到可用快照，已将原生 Dock 恢复为默认显示状态: autohide=false, autohide-delay=<已删除>")
    }
}

private func hideDock() {
    CFPreferencesSetAppValue(autohideKey, kCFBooleanTrue, dockDomain)
    CFPreferencesSetAppValue(autohideDelayKey, NSNumber(value: takeoverDelaySeconds), dockDomain)
    CFPreferencesAppSynchronize(dockDomain)
    restartDock()
    print("已模拟接管隐藏原生 Dock: autohide=true, autohide-delay=\(takeoverDelaySeconds)")
}

switch CommandLine.arguments.dropFirst().first {
case "status":
    printStatus()
case "restore":
    restoreDock()
case "hide":
    hideDock()
default:
    print("""
    用法: swift Tools/NativeDock.swift <status|restore|hide>
      status   只读打印当前 com.apple.dock 的 autohide 与 autohide-delay
      restore  归还原生 Dock（优先按 com.cheney12138.macswitcher 的 dock.nativeSnapshot 精确还原，
               否则删除 autohide-delay 并将 autohide 设为 false 后重启 Dock）
      hide     手动模拟接管（设置 autohide=true、autohide-delay=1000.0 并重启 Dock）
    """)
}
