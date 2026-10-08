import SwiftUI
import AppKit
import GlanceCore

/// **幽灵贴**(T84):托盘启动行的「壳」—— 未启动图标坐在一枚 **app 图标几何**的玻璃贴里。
/// 立身之本:**图标同尺寸 + macOS 图标同圆角比例**(`ghostTileRadius`),
/// 材质比 puck 收一档 —— 壳是座位,不是主角。
/// (曾兼作主环入口槽的底座;v15 用户终审:入口槽**不要底座** —— 无底色/无边框/无软影,
/// 只留点阵 + 凸透镜放大。任何"贴"在入口槽里都会被读成一枚 App,而它只是个入口。)
struct GhostTile: View {
    var body: some View {
        let r = PanelMetrics.ghostTileRadius
        return RoundedRectangle(cornerRadius: r, style: .continuous)
            .fill(PanelColors.ghostTile)
            .overlay(
                // 发丝外边:浅色暗发丝收形;深色不给白边(v14)
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(PanelColors.ghostTileBorder, lineWidth: 1)
            )
            // 贴身软影:壳离玻璃 1mm 的那点厚度
            .shadow(color: Color(nsColor: NSColor.black.withAlphaComponent(0.10)),
                    radius: 4, x: 0, y: 2)
    }
}

/// 切换器主面板 —— 施工契约 = 最新设计 demo「Liquid Glass App Switcher」。
///
/// 本文件是全系统度量与色板的**唯一来源**:`PanelController` 的定位数学与两个面板视图同源,
/// 任何数值只在这里定义一次。
///
/// 与 v1.10 的分野:选择态不再是"图标底下贴一块托底",而是一枚**会滑动的 puck**(胶囊托底,
/// 宽度=图标宽、上下各出 8px),配图标 14px 上浮 + 1.14 放大 + 未选降饱和;玻璃边缘恢复
/// 1px 亮边 + 指针跟随的 sheen。玻璃底色仍交给原生 `NSGlassEffectView`,不手写 tintColor。
///
/// v1.11 = 动效对表,三处机械病因的处治(别再退回去):
/// 1. **sheen 看不见**:demo 的 `.panel-sheen` 是 `mix-blend-mode: soft-light` 叠在**玻璃 DOM
///    元素**上;原生这边玻璃是 WindowServer 在**进程外**合成的,压根不在我们的层树里 —— SwiftUI
///    的 `blendMode(.softLight)` 对着透明底混了个寂寞。改成等效亮度的普通 alpha 合成,
///    并且按 demo 的 z 序落位:玻璃之上、puck 与图标**之下**(旧版画在最顶上,糊在图标脸上)。
/// 2. **动效僵硬**:过冲 `timingCurve` 在 SwiftUI 里不可靠,而且每次打断都从**零速度**重起 ——
///    横扫面板就一顿一顿。可打断的动效一律换弹簧(`PanelMotion`):弹簧带着当前速度续跑,
///    打断是"接力"不是"重起"。
/// 3. **sheen 拖着玻璃重渲染**:指针每挪一像素写一次 `@State`,整个 body(含玻璃
///    `NSViewRepresentable`)重算一遍,`updateNSView` 被按在地上摩擦。sheen 改由自带
///    `CAGradientLayer` 的 `SheenNSView` 自己听本窗 `.mouseMoved`,只挪一个 layer 的 position。
struct PanelView: View {
    /// 指针光晕开关(设置 → 通用 →「指针光晕」)
    @AppStorage(Keys.panelSheen) private var sheen = KeyDefaults.sheen
    @ObservedObject var controller: PanelController

    var body: some View {
        ZStack {
            // 说话时:同一块玻璃,形状变成胶囊(芯片样式) —— 材质不变,只改形状。
            // 圆角 = 玻璃高的一半(真胶囊)。⚠️ 别在这里减 shadowPadStrip:hintContentSize
            // 是**玻璃**的账,窗口的呼吸区在 .padding(shadowPadStrip) 那一层(见文件尾)——
            // 上一版减了,算出负圆角喂给 NSGlassEffectView,玻璃形状当场失真
            // (「尺寸账两本」的又一份病例,见 PanelTokens.hintContentSize 的注释)
            GlassBackground(cornerRadius: controller.hintText == nil
                            ? PanelMetrics.rPanel
                            : PanelMetrics.hintContentSize.height / 2)
            // ★ **玻璃纱**(2026-10-08):浅色一道很淡的中性灰(深色透明),铺在**玻璃之上、图标之下** ✓
            //   目的:把基色从 0.89 压到 ≈0.84,贴住原生的两点反解(见 PanelColors.glassVeil 的推导 ✓)
            //   ⚠️ 必须挂在玻璃**之后**、内容**之前** —— 否则要么压到图标,要么盖在玻璃底下看不见 ✓
            .overlay(
                RoundedRectangle(cornerRadius: controller.hintText == nil
                                 ? PanelMetrics.rPanel
                                 : PanelMetrics.hintContentSize.height / 2,
                                 style: .continuous)
                    .fill(PanelColors.glassVeil)
                    .allowsHitTesting(false)
            )
            // ★★ **玻璃反光边**(2026-10-08)—— 三条否掉的错路都记在这,别再走:
            //   ① 2026-09-15:`strokeBorder` **均匀实线** ⇒ 「还是有边框看着」✗
            //   ② 本日第一稿:细 stroke + 模糊 ⇒ 「**像是描的边**, 没有手机**曲面屏**那种自然向下过渡」✗
            //      —— stroke 的亮度是**恒定**的:它只在那一圈上"亮",没有"离边缘越远越淡"这件物理 ✗
            //   ③ 本日第二稿:`fill(.clear).shadow(.inner(...))` ⇒ 编译过了,但实测贴边只 **+0.019** ✗
            //      —— 内阴影挂在**透明填充**上几乎不变现(它需要一层"面"才落得下来)✗
            //   ⇒ 正解 = **层叠的圈**:贴边一圈最亮,往里逐圈更淡更宽 ⇒ 合成出来就是"向内衰减的过渡" ✓
            //     与原生剖面同形(顶 +0.22 / 底 +0.215 / 左上 +0.25,整周均匀 ✓,紧贴内侧再 −0.04 ✓)
            //     代价:三圈描边(不触发任何离屏光栅化 ⇒ 比 .blur/.shadow 便宜 ✓;模糊只给一点点)
            .overlay(GlassRim(cornerRadius: controller.hintText == nil
                              ? PanelMetrics.rPanel
                              : PanelMetrics.hintContentSize.height / 2))
            glassTopEdge
// ★ 2026-09-24:未启动环**不要**这团光(用户裁定「意义不大」✓)
//   病例:加了"选中图标颜色晕染"之后,未启动环里它也出现,但**位置错位** ✗
//   原因:两个环是**同一条 strip** 加开关(`entrySelected` ✓),而这团光的位置按**主环几何**算 ✓
// ⚠️⚠️ 第二版(踩过):我先写成 `if sheen && !entrySelected` —— 换环那一刻**视图树变了** ⇒ 触发一次重排 ✗
//   ⇒ 正是 v1 抖动那一族(见本文件 182/204 行那两条诊断 ✓),而且刚好发生在"切环"那一下 ✗
//   ⇒ 改成"**视图一直在,只是不画**":布局零变化 ✓ 未启动环里也不出现 ✓
//   (设置里那个总开关仍用 `if`:会话级、极低频 ✓;换环是高频 ✓ 两者不能混为一谈)
if sheen {
                SheenOverlay(
                    active: controller.isVisible,
                    enabled: !controller.entrySelected,
                    center: { [weak controller] in controller?.sheenCenterInContent() },
                    tint: { [weak controller] in controller?.sheenTint },
                    owner: { [weak controller] in controller?.sheenTintOwner ?? "?" }
                )
            }

            iconStrip
                // 上下对称:选中态"往上长"的那一段由**克制幅度**承担,不由边距承担
                // (加边距会让未选中时的长条白厚一圈,见 PanelTokens.iconLift 的取舍)。
                // 水平内边距由 iconStrip 自己给(左 rowPadX / 右随启动区变,见那里)——
                // 这层只管竖直,不然左右各叠一层就是双重边距
                .padding(.vertical, PanelMetrics.rowPadY)
                // T91 表三:说话时环整条退场(窗口只剩芯片那么大)。退场是**当帧**的
                // (showHint 不带动画写状态):弹簧拖着的淡出就是用户实拍的「环一闪而过」
                .opacity(controller.hintText == nil ? 1 : 0)
                // ★★ 2026-10-08 换环翻牌**不再挂在这条图标行上** ✗ ——
                //   原来这里是 `.id(entrySelected) + .transition(SegmentFlip)`:
                //   ① 翻的只有**图标条** ⇒ 用户实评「环先变形到位、然后只翻图标 ⇒ 翻了个寂寞」✗
                //   ② `.transition` 会被系统「减弱动态效果」**自己**降级,Glance 的设置管不到 ✗
                //   ⇒ 现在改成"**整条环(玻璃 + 图标)当一块牌翻**":角度是控制器里的参数,
                //     挂在**环里那块容器**上(`RingFlipEffect`,见文件尾 ✓ 与托底 PuckView 同一套哲学)

            // T91 表三(用户口径):没有可启动的 App ⇒ **只要一枚芯片**。
            // 上一轮把尺寸和形状做了、**文字漏了** —— 于是"芯片出来了, 没文案"。
            // v2(2026-09-18「太大太重」):12pt regular + 14/6 内边距,配 168×36 的玻璃
            // (尺寸在 PanelMetrics.hintContentSize,别在这里另立一本)
            if let hint = controller.hintText {
                Text(hint)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: controller.contentSize().width, height: controller.contentSize().height)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rPanel, style: .continuous))
        // 模型 C(ADR-0013):段头 —— 只在未启动段存在,住在下缘 rowPadY 留白里
        // (零高度、不参与布局,不碰尺寸账)。发现性由 Tab 走到底自然遇见(那是模型本身),
        // 段头只负责交代两件事:这是什么、怎么回去。
        .overlay(alignment: .bottom) {
            if controller.entrySelected {
                Text("未启动的 App · ↑ 返回 / Tab 继续")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PanelColors.txt2)
                    .opacity(0.9)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4)
                    .allowsHitTesting(false)
            }
        }
        // 玻璃边:**软的受光唇**(删掉原来那条 1px 硬线 —— 见 PanelGlass.GlassEdge 的两张剖面表)
        .glassEdge(cornerRadius: PanelMetrics.rPanel)
        // 顶缘内阴影(demo inset 0 1px 0 --glass-inner-shadow):深色下这道暗线顺着圆角压住亮度
        // (挂 `PanelEdgeStyle.drawsEdge`:用户要"完全去掉"时,这两道也要一起消失)
        .overlay {
            if PanelEdgeStyle.drawsEdge {
                RoundedRectangle(cornerRadius: PanelMetrics.rPanel, style: .continuous)
                    .strokeBorder(PanelColors.glassInner, lineWidth: PanelMetrics.hairline)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
        }
        // 入场与退场**都不做动效**(v1.12 砍入场,2026-09-14 砍退场):
        // ⌘Tab 是效率动作,面板要"已经在",关闭要"已经没了"——两头都不该让用户等动画。
        // ★★ T91 病例(2026-09-17,用户实报「重启之后**第一次**唤起面板, 会闪一下, 有一道白光」):
        //
        // 这里原来挂着 `.opacity(controller.isVisible ? 1 : 0)` —— 窗口的出现/消失**本来**由
        // 控制器 orderFrontRegardless / orderOut 负责,这一层是多余的"双保险"。
        // 它的代价正好落在"第一次"上:`isVisible = true` 写下去之后,SwiftUI 的那一帧**还没重算**
        // ⇒ 窗口先上屏的是"玻璃 + 阴影",而**内容整层透明度还是 0** ⇒
        // 屏幕上一块空的白色玻璃 = 用户说的"一道白光";下一帧图标才补上。
        // 之后几次唤起之所以看不出来,是因为视图状态已经算过一帧了 —— 这就是"只在重启后第一次"。
        //
        // 结论:**视图不该再藏一层**。窗口在屏幕上 = 内容就可见。
        // (将来若真要做退场淡出,请用窗口的 alphaValue,别回到这里。)
        // 投影:长条用 .strip;芯片(说话局)换 .puck —— .strip 的深色 α .62 是大面板的配重,
        // 小胶囊扛不住,读作"重"(用户 2026-09-18「太大太重」的后一半)。
        // 用改参数而不是改修饰符链:视图身份不变,与"参数归零"同一条规矩(见 elevation 的注释)
        .elevation(controller.hintText == nil ? .strip : .puck)
        // ★ 唤起轻弹 = **横向橡皮筋**(2026-10-08 第三版):只拉**宽度**,高度不变 ✓
        //   ⚠️⚠️ 必须用 **transform**(`scaleEffect(x:y:)`),不许逐帧改 `frame` ✗ ——
        //     第二版把弹写成"宽度每帧变一次" ⇒ 那是**逐帧布局** ⇒ 一唤起就踩
        //     "Update Constraints in Window pass" 递归 ⇒ SIGABRT ✗(真机复现 ✓)
        //     而等比 scaleEffect 那版连按 10 轮 0 崩 ✓ ⇒ 差别就在"布局 vs 绘制" ✓
        .scaleEffect(x: controller.entryPopStretch, y: 1, anchor: .center)
        // ⚠️⚠️ 换环翻牌**不在这一层做**(2026-10-08 修):
        //   这里原来挂着 `.rotation3DEffect(ringFlipAngle)` —— 那是"整条环当一块牌翻"那一版的残留 ✗
        //   它把**整块玻璃**一起转了 ⇒ 玻璃材质掉(变透明/暗板 ✗),而且它和下面 `RingFlipEffect`
        //   里那层**同时**在转 ⇒ 用户那四格消元实验(3D/2D × 长度变/不变)**全部失效** ✗✗
        //   ⇒ 翻牌只由 `RingFlipEffect` 作用在**环里那块容器**上;玻璃/阴影/受光边在这一层保持不动 ✓
        .padding(PanelMetrics.shadowPadStrip) // 必须与 PanelController.paddedSize 口径一致
        // ★ 2026-09-22:窗框现在按"两环更宽者"开一局 ⇒ 环比窗框窄时,内容要**居中**摆放
        //   (玻璃仍按各自环宽画 ✓,只是它在窗里居中 ⇒ 换环时左右边缘一动不动 ✓)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusEffectDisabled(true)   // ★ 窗口根:切换器面板永不出现焦点环
        // ⚠️ 这里**不许**再包"撑满窗口的弹性 frame"(同根变形 v2 试过,为了在 oversized 窗口里
        // 居中玻璃)—— 根视图尺寸依赖提议、提议依赖尺寸 ⇒ AppKit Update Constraints 布局递归
        // FAULT(2026-09-18 实机崩溃,本仓库此病第三次现形)。段变形的居中问题已在窗口侧解决。
    }

    // MARK: - 图标层

    /// (2026-10-08 原 `segmentTransition` / `_segmentTransitionLegacy` 已删:
    ///  翻牌改由 `controller.ringFlipAngle` 参数驱动,挂在整个面板根上 —— 见 body 尾部 ✓
    ///  它们原来挂在 `iconStrip` 的 `.id() + .transition()` 上,只会翻"图标条"而且归不了 Glance 的设置 ✗)

    private var iconStrip: some View {
        // spacing 归零、格子自己吃掉左右各半个间隙(hitSlop),App 区两端再负 padding 收回来 ——
        // 这样格与格之间没有"鼠标划过却什么都不选中"的死区。
        // T89 v2:负 padding **只属于 App 区**(内层 HStack)—— 它原本吃在整条上,
        // 会把尾格的右半格也吃掉,点阵到玻璃边变成 rowPadX+半格,比线到两边宽出一档
        // (用户实拍「左右不对称」)。右缘留白也改成 iconGap:尾部节奏三点同距
        // (App→线 = 线→点 = 点→玻璃边 = iconGap)。
        // ★★ 2026-10-08 定版(**用户提案**):**环里加一个容器,只翻那个容器** ——
        //   玻璃不转(转了就掉材质 ✗)、也**不逐帧改宽度**(每帧 resize 原生玻璃同样掉材质 ✗,
        //   两轮截图都验过)⇒ 玻璃只在"看不见的那一帧"(内容侧立)变一次长度 ✓
        //   容器里的内容由控制器在侧立那一帧换掉(看不见 ✓),所以这里只需要一块容器 ✓
        ringRow(launch: controller.entrySelected)
            .modifier(RingFlipEffect(angle: controller.ringFlipAngle, progress: flipProgress))
            // ★ 唤起轻弹(2026-10-08):纯 2D 缩放,作用于**环里那块内容**,玻璃不动 ✓
            //   参数按 Apple 录屏逐帧量:起始略大(默认 1.04)→ 130ms ease-out 收到位 ✓
            //   ⚠️ 起跳**延后一拍**(见 PanelController.showPanel):提前起跳会踩 AppKit 的
            //     "Update Constraints in Window pass" 递归 ⇒ 一唤起就 SIGABRT ✗
            //     (缩放/位移两版都验过;延后一拍是最后一条活路 —— 还崩就按 v1.12 收场,别再试 ✗)

            // ★★ 2026-10-08 病例(**别再试了**):这里**不许做"唤起入场动效"** ✗
            //   用户提「Spotlight 唤起有个 Q 弹的动效, Glance 是直接打在屏幕上的, 能借鉴吗」⇒
            //   我做了两版(内容 `scaleEffect` / 内容 `offset` + 弹簧),**两版都一唤起就闪退** ✗:
            //     AppKit 抛 `NSGenericException`:「The window has been marked as needing another
            //     Update Constraints in Window pass … more passes than there are views in the window」
            //     ⇒ 布局递归 ⇒ SIGABRT ✓(本仓第三次栽在这一族 ✓)
            //   为什么换环的旋转没事:它发生在**面板落定之后**;而入场动效正好横跨
            //     `orderFront → layoutSubtreeIfNeeded → displayIfNeeded` 那几拍 ✗
            //   ⇒ 与 v1.12 那条裁定一致:**面板要"已经在",两头都不该让用户等动画** ✓
        // demo 的 .puck 是 z-index:1、.app-row 是 z-index:2——托底在图标**后面**。
        // SwiftUI 里 overlay 画在内容上面,会把选中格蒙住并吃掉点击,必须用 background。
        // 挂在**水平 padding 之前**:托底要对齐的是第一枚图标(负 padding 后的 frame 左缘),不是玻璃边
        // ★ 2026-10-08(用户:「翻转的时候, 托底滑块没有动作」):
        //   托底是**主环内容**的一部分 ⇒ 它必须跟环一起翻 ✓
        //   翻出去:托底跟主环一起转到侧立(第一半);换环那一帧 `entrySelected` 反转 ⇒
        //   托底按"只在主环显示"的旧规矩消失 —— 而那一刻它正好在 ±88°(一条线,看不见)✓
        //   ⇒ 消失是无缝的,不需要额外的淡出 ✗
        .background(alignment: .leading) {
            puck
                .modifier(RingFlipEffect(angle: controller.ringFlipAngle, progress: flipProgress))
                .allowsHitTesting(false)
        }
        .padding(.leading, PanelMetrics.rowPadX)
        .padding(.trailing, PanelMetrics.rowPadX)
    }

    /// 翻牌的进度(0…1):只用来定"侧立时淡到多淡" ✓
    /// (翻法本身在 `RingFlipEffect` ✓)
    private var flipProgress: Double {
        min(abs(controller.ringFlipAngle) / PanelMetrics.ringFlipLimit, 1)
    }

    /// **一环的图标行**(主环 / 未启动环二选一)。
    /// 抽出来只为翻牌:那一拍要**同时**放两块(旧环翻出去 + 新环翻进来 ✓),玻璃留在原地 ✓
    @ViewBuilder
    private func ringRow(launch: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if launch {
                    // T91 ↓ 换环:这格里装的是"未启动的 App"——**完全覆盖**,不是多一行
                    ForEach(Array(controller.launchables.enumerated()), id: \.offset) { i, _ in
                        launchRingCell(i)
                    }
                } else {
                ForEach(Array(controller.groups.enumerated()), id: \.element.pid) { i, group in
                    IconCell(
                        group: group,
                        // 本局被我们缩小收纳过的 App ⇒ 图标上给个标记(用户第 2 条诉求 ✓)
                        mark: controller.mark(for: group.pid),
                        // **选中互斥**(v8 用户裁定):槽被占住时,主环的选中退场 ——
                        // 指针与 Tab 不能同时各选一个,一局只有一个"选中"
                        selected: i == controller.appIndex && !controller.entrySelected,
                        // 开局第一帧/animation 关掉时给 nil:窗口是复用的,上一局的选中会在新一局开局时
                        // 从第 5 位"飞"回第 1 位。demo 的 positionPuck(_, animate:false) 同理
                        motion: controller.selectionAnimation(PanelMotion.select)
                    )
                    .frame(width: PanelMetrics.pitch, height: PanelMetrics.icon)
                    // 入场升起**只给选中的那一格**(与托底同一次 withAnimation、同一根 spring):
                    // ① 正确范围:第一版做成整行一起升 → "全部图标一起弹出来了"(用户实评,太重);
                    // ② 为什么选中格必须跟着动:"正常 Tab 切换"里动的就是托底 + 新选中的那个图标,
                    //    其余的只是被取消选中 —— 只滑托底而图标已经就位,读起来就是"两个动作各走各的";
                    // ③ 幅度 = `entryFloatDistance`(选中图标自己的上浮量):读作"轻轻浮上来",不是"钻出来"
                    .offset(y: i == controller.appIndex && !controller.entrySelected ? controller.contentEntryRise : 0)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { controller.hoverApp(i) } }
                    // 点图标 = 选中;再点已选中的 = 确认它的头牌窗(或激活无窗应用)
                    .onTapGesture {
                        if i == controller.appIndex { controller.confirmSelection() } else { controller.hoverApp(i, strict: false) }
                    }
                }
            }
            }
            .padding(.horizontal, -PanelMetrics.iconGap / 2) // App 区首格左、末格右各收回半个间隙
        }
        // 主环 hover 的兜底轮询不挂在这里:TimelineView(.animation) 在静态窗口上**不跳帧**
        // (macOS 不给静止窗口排帧,"每帧"实际只是"有视图更新的那几拍"),兜不住
        // "界面静止、指针开始动"的那一刻 —— 帧拍已由控制器里的 60Hz 定时器统一驱动
        // (PanelController.startHoverPolling,主环 + 托盘一份账)。
    }

    /// 换环后(strip 里装的是"未启动的 App")的格子。
    ///
    /// 与托盘里那一行**同一套**(幽灵壳 + 图标收到 76% + 上浮这层反馈),不另立语言 ——
    /// 用户口径:「完全覆盖掉」:同一块地方换了内容,不是另一种东西。
    /// 托底不在这儿:仍是主环那一枚滑动的,只是换环后跟着 launchIndex 走(见 puckOffsetX)。
    private func launchRingCell(_ i: Int) -> some View {
        let app = controller.launchables[i]
        let sel = i == controller.launchIndex
        return ZStack {
            GhostTile().frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            Image(nsImage: app.icon)
                .resizable()
                .renderingMode(.original)
                .aspectRatio(contentMode: .fit)
                .frame(width: PanelMetrics.icon * 0.76, height: PanelMetrics.icon * 0.76)
        }
        .scaleEffect(sel ? PanelMetrics.iconScale : 1)
        .offset(y: sel ? controller.contentEntryRise - PanelMetrics.iconLift : 0)
        .elevation(.icon, active: sel)
        .frame(width: PanelMetrics.pitch, height: PanelMetrics.icon)
        .contentShape(Rectangle())
        .onHover { inside in if inside { controller.hoverApp(i) } }
        .onTapGesture { controller.launchAt(i) }
        .animation(controller.selectionAnimation(PanelMotion.select), value: controller.launchIndex)
    }
    
    /// 滑动托底 —— **实现搬去 `PuckView.swift`**(2026-09-22 拆分:它是独立一块,
    /// 几何/视觉/动效/落点数学全在那边,改它不用翻这个 500 行的视图 ✓)。
    /// 这里只负责"喂当前状态"。
    private var puck: some View {
        Puck(offsetX: Puck.offsetX(appIndex: controller.appIndex),
             entryRise: controller.contentEntryRise,
             visible: !controller.entrySelected,
             animation: controller.selectionAnimation(PanelMotion.slide),
             animationValue: controller.appIndex)
    }

    // MARK: - 启动区入口槽(方案 E v3:点阵记号 + 自己的轻选中语言)

    /// 托底落点:**回归主环**(v3 裁定)。v2 曾让托底滑进环尾槽(实心大胶囊罩住空槽,
    /// 用户实评"丑的要死");v3 起槽的选中由**记号自己**表达(点阵点亮 + 描边胶囊),
    /// 托底永远只属于主环的 App。历史账:"缩宽"与"滑过去淡出"两案也都试过、都被否
    /// —— 那是在"槽里没有可见记号"的前提下的困境;有了点阵,落点由记号承担。
    /// 顶缘一道**极窄的**受光边(深色专用)。
    ///
    /// 深色面板的"厚度"不来自阴影 —— 黑影子在黑底上没有对手。真正让人读出"这是块板"
    /// 的是顶缘这道亮线:光从上方来,玻璃的上沿受光,下沿背光,板子就有了厚度。
    /// macOS 自己的深色窗口、NSGlassEffectView 的深色态都有这道线。
    ///
    /// 与已删的 `glassTopLight`(白 .18 铺到 30% 高度)的区别在**高度**:
    /// 那道是一层纱(浅色上就是"透明度不行"的元凶),这道只有 1.5% 高度、只够描一条边。
    /// 浅色返回透明色(不改浅色)。
    /// 顶缘那道静态受光带 —— **只在深色**要(浅色不要,见上面的注释)。
    ///
    /// ★★ 判据**不许**读环境/DynamicColor(T91 病例,2026-09-17):
    /// 用户实报「**一排 app 上很明显的一条闪光**, 第二次唤起就没有了」。
    /// 根因:动态色(`PanelColors.glassTopEdge`)要靠"外观"解析,而进程起来后的**第一帧**里
    /// 窗口/环境的外观还没落定 ⇒ 它按**深色**解析 ⇒ 一排图标上方闪出一道亮线;
    /// 下一帧浅色生效,线就没了 —— 这正是"只在以后第一次"的来源。
    /// 现在改成读**设置里那个确定值**(UserDefaults 直读,第一时间就是对的),
    /// 「跟随系统」时才回落到 NSApp 的实际外观。
    @ViewBuilder
    private var glassTopEdge: some View {
        let pref = UserDefaults.standard.string(forKey: Keys.panelAppearance) ?? "system"
        let dark = pref == "dark"
            || (pref != "light" && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        if dark {
            LinearGradient(
                colors: [PanelColors.glassTopEdge, .clear],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.015)
            )
            .allowsHitTesting(false)
        }
    }

}

// MARK: - 图标格(选中 = 上浮 14 + 放大 1.14 + 提亮;未选 = 压暗去饱和)

/// 环上图标的**状态记号**(用户 2026-09-22 要求:常驻 + 贴切)
extension PanelMark {
    /// 记号怎么画 —— **视图细节,留在 App 层** ✓(领域层只有 `PanelMark` 这个两态枚举 ✓)
    ///
    /// ⚠️ 语义与表现分开看(2026-09-22 定版):
    ///   · `.tucked`(有窗被我们收进 Dock)⇒ **整枚图标变灰 + 压暗** ✓ —— 不画角标 ✓(见 IconCell)
    ///   · `.hidden`(⌘H)⇒ `eye.slash` 角标 ✓
    ///   `symbol` 因此只为 `.hidden` 而设 ✓
    /// 旧案留档(`.tucked` 走过的路):`arrow.down.to.line` = 下载图标 ✗ /
    /// `rectangle.compress.vertical` = 只有"被压缩" ✗ / 手画窗身+标题栏+小点 ⇒
    /// 用户评「有点丑, 复杂了, 一缩小就看着很脏」✗ / `rectangle.inset.bottomleft.filled` = 画中画 ✓
    /// ⇒ 最后**整枚变灰**顶替了角标 ✓ 教训:15pt 里"一个块面读懂" > 画得"准" ✓
    var symbol: String {
        switch self {
        case .tucked: return "rectangle.inset.bottomleft.filled"   // 已收纳不画角标:这里只为穷尽枚举 ✓
        case .hidden: return "eye.slash"
        }
    }
}

private struct IconCell: View {
    let group: AppGroup
    /// 图标右下角的状态记号(nil = 无记号)。
    /// ⚠️ `.tucked` **不画这个角标**(用户 2026-09-22 定版,见下面 `tuckedStyle`)——
    /// 它的表现是"整枚图标变灰",`mark` 只是携带那条信息 ✓
    let mark: PanelMark?
    let selected: Bool
    /// 该用的动效(nil = 不动:"面板不在台上"或系统要求降级)
    let motion: Animation?

    /// **光效总闸**(设置 → 通用 →「光效」):指针那团游走的柔光 + 这里的静态反光是同一件事的两半,
    /// 一起开、一起关(用户口径:"app 上的静态反光也关闭,一齐开启,或者关闭")。
    /// 关掉时图标回到**本来的样子**(不额外提亮、也不压暗),选中态靠放大 + 上浮 + 托底交代 ——
    /// 那三样是"形",不是"光",不受这个开关影响。
    @AppStorage(Keys.panelSheen) private var glow = KeyDefaults.sheen

    var body: some View {
        let art = IconProvider.art(for: group.pid)
        Image(nsImage: art.image)
            .renderingMode(.original)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            // ★ **"已收纳"= 整枚图标变灰**(2026-09-22 用户提案,我附议 ⇒ 定版)
            //   用户原话:「这个角标不够明显, 要不大胆一点, 不用角标表示了. 直接给 app 颜色改成
            //   遗照灰 哈哈哈」✓
            //   为什么同意:角标 15pt 这一路已经试过四种画法(箭头/压缩/手画窗/画中画),
            //   用户两次评"不够明白/有点丑/复杂了" ⇒ **"够明显"这条上,角标这条路已被证伪** ✓
            //   为什么不算乱来:macOS 自己对**隐藏的 App** 就是这个画法(Dock 里那枚淡淡的)⇒
            //   "变灰 = 不在台上"是系统已有的语言,不是我们新造的符号 ✓
            //   ⚠️ 与"选中"不冲突:选中是**形**(放大 + 上浮 + 托底 ✓),灰掉的是**光** ✓
            //      —— 仓库里早就定过这条口径(见 IconCell 顶部关于"光效总闸"的注释 ✓)
            //   ⚠️ 与"已隐藏"分得开:隐藏仍走 `eye.slash` 角标 ✓ 两套语言,一眼分辨 ✓
            .saturation(mark == .tucked ? 0 : (glow ? (selected ? 1.15 : 0.92) : 1))
            // ⚠️⚠️ **别用 opacity 表达"退后"** ✗ —— 用户 2026-09-22 实报:
            //   「坏了, 给后面的"骨头"显示出来了」:图标一透明,它**后面那一层**就露出来了
            //   (面板玻璃、相邻图标、托底那一块的轮廓全透出来 ⇒ 读成"碎图/见骨头" ✓)
            //   我上一版的对照图是画在**纯色底**上的 ⇒ 根本测不出这个 ✗
            //   ★ 纪律:量具必须包含**真实现场**(这里是"图标后面还有别的东西" ✓),否则等于没测 ✓
            // ⇒ 正确手法:**灰 + 压暗,全程不透明** ✓("退后"靠亮度差交代,不靠透明度 ✓)
            //   深色面板下图标本身就暗 ⇒ 压暗要更狠一点才读得出 ✓
            .brightness(mark == .tucked ? -0.10 : (glow ? (selected ? 0.05 : -0.04) : 0))
            // 倍率 = 选中放大 × 图标透明边距补偿。**补偿是必须的**:macOS 图标的画面只占画布
            // 87.5%(Finder/Safari/Xcode/Terminal 实测 .875,Chrome .867,Obsidian .83),
            // 直接铺进 78pt 格子,画面就只有 68pt —— 比 demo 里铺满格子的色块小一圈,
            // 面板四周的留白跟着全部放大,这就是"下巴长的离谱"的真身(实测选中图标下方
            // 空出 24.5pt,demo 只有 16.5pt)。补偿后画面正好铺满格子,与 demo 一比一对齐。
            .scaleEffect((selected ? PanelMetrics.iconScale : 1) * art.fill)
            .offset(y: selected ? -PanelMetrics.iconLift : 0)
            // 不变量:阴影跟图片 alpha 走,不裁圆角、不套矩形 box-shadow
            .elevation(.icon, active: selected)   // 帧率优先:只有选中那颗有投影
            .overlay(alignment: .bottom) { windowDots }
            // ★ "已收纳"角标(2026-09-22 用户第 2 条诉求:标记被缩小收纳的 app ✓)
            //   位置选右下角:那里平时空着(收纳之后窗数是 0 ⇒ 窗数记号也空着 ✓),不挤任何既有元素 ✓
            //   ⚠️ 形状/颜色是一行的事:想换别的记号(比如小箭头、或整个图标压暗)改这里就够 ✓
            // 角标只为"已隐藏"服务;"已收纳"走整枚变灰(见上面的 saturation/opacity ✓)
            .overlay(alignment: .bottomTrailing) { markBadge }
            .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            .contentShape(Rectangle())
            // 真实弹簧:response 越小越"脆",dampingFraction 越小回弹越明显。
            // 不用 .32s 的过冲 bezier —— 它在 SwiftUI 里不可靠,且每次打断从零速重起
            .animation(motion, value: selected)
    }

        /// **状态记号**(右下角一枚)
    ///
    /// 用户 2026-09-22:「怎么是个下载的 download 样式…设计的贴切一点, 高级一点」
    /// ⇒ 语汇换成**窗本身的形态**,不借"箭头"那个外来符号 ✓:
    ///   · **已收纳**(⌘M 收进 Dock)= `rectangle.compress.vertical` —— 一扇**被压扁的窗** ✓
    ///     (最小化真身就是"窗被压扁收进 Dock" ✓;而箭头一定会被读成"下载/导出" ✗)
    ///   · **已隐藏**(⌘H)= `eye.slash` —— 「看不见了」✓(与"收纳"必须能一眼分清 ✓)
    /// 底衬沿用芯片那套材料(chipBg + hairline + 极淡投影 ✓)—— 深浅底都读得清,且不是贴纸 ✓
    @ViewBuilder private var markBadge: some View {
        if let mark, mark == .hidden {   // ★ 只有"已隐藏"画角标("已收纳"= 整枚变灰 ✓)
            Image(systemName: mark.symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(PanelColors.thumbTitle)
                .frame(width: 15, height: 15)
                .background(Circle().fill(PanelColors.chipBg))
                .overlay(Circle().strokeBorder(PanelColors.chipBorder,
                                               lineWidth: PanelMetrics.hairline))
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                .offset(x: -1, y: -1)
                .allowsHitTesting(false)
        }
    }

/// 窗数记号:圆点 = 1 扇、**短横 = 5 扇**(记账法 / 罗马数字 I-V 那一套,见 `WindowTally`)。
    ///
    /// 2026-09-15 定稿:原来是"每扇窗一粒点" —— 13 扇正好铺满格子、20 扇溢出 1.56 倍
    /// (相邻两格的点连成一片),而且同色点只能逐个默数。现在:① 5 进制记号把 20 扇从 164pt
    /// 压到 29.8pt;② 超宽时**等比收窄**,到下限还放不下就从尾部摘记号(兜底,现实中到不了)。
    /// 口径(用户定):窗数不是必须被 100% 解析的信息 —— 它能告诉你"这家窗多",而不是
    /// "有 7 扇",所以宁可靠近示意也不要溢出。
    ///
    /// 选中时必须跟着图标一起抬(`dotLift`,理由见 `PanelTokens`)—— 记号挂的是**格子**底边,
    /// 而图标选中后是"上浮 + 放大"两件事一起动,不跟就会掉队到托盘底边上去。
    @ViewBuilder private var windowDots: some View {
        let tally = WindowTally.layout(windows: group.windows.count,
                                       available: PanelMetrics.icon,
                                       metrics: PanelMetrics.tally)
        if !tally.marks.isEmpty {
            HStack(spacing: tally.sizes.gap) {
                ForEach(Array(tally.marks.enumerated()), id: \.offset) { _, mark in
                    switch mark {
                    case .dot:
                        Circle()
                            .fill(PanelColors.dot)
                            .frame(width: tally.sizes.dot, height: tally.sizes.dot)
                    case .dash:
                        // 横要"压得住"五个点:与圆点同族、但明显更重(理由与对照图见 PanelMetrics.dashHeight)
                        Capsule()
                            .fill(PanelColors.dot)
                            .frame(width: tally.sizes.dashWidth,
                                   height: PanelMetrics.dashHeight * tally.sizes.scale)
                    }
                }
            }
            .opacity(0.8)
            .offset(y: PanelMetrics.dotBottom - (selected ? PanelMetrics.dotLift : 0))
        }
    }
}

// MARK: - 选中格高光(源自 demo .panel-sheen)
//
// demo:`radial-gradient(220px circle at mx my, rgba(255,255,255,.30), transparent 60%)`
//      + `mix-blend-mode: soft-light`,z 序在 `.panel-glass` 之上、`.puck`/`.app-row` 之下,
//      `transition: background .08s linear`(只跟光,不跟手粘死)。
//
// ★ 2026-10-08:**圆心改成"选中那一格的中心",不再跟着指针** ✗(用户裁定 ——
//   它读作"这个 App 被选中"的柔光,而不是一盏手电筒 ✓)。位置与颜色因此同源:
//   都取自控制器里的"当前选中" ⇒ 指针怎么移动都不影响它 ✓
//   (原来位置来自 `NSEvent.mouseLocation`、颜色来自选中图标 ⇒ 两个源,光晕会飘在空格子里 ✗)
//
// 两条原生现实决定了它不能照抄:
// 1. **混不动**:soft-light 要采样背后的像素,而原生玻璃由 WindowServer 在进程外合成,
//    我们层树里那一块是透明的 —— 对着透明底混,混出个寂寞。折换:soft-light(白)的等效
//    结果是 √b,按 .30 权重约提亮 0.06~0.08;白 alpha .12/.16 的普通合成给 0.05~0.09,肉眼等价。
// 2. **不能走 SwiftUI 状态**:指针每像素一写,整个 body(含玻璃 NSViewRepresentable)重算,
//    `updateNSView` 次次重进,拖着玻璃重渲染 —— 横扫面板一顿一顿的就是它。
//
// 3. **拿不到鼠标事件**(历史上的第三关,现已用不着):面板是 `nonactivatingPanel`,永不成 key。
//    AppKit 的 mouseMoved 只投给 key 窗口(上一版走 `addLocalMonitorForEvents(.mouseMoved)`,
//    一个事件都收不到),NSTrackingArea 在 non-key 窗口上也不可靠。
//    —— 这条只对"跟指针"那版要紧;圆心改成选中格之后,**根本不需要指针输入** ✓
//
// 解法:`TimelineView(.animation)` 每帧问一次控制器"选中格在哪",`Canvas` 直接画。三个好处:
// ① 它是纯 SwiftUI 内容,z 序就是写在 ZStack 里的顺序,不会被玻璃的 NSView 顶掉;
// ② 每帧只重算这一个叶子视图 —— 玻璃的 `updateNSView` 与图标一概不碰;
// ③ 圆心用闭包现问,不进 `@State`,指针怎么划都不产生状态变更。

struct SheenOverlay: View {
    /// 面板在台上吗(不在台上就让时间轴停摆,省掉每秒 60 次空转)
    let active: Bool
    /// 这一帧该不该画光(未启动环 = 不画 ✓)
    /// ⚠️ 它**不能**用 `if` 在调用处摘视图 —— 换环那一刻视图树一变就会触发重排 ⇒ 抖 ✗(踩过)
    let enabled: Bool
    /// **选中格的中心**(面板内容坐标;nil = 这一帧不画 —— 没有选中 / 未启动环 ✓)
    ///   它**与指针无关**:指针怎么移动都不改它(用户 2026-10-08 裁定 ✓)
    let center: () -> CGPoint?
    /// ★ 光晕的**颜色** = 选中 App 图标的主色（nil ⇒ 白：图标基本是灰的 / 还没选中 ✓）
    ///   30Hz 每帧问一次 ⇒ 走 `IconTint` 的缓存查表，很便宜 ✓
    let tint: () -> NSColor?
    /// 日志用:这个颜色属于哪个 App(只给排查看 ✓;与 `tint` **同一个源** ✓)
    let owner: () -> String
    @State private var tracker = SheenTracker()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // ⚠️ 30Hz 而不是每帧(2026-09-24):这里是**纯绘制**(Canvas 画一团径向渐变),
        //   指针采样不在这儿(那在控制器的 60Hz 定时器里)⇒ 降频只影响这团光的刷新率,
        //   手感一个字不变;而它是"面板在台上 = 8.2% 一个核"里的一份
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(active && enabled))) { _ in
            Canvas { ctx, _ in
                guard enabled else { tracker.reset(); return }   // 不画(未启动环 ✓)
                guard let (p, alpha) = tracker.step(target: center()) else { return }
                tracker.note(tint: tint(), owner: owner())
                let peak = (scheme == .dark ? PanelColors.sheenAlphaDark : PanelColors.sheenAlphaLight)
                    * alpha * PanelColors.sheenGain
                // 颜色跟着选中的那一格走（用户口径:要的是"图标本色的晕染" ✓;
                // 图标基本是灰的 ⇒ 退回白 —— 灰蒙蒙的染色比没有更糟 ✗）
                let base = tint().map { Color(nsColor: $0) } ?? .white
                let r = PanelMetrics.sheenExtent // demo 的 220px 是**结束形状半径**
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: base.opacity(peak), location: 0),
                            .init(color: base.opacity(0), location: PanelMetrics.sheenStop),
                        ]),
                        center: p, startRadius: 0, endRadius: r
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// 光晕的**移动**状态:圆心换格时带一点滞后(只跟光,不跟手粘死),进出面板带淡入淡出。
/// 故意做成**引用类型**:每帧改它不算 SwiftUI 状态变更,不会触发任何视图重算。
final class SheenTracker {
    private var point: CGPoint?
    private var intensity: CGFloat = 0
    private var logged = false
    /// 上一次报过的颜色(换色时才打一行 ⇒ "光晕到底跟的谁"一眼可见 ✓)
    private var lastTintHex: String?
    /// demo 的 `transition: background .08s linear`:每帧追 45%,约 80ms 跟到位
    /// (原来是"追指针";现在追的是**选中格** ⇒ 换选中时那团光会滑过去一小段,不是硬跳 ✓
    ///  要硬跳就设 1.0 ✓)
    private let follow: CGFloat = 0.45

    /// 返回这一帧该画的位置与强度;nil = 不画
    /// 颜色换了就报一行(trace 门 + 只在变化时 ⇒ 常态零噪声 ✓)
    func note(tint: NSColor?, owner: String) {
        guard isTraceEnabled else { return }
        let hex: String
        if let c = tint, let srgb = c.usingColorSpace(.sRGB) {
            hex = String(format: "#%02X%02X%02X", Int(srgb.redComponent * 255),
                         Int(srgb.greenComponent * 255), Int(srgb.blueComponent * 255))
        } else { hex = "白(图标基本是灰的 ⇒ 退回白)" }
        guard hex != lastTintHex else { return }
        lastTintHex = hex
        glog("[光晕] 颜色 = \(hex) · 跟的是 \(owner)")
    }

    /// 归零(被禁用时调用 ✓):免得再回来时那一帧闪在**旧位置** ✗
    func reset() { point = nil; intensity = 0 }

    func step(target: CGPoint?) -> (CGPoint, CGFloat)? {
        if let t = target {
            // 第一次被点亮打一行:光晕有没有被驱动起来,日志里一眼可见(只打一次)
            if !logged, isTraceEnabled { logged = true; glog("[T6] 光晕上线:圆心 \(Int(t.x)), \(Int(t.y))(跟选中格)") }
            point = point.map { CGPoint(x: $0.x + (t.x - $0.x) * follow, y: $0.y + (t.y - $0.y) * follow) } ?? t
            intensity += (1 - intensity) * 0.35
            return (point!, intensity)
        }
        intensity += (0 - intensity) * 0.18
        guard intensity > 0.01, let p = point else { point = nil; intensity = 0; return nil }
        return (p, intensity)
    }
}


/// 环里那块容器的"翻"法:绕**水平轴**转 + 一点透视(2026-10-08 定版)。
///
/// 定版过程(两轮真机截图 + 用户四格消元):
///   · 翻的**单位**是"环里那块容器",**不是整条环** —— 原生玻璃不能被 3D 变换(一转材质就掉 ✗),
///     也不能逐帧 resize(同样掉 ✗)⇒ 玻璃只做"长度平滑过渡",翻的是容器 ✓
///   · 消元用的 `squash`(纯 2D)/ `none`(不翻)两条临时路**验完即删** ✓
///     (那轮结论:掉材质既不是 3D、也不是几何变化 —— 是**同一扇窗里逐帧重绘内容**;
///      而当时其实还残留着"容器层也在转玻璃"那一处 ✗ ⇒ 删掉后玻璃全程完好 ✓)
/// 纯 transform(rotation + opacity)⇒ 不触发重排、不碰窗口 alpha ✓
struct RingFlipEffect: ViewModifier {
    let angle: Double
    let progress: Double

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0),
                              anchor: .center, perspective: 0.32)
            .opacity(1 - 0.75 * progress)
    }
}


/// **玻璃反光边**:贴边最亮、往内逐圈变淡 —— 合起来读作"边缘自然向内的过渡"(曲面屏那种 ✓)。
///
/// 三圈(参数都在 `PanelColors`,量出来的依据见那边注释):
///   1. 贴边一圈最亮(1.2pt · 峰 +0.22)
///   2. 往里一圈中等(2.6pt · 模糊 1.6 ⇒ 化开)
///   3. 再往里一道**内暗落**(原生紧贴亮边内侧 −0.04 ✓)
///
/// 为什么不用 `.blur` 铺满整块:那会退化成一次**面板尺寸**的离屏光栅化,
/// 而这三圈各自只有一条窄环 ⇒ 光栅化面积小、且不随图标数增长 ✓
struct GlassRim: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            ring(inset: 3.0, width: 2.4, color: PanelColors.glassRimInner, blur: 1.4)
            ring(inset: 2.0, width: 2.6, color: PanelColors.glassRimMid, blur: 1.6)
            ring(inset: 0.6, width: 1.2, color: PanelColors.glassRimGlow, blur: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func ring(inset: CGFloat, width: CGFloat, color: Color, blur: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous)
            .inset(by: inset)
            .strokeBorder(color, lineWidth: width)
            .blur(radius: blur)
    }
}
