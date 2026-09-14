# Glance 图标(设计源 + 再生成)

两个标记,一个来源:

| 标记 | 落点 | 说明 |
|---|---|---|
| **App 图标** | `Sources/mac-switcher/Assets.xcassets/AppIcon.appiconset` | macOS 十档 16…1024,每档从矢量直接栅格化 |
| **菜单栏图标** | `Sources/mac-switcher/Assets.xcassets/MenuBarIcon.imageset` | 18/36/54(1x/2x/3x),`template` 渲染 |

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

接线在 `Sources/mac-switcher/App/mac_switcherApp.swift`:
权限齐 → `Image("MenuBarIcon")`(asset catalog);缺权 → `Image(systemName: "exclamationmark.triangle")`(SF Symbols)。

★ **两格必须是两个构造器,不能合并成三元表达式**:`Image(_ name:)` 只查 asset catalog,
`Image(systemName:)` 只查 SF Symbols。合并写法(曾经就是这么写的)会把 SF Symbol 名喂给
asset catalog,查不到就画一个空图 —— 日志里报 “No image named 'exclamationmark.triangle'
found in asset catalog”,而菜单栏上“缺权限”整个没有可见信号。

## 再生成

改设计 = 改下面的脚本,不要手改 PNG。

> ⚠️ **当前图标处于待定状态(2026-09-14)**:v1(`make_icon.py`,棱镜色散多彩)被认为配色过多;
> v2/v3 的 SVG 迭代也被否 —— 横条母题塞进圆角方上下必然留死白(几何决定)。
> 现改走**纯 logo 标记 + 对角线构图**,由外部生图模型出图,提示词见
> **`prompt-image-model.md` 第 9 节; jimeng 出图方向已进一步由 `make_icon_v4.py` 矢量化为可交付的 v4 玻璃斜掠光(SVG + PNG)。
> 定稿后:裁 squircle 遮罩(超椭圆 n=5,内容 824/1024)→ 各档从矢量重栅格化 → 写回资产目录。
> `make_icon_v2.py` / `make_icon_v3.py` 与其 `build/` 产物均为探索期草稿,定稿后可删。

```bash
python3 design/icon/build_assets.py     # 渲染并写回 Assets.xcassets
```

- `make_icon.py` —— App 图标(参数化 SVG):`python3 design/icon/make_icon.py` 出 1024 预览
- `make_menubar.py` —— 菜单栏图标的候选草图对照表(定稿用的是 `A-strip`)
- `build_assets.py` —— 按 Xcode 档位渲染进资产目录(Chrome headless 栅格化,无第三方依赖)

> 渲染器用本机 Chrome headless(SVG → PNG,透明底);`sips` 只用来抽查,不参与出图
> —— 每一档都从矢量直接栅格化,不做"1024 缩一圈"的二次采样。
