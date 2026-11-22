import AppKit
import Carbon
import Foundation
import GlanceCore

/// 顶层诊断报告采集器（位于 `App/` 组装根，合规读取各子系统状态并输出严格脱敏 JSON）。
///
/// 纪律：
/// - `Settings` 禁引 `HotkeyTapCenter` / `WindowEnumerator` 等模块 ⇒ 由 `GlanceApp` 通过闭包注入本采集器；
/// - 绝不采集窗口标题、截图、用户名路径或第三方 App 名称。
@MainActor
enum DiagnosticCollector {

    static func buildJSON(permissions: PermissionMonitor, hotkeys: HotkeyTapCenter) -> String {
        let report = collect(permissions: permissions, hotkeys: hotkeys)
        return DiagnosticReportEncoder.encode(report, pretty: true)
    }

    static func defaultFileName(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return "glance-diag-\(fmt.string(from: now)).json"
    }

    private static func collect(permissions: PermissionMonitor, hotkeys: HotkeyTapCenter) -> DiagnosticReport {
        let proc = ProcessInfo.processInfo
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ring = DiagnosticRingBuffer.shared.snapshot()

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withTimeZone]
        iso.timeZone = .current

        let os = proc.operatingSystemVersion
        let osVer = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let osBuild = sysctlString("kern.osversion") ?? "?"
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif

        let thermal: String = {
            switch proc.thermalState {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }()

        let meta = DiagnosticReport.Meta(
            generatedAt: iso.string(from: Date()),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            pid: proc.processIdentifier,
            uptimeSec: (glanceUptimeMs() / 100.0).rounded() / 10.0,
            osVersion: osVer,
            osBuild: osBuild,
            arch: arch,
            cpuCount: proc.processorCount,
            memGB: Int((Double(proc.physicalMemory) / 1_073_741_824.0).rounded()),
            thermalState: thermal,
            lowPowerMode: proc.isLowPowerModeEnabled,
            reduceMotion: MotionPolicy.systemReduced,
            secureEventInput: IsSecureEventInputEnabled(),
            dirtyExitRecovered: ring.dirtyExitRecovered
        )

        let runtime = DiagnosticReport.RuntimeState(
            axGranted: permissions.accessibilityGranted,
            screenCaptureGranted: permissions.screenCaptureGranted,
            permissionGateOpen: hotkeys.permissionGateOpen,
            taps: hotkeys.diagnosticTapState,
            threeFingerActive: ThreeFingerTap.shared.isDiagnosticActive
        )

        let mainID = NSScreen.main?.displayNumber
        let displays: [DiagnosticReport.DisplayInfo] = NSScreen.screens.map { s in
            let id = s.displayNumber ?? 0
            return DiagnosticReport.DisplayInfo(
                id: id,
                isMain: id != 0 && id == mainID,
                frame: [Double(s.frame.origin.x), Double(s.frame.origin.y),
                        Double(s.frame.width), Double(s.frame.height)],
                visibleFrame: [Double(s.visibleFrame.origin.x), Double(s.visibleFrame.origin.y),
                               Double(s.visibleFrame.width), Double(s.visibleFrame.height)],
                scale: Double(s.backingScaleFactor),
                maxFps: s.maximumFramesPerSecond
            )
        }

        let ud = UserDefaults.standard
        let trigger = TriggerConfig.load()
        let moveWin = TriggerConfig.loadMoveWindow()
        let config = DiagnosticReport.ConfigState(
            appearance: ud.string(forKey: AppearancePreference.key) ?? AppearancePreference.auto,
            windowLayout: ud.string(forKey: Keys.panelWindowLayout) ?? KeyDefaults.windowLayout,
            livePreviewTier: ud.string(forKey: Keys.livePreviewTier) ?? "20",
            triggerKeyCode: Int(trigger.keyCode),
            triggerModifier: trigger.modifierSymbol,
            takeoverSystemSwitcher: TriggerConfig.takeoverEnabled,
            takeoverGrave: (ud.object(forKey: Keys.triggerTakeoverGraveCyclesWindows) as? Bool) ?? KeyDefaults.takeoverGraveCyclesWindows,
            moveWindowKeyCode: Int(moveWin.keyCode),
            moveWindowModifier: moveWin.modifierSymbol,
            digitPicksApp: Keys.digitPicksApp,
            includeMinimized: Keys.includeMinimized,
            threeFingerTap: (ud.object(forKey: Keys.pointerThreeFingerTapPanel) as? Bool) ?? KeyDefaults.threeFingerTapPanel,
            fourFingerTap: (ud.object(forKey: Keys.pointerFourFingerTapLaunchRing) as? Bool) ?? KeyDefaults.fourFingerTapLaunchRing,
            doubleOptionJumps: (ud.object(forKey: Keys.pointerDoubleOptionJumps) as? Bool) ?? KeyDefaults.doubleOptionJumps,
            pinOnRelease: (ud.object(forKey: Keys.panelPinOnRelease) as? Bool) ?? KeyDefaults.pinOnRelease,
            alwaysAnimate: (ud.object(forKey: Keys.motionAlwaysAnimate) as? Bool) ?? KeyDefaults.alwaysAnimate,
            summonPop: (ud.object(forKey: Keys.panelSummonPop) as? Bool) ?? KeyDefaults.summonPop,
            hapticEnabled: (ud.object(forKey: Keys.hapticEnabled) as? Bool) ?? HapticPolicy.enabledDefault,
            hapticStrength: ud.string(forKey: Keys.hapticStrength) ?? "medium",
            counts: DiagnosticReport.ListCounts(
                ringBlacklist: DockAppsProvider.listCount(forKey: Keys.ringBlacklist),
                launchWhitelist: DockAppsProvider.listCount(forKey: Keys.launchWhitelist),
                launchBlacklist: DockAppsProvider.listCount(forKey: Keys.launchBlacklist)
            ),
            activeDebugFlags: DebugFlags.heavySwitches.filter { $0.isOn }.map { $0.name }
        )

        let hangAndCrash = collectHangAndCrash(homePath: home)

        return DiagnosticReport(
            meta: meta,
            runtime: runtime,
            displays: displays,
            config: config,
            counters: ring.counters,
            recentSessions: ring.sessions,
            recentEvents: ring.events,
            hangAndCrash: hangAndCrash
        )
    }

    private static func collectHangAndCrash(homePath: String) -> DiagnosticReport.HangAndCrashInfo {
        let fm = FileManager.default

        let marker: String? = (try? String(contentsOfFile: "/tmp/glance-hang-marker.txt", encoding: .utf8))
            .map { DiagnosticRedactor.redact($0.trimmingCharacters(in: .whitespacesAndNewlines), homePath: homePath) }

        var stackHead: [String] = []
        if let rawSample = try? String(contentsOfFile: "/tmp/glance-hang.txt", encoding: .utf8) {
            let lines = rawSample.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            stackHead = DiagnosticRedactor.redactLines(lines, maxLines: 40, homePath: homePath)
        }

        var crashes: [DiagnosticReport.CrashSummary] = []
        let reportsDir = URL(fileURLWithPath: homePath).appendingPathComponent("Library/Logs/DiagnosticReports")
        if let files = try? fm.contentsOfDirectory(at: reportsDir,
                                                   includingPropertiesForKeys: [.contentModificationDateKey],
                                                   options: [.skipsHiddenFiles]) {
            let glanceIPS = files
                .filter { $0.lastPathComponent.hasPrefix("Glance") && $0.pathExtension == "ips" }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
            for url in glanceIPS.prefix(3) {
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   let parsed = DiagnosticIPSParser.parse(fileName: url.lastPathComponent,
                                                          content: text,
                                                          maxFrames: 15,
                                                          homePath: homePath) {
                    crashes.append(parsed)
                }
            }
        }

        let traceURL = URL(fileURLWithPath: homePath).appendingPathComponent("Library/Logs/Glance/trace.log")
        let traceBytes = (try? fm.attributesOfItem(atPath: traceURL.path)[.size] as? Int)

        return DiagnosticReport.HangAndCrashInfo(
            watchdogMarker: marker,
            watchdogStackHead: stackHead,
            crashReports: crashes,
            traceLogBytes: traceBytes
        )
    }

    private static func sysctlString(_ key: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

private extension NSScreen {
    var displayNumber: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
