import Foundation

/// 面向崩溃与性能排障的机器可读诊断报告（纯核模型 + 脱敏器 + Apple `.ips` 崩溃日志摘要解析）。
///
/// 纪律：
/// - 绝不包含窗口标题、URL、截图、用户个人目录名或第三方 App 名称；
/// - JSON 字段保持稳定、扁平、可被 `jq` / Python / AI 代理直接消费。
public struct DiagnosticReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let meta: Meta
    public let runtime: RuntimeState
    public let displays: [DisplayInfo]
    public let config: ConfigState
    public let counters: HealthCounters
    public let recentSessions: [SessionMetric]
    public let recentEvents: [DiagnosticEvent]
    public let hangAndCrash: HangAndCrashInfo

    public init(schemaVersion: Int = 1,
                meta: Meta,
                runtime: RuntimeState,
                displays: [DisplayInfo],
                config: ConfigState,
                counters: HealthCounters,
                recentSessions: [SessionMetric],
                recentEvents: [DiagnosticEvent],
                hangAndCrash: HangAndCrashInfo) {
        self.schemaVersion = schemaVersion
        self.meta = meta
        self.runtime = runtime
        self.displays = displays
        self.config = config
        self.counters = counters
        self.recentSessions = recentSessions
        self.recentEvents = recentEvents
        self.hangAndCrash = hangAndCrash
    }

    public struct Meta: Codable, Equatable, Sendable {
        public let generatedAt: String
        public let appVersion: String
        public let build: String
        public let pid: Int32
        public let uptimeSec: Double
        public let osVersion: String
        public let osBuild: String
        public let arch: String
        public let cpuCount: Int
        public let memGB: Int
        public let thermalState: String
        public let lowPowerMode: Bool
        public let reduceMotion: Bool
        public let secureEventInput: Bool
        public let dirtyExitRecovered: Bool

        public init(generatedAt: String, appVersion: String, build: String, pid: Int32,
                    uptimeSec: Double, osVersion: String, osBuild: String, arch: String,
                    cpuCount: Int, memGB: Int, thermalState: String, lowPowerMode: Bool,
                    reduceMotion: Bool, secureEventInput: Bool, dirtyExitRecovered: Bool) {
            self.generatedAt = generatedAt
            self.appVersion = appVersion
            self.build = build
            self.pid = pid
            self.uptimeSec = uptimeSec
            self.osVersion = osVersion
            self.osBuild = osBuild
            self.arch = arch
            self.cpuCount = cpuCount
            self.memGB = memGB
            self.thermalState = thermalState
            self.lowPowerMode = lowPowerMode
            self.reduceMotion = reduceMotion
            self.secureEventInput = secureEventInput
            self.dirtyExitRecovered = dirtyExitRecovered
        }
    }

    public struct TapState: Codable, Equatable, Sendable {
        public let flags: Bool
        public let mouse: Bool
        public let nav: Bool

        public init(flags: Bool, mouse: Bool, nav: Bool) {
            self.flags = flags
            self.mouse = mouse
            self.nav = nav
        }
    }

    public struct RuntimeState: Codable, Equatable, Sendable {
        public let axGranted: Bool
        public let screenCaptureGranted: Bool
        public let permissionGateOpen: Bool
        public let taps: TapState
        public let threeFingerActive: Bool

        public init(axGranted: Bool, screenCaptureGranted: Bool, permissionGateOpen: Bool,
                    taps: TapState, threeFingerActive: Bool) {
            self.axGranted = axGranted
            self.screenCaptureGranted = screenCaptureGranted
            self.permissionGateOpen = permissionGateOpen
            self.taps = taps
            self.threeFingerActive = threeFingerActive
        }
    }

    public struct DisplayInfo: Codable, Equatable, Sendable {
        public let id: UInt32
        public let isMain: Bool
        /// `[x, y, width, height]`
        public let frame: [Double]
        /// `[x, y, width, height]`
        public let visibleFrame: [Double]
        public let scale: Double
        public let maxFps: Int

        public init(id: UInt32, isMain: Bool, frame: [Double], visibleFrame: [Double],
                    scale: Double, maxFps: Int) {
            self.id = id
            self.isMain = isMain
            self.frame = frame
            self.visibleFrame = visibleFrame
            self.scale = scale
            self.maxFps = maxFps
        }
    }

    public struct ListCounts: Codable, Equatable, Sendable {
        public let ringBlacklist: Int
        public let launchWhitelist: Int
        public let launchBlacklist: Int

        public init(ringBlacklist: Int, launchWhitelist: Int, launchBlacklist: Int) {
            self.ringBlacklist = ringBlacklist
            self.launchWhitelist = launchWhitelist
            self.launchBlacklist = launchBlacklist
        }
    }

    public struct ConfigState: Codable, Equatable, Sendable {
        public let appearance: String
        public let windowLayout: String
        public let livePreviewTier: String
        public let triggerKeyCode: Int
        public let triggerModifier: String
        public let takeoverSystemSwitcher: Bool
        public let takeoverGrave: Bool
        public let moveWindowKeyCode: Int
        public let moveWindowModifier: String
        public let digitPicksApp: Bool
        public let includeMinimized: Bool
        public let threeFingerTap: Bool
        public let fourFingerTap: Bool
        public let doubleOptionJumps: Bool
        public let pinOnRelease: Bool
        public let alwaysAnimate: Bool
        public let summonPop: Bool
        public let hapticEnabled: Bool
        public let hapticStrength: String
        public let counts: ListCounts
        public let activeDebugFlags: [String]

        public init(appearance: String, windowLayout: String, livePreviewTier: String,
                    triggerKeyCode: Int, triggerModifier: String, takeoverSystemSwitcher: Bool,
                    takeoverGrave: Bool, moveWindowKeyCode: Int, moveWindowModifier: String,
                    digitPicksApp: Bool, includeMinimized: Bool, threeFingerTap: Bool,
                    fourFingerTap: Bool, doubleOptionJumps: Bool, pinOnRelease: Bool,
                    alwaysAnimate: Bool, summonPop: Bool, hapticEnabled: Bool,
                    hapticStrength: String, counts: ListCounts, activeDebugFlags: [String]) {
            self.appearance = appearance
            self.windowLayout = windowLayout
            self.livePreviewTier = livePreviewTier
            self.triggerKeyCode = triggerKeyCode
            self.triggerModifier = triggerModifier
            self.takeoverSystemSwitcher = takeoverSystemSwitcher
            self.takeoverGrave = takeoverGrave
            self.moveWindowKeyCode = moveWindowKeyCode
            self.moveWindowModifier = moveWindowModifier
            self.digitPicksApp = digitPicksApp
            self.includeMinimized = includeMinimized
            self.threeFingerTap = threeFingerTap
            self.fourFingerTap = fourFingerTap
            self.doubleOptionJumps = doubleOptionJumps
            self.pinOnRelease = pinOnRelease
            self.alwaysAnimate = alwaysAnimate
            self.summonPop = summonPop
            self.hapticEnabled = hapticEnabled
            self.hapticStrength = hapticStrength
            self.counts = counts
            self.activeDebugFlags = activeDebugFlags
        }
    }

    public struct HealthCounters: Codable, Equatable, Sendable {
        public var sessionsOpened: Int = 0
        public var sessionsConfirmed: Int = 0
        public var sessionsCancelled: Int = 0
        public var axSlowOver50ms: Int = 0
        public var axMaxMs: Double = 0
        public var slpsDegrades: Int = 0
        public var slpsVerifyFallbacks: Int = 0
        public var tapDisabledTimeout: Int = 0
        public var tapDisabledUserInput: Int = 0
        public var tapReattaches: Int = 0
        public var secureInputFallbacks: Int = 0
        public var threeFingerFires: Int = 0
        public var threeFingerDragCancels: Int = 0
        public var threeFingerRevives: Int = 0
        public var watchdogStalls: Int = 0

        public init() {}
    }

    public struct SessionMetric: Codable, Equatable, Sendable {
        public let tMs: Int
        public let label: String
        public let totalMs: Double
        public let cpuMs: Double
        public let waitMs: Double
        public let steps: [String: Double]
        public var frames: Int?
        public var p50Ms: Double?
        public var p95Ms: Double?
        public var maxFrameMs: Double?
        public var longFramePct: Double?

        public init(tMs: Int, label: String, totalMs: Double, cpuMs: Double, waitMs: Double,
                    steps: [String: Double], frames: Int? = nil, p50Ms: Double? = nil,
                    p95Ms: Double? = nil, maxFrameMs: Double? = nil, longFramePct: Double? = nil) {
            self.tMs = tMs
            self.label = label
            self.totalMs = totalMs
            self.cpuMs = cpuMs
            self.waitMs = waitMs
            self.steps = steps
            self.frames = frames
            self.p50Ms = p50Ms
            self.p95Ms = p95Ms
            self.maxFrameMs = maxFrameMs
            self.longFramePct = longFramePct
        }
    }

    public struct DiagnosticEvent: Codable, Equatable, Sendable {
        public let tMs: Int
        public let cat: String
        public let code: String
        public let ms: Double?
        public let detail: String?

        public init(tMs: Int, cat: String, code: String, ms: Double? = nil, detail: String? = nil) {
            self.tMs = tMs
            self.cat = cat
            self.code = code
            self.ms = ms
            self.detail = detail
        }
    }

    public struct CrashSummary: Codable, Equatable, Sendable {
        public let file: String
        public let timestamp: String?
        public let exception: String?
        public let termination: String?
        public let faultingThread: Int?
        public let crashedFrames: [String]

        public init(file: String, timestamp: String?, exception: String?, termination: String?,
                    faultingThread: Int?, crashedFrames: [String]) {
            self.file = file
            self.timestamp = timestamp
            self.exception = exception
            self.termination = termination
            self.faultingThread = faultingThread
            self.crashedFrames = crashedFrames
        }
    }

    public struct HangAndCrashInfo: Codable, Equatable, Sendable {
        public let watchdogMarker: String?
        public let watchdogStackHead: [String]
        public let crashReports: [CrashSummary]
        public let traceLogBytes: Int?

        public init(watchdogMarker: String?, watchdogStackHead: [String],
                    crashReports: [CrashSummary], traceLogBytes: Int?) {
            self.watchdogMarker = watchdogMarker
            self.watchdogStackHead = watchdogStackHead
            self.crashReports = crashReports
            self.traceLogBytes = traceLogBytes
        }
    }
}

/// 路径与隐私脱敏器（纯函数，单测兜底）。
public enum DiagnosticRedactor {
    private static let userDirRegex = try? NSRegularExpression(pattern: #"/Users/[^/\s"'(),:;]+"#)

    /// 把明确的用户家目录与任意 `/Users/<name>` 替换为 `~`。
    public static func redact(_ text: String, homePath: String? = nil) -> String {
        var out = text
        if let homePath, !homePath.isEmpty {
            out = out.replacingOccurrences(of: homePath, with: "~")
        }
        if let regex = userDirRegex {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "~")
        }
        return out
    }

    public static func redactLines(_ lines: [String], maxLines: Int, homePath: String? = nil) -> [String] {
        guard maxLines > 0 else { return [] }
        return lines.prefix(maxLines).map { redact($0, homePath: homePath) }
    }
}

/// 解析 macOS `.ips`（两段式 JSON）崩溃日志，只提取异常类型与崩溃线程前 N 帧。
public enum DiagnosticIPSParser {
    public static func parse(fileName: String,
                             content: String,
                             maxFrames: Int = 15,
                             homePath: String? = nil) -> DiagnosticReport.CrashSummary? {
        // Apple `.ips` 格式：第 1 行为单行 JSON header，第 2 行起为完整 JSON body
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let firstNewline = trimmed.firstIndex(of: "\n") else {
            return nil
        }
        let headerText = String(trimmed[..<firstNewline])
        let bodyText = String(trimmed[trimmed.index(after: firstNewline)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let header = (try? JSONSerialization.jsonObject(with: Data(headerText.utf8))) as? [String: Any]
        guard let body = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any] else {
            return nil
        }

        let timestamp = (header?["timestamp"] as? String) ?? (body["captureTime"] as? String)

        var exceptionText: String?
        if let exc = body["exception"] as? [String: Any] {
            let parts = [
                exc["type"] as? String,
                exc["signal"] as? String,
                exc["subtype"] as? String
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty {
                exceptionText = DiagnosticRedactor.redact(parts.joined(separator: " | "), homePath: homePath)
            }
        }

        var terminationText: String?
        if let term = body["termination"] as? [String: Any] {
            let parts = [
                term["namespace"] as? String,
                term["indicator"] as? String,
                (term["code"] as? NSNumber).map { "code=\($0)" }
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty {
                terminationText = DiagnosticRedactor.redact(parts.joined(separator: " | "), homePath: homePath)
            }
        }

        let faultingIndex = body["faultingThread"] as? Int
        let usedImages = (body["usedImages"] as? [[String: Any]]) ?? []
        var framesOut: [String] = []

        if let threads = body["threads"] as? [[String: Any]],
           let idx = faultingIndex,
           threads.indices.contains(idx),
           let frames = threads[idx]["frames"] as? [[String: Any]] {
            for (i, frame) in frames.prefix(maxFrames).enumerated() {
                let imgIdx = frame["imageIndex"] as? Int
                let imgName: String
                if let imgIdx, usedImages.indices.contains(imgIdx) {
                    imgName = (usedImages[imgIdx]["name"] as? String)
                        ?? (usedImages[imgIdx]["path"] as? String).map { ($0 as NSString).lastPathComponent }
                        ?? "?"
                } else {
                    imgName = "?"
                }
                let symbol = (frame["symbol"] as? String) ?? "<unnamed>"
                let offset = (frame["symbolLocation"] as? Int).map { "+\($0)" }
                    ?? (frame["imageOffset"] as? Int).map { "@0x\(String($0, radix: 16))" }
                    ?? ""
                let line = DiagnosticRedactor.redact("#\(i) \(imgName) \(symbol)\(offset)", homePath: homePath)
                framesOut.append(line)
            }
        }

        return DiagnosticReport.CrashSummary(
            file: DiagnosticRedactor.redact(fileName, homePath: homePath),
            timestamp: timestamp,
            exception: exceptionText,
            termination: terminationText,
            faultingThread: faultingIndex,
            crashedFrames: framesOut
        )
    }
}

/// 确定性 JSON 编码（排序键 + 标准缩进，便于 diff、脚本与 AI 直接解析）。
public enum DiagnosticReportEncoder {
    public static func encode(_ report: DiagnosticReport, pretty: Bool = true) -> String {
        let encoder = JSONEncoder()
        var fmt: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { fmt.insert(.prettyPrinted) }
        encoder.outputFormatting = fmt
        guard let data = try? encoder.encode(report),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
