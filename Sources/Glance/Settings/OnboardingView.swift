import AppKit
import GlanceCore
import SwiftUI

/// 首次 30 秒轻引导（3 步可跳过，沿用设置窗纸面语言）。
///
/// 触发规则：
/// - 新用户在权限窗两项授权全部完成后，原地无缝切换为本引导；
/// - 老用户（存在历史配置键）启动时自动静默标记已完成，绝不打扰；
/// - 随时可在「设置 → 关于 → 帮助」重新打开。
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var step = 0
    /// 切步动效的两个参数(2026-11-25)。**不用 `.transition`**:系统开着「减弱动态效果」时
    /// SwiftUI 会把过渡抹成瞬切,而 opacity/位移这些**参数**动画不受影响 ✓
    /// 两拍写法与 `SettingsView` 的切页淡入同一套(推初值 → 下一拍收回)
    @State private var stepOpacity: Double = 1
    @State private var stepOffsetY: CGFloat = 0
    @State private var triedSummon = false
    @State private var trigger = TriggerConfig.load()
    @State private var takeover = TriggerConfig.takeoverEnabled

    @AppStorage(Keys.panelWindowLayout) private var windowLayoutRaw = KeyDefaults.windowLayout
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.auto
    @AppStorage(Keys.switchDigitPicksApp) private var digitPicksApp = KeyDefaults.digitPicksApp
    @AppStorage(Keys.pointerDoubleOptionJumps) private var doubleOptionJumps = KeyDefaults.doubleOptionJumps

    private let totalSteps = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶栏（0…39pt 给系统原生红绿灯让位）：居中步骤点 + 右侧跳过
            ZStack {
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { idx in
                        Capsule()
                            .fill(idx == step ? SettingsTheme.beam : SettingsTheme.trackOff)
                            .frame(width: idx == step ? 18 : 6, height: 6)
                            // 步点指示器:宽度/颜色跟着 `step` 走 token(原来是一条裸 `.easeOut(0.18)`)
                            .animation(MotionPolicy.animation(SettingsMotion.status), value: step)
                    }
                }

                HStack {
                    Spacer()
                    Button("跳过") { finish() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.ink2)
                }
                .padding(.trailing, 18)
            }
            .frame(maxWidth: .infinity)
            .frame(height: SettingsMetrics.prismTop)

            SettingsTheme.prism
                .frame(height: SettingsMetrics.prismHeight)
                .opacity(SettingsMetrics.prismOpacity)

            Group {
                switch step {
                case 0: stepOneTrySummon
                case 1: stepTwoStyle
                default: stepThreeShortcuts
                }
            }
            // 切步的"入场系数":新正文从 0.15 淡回 1、从下方 6pt 浮回原位(由 onChange 驱动 ✓)
            .opacity(stepOpacity)
            .offset(y: stepOffsetY)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(minHeight: 235, alignment: .topLeading)

            Divider().overlay(SettingsTheme.hairline)

            // 底栏操作
            HStack {
                if step > 0 {
                    Button("上一步") {
                        step -= 1   // 动画全在 `.onChange(of: step)` 里(参数驱动,与下一步同一套)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsTheme.ink2)
                }
                Spacer()
                Button(step == totalSteps - 1 ? "开始使用" : "下一步") {
                    if step == totalSteps - 1 {
                        finish()
                    } else {
                        step += 1   // 同上:切步动效由 `.onChange(of: step)` 统一驱动
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().fill(SettingsTheme.beam))
                .contentShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
        .background {
            SettingsWindowChrome().frame(width: 0, height: 0)
            SettingsTheme.paper
        }
        .ignoresSafeArea(.container, edges: .top)
        .focusEffectDisabled(!SettingsTheme.showsFocusRing)
        // 切步:两拍 —— ①禁用动画的事务把正文推到半透明 + 下移 6pt(即拍生效);
        //   ②下一拍用 `SettingsMotion.contentSwap` 收回。参数驱动的柔和切步,
        //   不靠 `.transition` ⇒ 系统减少动效时照样演,只是被 `MotionPolicy` 折成短线 ✓
        .onChange(of: step) { _, _ in
            var push = Transaction()
            push.disablesAnimations = true
            withTransaction(push) {
                stepOpacity = 0.15
                stepOffsetY = 6
            }
            DispatchQueue.main.async {
                withAnimation(MotionPolicy.animation(SettingsMotion.contentSwap)) {
                    stepOpacity = 1
                    stepOffsetY = 0
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .glancePanelDidSummon)) { _ in
            triedSummon = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            trigger = TriggerConfig.load()
            takeover = TriggerConfig.takeoverEnabled
        }
    }

    // MARK: - Step 1：按屏隔离 + 当场按一次

    private var stepOneTrySummon: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("鼠标在哪块屏，就只切哪块屏的窗")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SettingsTheme.ink)

            Text("Glance 替换系统跨屏乱弹的切换体验：按屏隔离候选列表，选中哪扇窗就只拉起哪扇窗。")
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                KeyChip(text: trigger.display)
                VStack(alignment: .leading, spacing: 2) {
                    Text(triedSummon ? "已成功唤起切换面板" : "现在按一下试试唤起面板")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SettingsTheme.ink)
                    Text("面板开启时随时按 ? 或 / 可打开快捷键速查卡。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsTheme.ink2)
                }
                Spacer()
                Image(systemName: triedSummon ? "checkmark.circle.fill" : "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(triedSummon ? Color.green : SettingsTheme.beam)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsTheme.tabRail)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(SettingsTheme.hairline, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Step 2：浏览样式与外观

    private var stepTwoStyle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("挑一套合眼的窗口呈现与外观")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SettingsTheme.ink)

            HStack(spacing: 10) {
                OnboardingLayoutCard(title: "卡片行",
                                     desc: "同 App 多窗并排平铺，适合窗口不多时一眼扫完。",
                                     selected: windowLayoutRaw == WindowLayout.row.rawValue) {
                    windowLayoutRaw = WindowLayout.row.rawValue
                }
                OnboardingLayoutCard(title: "芯片轨道",
                                     desc: "左侧大图预览 + 右侧标题目录，专治 IDEA / 浏览器多窗。",
                                     selected: windowLayoutRaw == WindowLayout.rail.rawValue) {
                    windowLayoutRaw = WindowLayout.rail.rawValue
                }
            }

            HStack {
                Text("外观主题")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsTheme.ink)
                Spacer()
                HStack(spacing: 6) {
                    appearancePill("跟随系统", value: AppearancePreference.auto)
                    appearancePill("浅色", value: AppearancePreference.light)
                    appearancePill("深色", value: AppearancePreference.dark)
                }
            }
            .padding(.top, 4)
        }
    }

    private func appearancePill(_ title: String, value: String) -> some View {
        let on = appearance == value
        // 胶囊底挪进 label:①整颗胶囊都能点(原来只有文字是命中区 ✗);
        // ②按压微缩缩的是"整颗胶囊",不是只缩文字 ✓
        return Button {
            appearance = value
            AppearancePreference.apply()
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .white : SettingsTheme.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(on ? SettingsTheme.beam : SettingsTheme.tabRail)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(SettingsButtonStyle(scale: 0.96, hoverTint: false, cornerRadius: 10))
        // 换主题:底色(蓝 ↔ 灰)与文字颜色平滑过渡
        .animation(MotionPolicy.animation(SettingsMotion.status), value: on)
    }

    // MARK: - Step 3：高频效率开关

    private var stepThreeShortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("顺手开启高频捷径")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SettingsTheme.ink)
                .padding(.bottom, 2)

            SettingsRow(title: "接管系统 ⌘Tab",
                        desc: "直接用 ⌘Tab 唤起 Glance，关闭后自动还原系统原生切换器。") {
                BeamSwitch(isOn: Binding(
                    get: { takeover },
                    set: { on in
                        takeover = on
                        TriggerConfig.setTakeover(on)
                        if on {
                            UserDefaults.standard.set(0x30, forKey: Keys.triggerKeyCode)
                            UserDefaults.standard.set("command", forKey: Keys.triggerModifier)
                        } else {
                            UserDefaults.standard.removeObject(forKey: Keys.triggerKeyCode)
                            UserDefaults.standard.removeObject(forKey: Keys.triggerModifier)
                        }
                    }
                ))
            }

            SettingsRow(title: "数字键 1–9 直选 App",
                        desc: "面板开启时直接按 1–9 跳到第 N 格，无需逐格按 Tab。") {
                BeamSwitch(isOn: $digitPicksApp)
            }

            SettingsRow(title: "双击 ⌥ 指针跳到下一块屏",
                        desc: "多屏工作时快速把指针与焦点送到另一块显示器。",
                        hairline: false) {
                BeamSwitch(isOn: $doubleOptionJumps)
            }
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Keys.appOnboardingCompleted)
        onFinish()
    }
}

// MARK: - 版式选择卡

/// 引导第二步的两张版式卡(原先内联在 `OnboardingView.layoutChoice` 里)。
/// 提成独立 view 只为一件事:**hover 需要 `@State`**(内联的 `some View` 方法没法持有状态)。
/// 按压微缩交给 `SettingsButtonStyle`;卡本身已有底色,再叠一层 hover 底会发脏 ⇒ 只提一层极浅白 ✓
private struct OnboardingLayoutCard: View {
    let title: String
    let desc: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? SettingsTheme.beam : SettingsTheme.ink2)
                        .contentTransition(.opacity)
                }
                Text(desc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SettingsTheme.tabRail)
                    .overlay(
                        // 选中态:发丝 → 强调蓝 + 描边加粗(参数动画,不做 .transition)
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? SettingsTheme.beam : SettingsTheme.hairline,
                                          lineWidth: selected ? 1.5 : 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(hovering ? 0.10 : 0))
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(SettingsButtonStyle(scale: 0.98, hoverTint: false, cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(MotionPolicy.animation(SettingsMotion.status), value: selected)
        .animation(MotionPolicy.animation(SettingsMotion.hover), value: hovering)
    }
}
