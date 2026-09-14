# Glance 图标 · 交给图像模型的提示词

> 用途:把下面 Prompt 直接丢给 Midjourney / Flux / SDXL / 即梦 等,1:1,1024+ 出图。
> 关键不是"好看",是**三件事必须被描述死**:功能(窗口切换器)、选中关系(微放大+微抬升,同一平面)、配色(最多两个色源)。
> 别让模型画 Chrome —— 格子里的图形应是中性占位,不是任何一个真实 App 的 logo。

---

## 1. 主推 · Light Glass(浅色玻璃)

### Prompt(英文,直接复制)

```
App icon for a macOS utility app, official Apple design language, Apple HIG style,
perfect 1:1 squircle icon with continuous rounded corners, centered composition,
generous safe margin, glyph occupies about 78% of the canvas.

SUBJECT (the function): this is a window / app switcher. A single horizontal
translucent frosted-glass bar runs across the middle of the icon, like the macOS
Command-Tab row or a Dock app row. Inside the bar, rounded-square app tiles are
packed tightly, filling the bar almost edge to edge — a crowded row of windows/apps.

THE SELECTED ONE (the key detail): one tile near the center is the selected app.
It is only about 1.5x larger than its neighbours. It sits on the SAME plane as the
rest of the row — NOT floating in a separate layer, NOT levitating, NOT detached.
It is raised just slightly upward, so its top edge rises a little above the bar's
top edge while its bottom stays INSIDE the bar. A soft, tight contact shadow falls
from it onto the bar surface directly beneath it. Neighbour tiles sit slightly
lower and slightly dimmer, clearly the same size family, same depth, same world.

MATERIAL AND LIGHT: matte frosted glass with a faint 1px hairline highlight along
the top edges of every shape, one soft directional light from top-left, gentle
depth, no bevel, no 2000s gloss, no skeuomorphism.

COLOR (very restrained): cool neutral greys and off-whites plus exactly ONE accent
colour, Apple focus blue #0A84FF. No rainbow, no spectrum, no prism, no multicolour
gradients, no more than two colour sources in the whole icon.

BACKGROUND: light mode — a very soft vertical gradient from off-white to cool
light-grey, with a faint blue tint near the top, like a native Apple light-mode
app icon.

STYLE: flat 2D vector illustration with soft realistic shadows, crisp clean edges,
minimalist, premium, quiet. No text, no letters, no numbers, no words, no app names,
no UI chrome, no window frame, no mockup, no device, no screenshot look,
no drop shadow underneath the whole icon.
```

### Negative prompt

```
text, letters, words, typography, logo lockup, watermark, brand logos, Chrome logo,
neon glow, rainbow gradient, spectrum, prism dispersion, multicolour, busy detail,
3D bevel, glossy 2000s icon, photorealistic screenshot, dark background, emoji,
frame, border, mockup, device, hand, person, drop shadow under icon, off-center
```

### 参数建议

| 平台 | 参数 |
|---|---|
| Midjourney | 末尾加 `--ar 1:1 --style raw --v 6.1`(想要更规矩可 `--s 50`) |
| Flux / SDXL | 尺寸 1024×1024,steps 30+,CFG 3.5–5(Flux 偏低),保持 prompt 全英文 |
| 即梦 / 国内模型 | 用下面"中文版",或英文 prompt + 中文补一句"扁平矢量,扁平投影" |

---

## 2. 备选 · Graphite(深石墨底)

同上面全部内容,只把 BACKGROUND 段换成:

```
BACKGROUND: dark mode — a graphite / near-black vertical gradient (#2C313D at top
to #101218 at bottom), matte, like a native Apple dark-mode app icon. The frosted
bar reads as a lighter translucent grey, and the one blue accent is the only
saturated colour in the frame.
```

Negative 里把 `dark background` 换成 `light background`。

---

## 3. 中文版(给国内模型用)

```
macOS 工具类 App 图标,Apple 官方设计语言,1:1 圆角正方形(squircle)图标,
构图居中,图形占画面约 78%,四周留足安全边距。

主体(表达功能):这是一个窗口/应用切换器。一条横向的半透明磨砂玻璃长条横贯图标中部,
类似 macOS 的 Command-Tab 切换条或 Dock 的程序行。长条内部紧凑排满圆角方形的应用格子,
几乎撑满长条,像一排挤在一起的窗口。

选中态(最关键):靠近中间的那一格是被选中的应用。它只比相邻格子大约 1.5 倍,
和整排格子处在同一个平面 —— 不悬空、不浮起、不在另一个图层。它只是轻微向上抬了一点,
顶边刚刚探出长条的上沿,底边仍然落在长条内部;下方紧贴着一层很轻的接触阴影,投在长条表面。
相邻格子略小、略暗、位置略低,明显和它是同一族尺寸、同一景深、同一个世界。

材质与光:哑光磨砂玻璃,每个形状顶缘一条极细的高光发丝线,单一柔和的左上方向光,
轻微景深,无斜面,无 2000 年代的高光塑料感。

配色(极度克制):冷调中性灰与米白,加且仅加一个强调色 Apple 聚焦蓝 #0A84FF。
不要彩虹色、不要光谱、不要棱镜色散、不要多彩渐变,全图彩色来源不超过两个。

背景:浅色模式 —— 极柔和的米白到冷灰的竖向渐变,顶部带一点极淡的蓝色倾向,
像 Apple 原生浅色模式图标。

风格:扁平二维矢量 + 柔和真实投影,边缘干净利落,极简、高级、安静。
不要文字、不要字母、不要数字、不要应用名、不要 UI 外框、不要窗口边框、不要样机、
不要设备、不要截图感、不要给整个图标加投影。
```

---

## 4. 出图后必须做的两件事

1. **裁成 squircle**:模型通常出满幅方图,macOS 需要连续圆角的圆角方形。用 `design/icon/` 里
   现成的 squircle 路径(超椭圆 n=5,内容 824/1024)做遮罩,每档尺寸从矢量重栅格化。
2. **小尺寸验收**:放 64px 看一眼 —— 若"选中那一格更大更高"在 64px 读不出来,说明对比不够,
   把放大倍数从 1.5 提到 1.7,或把探出量加大,别加细节。

## 5. 别让模型踩的坑(我这轮全踩过)

- 画成某个具体 App 的 logo(Chrome / 微信)—— 那是"被选中的应用"的占位,不是品牌
- 把选中格做成悬浮:大间隔 + 大软影 = 换图层,实机选中是原位微放大微抬升
- 长条里只放 3 个小格子:留白太多会变成"多邻国味",要挤满
- 棱镜色散 / 多彩渐变:一眼廉价,且违背"配色不要太多"

---

## 6. 实测反馈修正(2026-09-14,ChatGPT 出图评审)

首版出图:形准但功能弱 —— 更像 segmented control / 标签栏,不像"切换器"。
问题与修正,下次出图把下面这段**追加**到主 prompt 末尾:

```
REFINEMENTS (important):
- The tiles are NOT empty colour swatches. Each tile is a miniature app tile that
  contains a simple abstract app glyph (a tiny rounded shape, circle or squircle
  motif) rendered in muted, desaturated grey tones — so the row reads as "a row of
  apps", not a segmented control or tab bar. Do not use any real brand logos.
- The selected tile is noticeably larger, about 1.5x its neighbours (not 1.1x), and
  clearly pops upward: its top edge rises above the bar's top edge, and a visible
  soft contact shadow sits under it on the bar. Its selection is expressed by BOTH
  size+lift AND the blue accent, not by colour alone.
- All four neighbour tiles are the same near-white frosted tone; no dark grey tile,
  nothing that reads as "disabled".
- The bar is vertically centered in the icon; equal breathing room above and below.
```

Negative 追加:`empty tiles, colour swatches, segmented control, tab bar, flat colour blocks`

---

## 7. v2 定稿提示词(空格版 · 用户采纳 2026-09-14)

> 推翻第 6 节"格子里加抽象图形"那条:**空白的更好看**。
> 空格保留,但"选中 = 放大 + 上浮"这条硬要求不变(不能只靠颜色),另外去掉深灰格、条要垂直居中。
> 下面这段可直接整段替换主 prompt。

### Prompt(英文)

```
App icon for a macOS utility app — a window / app switcher. Official Apple design
language, Apple HIG style, perfect 1:1 squircle icon with continuous rounded corners,
centered composition, glyph occupies about 78% of the canvas, generous safe margin.

SUBJECT: a single horizontal translucent frosted-glass bar runs across the middle of
the icon, like the macOS Command-Tab row. Inside it, four to five rounded-square
tiles sit tightly packed, filling the bar almost edge to edge. The tiles are EMPTY —
clean blank frosted near-white rounded squares with a faint hairline highlight along
their top edges, no icons, no glyphs, no inner graphics, no text. A quiet row of
minimal blank cards, not a tab bar, not a segmented control.

THE SELECTED ONE (key detail): one tile is the selected app. It is clearly larger
than its neighbours, about 1.5x, and lifts slightly upward while staying on the SAME
plane — its top edge rises just above the bar's top edge, its bottom stays inside the
bar, and a soft tight contact shadow falls onto the bar directly beneath it. It is
the only tile carrying the accent colour: a flat Apple focus blue #0A84FF fill, no
gradient. Selection is expressed by SIZE AND LIFT first, colour second.

NEIGHBOURS: all in the same tone — soft frosted off-white, slightly smaller, sitting
slightly lower. No dark grey tile, nothing that reads as disabled or inactive.

MATERIAL AND LIGHT: matte frosted glass, 1px hairline highlight along top edges, one
soft directional light from top-left, gentle depth, no bevel, no 2000s gloss.

COLOR (very restrained): cool neutral greys and off-whites plus exactly ONE accent,
Apple focus blue #0A84FF. No rainbow, no spectrum, no prism, no multicolour gradients,
no more than two colour sources in the whole icon.

BACKGROUND: light mode — a very soft vertical gradient from off-white to cool
light-grey, faint blue tint near the top, native Apple light-mode app icon feel.

STYLE: flat 2D vector with soft realistic shadows, crisp clean edges, minimalist,
premium, quiet. The bar is vertically centered with equal breathing room above and
below. No text, no letters, no numbers, no UI chrome, no window frame, no mockup,
no device, no screenshot look, no drop shadow underneath the whole icon.
```

### Negative prompt

```
icons inside tiles, glyphs, symbols, app logos, brand logos, letters, text, numbers,
dark grey tile, disabled tile, rainbow, spectrum, prism dispersion, multicolour,
neon glow, 3D bevel, glossy 2000s icon, segmented control, tab bar, colour swatches,
photorealistic screenshot, dark background, emoji, frame, border, mockup, device,
drop shadow under icon, off-center
```

### 参数

- MJ:`--ar 1:1 --style raw --v 6.1 --s 50`(上一版能出这种干净的图,参数沿用即可,只换 prompt)
- Flux / SDXL:1024×1024,CFG 3.5–5

### 出图后照旧的验收

1. 64px 下还能看出"有一格更大更高" —— 看不出就把放大倍数往 1.7 提
2. 空格 ≠ 无色差:邻格要靠"略小 + 略低 + 略暗"分出层次,别四格一模一样
3. 裁 squircle 遮罩(超椭圆 n=5,内容 824/1024),各档从矢量重栅格化

---

## 8. 压缩版(1609 字符,prompt 1351 + negative 258)

```
macOS app icon, Apple HIG, 1:1 squircle, continuous rounded corners, glyph ~78% of canvas, centered.

Subject: a window/app switcher. One horizontal translucent frosted-glass bar across the middle, like macOS Command-Tab. Inside, 5 tightly packed blank rounded-square tiles, filling the bar nearly edge to edge; frosted off-white with a faint hairline top highlight, no icons, no glyphs, no text.

Selected: one tile is clearly ~1.5x larger and lifts slightly on the SAME plane - top edge just above the bar's top edge, bottom still inside the bar, soft tight contact shadow on the bar beneath it. The only element with accent color: flat Apple focus blue #0A84FF. Selection = size and lift first, color second.

Neighbours: same frosted off-white tone, slightly smaller, slightly lower. No dark grey or disabled tile.

Material: matte frosted glass, 1px hairline highlight on top edges, one soft top-left light, gentle depth, no bevel, no 2000s gloss.

Color: cool neutral greys and off-white plus exactly one accent blue. No rainbow, spectrum or multicolor gradient.

Background: light mode, soft off-white to cool light-grey vertical gradient, faint blue tint at top.

Style: flat 2D vector with soft shadows, crisp edges, minimal, premium, quiet. Bar vertically centered. No text, letters, UI chrome, mockup, device, or drop shadow under the icon.
```

Negative:

```
icons in tiles, glyphs, symbols, logos, text, letters, numbers, dark grey tile, disabled tile, rainbow, spectrum, neon, 3D bevel, glossy 2000s, segmented control, tab bar, color swatches, dark background, frame, border, mockup, device, drop shadow under icon
```

---

## 9. 放弃拟物 · 纯 Logo 标记(v3,2026-09-14)

> 结论:横条塞进圆角方,上下必留死白 —— 几何决定,调比例没救。
> 改走纯商业 logo:母题抽象为「玻璃 / 窗 / 光」+ **对角线构图**撑满画布。
> 三套方向各一段,单独跑。共用 Negative 在最后。

### A · Glint 斜掠光(推荐:最像 logo,最贴 "Glance = 光透过玻璃")

```
macOS app icon, a pure abstract logo mark, NOT a UI screenshot and NOT a literal
interface. Apple HIG, 1:1 squircle, continuous rounded corners, centered, the mark
fills about 80% of the canvas, composition running corner to corner along the
diagonal so the icon feels completely full — no empty bands top or bottom.

Subject: one rounded-square pane of frosted glass, with a beam of light sweeping
diagonally across it from the bottom-left corner to the top-right corner: one wide
soft blue band plus one thin parallel band beside it, like a glint on glass.
Nothing else. No bar, no row of items, no UI elements.

Material: matte frosted glass, 1px hairline highlight along the top-left edges, one
soft light from top-left, gentle depth, no bevel, no 2000s gloss.

Color: cool neutral greys and off-white plus exactly ONE accent, Apple focus blue
#0A84FF, flat fill. No rainbow, spectrum or multicolor gradient.

Background: light mode, soft off-white to cool light-grey vertical gradient, faint
blue tint at top.

Style: flat 2D vector, crisp edges, minimal, premium, quiet, memorable. No text,
letters, device, mockup, or drop shadow under the icon.
```

### B · Deck 叠窗(功能最直白:一堆窗里选中一扇)

```
macOS app icon, a pure abstract logo mark, NOT a UI screenshot. Apple HIG, 1:1
squircle, continuous rounded corners, centered, the mark fills about 80% of the
canvas, arranged along the diagonal from bottom-left to top-right so the icon is
visually full — no empty bands.

Subject: three rounded-square window panes stacked like a fanned deck of cards, each
one offset up and to the right, overlapping. The front one is filled with flat Apple
focus blue #0A84FF and casts a soft shadow onto the pane behind it; the two behind it
are frosted off-white, slightly dimmer, receding. Blank surfaces, no icons inside.
Reads as: a stack of windows, the front one is the selected one.

Material: matte frosted glass, 1px hairline highlight on top-left edges, one soft
light from top-left, gentle depth, no bevel, no 2000s gloss.

Color: cool neutral greys and off-white plus exactly ONE accent, Apple focus blue
#0A84FF. No rainbow, spectrum or multicolor gradient.

Background: light mode, soft off-white to cool light-grey vertical gradient, faint
blue tint at top.

Style: flat 2D vector, crisp edges, minimal, premium, quiet. No text, letters,
device, mockup, or drop shadow under the icon.
```

### C · Inset 格中格(最简:选中那扇浮起)

```
macOS app icon, a pure abstract logo mark, NOT a UI screenshot. Apple HIG, 1:1
squircle, continuous rounded corners, centered, the mark fills about 80% of the
canvas, offset on the diagonal so the icon is visually full — no empty bands.

Subject: a large rounded-square frame standing for the screen, and inside it a
smaller rounded square floating slightly up and to the right, filled with flat Apple
focus blue #0A84FF and casting a soft shadow onto the frame — "the selected window
lifted above the rest". Nested, blank, minimal. No traffic lights, no icons, no UI
chrome.

Material: matte frosted glass, 1px hairline highlight on top-left edges, one soft
light from top-left, gentle depth, no bevel, no 2000s gloss.

Color: cool neutral greys and off-white plus exactly ONE accent, Apple focus blue
#0A84FF. No rainbow, spectrum or multicolor gradient.

Background: light mode, soft off-white to cool light-grey vertical gradient, faint
blue tint at top.

Style: flat 2D vector, crisp edges, minimal, premium, quiet. No text, letters,
device, mockup, or drop shadow under the icon.
```

### 共用 Negative

```
horizontal UI bar, row of app icons, dock, taskbar, tab bar, segmented control,
screenshot of an interface, window controls, traffic lights, empty band at top or
bottom, small element floating in a white void, glyphs inside shapes, logos, brand
logos, text, letters, numbers, rainbow, spectrum, prism, neon glow, 3D bevel,
glossy 2000s icon, dark background, frame, border, mockup, device, hand, drop shadow
under the icon
```

### 三套怎么选

| 方向 | 强项 | 风险 |
|---|---|---|
| A Glint | 最像品牌 logo、最 Apple、和名字 Glance 同源 | 功能(切换)不直白,靠联想 |
| B Deck | "一堆窗 + 选中一扇"一眼可读 | 16px 下三个块可能糊成一团 |
| C Inset | 最简、小尺寸最稳 | 略普通,像"方框里套方框" |

我投 A:App 图标第一职责是被认出来、被记住,功能语义交给名字和菜单栏。想要功能一眼明白就投 B。
