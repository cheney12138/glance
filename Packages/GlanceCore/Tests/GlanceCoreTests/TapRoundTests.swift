import XCTest
@testable import GlanceCore

/// 判卷的**回归测试**：把四次翻车各钉一条。
///
/// 为什么值得写这么多：这套判卷在两周内错了四次，每次都只能靠用户"用手指数"来发现 ✗
/// （11 指 / 幽灵触点 / 单指数成三指 / 拖拽误判）。⇒ 从这里开始，它们必须**当场被红测试挡住** ✓
final class TapRoundTests: XCTestCase {

    // MARK: 工具

    private func c(_ id: Int32, _ x: Double, _ y: Double,
                   state: Int32 = 4, size: Float = 0.8, major: Float = 7.4) -> TapRound.Contact {
        TapRound.Contact(id: id, normalized: .init(x, y), absolute: .init(x * 1920, y * 1080),
                         size: size, majorAxis: major, state: state)
    }

    private func frame(_ t: Double, _ cs: TapRound.Contact...) -> TapRound.Frame {
        TapRound.Frame(contacts: cs, time: t)
    }

    /// 模拟 App 的用法：喂帧；某一帧空 ⇒ 当场判卷（照 LumaRing：只在全部离开那一帧判）
    private func run(_ frames: [TapRound.Frame], policy: TapRound.Policy = .standard) -> TapRound.Outcome {
        var tr = TapRound.Tracker(policy: policy)
        for f in frames {
            if tr.feed(f) == 0 {
                // ⚠️ 顺序照 App:**先判卷、再清账** —— 反了就是拿空账本判卷（我第一版写反过 ✗）
                let out = tr.judge(now: f.time)
                tr.endRound()
                return out
            }
        }
        // 没等到空帧 ⇒ 用最后一帧时刻判（测试里基本用不到）
        let last = frames.last?.time ?? 0
        return tr.judge(now: last)
    }

    /// 三根手指：分两帧落齐（第 3 根 40ms 后到 —— 本仓病历里就是常态 ✓）
    private func threeFingers(t0: Double, ids: (Int32, Int32, Int32) = (11, 12, 13),
                             at p: (Double, Double) = (0.5, 0.5)) -> [TapRound.Frame] {
        [frame(t0, c(ids.0, p.0, p.1), c(ids.1, p.0 + 0.02, p.1)),
         frame(t0 + 0.04, c(ids.0, p.0, p.1), c(ids.1, p.0 + 0.02, p.1), c(ids.2, p.0 + 0.04, p.1))]
    }

    /// 按**真实节奏**按住三指到 `end`(约 40ms 一帧 —— 触控板的实际帧率 ✓)
    /// ⚠️ 写测试时的坑:我第一版只喂"落下"和"抬起"两帧(隔 160ms)⇒ 被判`帧间隔 >120ms` ✗
    ///    —— 那条规则是对的(丢帧时位移不可信 ✓),**不真实的测试才会被它挡** ✓
    private func heldThree(t0: Double, until end: Double,
                          ids: (Int32, Int32, Int32) = (11, 12, 13)) -> [TapRound.Frame] {
        var out = threeFingers(t0: t0, ids: ids)
        var t = t0 + 0.04
        while t < end - 0.001 {
            out.append(frame(t, c(ids.0, 0.5, 0.5), c(ids.1, 0.52, 0.5), c(ids.2, 0.54, 0.5)))
            t += 0.04
        }
        out.append(frame(end))
        return out
    }

    // MARK: ① 三次翻车：单指不该被数成三指

    /// 病例（2026-09-22 用户实报「我刚才单指单击怎么也唤起了... 这肯定不对啊」）：
    /// `distinctIDs` **跨轮累计** ⇒ 攒到 3 个之后，任何一次单击都被数成"三指轻点" ✗
    func testSingleFingerTapNeverFiresEvenAfterManyPriorRounds() {
        var tr = TapRound.Tracker()
        // 先来五轮"两根/三根手指"的接触（真实使用里就是休息的手、幽灵触点）
        for round in 0..<5 {
            let t = Double(round) * 1.0
            _ = tr.feed(frame(t, c(1, 0.4, 0.4), c(2, 0.45, 0.4)))
            _ = tr.feed(frame(t + 0.05, c(1, 0.4, 0.4), c(2, 0.45, 0.4)))
            _ = tr.feed(frame(t + 0.10))                 // 全离开
            tr.endRound()
        }
        // 现在来一记**单指单击**
        _ = tr.feed(frame(10.0, c(9, 0.5, 0.5)))
        _ = tr.feed(frame(10.06, c(9, 0.5, 0.5)))
        _ = tr.feed(frame(10.10))
        let out = tr.judge(now: 10.10)
        XCTAssertEqual(out, .rejected(""), "单指点按必须被无视（不能进日志、更不能开面板）")
        XCTAssertEqual(tr.snapshot(now: 10.10).fingerCount, 1, "手指数必须只有 1")
    }

    /// 病例：`distinctIDs` 不按轮清 ⇒ 一路攒到 **11 指** ⇒ "只认 3/4 指"永不成立 ⇒ 手势全灭
    func testFingerCountDoesNotAccumulateAcrossRounds() {
        var tr = TapRound.Tracker()
        for round in 0..<4 {                                  // 四轮三指接触
            let t = Double(round)
            for (i, id) in [Int32(1), 2, 3].enumerated() {
                _ = tr.feed(frame(t, c(id, 0.4 + Double(i) * 0.02, 0.4)))
            }
            _ = tr.feed(frame(t + 0.05))
            tr.endRound()
        }
        let first = threeFingers(t0: 10.0, ids: (21, 22, 23))
        _ = tr.feed(first[0]); _ = tr.feed(first[1])
        XCTAssertEqual(tr.snapshot(now: 10.04).fingerCount, 3, "第二轮的手指数只能是这一轮的 3，不能是 3×N")
    }

    // MARK: ② 正常点按要生效

    func testThreeFingerTapFires() {
        var frames = threeFingers(t0: 1.0)
        frames.append(frame(1.10))                            // 全部离开那一帧
        guard case .fireThree(let held, _, _, _, _) = run(frames) else { return XCTFail("三指轻点应当生效") }
        XCTAssertGreaterThan(held, 30)                        // ≥ minDuration
        XCTAssertLessThanOrEqual(held, 300)
    }

    func testFourFingerTapFires() {
        let frames = [frame(2.0, c(1, 0.40, 0.4), c(2, 0.44, 0.4), c(3, 0.48, 0.4), c(4, 0.52, 0.4)),
                      frame(2.10)]
        guard case .fireFour = run(frames) else { return XCTFail("四指轻点应当生效") }
    }

    /// ⚠️ **这条测的是"照实镜像"**：`policy.pressHoldRange`（四指按住 0.45–1.2s）在当前口径下
    /// **不可达** —— 因为第一道 guard 就要求 `held <= maxDuration(0.30s)` ✗ ⇒ 后面那条永远轮不到 ✓。
    ///
    /// 这是**既有行为**（App 里同样如此 ✓），我抽纯函数时**照实镜像**，没有顺手打开它 ——
    /// "四指按住也能唤起"是一个**新的触发面**，开不开由用户定 ✓（别在重构里偷偷改产品行为 ✗）。
    /// 若哪天用户说要它生效 ⇒ 把第一道 guard 的时长条件下沉到那条分支即可 ✓（单测改成断言 fireFour ✓）。
    func testFourFingerHoldIsRejectedTodayBecauseTheHoldWindowIsUnreachable() {
        var frames: [TapRound.Frame] = []
        var t = 3.0
        while t < 3.56 {
            frames.append(frame(t, c(1, 0.40, 0.4), c(2, 0.44, 0.4), c(3, 0.48, 0.4), c(4, 0.52, 0.4)))
            t += 0.05
        }
        frames.append(frame(t))
        guard case .rejected(let why) = run(frames) else { return XCTFail("按住这条路当前不可达 ⇒ 应当是 rejected") }
        XCTAssertTrue(why.contains("只认 3/4 指"), why)
    }

    // MARK: ③ 拖拽：位移必须量得出来（哪怕 id 一路换号）

    /// 病例（2026-09-22「我三指拖拽窗口边框, 也唤起了面板」）：
    /// id 换号 ⇒ 位移基线被重置 ⇒ 挪了 30pt 看着像"没动" ✗
    func testThreeFingerDragWithIDChurnIsRejectedAsSlide() {
        var frames: [TapRound.Frame] = []
        var t = 5.0
        // 每帧都换新 id（模拟框架换号），三根手指一路右移
        for i in 0..<6 {
            let x = 0.40 + Double(i) * 0.015                 // 累计 0.075 > maxMove(0.03) ✓
            let base = Int32(100 + i * 10)
            frames.append(frame(t, c(base, x, 0.4), c(base + 1, x + 0.03, 0.4), c(base + 2, x + 0.06, 0.4)))
            t += 0.016
        }
        frames.append(frame(t))                              // 松手
        let out = run(frames)
        guard case .slide(let norm) = out else { return XCTFail("拖拽必须被判成滑动, 实际:\(out)") }
        XCTAssertGreaterThan(norm, 0.03)
    }

    /// 同一次拖拽若 id 不换号，同样要被拒（对照：避免"只有换号时才修好"的假修复 ✓）
    func testThreeFingerDragWithStableIDsIsRejectedAsSlide() {
        var frames: [TapRound.Frame] = []
        var t = 6.0
        for i in 0..<6 {
            let x = 0.40 + Double(i) * 0.015
            frames.append(frame(t, c(1, x, 0.4), c(2, x + 0.03, 0.4), c(3, x + 0.06, 0.4)))
            t += 0.016
        }
        frames.append(frame(t))
        guard case .slide = run(frames) else { return XCTFail("稳定 id 的拖拽也必须被判成滑动") }
    }

    /// id 换号、但**没移动** ⇒ 仍然是"轻点"（续接不能把静止也当成移动 ✓，也不能制造多指 ✗）
    func testIDChurnWithoutMovementStillFiresExactlyOnce() {
        var frames: [TapRound.Frame] = []
        var t = 7.0
        for i in 0..<5 {
            let base = Int32(200 + i * 10)
            frames.append(frame(t, c(base, 0.40, 0.4), c(base + 1, 0.44, 0.4), c(base + 2, 0.48, 0.4)))
            t += 0.016
        }
        frames.append(frame(t))
        let out = run(frames)
        guard case .fireThree = out else { return XCTFail("换号但没动的三指轻点应当生效, 实际:\(out)") }
    }

    // MARK: ④ 其余纪律

    func testFrameGapRejects() {
        let frames = [frame(8.0, c(1, 0.40, 0.4), c(2, 0.44, 0.4), c(3, 0.48, 0.4)),
                      frame(8.20, c(1, 0.40, 0.4), c(2, 0.44, 0.4), c(3, 0.48, 0.4)),   // 帧间隔 200ms > 120ms
                      frame(8.22)]
        guard case .rejected(let why) = run(frames) else { return XCTFail("丢帧必须拒") }
        XCTAssertTrue(why.contains("帧间隔"), why)
    }

    func testSlowReleaseRejects() {
        // 三指落齐 ⇒ 松开第一根 ⇒ 0.25s 后才全离开（> 0.12s 抬手窗口）
        // 总时长压到 0.20s(< 0.30s 的点按上限)⇒ 让它**只能**撞"抬手窗口"那道门 ✓
        let frames = [frame(9.0, c(1, 0.40, 0.4), c(2, 0.44, 0.4), c(3, 0.48, 0.4)),
                      frame(9.05, c(2, 0.44, 0.4), c(3, 0.48, 0.4)),
                      frame(9.10, c(3, 0.48, 0.4)),
                      frame(9.20)]
        guard case .rejected(let why) = run(frames) else { return XCTFail("慢慢松开必须拒") }
        XCTAssertTrue(why.contains("抬手"), why)
    }

    func testPalmOnlyNeverEntersTheLedger() {
        // 掌缘搭着（size 大）⇒ 不算手指、不开面板
        let frames = [frame(10.0, c(1, 0.4, 0.4, size: 5.2, major: 30)),
                      frame(10.20, c(1, 0.4, 0.4, size: 5.2, major: 30)),
                      frame(10.25)]
        let out = run(frames)
        // ⚠️ 不写具体理由 ✗:这条测的是"**不动作**",理由文案会随规则细化而变 ✓
        // (2026-09-22 我给时长下限加了理由 ⇒ 原来断言 `rejected("")` 当场变红 ✓ ——
        //  这正是它该有的样子:文案一变就该有人看一眼 ✓ 但不该把"理由"本身钉死 ✓)
        guard case .rejected = out else { return XCTFail("只有掌缘时不该有任何动作, 实际:\(out)") }
    }

    func testStuckLedgerSelfHeals() {
        var tr = TapRound.Tracker()
        _ = tr.feed(frame(11.0, c(1, 0.4, 0.4)))             // 一直"搭着"不收口
        XCTAssertEqual(tr.resetIfStuck(now: 11.5), 0, "1s 之内不该自愈")
        let stale = tr.resetIfStuck(now: 12.5)
        XCTAssertGreaterThan(stale, 1.0, "超过 stuckLedgerAfter 必须自愈并报出卡的时长")
        XCTAssertEqual(tr.snapshot(now: 12.5).fingerCount, 0, "自愈后账本要是干净的")
    }

    func testStateOutsideOneToFourIsIgnored() {
        // state 5–7 = 离板 ⇒ 与"空帧"等价
        let frames = [frame(13.0, c(1, 0.4, 0.4, state: 7)),
                      frame(13.1, c(1, 0.4, 0.4, state: 5))]
        var tr = TapRound.Tracker()
        XCTAssertEqual(tr.feed(frames[0]), 0, "离板档不算在板上")
        XCTAssertEqual(tr.feed(frames[1]), 0)
    }
    // MARK: ⑥ 三指误触(2026-09-22 实报:回复消息时就弹出来了)

    /// 现场(日志 `[404388ms]`):`三指 60ms[state 4] 位移 norm=0.0018 abs=0.3 → 唤起` ✓
    /// 位移几乎为零、时长 60ms ⇒ 在**下限 30ms** 的口径里它**就是**一记标准点按 ✓
    /// ⇒ 判卷没写错;错的是"这种形状也可能是无意的一搭" ✓ 所以下限要做成**可试档位** ✓
    func testSixtyMillisecondStillTapFiresUnderDefaultFloor() {
        let frames = heldThree(t0: 0, until: 0.10)               // 落齐(0.04)后 60ms 抬起
        guard case .fireThree = run(frames) else { return XCTFail("默认下限下它应当生效 —— 这正是那天误触的形状") }
    }

    /// 抬下限必须能挡住那一记(档位的效果要可断言 ✓)
    func testRaisingFloorRejectsTheSixtyMillisecondMisfire() {
        var p = TapRound.Policy.standard
        p.minDuration = 0.08
        let frames = heldThree(t0: 0, until: 0.10)
        guard case let .rejected(reason) = run(frames, policy: p) else { return XCTFail("抬下限后必须被挡") }
        XCTAssertTrue(reason.contains("时长"), "理由要写明是时长挡的(原来空串 ⇒ 排查时看不见 ✗): \(reason)")
    }

    /// 但抬下限**不能**把有意的轻点一起挡掉 —— 这条是档位的取舍边界(真机上调的就是这里)✓
    func testRaisingFloorStillAcceptsNormalTaps() {
        var p = TapRound.Policy.standard
        p.minDuration = 0.08
        let frames = heldThree(t0: 0, until: 0.20)               // 落齐后 160ms:正常轻点
        let out = run(frames, policy: p)
        guard case .fireThree = out else { return XCTFail("正常轻点不该被挡, 实际:\(out)") }
    }

    /// 起火时要带上 size/major(日志要靠它分辨"是不是巴掌缘/指节" ✓ —— 那天缺的就是这两项)
    func testFireOutcomeCarriesContactSizeForDiagnosis() {
        // 真实节奏 + 带 size/major(那天日志缺的就是这两项 ✓)
        let frames = [frame(0.0, c(11, 0.5, 0.5, size: 3.1, major: 12.0)),
                      frame(0.04, c(11, 0.5, 0.5, size: 3.1, major: 12.0),
                                   c(12, 0.52, 0.5, size: 2.2, major: 11.0)),
                      frame(0.08, c(11, 0.5, 0.5, size: 3.1, major: 12.0),
                                   c(12, 0.52, 0.5, size: 2.2, major: 11.0),
                                   c(13, 0.54, 0.5, size: 1.9, major: 10.5)),
                      frame(0.12, c(11, 0.5, 0.5, size: 3.1, major: 12.0),
                                   c(12, 0.52, 0.5, size: 2.2, major: 11.0),
                                   c(13, 0.54, 0.5, size: 1.9, major: 10.5)),
                      frame(0.18)]
        let out = run(frames)
        guard case let .fireThree(_, _, _, maxSize, maxMajor) = out else { return XCTFail("应当生效, 实际:\(out)") }
        XCTAssertEqual(maxSize, 3.1, accuracy: 0.01)
        XCTAssertEqual(maxMajor, 12.0, accuracy: 0.01)
    }
}
