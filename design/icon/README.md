# Glance 图标(设计源 + 再生成)

两个标记,一个来源:

| 标记 | 落点 | 说明 |
|---|---|---|
| **App 图标** | `Sources/Glance/Assets.xcassets/AppIcon.appiconset` | macOS 十档 16…1024,每档从矢量直接栅格化 |
| **菜单栏图标** | `Sources/Glance/Assets.xcassets/MenuBarIcon.imageset` | 18/36/54(1x/2x/3x),`template` 渲染 |

## 设计读(read)

**Glance = 光透过玻璃**(与设置窗那句"glance 是关于光透过玻璃的名字"同源)。
面板的实物就是一块玻璃长条、三条窗格、中间一格被选中 —— App 图标是它的正投影:

- 深底 squircle,是"桌面在玻璃后面"
- 长条里那束蓝→紫→青,是透进来的光;**棱镜色散边**沿长条顶缘走一道,是全图唯一一次光谱色
- 三格窗:中间那格更亮、更大,套**聚焦蓝**双环 —— 选中,不是装饰
- 全图彩色只有两源:聚焦蓝 + 那道棱镜(红绿灯不在图标里出现)

度量:1024 画布,squircle 内容 **824**(= Apple 80.5% 安全区,与 `AppIconProvider`
量别人图标时的口径同源),超椭圆指数 n=5 逼近连续圆角。

**菜单栏图标是它的简化变体**:同一根长条、同样三格、同样"中间更大"。
没有玻璃、没有色 —— 菜单栏不需要第二套语言。

## 为什么菜单栏图标"必须是白色"

菜单栏图标正确的做法是 **template image**:只画形状(alpha),颜色由系统给 ——
深色菜单栏上渲染成白,浅色菜单栏上渲染成黑。

所以资产里存的就是**纯白形状 + 透明底**,`Contents.json` 里声明
`"template-rendering-intent": "template"`;系统据此在浅色栏上自动变黑。
若强写死白色,浅色菜单栏上就是一个看不见的图标。

接线在 `Sources/Glance/App/GlanceApp.swift`:
权限齐 → `Image("MenuBarIcon")`(asset catalog);缺权 → `Image(systemName: "exclamationmark.triangle")`(SF Symbols)。

★ **两格必须是两个构造器,不能合并成三元表达式**:`Image(_ name:)` 只查 asset catalog,
`Image(systemName:)` 只查 SF Symbols。合并写法(曾经就是这么写的)会把 SF Symbol 名喂给
asset catalog,查不到就画一个空图 —— 日志里报 “No image named 'exclamationmark.triangle'
found in asset catalog”,而菜单栏上“缺权限”整个没有可见信号。

## App 图标:定稿(2026-09-15)

**来源 = 外部生图模型出的那张正投影**(`glance-source.png`,2048×2048,暖米色渐变底)——
不是矢量的。所以这份资产的性质是:**一张被精确裁切过的位图**,不是"可无限缩放的矢量"。

裁切是**确定性**的,由 `Tools/Iconify.swift` 一次跑完(不手改 PNG):

```bash
swiftc -O -target arm64-apple-macos14.0 -o /tmp/iconify Tools/Iconify.swift
/tmp/iconify design/icon/glance-source.png      # 出 icon/icon_{16…1024}.png + 预览
```

四步,每一步都有理由(踩过的坑写在注释里):

1. **找边从外向内扫"第一条跳变"**,不是找"最强边" —— 中线竖扫时最强的那条是里面那层磨砂头,
   玻璃外壳的顶边是柔和渐变、强度反而低 ✗;
2. **强制正方形**(用宽度同时当高)—— 底边扫到的是投影会偏大,照它裁会把图形拉长 ✗;
3. **再内缩 2.00%** —— 从外向内扫到的第一条边是外层**泛光**的起点,不收就会带出一圈背景光 ✗。
   这个数字是**量出来的**:沿四条边取样比较"本地背景色",顶边到 1.75% 才干净(1.6% 时还有 12% 的
   样本是背景 —— 就是当初肉眼看到的那一点点 ✗)。判据只用顶边,因为另外三条边的玻璃本身近似背景色、
   这个指标会误报(注释里写明了,免得后人拿那三个数做决策);
4. **圆角遮罩 31.5%** + 摆到画布 **82%**(Apple 图标网格),四周透明 —— 生成图的水印在方块外,自动切掉 ✓。

写回资产目录:十档按 `Contents.json` 的槽位命名(16/32 各 1x·2x …… 512 各 1x·2x)。

**已知局限**:位图降采样到 16/32px 是干净的,但它**不是矢量** —— 真要无限锐利,得由设计同学
**分层描摹**成 4 条路径(外壳 / 头 / 三块)。

## 早期探索稿(留档,可删)

`make_icon.py`(v1 棱镜色散)、`make_icon_v2/v3/v4.py`、`make_macos.py`、`build_assets.py`、
`make_menubar.py`、`preview.py` 都是**探索期**的矢量尝试 —— 结论是"横条母题塞进圆角方上下必然留死白
(几何决定)",最后没走矢量,改由生图模型出图 + 上面的确定性裁切。菜单栏图标仍用矢量脚本
`make_menubar.py` 出(定稿用的是 `A-strip`),它的口径见上面"为什么必须是白色"一节。
