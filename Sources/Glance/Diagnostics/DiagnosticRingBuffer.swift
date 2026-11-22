import Foundation
import GlanceCore

/// 常态常开的进程内轻量诊断环形缓冲（零磁盘 I/O，线程安全）。
///
/// 纪律：
/// - 只记纯数值指标、计数器和脱敏后的错误/降级码，绝不传入窗口标题、App 名或用户路径；
/// - 固定上限（最近 10 局会话 + 最近 60 条异常/生命周期事件），内存占用恒定 < 20KB。
final class DiagnosticRingBuffer: @unchecked Sendable {
    static let shared = DiagnosticRingBuffer()

    private let lock = NSLock()
    private var counters = DiagnosticReport.HealthCounters()
    private var sessions: [DiagnosticReport.SessionMetric] = []
    private var events: [DiagnosticReport.DiagnosticEvent] = []
    private var dirtyExitRecoveredFlag = false

    private let maxSessions = 10
    private let maxEvents = 60

    private init() {}

    func markDirtyExitRecovered() {
        lock.lock()
        dirtyExitRecoveredFlag = true
        lock.unlock()
        recordEvent(cat: "lifecycle", code: "dirty_exit_recovered")
    }

    func recordSessionOpen() {
        lock.lock()
        counters.sessionsOpened += 1
        lock.unlock()
    }

    func recordSessionConfirm() {
        lock.lock()
        counters.sessionsConfirmed += 1
        lock.unlock()
    }

    func recordSessionCancel() {
        lock.lock()
        counters.sessionsCancelled += 1
        lock.unlock()
    }

    func recordSessionMarks(label: String, totalMs: Double, cpuMs: Double, waitMs: Double, steps: [(String, Double)]) {
        let map = Dictionary(steps.map { ($0.0, ($0.1 * 10).rounded() / 10) }, uniquingKeysWith: { _, b in b })
        let metric = DiagnosticReport.SessionMetric(
            tMs: Int(glanceUptimeMs()),
            label: label,
            totalMs: (totalMs * 10).rounded() / 10,
            cpuMs: (cpuMs * 10).rounded() / 10,
            waitMs: (waitMs * 10).rounded() / 10,
            steps: map
        )
        lock.lock()
        sessions.append(metric)
        if sessions.count > maxSessions {
            sessions.removeFirst(sessions.count - maxSessions)
        }
        lock.unlock()
    }

    func attachFrameMetrics(frames: Int, p50Ms: Double, p95Ms: Double, maxFrameMs: Double, longFramePct: Double) {
        lock.lock()
        if !sessions.isEmpty {
            let idx = sessions.count - 1
            sessions[idx].frames = frames
            sessions[idx].p50Ms = (p50Ms * 10).rounded() / 10
            sessions[idx].p95Ms = (p95Ms * 10).rounded() / 10
            sessions[idx].maxFrameMs = (maxFrameMs * 10).rounded() / 10
            sessions[idx].longFramePct = (longFramePct * 10).rounded() / 10
        }
        lock.unlock()
    }

    func recordAXSlow(ms: Double) {
        lock.lock()
        counters.axSlowOver50ms += 1
        if ms > counters.axMaxMs { counters.axMaxMs = (ms * 10).rounded() / 10 }
        lock.unlock()
        recordEvent(cat: "ax", code: "slow_over_50ms", ms: (ms * 10).rounded() / 10)
    }

    func recordSLPSDegrade(code: String) {
        lock.lock()
        counters.slpsDegrades += 1
        lock.unlock()
        recordEvent(cat: "focus", code: "slps_degrade", detail: code)
    }

    func recordSLPSVerifyFallback() {
        lock.lock()
        counters.slpsVerifyFallbacks += 1
        lock.unlock()
        recordEvent(cat: "focus", code: "slps_verify_fallback")
    }

    func recordTapDisabled(byTimeout: Bool) {
        lock.lock()
        if byTimeout {
            counters.tapDisabledTimeout += 1
        } else {
            counters.tapDisabledUserInput += 1
        }
        lock.unlock()
        recordEvent(cat: "tap", code: byTimeout ? "disabled_timeout" : "disabled_user_input")
    }

    func recordTapReattach() {
        lock.lock()
        counters.tapReattaches += 1
        lock.unlock()
    }

    func recordSecureInputFallback() {
        lock.lock()
        counters.secureInputFallbacks += 1
        lock.unlock()
        recordEvent(cat: "hotkey", code: "secure_input_repeat_fallback")
    }

    func recordThreeFingerFire(fourFinger: Bool) {
        lock.lock()
        counters.threeFingerFires += 1
        lock.unlock()
        recordEvent(cat: "mt", code: fourFinger ? "four_finger_fire" : "three_finger_fire")
    }

    func recordThreeFingerDragCancel() {
        lock.lock()
        counters.threeFingerDragCancels += 1
        lock.unlock()
        recordEvent(cat: "mt", code: "drag_misfire_cancel")
    }

    func recordThreeFingerRevive() {
        lock.lock()
        counters.threeFingerRevives += 1
        lock.unlock()
        recordEvent(cat: "mt", code: "revive_reattach")
    }

    func recordWatchdogStall(seconds: Double) {
        lock.lock()
        counters.watchdogStalls += 1
        lock.unlock()
        recordEvent(cat: "watchdog", code: "main_thread_stall", ms: seconds * 1000)
    }

    func recordEvent(cat: String, code: String, ms: Double? = nil, detail: String? = nil) {
        let ev = DiagnosticReport.DiagnosticEvent(
            tMs: Int(glanceUptimeMs()),
            cat: cat,
            code: code,
            ms: ms,
            detail: detail
        )
        lock.lock()
        events.append(ev)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lock.unlock()
    }

    func snapshot() -> (counters: DiagnosticReport.HealthCounters,
                        sessions: [DiagnosticReport.SessionMetric],
                        events: [DiagnosticReport.DiagnosticEvent],
                        dirtyExitRecovered: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (counters, sessions, events, dirtyExitRecoveredFlag)
    }
}
