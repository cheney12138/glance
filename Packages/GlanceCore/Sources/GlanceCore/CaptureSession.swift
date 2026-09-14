import Foundation

/// **截图会话**的裁决 —— "这一发回车到底归谁"。
///
/// 病例(2026-09-14,用户实报):「在截图的情况下,我按回车会同时触发截图的复制和选中的逻辑」。
/// 病根是**一次击键被两个主人收下**:截图工具的取景框自己也在收回车(`Return` = 完成/复制),
/// 而我们的 navTap 是**后装**的 tap,排在同一颗事件的后半段 —— 它照样看见这一发,照样确认了一次。
/// 于是用户眼里就是"截图拷走了,App 也被拉起来了"。
///
/// 判断"这颗回车归谁"本来就不该靠"谁的 tap 更靠前"这种偶然事实,而该靠**语境**:
/// 屏幕上正在取景/正等着"完成"的那一刻,回车的第一所有权在截图工具手上,
/// 面板能做的最多是把舞台让开(关闭、不聚焦),**而且不能吞键** —— 吞了截图工具的"完成"就没了。
///
/// 本文件是**纯核**:只做"证据 → 裁决",采集那一侧在 `Trigger/CaptureSessionProbe.swift`
/// (NSWorkspace / CGWindowList 都是 plumbing)。这样裁决可以逐格单测,
/// 不必为了验一条规则真的去截一次图。
public struct CaptureSessionEvidence: Equatable, Sendable {
    /// 前台 App 的 bundle id(`NSWorkspace.frontmostApplication`)
    public var frontmostBundleID: String?
    /// 前台 App 的显示名(本地化名,如 "CleanShot X")
    public var frontmostName: String?
    /// 系统截图 UI 在跑:⇧⌘4 / ⇧⌘5 的取景框与拍完的浮窗缩略图都由它画
    public var systemCaptureUIRunning: Bool
    /// 屏幕上是否有一块**铺满整屏的高层窗口**,且不是我们自己的 —— 取景框的通用特征
    public var screenWideOverlay: Bool

    public init(frontmostBundleID: String? = nil,
                frontmostName: String? = nil,
                systemCaptureUIRunning: Bool = false,
                screenWideOverlay: Bool = false) {
        self.frontmostBundleID = frontmostBundleID
        self.frontmostName = frontmostName
        self.systemCaptureUIRunning = systemCaptureUIRunning
        self.screenWideOverlay = screenWideOverlay
    }
}

public enum CaptureSessionRule {
    /// 裁决 + **人话理由**。理由不是装饰:这条规则只在真机上被咬到才复现,
    /// 日志里必须一眼看出"当时是按哪一条判的",否则下一次还是只能靠猜。
    public struct Verdict: Equatable {
        public let isCapture: Bool
        public let reason: String
        public static let panel = Verdict(isCapture: false, reason: "无截图会话")
    }

    /// 系统截图 UI 的 bundle id。它是**只在截图会话里存在**的进程:
    /// 取景框、拍完的浮窗缩略图、标注窗全归它 —— 所以"它在跑"就等于"截图会话还活着"。
    public static let systemUIBundleIDs: Set<String> = [
        "com.apple.screencaptureui",
        "com.apple.ScreenCaptureUI",
    ]

    /// 已知第三方截图 App 的 bundle id。
    ///
    /// ⚠️ 白名单**天然不全**(新工具一直在出),所以它只是"加分项",不是主判据 ——
    /// 主判据是 `screenWideOverlay`(任何工具取景时都得铺满屏幕,不依赖它叫什么)。
    /// 这一条的意义在于**误报为零**:前台 App 明确就是截图工具时,不必再等覆盖窗被认出来。
    public static let knownBundleIDs: Set<String> = [
        "pl.maketheweb.cleanshotx",   // CleanShot X
        "io.shottr.Shottr",           // Shottr
        "com.xnip.app",               // Xnip
        "com.Snipaste",               // Snipaste
        "com.techsmith.snagit",       // Snagit
        "com.techsmith.snagiteditor",
        "com.pixpin.pixpin",          // PixPin
        "com.apple.Screenshot",       // 系统截图 App 的另一种打包方式
    ]

    /// 名字关键词(前台 App 的**本地化名**小写后子串匹配)。
    ///
    /// 为什么除了 bundle 白名单还要这个:白名单要靠"知道这个 App"才能维护,
    /// 而名字里的 `shot / snip / snap / grab` 是这类工具的**自我命名习惯**——
    /// 用户装了一个我们没听说过的工具,只要它叫得像个截图工具,这一条就接得住。
    /// 故意**不收** `cap`(会咬到 Capital / Capsule 之类)与 IM 家族(见下)。
    /// (`screenshot` 不用单列:"shot" 已经把它含住了)
    public static let nameKeywords: [String] = ["shot", "snip", "snap", "grab", "截图", "截屏", "抓图"]

    /// 裁决。`extraBundleIDs` 给用户留的手工口径(plumbing 从 UserDefaults 读进来)。
    ///
    /// 判据顺序 = 精确 → 通用:系统 UI 最确定;其次是"前台就是截图 App";
    /// 最后才是"屏幕被铺满了"(它也不知道是谁铺的,只知道"这里在取景")。
    ///
    /// **故意不把 QQ / 微信 这类 IM 放进白名单**:它们的截图模式与聊天模式**同进程同 bundle**,
    /// 靠 bundle 判断等于"只要在聊天就把回车的所有权让出去"。它们的截图模式靠
    /// `screenWideOverlay` 认(取景框铺满屏,聊天窗不铺) —— 这个区分是准的,不需要猜。
    public static func verdict(_ evidence: CaptureSessionEvidence,
                              extraBundleIDs: Set<String> = []) -> Verdict {
        if evidence.systemCaptureUIRunning {
            return Verdict(isCapture: true, reason: "系统截图 UI(screencaptureui)在跑")
        }
        if let bundleID = evidence.frontmostBundleID {
            if systemUIBundleIDs.contains(bundleID) {
                return Verdict(isCapture: true, reason: "前台就是系统截图 UI")
            }
            if knownBundleIDs.contains(bundleID) || extraBundleIDs.contains(bundleID) {
                return Verdict(isCapture: true, reason: "前台是截图 App(\(bundleID))")
            }
        }
        if evidence.screenWideOverlay {
            return Verdict(isCapture: true, reason: "屏幕被一块高层覆盖窗铺满(取景框)")
        }
        if let name = evidence.frontmostName {
            let lowered = name.lowercased()
            if let hit = nameKeywords.first(where: { lowered.contains($0) }) {
                return Verdict(isCapture: true, reason: "前台 App 名字含「\(hit)」")
            }
        }
        return .panel
    }
}
