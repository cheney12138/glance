#!/usr/bin/env python3
"""Glance App 图标生成器。

产物:1024×1024 透明底 PNG(Chrome headless 渲染内联 SVG),再交给 `render.sh`
用 sips 切成 macOS 需要的十档,装进 Assets.xcassets/AppIcon.appiconset。

设计语言对齐(见 design/settings-spec.md §0、design/v4/design-system.md):
  · Glance = 光透过玻璃 —— 图标是一块玻璃,桌面在它背后被折射
  · 全系统只两色源:聚焦蓝 accent + 红绿灯;这里只放聚焦蓝
  · 唯一的高光时刻 = 棱镜色散边,放在长条玻璃的顶缘

只做图,不碰工程。渲染口径固定:viewBox 1024,内容 squircle 824(Apple 安全区
80.5%,与 AppIconProvider 的量法同源)。
"""

import math
import os
import subprocess
import sys

SIZE = 1024
HALF = 412.0          # squircle 半宽 → 内容 824
N_EXP = 5.0           # 超椭圆指数(Apple 连续圆角的常用逼近)
CENTER = SIZE / 2.0

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "build")

# 色板(与设置窗 demo 同源)
INK_TOP = "#2a49c8"
INK_MID = "#171a2b"
INK_BOT = "#0a0b10"
BAND_A = "#2b56e6"
BAND_B = "#7b4dff"
BAND_C = "#12b0a0"
BAND_D = "#5ec8ff"
ACCENT = "#0a84ff"
DARK_GAP = "#0a0b0e"   # --ko:蓝环与玻璃之间的剥离缝


def squircle_path(cx=CENTER, cy=CENTER, half=HALF, n=N_EXP, steps=240):
    """超椭圆 |x|^n + |y|^n = 1 的折线逼近。"""
    pts = []
    for i in range(steps):
        t = 2.0 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + half * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = cy + half * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append(f"{x:.2f} {y:.2f}")
    return "M " + " L ".join(pts) + " Z"


def rounded(x, y, w, h, r):
    return (f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" '
            f'rx="{r:.2f}" ry="{r:.2f}"/>')


# ---------------------------------------------------------------- 背景(玻璃背后的桌面)

def bg_art():
    return f'''
    <g id="bgart">
      <rect x="0" y="0" width="{SIZE}" height="{SIZE}" fill="url(#bgGrad)"/>
      <ellipse cx="300" cy="230" rx="400" ry="330" fill="#4f6bff" opacity=".42"
               filter="url(#blobBlur)"/>
      <ellipse cx="780" cy="830" rx="380" ry="320" fill="#12b0a0" opacity=".20"
               filter="url(#blobBlur)"/>
      <rect x="0" y="0" width="{SIZE}" height="{SIZE}" fill="url(#vignette)"/>
    </g>'''


# ---------------------------------------------------------------- 长条玻璃

def glass_strip(x, y, w, h, r):
    """折射:长条里是同一束光的浓缩版 —— 深底上唯一发亮的窗口。"""
    cx, cy = x + w / 2.0, y + h / 2.0
    s = 1.14
    tx, ty = cx * (1 - s), cy * (1 - s)   # 以长条中心为不动点的缩放
    return f'''
    <g clip-path="url(#clipStrip)">
      <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="url(#stripGrad)"/>
      <g transform="translate({tx:.1f} {ty:.1f}) scale({s})" filter="url(#refract)"
         opacity=".45">
        <rect x="0" y="0" width="{SIZE}" height="{SIZE}" fill="url(#bgGrad)"/>
      </g>
      <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="#fbfcff" opacity=".06"/>
    </g>
    <g clip-path="url(#clipStrip)" fill="none">
      <rect x="{x+0.75:.2f}" y="{y+0.75:.2f}" width="{w-1.5:.2f}" height="{h-1.5:.2f}"
            rx="{r-0.75:.2f}" stroke="#ffffff" stroke-opacity=".50" stroke-width="1.5"/>
    </g>'''


def prism(x, y, w, h=5.0):
    """棱镜色散边 —— 全图唯一一次出现光谱色。两端用 mask 收干,不做整条横杠。"""
    return f'''
    <g clip-path="url(#clipStrip)">
      <rect x="{x}" y="{y}" width="{w}" height="{h}" fill="url(#prismGrad)"
            opacity=".62" mask="url(#prismMask)"/>
    </g>'''


# ---------------------------------------------------------------- 窗口格

def tile(cx, cy, size, selected, r):
    x, y = cx - size / 2.0, cy - size / 2.0
    if selected:
        return f'''
        <g>
          <rect x="{x-13:.2f}" y="{y-13:.2f}" width="{size+26:.2f}" height="{size+26:.2f}"
                rx="{r+13:.2f}" fill="{ACCENT}" opacity=".45" filter="url(#glow)"/>
          <rect x="{x-13:.2f}" y="{y-13:.2f}" width="{size+26:.2f}" height="{size+26:.2f}"
                rx="{r+13:.2f}" fill="#ffffff" opacity=".14"/>
          <rect x="{x:.2f}" y="{y:.2f}" width="{size:.2f}" height="{size:.2f}"
                rx="{r:.2f}" fill="#ffffff" opacity=".42"/>
          <rect x="{x+1:.2f}" y="{y+1:.2f}" width="{size-2:.2f}" height="{size-2:.2f}"
                rx="{r-1:.2f}" fill="none" stroke="url(#tileTop)" stroke-width="1.5"/>
          <rect x="{x-2.5:.2f}" y="{y-2.5:.2f}" width="{size+5:.2f}" height="{size+5:.2f}"
                rx="{r+2.5:.2f}" fill="none" stroke="{DARK_GAP}" stroke-opacity=".65" stroke-width="7"/>
          <rect x="{x-3.5:.2f}" y="{y-3.5:.2f}" width="{size+7:.2f}" height="{size+7:.2f}"
                rx="{r+3.5:.2f}" fill="none" stroke="{ACCENT}" stroke-width="5.5"/>
        </g>'''
    return f'''
    <g>
      <rect x="{x:.2f}" y="{y:.2f}" width="{size:.2f}" height="{size:.2f}"
            rx="{r:.2f}" fill="#ffffff" opacity=".20"/>
      <rect x="{x+1:.2f}" y="{y+1:.2f}" width="{size-2:.2f}" height="{size-2:.2f}"
            rx="{r-1:.2f}" fill="none" stroke="url(#tileTop)" stroke-width="1.5"/>
    </g>'''


def build_svg(n_tiles=3, selected=1, strip_w=620, strip_h=310, tile_size=142, gap=44,
              pixel=SIZE):
    sq = squircle_path()
    sx = CENTER - strip_w / 2.0
    sy = CENTER - strip_h / 2.0
    r_strip = 52.0
    r_tile = tile_size * 0.22

    total = n_tiles * tile_size + (n_tiles - 1) * gap
    start = CENTER - total / 2.0 + tile_size / 2.0
    cy0 = CENTER

    tiles = []
    for i in range(n_tiles):
        d = abs(i - selected)
        scale = 1.0 - 0.05 * d
        dy = 7.0 * d + (-12.0 if i == selected else 0.0)
        cx = start + i * (tile_size + gap)
        tiles.append(
            f'<g opacity="{max(1.0 - 0.16*d, 0.5):.2f}">'
            + tile(cx, cy0 + dy, tile_size * scale, i == selected, r_tile * scale)
            + '</g>'
        )

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{pixel}" height="{pixel}"
     viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    <linearGradient id="bgGrad" x1="0.05" y1="0" x2="0.9" y2="1">
      <stop offset="0.00" stop-color="#2c3880"/>
      <stop offset="0.45" stop-color="#14162c"/>
      <stop offset="1.00" stop-color="{INK_BOT}"/>
    </linearGradient>

    <linearGradient id="stripGrad" x1="0.05" y1="0" x2="1" y2="1">
      <stop offset="0.00" stop-color="{BAND_A}"/>
      <stop offset="0.42" stop-color="{BAND_B}"/>
      <stop offset="0.78" stop-color="{BAND_C}"/>
      <stop offset="1.00" stop-color="{BAND_D}"/>
    </linearGradient>

    <radialGradient id="vignette" cx="0.46" cy="0.40" r="0.78">
      <stop offset="0.35" stop-color="#06070c" stop-opacity="0"/>
      <stop offset="0.78" stop-color="#06070c" stop-opacity=".28"/>
      <stop offset="1" stop-color="#06070c" stop-opacity=".62"/>
    </radialGradient>

    <linearGradient id="prismGrad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0.00" stop-color="#ff5f57"/>
      <stop offset="0.22" stop-color="#febc2e"/>
      <stop offset="0.42" stop-color="#28c840"/>
      <stop offset="0.60" stop-color="#32ade6"/>
      <stop offset="0.80" stop-color="#0a84ff"/>
      <stop offset="1.00" stop-color="#af52de"/>
    </linearGradient>

    <linearGradient id="rimGrad" x1="0.15" y1="0" x2="0.5" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".55"/>
      <stop offset="0.45" stop-color="#ffffff" stop-opacity=".10"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity=".02"/>
    </linearGradient>

    <radialGradient id="sheenGrad" cx="0.32" cy="0.24" r="0.62">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".22"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>

    <linearGradient id="tileTop" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".55"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>

    <linearGradient id="prismMaskGrad" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#000"/>
      <stop offset="0.18" stop-color="#fff"/>
      <stop offset="0.82" stop-color="#fff"/>
      <stop offset="1" stop-color="#000"/>
    </linearGradient>

    <filter id="blobBlur" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="80"/>
    </filter>

    <filter id="refract" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="16"/>
      <feColorMatrix type="saturate" values="1.85"/>
      <feComponentTransfer><feFuncR type="linear" slope="1.12"/>
        <feFuncG type="linear" slope="1.12"/><feFuncB type="linear" slope="1.12"/>
      </feComponentTransfer>
    </filter>

    <filter id="iconShadow" x="-25%" y="-25%" width="150%" height="150%">
      <feDropShadow dx="0" dy="20" stdDeviation="26" flood-color="#05060a" flood-opacity=".45"/>
    </filter>

    <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="22"/>
    </filter>

    <clipPath id="clipSquircle"><path d="{sq}"/></clipPath>
    <clipPath id="clipStrip">
      {rounded(sx, sy, strip_w, strip_h, r_strip)}
    </clipPath>
    <mask id="prismMask">
      <rect x="{sx}" y="{sy - 4}" width="{strip_w}" height="20" fill="url(#prismMaskGrad)"/>
    </mask>

    {bg_art()}
  </defs>

  <!-- 图标本体:阴影 + squircle 内的桌面 -->
  <path d="{sq}" fill="#0a0b0e" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSquircle)">
    <use href="#bgart"/>
    <rect x="0" y="0" width="{SIZE}" height="{SIZE}" fill="url(#sheenGrad)"/>
  </g>

  <!-- 长条玻璃 -->
  {glass_strip(sx, sy, strip_w, strip_h, r_strip)}

  <!-- 窗口格 -->
  {''.join(tiles)}

  <!-- 棱镜色散边(唯一高光时刻) -->
  {prism(sx + 6, sy + 3, strip_w - 12)}

  <!-- 玻璃外轮廓发丝:rim(顶亮底暗)+ edge-ring -->
  <path d="{sq}" fill="none" stroke="url(#rimGrad)" stroke-width="2.5"/>
  <path d="{sq}" fill="none" stroke="#000000" stroke-opacity=".22" stroke-width="1.5"
        transform="translate(0,1.5)"/>
</svg>
'''


def render(svg_markup, px, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    html = (f'<!DOCTYPE html><html><head><meta charset="utf-8"><style>html,body{{margin:0;'
            f'padding:0;background:transparent;overflow:hidden;}}</style></head><body>'
            f'{svg_markup}</body></html>')
    scratch = os.path.join(OUT, "html")
    os.makedirs(scratch, exist_ok=True)
    hp = os.path.join(scratch, os.path.splitext(os.path.basename(path))[0] + ".html")
    with open(hp, "w") as f:
        f.write(html)
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", f"--window-size={px},{px}",
                    "--default-background-color=00000000", f"--screenshot={path}",
                    f"file://{hp}"], check=True, capture_output=True)
    return path


def main():
    os.makedirs(OUT, exist_ok=True)
    png = os.path.join(OUT, "icon-1024.png")
    render(build_svg(pixel=SIZE), SIZE, png)
    print(png)


if __name__ == "__main__":
    main()
