import SwiftUI
import AppKit
import GlanceCore

// MARK: - 外观区实时交互预览条（响应颜色外观 / 高光效果 / App 间距）

/// 嵌在「外观」组底部的微型切换器舞台：
/// 鼠标滑过或点击小图标，玻璃托底实时跟随；拖动「App 间距」或拨动「高光效果」开关会当场反馈画面。
struct AppearanceRingToy: View {
    let clearance: Double
    let sheen: Bool
    let appearance: String

    @State private var selectedIndex = 2
    @State private var hoveredIndex: Int?
    @Namespace private var puckNS

    private struct TileSpec: Identifiable {
        let id: Int
        let symbol: String
        let topColor: Color
        let bottomColor: Color
        let glowColor: Color
    }

    private let tiles: [TileSpec] = [
        .init(id: 0, symbol: "terminal.fill", topColor: Color(red: 0.24, green: 0.27, blue: 0.34), bottomColor: Color(red: 0.13, green: 0.15, blue: 0.20), glowColor: Color(red: 0.38, green: 0.72, blue: 0.98)),
        .init(id: 1, symbol: "safari.fill", topColor: Color(red: 0.20, green: 0.58, blue: 0.96), bottomColor: Color(red: 0.10, green: 0.36, blue: 0.84), glowColor: Color(red: 0.28, green: 0.66, blue: 1.0)),
        .init(id: 2, symbol: "sparkles", topColor: Color(red: 0.45, green: 0.42, blue: 0.95), bottomColor: Color(red: 0.28, green: 0.24, blue: 0.78), glowColor: Color(red: 0.62, green: 0.52, blue: 1.0)),
        .init(id: 3, symbol: "doc.text.fill", topColor: Color(red: 0.96, green: 0.62, blue: 0.22), bottomColor: Color(red: 0.82, green: 0.41, blue: 0.12), glowColor: Color(red: 1.0, green: 0.68, blue: 0.28)),
        .init(id: 4, symbol: "music.note", topColor: Color(red: 0.95, green: 0.30, blue: 0.45), bottomColor: Color(red: 0.75, green: 0.16, blue: 0.32), glowColor: Color(red: 1.0, green: 0.38, blue: 0.54)),
    ]

    private var activeIndex: Int { hoveredIndex ?? selectedIndex }

    /// 按比例压缩真实的 `4...28 pt` 间距，让滑块拖动时能一眼看到相邻图标让位。
    private var scaledClearance: CGFloat {
        CGFloat(clearance - 4) * 0.42
    }

    private var isForcedDark: Bool {
        appearance == AppearancePreference.dark
    }

    private var isForcedLight: Bool {
        appearance == AppearancePreference.light
    }

    private var stageBg: Color {
        if isForcedDark { return Color(.sRGB, red: 0.13, green: 0.14, blue: 0.17) }
        if isForcedLight { return Color(.sRGB, red: 0.94, green: 0.95, blue: 0.97) }
        return SettingsTheme.tabRail
    }

    private var puckFill: Color {
        if isForcedDark { return Color.white.opacity(0.14) }
        if isForcedLight { return Color.white.opacity(0.86) }
        return SettingsTheme.puck
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("手感预览")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsTheme.ink)
                Text(hoveredIndex != nil ? "指针跟随 · 间距 \(Int(clearance)) pt" : "划过图标试试效果")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsTheme.ink2)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            // 迷你玻璃环
            HStack(spacing: 6) {
                ForEach(tiles) { tile in
                    let isSelected = tile.id == activeIndex
                    let isNeighbor = abs(tile.id - activeIndex) == 1
                    let sideOffset: CGFloat = isNeighbor
                        ? (tile.id < activeIndex ? -scaledClearance * 0.45 : scaledClearance * 0.45)
                        : 0

                    ZStack {
                        if isSelected {
                            if sheen {
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            colors: [tile.glowColor.opacity(0.45), .clear],
                                            center: .center, startRadius: 2, endRadius: 22
                                        )
                                    )
                                    .frame(width: 40, height: 40)
                                    .allowsHitTesting(false)
                            }
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(puckFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(SettingsTheme.puckLip, lineWidth: 0.75)
                                )
                                .shadow(color: .black.opacity(0.10), radius: 3, y: 1.5)
                                .frame(width: 28, height: 28)
                                .matchedGeometryEffect(id: "toyPuck", in: puckNS)
                        }

                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(
                                LinearGradient(colors: [tile.topColor, tile.bottomColor],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .overlay(
                                Image(systemName: tile.symbol)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                            )
                            .frame(width: 22, height: 22)
                            .scaleEffect(isSelected ? 1.12 : 1.0)
                            .offset(y: isSelected ? -2.5 : 0)
                            .saturation(sheen && !isSelected ? 0.65 : 1.0)
                            .opacity(sheen && !isSelected ? 0.78 : 1.0)
                            .shadow(color: .black.opacity(isSelected ? 0.18 : 0.08), radius: isSelected ? 4 : 1.5, y: 1.5)
                    }
                    .frame(width: 28, height: 32)
                    .padding(.horizontal, isSelected ? scaledClearance * 0.35 : 0)
                    .offset(x: sideOffset)
                    .contentShape(Rectangle())
                    .onHover { over in
                        withAnimation(MotionPolicy.animation(SettingsMotion.puck)) {
                            if over { hoveredIndex = tile.id } else if hoveredIndex == tile.id { hoveredIndex = nil }
                        }
                    }
                    .onTapGesture {
                        withAnimation(MotionPolicy.animation(SettingsMotion.puck)) {
                            selectedIndex = tile.id
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(stageBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(SettingsTheme.hairline, lineWidth: SettingsMetrics.hairline)
                    )
            )
            .animation(MotionPolicy.animation(SettingsMotion.puck), value: clearance)
            .animation(MotionPolicy.animation(SettingsMotion.tint), value: sheen)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsTheme.tabRail)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(SettingsTheme.hairline, lineWidth: SettingsMetrics.hairline)
                )
        )
        .padding(.bottom, 6)
    }
}

// MARK: - 实时预览板式小图景（芯片轨道 vs 多张预览卡）

/// 点击即可在「芯片轨道」与「多张预览卡」之间切换，同时以微缩示意呼应下方的帧率状态。
struct TrayLayoutToy: View {
    @Binding var useChipRail: Bool
    let fps: Int

    @State private var selectedChip = 0
    /// 版式切换的入场系数(2026-11-25):0.35 → 1。参数驱动 ⇒ 系统开着「减弱动态效果」也照演 ✓
    @State private var layoutReveal: Double = 1
    @Namespace private var chipNS

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(fps > 0 ? Color.green : SettingsTheme.ink2.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(useChipRail ? "芯片轨道模式" : "多卡平铺模式")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsTheme.ink)
                }
                Text(fps > 0 ? "实况预览 \(fps) fps · 点击切换版式" : "静态快照模式 · 点击切换版式")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsTheme.ink2)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Group {
                if useChipRail {
                    HStack(spacing: 6) {
                        miniWindowCard(active: true, width: 52, height: 34)
                        VStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(i == selectedChip ? SettingsTheme.beam.opacity(0.85) : SettingsTheme.trackOff.opacity(0.65))
                                    .frame(width: 28, height: 7)
                                    .matchedGeometryEffect(id: "miniWin\(i)", in: chipNS)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { i in
                            miniWindowCard(active: i == selectedChip, width: 28, height: 30)
                                .matchedGeometryEffect(id: "miniWin\(i)", in: chipNS)
                        }
                    }
                }
            }
            .opacity(layoutReveal)
            .scaleEffect(0.97 + 0.03 * layoutReveal)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SettingsTheme.puck)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(SettingsTheme.hairline, lineWidth: SettingsMetrics.hairline)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture { swapLayout() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SettingsTheme.tabRail)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(SettingsTheme.hairline, lineWidth: SettingsMetrics.hairline)
                )
        )
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// 版式切换(2026-11-25:原来只是一条 `useChipRail.toggle()`,而 if/else 两分支的内容替换
    /// 压根没过渡 —— 小图景"叭"地就换了 ✗)。两件事分开做:
    /// ① 版式换过去仍旧走 `SettingsMotion.puck` —— `matchedGeometryEffect` 的卡片位移靠这个事务
    ///   (放进禁用动画的事务里,卡片会瞬间跳过去 ✗);
    /// ② 再叠一层"入场":当拍把示意图压暗缩小(禁动画),下一拍用 `SettingsMotion.contentSwap` 收回。
    ///   全程不靠 `.transition` —— 系统「减弱动态效果」会把过渡抹成瞬切,参数动画不受影响 ✓
    private func swapLayout() {
        withAnimation(MotionPolicy.animation(SettingsMotion.puck)) { useChipRail.toggle() }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { layoutReveal = 0.35 }
        DispatchQueue.main.async {
            withAnimation(MotionPolicy.animation(SettingsMotion.contentSwap)) { layoutReveal = 1 }
        }
    }

    private func miniWindowCard(active: Bool, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(active ? SettingsTheme.beam.opacity(0.18) : SettingsTheme.keyBg)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(active ? SettingsTheme.beam.opacity(0.75) : SettingsTheme.hairline,
                                  lineWidth: active ? 1.2 : SettingsMetrics.hairline)
            )
            .overlay(alignment: .topLeading) {
                HStack(spacing: 2) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 3, height: 3)
                    Circle().fill(Color(red: 0.99, green: 0.74, blue: 0.18)).frame(width: 3, height: 3)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 3, height: 3)
                }
                .padding(4)
            }
            .frame(width: width, height: height)
    }
}

// MARK: - 物理感键帽簇（快捷键页）

/// 把 `"Tab / ⇧ Tab"`、`松开 ⌘ / Esc`、`Q / W / M` 拆成有立体底边的物理键帽，
/// 一眼分清组合键与各自独立的热键；保留 `KeyChip` 在可录制按钮处的契约。
struct KeyCapCluster: View {
    let spec: String

    var body: some View {
        let parts = spec.components(separatedBy: " / ")
        HStack(spacing: 5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                if idx > 0 {
                    Text("/")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SettingsTheme.ink2.opacity(0.65))
                }
                Text(part)
                    .font(SettingsFont.key)
                    .foregroundStyle(SettingsTheme.ink.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(SettingsTheme.hairline)
                                .offset(y: 1.5)
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(SettingsTheme.keyBg)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(SettingsTheme.puckLip.opacity(0.7), lineWidth: 0.5)
                                )
                        }
                    )
            }
        }
    }
}

// MARK: - 「关于」互动考拉英雄区

/// 居中呈现 Glance 考拉图标、棱镜微光圈与版本/标语；轻拍考拉会弹跳眨眼并冒出一句小纸条。
struct KoalaAboutHero: View {
    let version: String
    let build: String

    @State private var hovered = false
    @State private var boopScale: CGFloat = 1.0
    @State private var boopTilt: Double = 0
    @State private var patCount = 0
    @State private var noteText: String?
    /// 小纸条的"在场"标志(2026-11-25)。纸条与标语**两层常驻**在一个 ZStack 里,
    /// 出场只改 opacity/scale 这两个参数 —— 不再用 `.transition`
    /// (本机 `reduceMotion = 1`,框架会把过渡抹成瞬切 ⇒ 轻拍考拉几乎没反馈 ✗)
    @State private var noteVisible = false
    @State private var hideNoteWork: DispatchWorkItem?

    private let whispers = [
        "耳朵里藏着正在排队的窗口。",
        "轻点 ⌘Tab 就能瞬间闪切，试试看！",
        "每一个窗口，都值得被单独看见。",
        "光透过玻璃的样子，刚刚好。",
        "按 ? 可以随时唤出快捷键速查。",
        "今天切窗也很顺滑吧。"
    ]

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // 悬停/轻拍时考拉背后的柔色光晕（复用棱镜色板，克制点缀）
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color(red: 0.22, green: 0.74, blue: 0.97),
                                Color(red: 0.55, green: 0.49, blue: 0.96),
                                Color(red: 0.98, green: 0.56, blue: 0.35),
                                Color(red: 0.29, green: 0.87, blue: 0.50),
                                Color(red: 0.22, green: 0.74, blue: 0.97)
                            ],
                            center: .center
                        )
                    )
                    .frame(width: 118, height: 118)
                    .blur(radius: 22)
                    .opacity(hovered ? 0.32 : 0.12)
                    .scaleEffect(hovered ? 1.06 : 0.94)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(hovered ? 0.22 : 0.16), radius: hovered ? 12 : 8, y: hovered ? 6 : 4)
                    .scaleEffect(boopScale * (hovered ? 1.04 : 1.0))
                    .rotationEffect(.degrees(boopTilt))
                    .onHover { over in
                        withAnimation(MotionPolicy.animation(SettingsMotion.puck)) { hovered = over }
                    }
                    .onTapGesture {
                        patKoala()
                    }
                    .help("点一下考拉")
            }

            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    Text("Glance")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(SettingsTheme.ink)
                    Text("v\(version) (\(build))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(SettingsTheme.ink2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(SettingsTheme.tabRail)
                                .overlay(Capsule().strokeBorder(SettingsTheme.hairline, lineWidth: SettingsMetrics.hairline))
                        )
                }

                // 纸条与标语同层常驻,靠 `noteVisible` 交叉淡入淡出(参数驱动,不靠 `.transition`)
                ZStack {
                    Text("每一个窗口，都值得被单独看见")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsTheme.ink2)
                        .opacity(noteVisible ? 0 : 1)
                    if let noteText {
                        Text(noteText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsTheme.beam)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(SettingsTheme.beam.opacity(0.10))
                                    .overlay(Capsule().strokeBorder(SettingsTheme.beam.opacity(0.25), lineWidth: 0.75))
                            )
                            // 连着拍好几次时,新句子自己淡化换代(不硬跳)
                            .contentTransition(.opacity)
                            .opacity(noteVisible ? 1 : 0)
                            .scaleEffect(noteVisible ? 1 : 0.92)
                            .allowsHitTesting(false)
                    }
                }
                .animation(MotionPolicy.animation(SettingsMotion.status), value: noteText)
                .animation(MotionPolicy.animation(SettingsMotion.status), value: noteVisible)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func patKoala() {
        patCount += 1
        let tiltDirection = patCount.isMultiple(of: 2) ? 4.5 : -4.5
        // 轻拍的弹跳收回 token(`SettingsMotion.press`):与全窗按钮同一根弹簧(0.18 / 0.72)
        if let anim = MotionPolicy.animation(SettingsMotion.press) {
            withAnimation(anim) {
                boopScale = 0.91
                boopTilt = tiltDirection
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                withAnimation(anim) {
                    boopScale = 1.0
                    boopTilt = 0
                }
            }
        }
        let message = patCount >= 5 && patCount.isMultiple(of: 3)
            ? "被顺毛了 \(patCount) 次，心情很好 ✓"
            : whispers[(patCount - 1) % whispers.count]
        // 画面过渡归 `noteVisible` 的 `.animation(_, value:)` 管,这里只改数值
        noteText = message
        noteVisible = true
        hideNoteWork?.cancel()
        let work = DispatchWorkItem {
            noteVisible = false
            // 淡出走完再清文字:提前清会让纸条"啪"地消失(动画中途换内容 = 硬跳 ✗)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                guard !noteVisible else { return }
                noteText = nil
            }
        }
        hideNoteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}
