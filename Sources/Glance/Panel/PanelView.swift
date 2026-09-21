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
    @AppStorage(Keys.panelSheen) private var sheen = true
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
            // 顶缘静态高光(旧 `glassTopLight`,白 .18)2026-09-14 已删:
            // 用户实评"整个面板透明度都不行"—— 它就是那层白纱的主体。
            // **浅色**不要这层,但**深色**要一道更窄更亮的 —— 见 glassTopEdge 的注释。
            glassTopEdge
            // demo .panel-sheen:玻璃之上、图标之下。
            //
            // v0.3 回退(2026-09-14 实拍):曾经试过给高光**挖掉图标格**(even-odd 遮罩),
            // 想让光斑只落在玻璃上 —— 结果是遮罩的**硬边界**在手电筒扫过时把每个格子
            // 读成了一个圆角"槽"(用户原话:"把后面 app 的浮起容器的槽给照出来了"),
            // 比原来的毛病重。结论:光斑落在 App 上也行(很浅,.14/.20 不影响观感),
            // 不准为了躲它去切硬边 —— 渐变上任何硬边界都是新的形状,不是遮罩。
            // 指针光晕(跟手柔光)—— 2026-09-15 做成**配置项**(用户口径:"有人不一定喜欢这个光效")。
            // 用 `if` 而不是"传 active:false":关掉时这层视图连同它的 TimelineView 一起不存在,
            // 不是"画一个看不见的东西",是真的没有开销。@AppStorage ⇒ 设置里一改立刻生效(不用重开面板)。
            if sheen {
                SheenOverlay(
                    active: controller.isVisible,
                    pointer: { [weak controller] in controller?.pointerInContent() }
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
                // 模型 C 跨段过渡:identity 换新触发 transition;方向随行进
                // (Tab = 内容左滑、⇧Tab = 右滑、↓/↑ 跳段 = 淡切),动画事务由 setSegment 的
                // withAnimation 提供 —— 与窗口(AppKit)那边的 0.22s easeInOut 同一根曲线
                .id(controller.entrySelected)
                .transition(segmentTransition)

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
        .padding(PanelMetrics.shadowPadStrip) // 必须与 PanelController.paddedSize 口径一致
        .focusEffectDisabled(true)   // ★ 窗口根:切换器面板永不出现焦点环
        // ⚠️ 这里**不许**再包"撑满窗口的弹性 frame"(同根变形 v2 试过,为了在 oversized 窗口里
        // 居中玻璃)—— 根视图尺寸依赖提议、提议依赖尺寸 ⇒ AppKit Update Constraints 布局递归
        // FAULT(2026-09-18 实机崩溃,本仓库此病第三次现形)。段变形的居中问题已在窗口侧解决。
    }

    // MARK: - 图标层

    /// 跨段过渡的方向(模型 C,见 `PanelController.SegmentTravel`)。
    /// 用**轻推 + 淡切**(14pt 的 transform 位移)而不是整排横滑:滑动 = 内容在"正在变形的
    /// 容器"里逐帧重排,是 v1 抖动的主源;offset 是纯 transform,不碰布局
    private var segmentTransition: AnyTransition {
        // ★★ 2026-09-21 用户裁定:「任何场景下都不要这个动效,直接毙掉」。
        // 病例:选中 app B 的**非第一个**窗口,再直接 hover 到相邻 app A
        //       ⇒ 新一组的卡片**左滑入场** ✗(窗口集合被判成"插入" ⇒ 播放 x:±14 的位移)。
        //       同类误触发还有:IDE 类 app 开场几帧刷新窗口列表 ⇒ 也会被判成插入。
        // ⇒ 位移**整段删除**,只保留淡切(opacity —— 淡切不是"滑入",换内容时不产生任何横向移动)。
        // 注:`segmentTravel`(forward/backward)因此不再被使用,留给后面的清理步骤一起收(见 docs/live-preview-设计.md)。
        return .opacity
    }

    private var iconStrip: some View {
        // spacing 归零、格子自己吃掉左右各半个间隙(hitSlop),App 区两端再负 padding 收回来 ——
        // 这样格与格之间没有"鼠标划过却什么都不选中"的死区。
        // T89 v2:负 padding **只属于 App 区**(内层 HStack)—— 它原本吃在整条上,
        // 会把尾格的右半格也吃掉,点阵到玻璃边变成 rowPadX+半格,比线到两边宽出一档
        // (用户实拍「左右不对称」)。右缘留白也改成 iconGap:尾部节奏三点同距
        // (App→线 = 线→点 = 点→玻璃边 = iconGap)。
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                if controller.entrySelected {
                    // T91 ↓ 换环:这格里装的是"未启动的 App"——**完全覆盖**,不是多一行
                    ForEach(Array(controller.launchables.enumerated()), id: \.offset) { i, _ in
                        launchRingCell(i)
                    }
                } else {
                ForEach(Array(controller.groups.enumerated()), id: \.element.pid) { i, group in
                    IconCell(
                        group: group,
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
        // demo 的 .puck 是 z-index:1、.app-row 是 z-index:2——托底在图标**后面**。
        // SwiftUI 里 overlay 画在内容上面,会把选中格蒙住并吃掉点击,必须用 background。
        // 挂在**水平 padding 之前**:托底要对齐的是第一枚图标(负 padding 后的 frame 左缘),
        // 不是玻璃边。水平内边距收在这层:左 rowPadX;右随启动区变 —— 有尾格时 = iconGap
        // (尾部三点同距),没有时 = rowPadX 与左缘对称
        .background(alignment: .leading) { puck.allowsHitTesting(false) }
        .padding(.leading, PanelMetrics.rowPadX)
        .padding(.trailing, PanelMetrics.rowPadX)   // T91:尾格撤了 ⇒ 右缘与左缘对称
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
    
    /// 滑动托底:宽 = 图标宽,上下各出 8px;换选中时整枚胶囊弹过去(位移+宽度同曲线)
    private var puck: some View {
        RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
            .fill(PanelColors.puck)
            // demo: inset 0 1px 1px rgba(255,255,255,.6)——托底上缘一道受光唇
            .overlay(
                RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
                    .strokeBorder(PanelColors.puckLip, lineWidth: 1)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .center))
            )
            // demo: inset 0 -1px 6px rgba(0,0,0,.12)——底缘一道内阴影,托底才有厚度,不是贴纸
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous))
            // 发丝边:把"纸片"放在玻璃上(实验台 P2)。用 strokeBorder = 画在边界**内侧**,
            // 所以托底的尺寸/位置一个像素都没动(用户口径:只改颜色,大小位置动效别动)
            .overlay(
                RoundedRectangle(cornerRadius: PanelMetrics.rPuck, style: .continuous)
                    .strokeBorder(PanelColors.puckBorder, lineWidth: 1)
            )
            .frame(width: PanelMetrics.icon, height: PanelMetrics.puckHeight)
            // 换环时只有"选中了某一格"才显形(launchIndex == nil = 还没选任何一格)
            // T91 v2:**换环后托底不上场**(用户实拍「选中态很怪, 嵌套太多圆角边框了」——
            // 托底的圆角+发丝边 套在 幽灵壳的圆角 外面,再叠一层投影 = 三层圆角框套在一起)。
            // 未启动的 App **只要"上浮"这一层反馈** —— 这正是 2026-09-16 给托盘里那一行定的规矩,
            // 换环后它们搬进了主环,规矩不变:同一个东西,同一套语言。
            .opacity(controller.entrySelected ? 0 : 1)
            .offset(x: puckOffsetX,
                    // 纵向 = 入场升起(与选中那一格同源同值,所以两者永远同步)
                    y: controller.contentEntryRise)
            .elevation(.puck)
            // 弹簧,不是过冲 timingCurve:连着 Tab 横扫时,每一次打断都从**当前速度**续跑。
            // 上膛门(开局第一帧 + 设置开关)见 PanelController.selectionAnimation
            // 🔬 2026-09-21 实验(用户实报「后面几个容器没相对 App 居中」):
            //   托底的**静态位置是准的**(数学核过:i × pitch vs i × pitch,完全重合 ✓),
            //   而换到较远的图标时它会**横着滑过去 + 弹簧过冲回弹** ⇒ 飞行途中它当然不在任何图标上 ✗
            //   越靠后的图标滑得越久、回弹越看得见 ⇒ 正好对上"后面几个没居中" ✓
            //   用户自己定过规矩:「任何场景都不要的动效 = 直接毙掉」⇒ 先改成**当帧到位**。
            //   嫌太生硬 ⇒ 改成 0.06s 的线性短移(不要弹簧 ✗)。
            .animation(nil, value: controller.appIndex)
            // ⚠️ 这里**故意没有** `.animation(…, value: entrySelected)`(T91 病例,
            // 用户实报「按下切换环的时候,在未启动的环上会有一个向右淡出的滑块效果」):
            // 托底的消失若走动画,会和"滑到 appIndex"叠在一起演 —— 读起来像"选中滑走了",
            // 而换环根本不是选中移动。去掉这条 ⇒ 换环时它**当帧就没了**。
    }

    // MARK: - 启动区入口槽(方案 E v3:点阵记号 + 自己的轻选中语言)

    /// 托底落点:**回归主环**(v3 裁定)。v2 曾让托底滑进环尾槽(实心大胶囊罩住空槽,
    /// 用户实评"丑的要死");v3 起槽的选中由**记号自己**表达(点阵点亮 + 描边胶囊),
    /// 托底永远只属于主环的 App。历史账:"缩宽"与"滑过去淡出"两案也都试过、都被否
    /// —— 那是在"槽里没有可见记号"的前提下的困境;有了点阵,落点由记号承担。
    private var puckOffsetX: CGFloat {
        // T91 v2:托底只属于已启动的主环(换环后它不上场)⇒ 永远跟 appIndex
        let i = controller.appIndex
        return CGFloat(max(i, 0)) * PanelMetrics.pitch
    }

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

    /// 确认涟漪的圆心 = 选中图标的中心(含 14px 上浮,demo 取的是变换后的 rect 中心)。
    /// X 与托盘锚点同源(`PanelLayout.iconCenterX`)
    private var selectedIconCenter: CGPoint {
        CGPoint(
            x: PanelLayout.iconCenterX(
                appIndex: controller.appIndex,
                appCount: controller.groups.count,
                contentWidth: controller.contentSize().width
            ),
            y: PanelMetrics.rowPadY + PanelMetrics.icon / 2 - PanelMetrics.iconLift
        )
    }
}

// MARK: - 图标格(选中 = 上浮 14 + 放大 1.14 + 提亮;未选 = 压暗去饱和)

private struct IconCell: View {
    let group: AppGroup
    let selected: Bool
    /// 该用的动效(nil = 不动:"面板不在台上"或系统要求降级)
    let motion: Animation?

    /// **光效总闸**(设置 → 通用 →「光效」):指针那团游走的柔光 + 这里的静态反光是同一件事的两半,
    /// 一起开、一起关(用户口径:"app 上的静态反光也关闭,一齐开启,或者关闭")。
    /// 关掉时图标回到**本来的样子**(不额外提亮、也不压暗),选中态靠放大 + 上浮 + 托底交代 ——
    /// 那三样是"形",不是"光",不受这个开关影响。
    @AppStorage(Keys.panelSheen) private var glow = true

    var body: some View {
        let art = IconProvider.art(for: group.pid)
        Image(nsImage: art.image)
            .renderingMode(.original)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            .saturation(glow ? (selected ? 1.15 : 0.92) : 1)
            .brightness(glow ? (selected ? 0.05 : -0.04) : 0)
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
            .frame(width: PanelMetrics.icon, height: PanelMetrics.icon)
            .contentShape(Rectangle())
            // 真实弹簧:response 越小越"脆",dampingFraction 越小回弹越明显。
            // 不用 .32s 的过冲 bezier —— 它在 SwiftUI 里不可靠,且每次打断从零速重起
            .animation(motion, value: selected)
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

// MARK: - 指针跟随高光(demo .panel-sheen)
//
// demo:`radial-gradient(220px circle at mx my, rgba(255,255,255,.30), transparent 60%)`
//      + `mix-blend-mode: soft-light`,z 序在 `.panel-glass` 之上、`.puck`/`.app-row` 之下,
//      `transition: background .08s linear`(只跟光,不跟手粘死)。
//
// 两条原生现实决定了它不能照抄:
// 1. **混不动**:soft-light 要采样背后的像素,而原生玻璃由 WindowServer 在进程外合成,
//    我们层树里那一块是透明的 —— 对着透明底混,混出个寂寞。折换:soft-light(白)的等效
//    结果是 √b,按 .30 权重约提亮 0.06~0.08;白 alpha .12/.16 的普通合成给 0.05~0.09,肉眼等价。
// 2. **不能走 SwiftUI 状态**:指针每像素一写,整个 body(含玻璃 NSViewRepresentable)重算,
//    `updateNSView` 次次重进,拖着玻璃重渲染 —— 横扫面板一顿一顿的就是它。
//
// 3. **拿不到鼠标事件**:面板是 `nonactivatingPanel`,永不成 key。AppKit 的 mouseMoved
//    只投给 key 窗口(上一版走 `addLocalMonitorForEvents(.mouseMoved)`,一个事件都收不到,
//    光晕从来没亮过),NSTrackingArea 在 non-key 窗口上也不可靠。
//
// 解法:**不靠事件**。`TimelineView(.animation)` 每帧问一次 `NSEvent.mouseLocation`
// (全局读数,与谁 key、有没有事件无关),`Canvas` 直接画。三个好处:
// ① 它是纯 SwiftUI 内容,z 序就是写在 ZStack 里的顺序,不会被玻璃的 NSView 顶掉;
// ② 每帧只重算这一个叶子视图 —— 玻璃的 `updateNSView` 与图标一概不碰;
// ③ 指针位置用闭包现问,不进 `@State`,指针怎么划都不产生状态变更。

struct SheenOverlay: View {
    /// 面板在台上吗(不在台上就让时间轴停摆,省掉每秒 60 次空转)
    let active: Bool
    /// 指针在面板内容坐标里的位置(nil = 不在面板上)
    let pointer: () -> CGPoint?
    @State private var tracker = SheenTracker()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(paused: !active)) { _ in
            Canvas { ctx, _ in
                guard let (p, alpha) = tracker.step(target: pointer()) else { return }
                let peak = (scheme == .dark ? PanelColors.sheenAlphaDark : PanelColors.sheenAlphaLight) * alpha
                let r = PanelMetrics.sheenExtent // demo 的 220px 是**结束形状半径**
                ctx.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(peak), location: 0),
                            .init(color: .white.opacity(0), location: PanelMetrics.sheenStop),
                        ]),
                        center: p, startRadius: 0, endRadius: r
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// 光晕的跟手状态:位置带滞后(只跟光,不跟手粘死),进出面板带淡入淡出。
/// 故意做成**引用类型**:每帧改它不算 SwiftUI 状态变更,不会触发任何视图重算。
final class SheenTracker {
    private var point: CGPoint?
    private var intensity: CGFloat = 0
    private var logged = false
    /// demo 的 `transition: background .08s linear`:60fps 下每帧追 45%,约 80ms 跟到位
    private let follow: CGFloat = 0.45

    /// 返回这一帧该画的位置与强度;nil = 不画
    func step(target: CGPoint?) -> (CGPoint, CGFloat)? {
        if let t = target {
            // 第一次被点亮打一行:光晕有没有被驱动起来,日志里一眼可见(只打一次)
            if !logged, isTraceEnabled { logged = true; glog("[T6] 光晕上线:指针 \(Int(t.x)), \(Int(t.y))") }
            point = point.map { CGPoint(x: $0.x + (t.x - $0.x) * follow, y: $0.y + (t.y - $0.y) * follow) } ?? t
            intensity += (1 - intensity) * 0.35
            return (point!, intensity)
        }
        intensity += (0 - intensity) * 0.18
        guard intensity > 0.01, let p = point else { point = nil; intensity = 0; return nil }
        return (p, intensity)
    }
}
