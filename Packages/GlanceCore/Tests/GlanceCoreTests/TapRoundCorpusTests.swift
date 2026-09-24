import XCTest
@testable import GlanceCore

/// **判卷的病例语料**（2026-09-23 立，为了"改结构不改行为"）。
///
/// 为什么要有它：`TapRound.judge` 里已经挤了 11 道门，每道都来自一次实报 ✓ —— 但病例散在
/// 注释里、顺序敏感 ⇒ 想捋顺结构时**没有一张网接着** ✗。
/// ⇒ 这份文件把**日志里真实发生过**的样本逐条钉住：重构前它绿，重构后它必须还绿 ✓。
///
/// **它锁的是"今天的结论"，不是"应该的结论"** ✓：
///   · `kind` = 今天的结论（重构的护栏 ✓）
///   · `verdict` = 用户当时的判定（"这是我的误触 ✗" / "这是我按的 ✓"）
///   ⇒ 两者不一致的样本，正是还没修完的目标 —— 修好那天，把 `kind` 改过来，测试变红提醒你 ✓
///
/// 样本来源：`~/Library/Logs/Glance/trace.log` 里带完整数字的判卷结论 ✓（不是编的 ✓）
/// 加新样本的规矩：**只加日志里真出现过的形状** ✓；参数照抄日志的 `norm / size / major` ✓。
final class TapRoundCorpusTests: XCTestCase {

    // MARK: 语料形状

    private enum Kind: Equatable {
        case fires          // 生效(三指/四指都算;四指另有断言)
        case firesFour
        case slide
        case rejected(String?)   // 关键字(理由里必须出现;nil = 不关心)
    }

    private enum Verdict: String {
        case intended = "用户按的"      // 用户没报为误触
        case misfire = "用户报的误触 ✗"  // 用户明确实报过
    }

    private struct Sample {
        let name: String
        let kind: Kind
        let verdict: Verdict
        let frames: [TapRound.Frame]
        /// 日志里那行原文(留档:一眼能对上 ✓)
        let log: String
        var dragEvidence = false
    }

    // MARK: 造帧(照真实节奏:落齐约 40ms、此后每 ~40ms 一帧 ✗ 别隔 160ms ⇒ 会被丢帧门挡 ✓)

    private func c(_ id: Int32, _ x: Double, _ y: Double, size: Float, major: Float) -> TapRound.Contact {
        TapRound.Contact(id: id, normalized: .init(x, y), absolute: .init(x * 144, y * 144),
                         size: size, majorAxis: major, state: 4)
    }

    /// `fingers` 指、落齐后按住 `holdMs` 再抬手;`moveTo` 给了就在最后一帧位移那一格(照日志的 norm ✓)
    private func frames(fingers: Int, holdMs: Double, size: Float, major: Float,
                        moveTo norm: Double = 0) -> [TapRound.Frame] {
        let xs: [Double] = [0.40, 0.44, 0.48, 0.52]
        let ids: [Int32] = [11, 12, 13, 14]
        var out: [TapRound.Frame] = []
        // 第一帧:先落 2 根(真实里就是这样先后落下 ✓)
        out.append(TapRound.Frame(contacts: stride(from: 0, to: min(2, fingers), by: 1).map {
            c(ids[$0], xs[$0], 0.40, size: size, major: major)
        }, time: 0))
        let allDown = 0.04
        let lift = allDown + holdMs / 1000
        var t = allDown
        while t < lift - 0.001 {
            let last = t + 0.04 >= lift - 0.001
            let dx = last ? norm : 0
            out.append(TapRound.Frame(contacts: (0..<fingers).map {
                c(ids[$0], xs[$0] + dx, 0.40, size: size, major: major)
            }, time: t))
            t += 0.04
        }
        out.append(TapRound.Frame(contacts: [], time: lift))   // 全离开那一帧 ⇒ 当场判卷 ✓
        return out
    }

    private func judge(_ s: Sample) -> TapRound.Outcome {
        var tracker = TapRound.Tracker()
        var lastTime = 0.0
        for f in s.frames {
            if tracker.feed(f) == 0 {
                let out = tracker.judge(now: f.time, dragEvidence: s.dragEvidence)   // 先判卷 ✓
                tracker.endRound()
                return out
            }
            lastTime = f.time
        }
        return tracker.judge(now: lastTime, dragEvidence: s.dragEvidence)
    }

    // MARK: 语料表

    private var corpus: [Sample] {
        [
            // ── 生效的样本(今天都会生效 ✓ —— 重构后必须仍然生效 ✓)────────────────────
            Sample(name: "三指 45ms/0.9/7.2", kind: .fires, verdict: .intended,
                   frames: frames(fingers: 3, holdMs: 45, size: 0.9, major: 7.2),
                   log: "三指   45ms norm=0.0028 abs=0.3 size=0.9 major=7.2"),
            Sample(name: "三指 76ms/1.0/7.9", kind: .fires, verdict: .intended,
                   frames: frames(fingers: 3, holdMs: 76, size: 1.0, major: 7.9),
                   log: "三指   76ms norm=0.0028 abs=0.4 size=1.0 major=7.9"),
            Sample(name: "三指 90ms/0.9/8.6", kind: .fires, verdict: .intended,
                   frames: frames(fingers: 3, holdMs: 90, size: 0.9, major: 8.6, moveTo: 0.0042),
                   log: "三指   90ms norm=0.0042 abs=0.5 size=0.9 major=8.6"),
            Sample(name: "四指 78ms/1.0/7.2", kind: .firesFour, verdict: .intended,
                   frames: frames(fingers: 4, holdMs: 78, size: 1.0, major: 7.2, moveTo: 0.0069),
                   log: "四指   78ms norm=0.0069 abs=1.0 size=1.0 major=7.2"),

            // ── 用户报过的误触 ✗(今天**仍然生效** ⇒ 这就是待修的目标)─────────────────
            Sample(name: "误触 · 三指 150ms/0.8/7.1(生效后 250ms 指针又动 57pt)",
                   kind: .fires, verdict: .misfire,
                   frames: frames(fingers: 3, holdMs: 150, size: 0.8, major: 7.1, moveTo: 0.0050),
                   log: "三指  150ms norm=0.0050 abs=0.7 size=0.8 major=7.1"),
            Sample(name: "误触 · 三指 237ms/0.6", kind: .fires, verdict: .misfire,
                   frames: frames(fingers: 3, holdMs: 237, size: 0.6, major: 7.4, moveTo: 0.0251),
                   log: "三指  237ms norm=0.0251 ... size=0.6 (快速选词,接触期间完成拖移)"),
            Sample(name: "误触 · 三指 285ms/0.8/12.1", kind: .fires, verdict: .misfire,
                   frames: frames(fingers: 3, holdMs: 285, size: 0.8, major: 12.1, moveTo: 0.0142),
                   log: "三指  285ms norm=0.0142 abs=2.1 size=0.8 major=12.1"),
            Sample(name: "误触 · 三指 77ms/1.0/11.1", kind: .fires, verdict: .misfire,
                   frames: frames(fingers: 3, holdMs: 77, size: 1.0, major: 11.1, moveTo: 0.0111),
                   log: "三指   77ms norm=0.0111 abs=1.6 size=1.0 major=11.1"),
            // 这两条**已经被重量门挡住** ✓(2026-09-23 加语料时当场发现的 ✓):
            // 它们的触点只有 0.4/0.5,是日志里最轻的一档 ⇒ `minContactSize = 0.6` 生效 ✓
            // ⇒ 它们是"已覆盖的误触" ✓ —— `verdict` 仍记 `.misfire`(用户当时确实报过 ✓)
            Sample(name: "误触(已挡住)· 三指 60ms/0.4(很轻)", kind: .rejected("过轻"), verdict: .misfire,
                   frames: frames(fingers: 3, holdMs: 60, size: 0.4, major: 6.7, moveTo: 0.0056),
                   log: "三指   60ms norm=0.0056 abs=0.6 size=0.4 major=6.7"),
            Sample(name: "误触(已挡住)· 三指 47ms/0.5(很轻)", kind: .rejected("过轻"), verdict: .misfire,
                   frames: frames(fingers: 3, holdMs: 47, size: 0.5, major: 6.9, moveTo: 0.0115),
                   log: "三指   47ms norm=0.0115 abs=1.2 size=0.5 major=6.9"),

            // ── "拖移证据"在场时:今天就已经被拦下 ✓(这是他那条修复的能力边界 ✓)──────
            Sample(name: "拖移证据 · 三指 237ms(同一形状 + 证据)", kind: .rejected("鼠标按下"),
                   verdict: .misfire,
                   frames: frames(fingers: 3, holdMs: 237, size: 0.6, major: 7.4, moveTo: 0.0251),
                   log: "(同上那条 + 按压期间见过 leftMouseDown ⇒ 应当一票否决 ✓)",
                   dragEvidence: true),

            // ── 不该动作的样本 ────────────────────────────────────────────────────
            Sample(name: "两指 46ms(只认 3/4 指)", kind: .rejected("只认 3/4 指"), verdict: .intended,
                   frames: frames(fingers: 2, holdMs: 46, size: 1.0, major: 7.2),
                   log: "2 指   46ms norm=0.0016 abs=0.2 size=1.0 → 不动作"),
            Sample(name: "两指 121ms 大幅位移(滚动)", kind: .rejected("只认 3/4 指"), verdict: .intended,
                   frames: frames(fingers: 2, holdMs: 121, size: 0.8, major: 7.2, moveTo: 0.2473),
                   log: "2 指  121ms norm=0.2473 abs=25.1 size=1.0 → 不动作"),
            Sample(name: "三指 435ms(超 300ms 上限)", kind: .rejected("只认 3/4 指"), verdict: .intended,
                   frames: frames(fingers: 3, holdMs: 435, size: 1.2, major: 8.0),
                   log: "3 指  435ms norm=0.1353 abs=17.2 size=1.4 → 不动作"),
            Sample(name: "三指 553ms(超时)", kind: .rejected("只认 3/4 指"), verdict: .intended,
                   frames: frames(fingers: 3, holdMs: 553, size: 1.1, major: 8.0),
                   log: "3 指  553ms norm=0.0033 abs=0.4 size=1.1 → 不动作"),
        ]
    }

    // MARK: 护栏

    func testCorpusHoldsToday() {
        for s in corpus {
            let out = judge(s)
            switch (s.kind, out) {
            case (.fires, .fireThree), (.firesFour, .fireFour), (.slide, .slide):
                break
            case let (.rejected(keyword), .rejected(reason)):
                if let keyword, !reason.contains(keyword) {
                    XCTFail("[\(s.name)] 被拒的理由里没出现「\(keyword)」,实际「\(reason)」\n  日志原文:\(s.log)")
                }
            default:
                XCTFail("[\(s.name)] 结论与今天不符 —— 期望 \(s.kind),实际 \(out)\n"
                         + "  日志原文:\(s.log)\n  用户判定:\(s.verdict.rawValue)")
            }
        }
    }

    /// 造出来的帧要对得上日志里的**时长**(不然语料是假的、测了也没意义 ✗)
    func testReconstructedFramesMatchLoggedDurations() {
        for s in corpus where !s.name.hasPrefix("两指") {
            var tracker = TapRound.Tracker()
            var snap = TapRound.Snapshot()
            for f in s.frames {
                _ = tracker.feed(f)
                snap = tracker.snapshot(now: f.time)
                if tracker.feed(f) == 0 { break }
            }
            let msTokens = s.log.split(separator: " ").filter { $0.hasSuffix("ms") }
            guard let token = msTokens.first,
                  let logged = Int(token.dropLast(2)) else { continue }
            XCTAssertEqual(Int(snap.held * 1000), logged, accuracy: 20,
                           "[\(s.name)] 造帧得到的按压时长与日志差太多:\(Int(snap.held * 1000))ms vs \(logged)ms")
        }
    }

    /// 把"用户报的误触"数出来打一行 —— 重构时这行就是进度条 ✓(个数应当只减不增 ✓)
    func testMisfireCountIsRecorded() {
        let misfires = corpus.filter { $0.verdict == .misfire }
        let stillFiring = misfires.filter { s in
            switch judge(s) { case .fireThree, .fireFour: return true; default: return false }
        }
        print("[语料] 用户报过的误触 \(misfires.count) 条,其中今天仍会生效的 \(stillFiring.count) 条:"
              + stillFiring.map { "\n    · " + $0.name }.joined())
    }
}
