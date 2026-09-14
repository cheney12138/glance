#!/usr/bin/env python3
"""Glance App 图标 v2 —— 苹果风格 · 收敛配色.

设计口径(回应"配色不要太多"):
  · 每个变体只允许 一个彩色源(聚焦蓝 #0A84FF 系)+ 中性色(白/灰/石墨)
  · 砍掉棱镜色散边、蓝紫青多色渐变、彩色光斑 —— 那些是 v1 颜色失控的来源
  · 母题不变:一根长条、三格窗、中间格被选中(= App 的功能正投影)

变体:
  A  light-glass   浅色:白玻璃长条 + 蓝色选中格(Apple 设置/备忘录系)
  B  graphite      深色:石墨底 + 磨砂长条 + 唯一发亮的蓝格
  C  cobalt        全蓝底 + 白色三格(最 Apple 的"单色满版"做法,小尺寸最稳)

渲染:Chrome headless,viewBox 1024,squircle 内容 824(Apple 80.5% 安全区),
与 make_icon.py 同一套度量。产物在 build/v2/。
"""

import math
import os
import subprocess

SIZE = 1024
HALF = 412.0
N_EXP = 5.0
CENTER = SIZE / 2.0

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "build", "v2")

ACCENT_TOP = "#3f9dff"
ACCENT_BOT = "#0a6cff"


def squircle_path(cx=CENTER, cy=CENTER, half=HALF, n=N_EXP, steps=240):
    pts = []
    for i in range(steps):
        t = 2.0 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + half * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = cy + half * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append(f"{x:.2f} {y:.2f}")
    return "M " + " L ".join(pts) + " Z"


SQ = squircle_path()


def strip_tiles(cx=CENTER, cy=CENTER, strip_w=620, strip_h=300, tile=138, gap=46,
                side_fill="", side_stroke="", center_fill="url(#accent)",
                center_scale=1.0):
    """长条 + 三格窗,中间格选中(可放大)。返回 (strip markup, tiles markup, 几何)。"""
    sx, sy = cx - strip_w / 2.0, cy - strip_h / 2.0
    r_strip = 56.0

    total = 3 * tile + 2 * gap
    start = cx - total / 2.0 + tile / 2.0
    tiles = []
    for i in range(3):
        sel = (i == 1)
        s = center_scale if sel else 1.0
        t = tile * s
        r_tile = t * 0.24
        x = start + i * (tile + gap) - t / 2.0
        y = cy - t / 2.0
        if sel:
            tiles.append(f'''
      <rect x="{x - 3:.2f}" y="{y - 3:.2f}" width="{t + 6:.2f}" height="{t + 6:.2f}"
            rx="{r_tile + 3:.2f}" fill="{ACCENT_BOT}" opacity=".38" filter="url(#glow)"/>
      <rect x="{x:.2f}" y="{y:.2f}" width="{t:.2f}" height="{t:.2f}"
            rx="{r_tile:.2f}" fill="{center_fill}"/>
      <rect x="{x + 2:.2f}" y="{y + 2:.2f}" width="{t - 4:.2f}" height="{(t - 4) * 0.52:.2f}"
            rx="{r_tile - 2:.2f}" fill="#ffffff" opacity=".22"/>''')
        else:
            tiles.append(f'''
      <rect x="{x:.2f}" y="{y:.2f}" width="{t:.2f}" height="{t:.2f}"
            rx="{r_tile:.2f}" fill="{side_fill}" {side_stroke}/>''')

    strip = f'''
    <rect x="{sx:.2f}" y="{sy:.2f}" width="{strip_w:.2f}" height="{strip_h:.2f}"
          rx="{r_strip:.2f}" filter="url(#stripShadow)"/>'''
    return strip, ''.join(tiles), (sx, sy, strip_w, strip_h, r_strip)


def svg_shell(body, defs):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}"
     viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    <linearGradient id="accent" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{ACCENT_TOP}"/>
      <stop offset="1" stop-color="{ACCENT_BOT}"/>
    </linearGradient>
    <filter id="glow" x="-80%" y="-80%" width="260%" height="260%">
      <feGaussianBlur stdDeviation="18"/>
    </filter>
    <filter id="stripShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="10" stdDeviation="18" flood-color="#0b1020" flood-opacity=".18"/>
    </filter>
    <filter id="iconShadow" x="-25%" y="-25%" width="150%" height="150%">
      <feDropShadow dx="0" dy="14" stdDeviation="22" flood-color="#05060a" flood-opacity=".30"/>
    </filter>
    {defs}
  </defs>
{body}
</svg>'''


# ---------------------------------------------------------------- A · light glass

def variant_a(tile=196, gap=20, pad=28, center_scale=1.06):
    """浅色玻璃。长条尺寸由"窗格 + 均匀留白"反推:横竖留白一致,长条被窗格填实。"""
    strip_h = tile * center_scale + 2 * pad
    strip_w = 3 * tile + 2 * gap + 2 * pad
    strip, tiles, _ = strip_tiles(
        strip_w=strip_w, strip_h=strip_h, tile=tile, gap=gap, center_scale=center_scale,
        side_fill="#ffffff", side_stroke='stroke="rgba(15,23,42,.10)" stroke-width="2"')
    defs = f'''
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fafbfd"/>
      <stop offset="1" stop-color="#e7eaf0"/>
    </linearGradient>
    <radialGradient id="tint" cx="0.5" cy="0.16" r="0.75">
      <stop offset="0" stop-color="#bfd9ff" stop-opacity=".55"/>
      <stop offset="1" stop-color="#bfd9ff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".9"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>'''
    body = f'''
  <path d="{SQ}" fill="#0d1220" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
    <rect width="{SIZE}" height="{SIZE}" fill="url(#tint)"/>
  </g>
  <g fill="#ffffff" fill-opacity=".78" stroke="rgba(15,23,42,.08)" stroke-width="2">
    {strip}
  </g>
  {tiles}
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="2.5"/>'''
    return svg_shell(body, defs)


# ---------------------------------------------------------------- B · graphite

def variant_b():
    strip, tiles, (sx, sy, w, h, r) = strip_tiles(
        side_fill="rgba(255,255,255,.16)", side_stroke="")
    defs = f'''
    <linearGradient id="bg" x1="0.1" y1="0" x2="0.9" y2="1">
      <stop offset="0" stop-color="#2c313d"/>
      <stop offset="1" stop-color="#101218"/>
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".38"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity=".04"/>
    </linearGradient>'''
    body = f'''
  <path d="{SQ}" fill="#0a0c10" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
  </g>
  <g fill="rgba(255,255,255,.07)" stroke="rgba(255,255,255,.20)" stroke-width="2">
    {strip}
  </g>
  {tiles}
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="2.5"/>'''
    return svg_shell(body, defs)


# ---------------------------------------------------------------- C · cobalt

def variant_c():
    """全蓝满版,白色三格 —— 不要长条,三格直接立在最纯的底上。"""
    tile, gap = 190.0, 62.0
    r_tile = tile * 0.26
    total = 3 * tile + 2 * gap
    start = CENTER - total / 2.0 + tile / 2.0
    tiles = []
    for i in range(3):
        x = start + i * (tile + gap) - tile / 2.0
        y = CENTER - tile / 2.0
        if i == 1:
            tiles.append(f'''
      <rect x="{x - 6:.2f}" y="{y - 6:.2f}" width="{tile + 12:.2f}" height="{tile + 12:.2f}"
            rx="{r_tile + 6:.2f}" fill="#083d8a" opacity=".45" filter="url(#glow)"/>
      <rect x="{x:.2f}" y="{y:.2f}" width="{tile:.2f}" height="{tile:.2f}"
            rx="{r_tile:.2f}" fill="#ffffff" filter="url(#tileShadow)"/>''')
        else:
            tiles.append(f'''
      <rect x="{x:.2f}" y="{y:.2f}" width="{tile:.2f}" height="{tile:.2f}"
            rx="{r_tile:.2f}" fill="#ffffff" opacity=".38"/>''')
    defs = '''
    <linearGradient id="bg" x1="0.12" y1="0" x2="0.88" y2="1">
      <stop offset="0" stop-color="#43a4ff"/>
      <stop offset="1" stop-color="#0a6cff"/>
    </linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".45"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <filter id="tileShadow" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="8" stdDeviation="14" flood-color="#062a63" flood-opacity=".35"/>
    </filter>'''
    body = f'''
  <path d="{SQ}" fill="#0a3f8f" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
  </g>
  {tiles}
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="2.5"/>'''
    return svg_shell(body, defs)


# ---------------------------------------------------------------- D · light glass · popped app

CHROME_RED = "#EA4335"
CHROME_YELLOW = "#FBBC05"
CHROME_GREEN = "#34A853"
CHROME_BLUE = "#4285F4"


def _pt(cx, cy, r, deg):
    """数学角(逆时针,0=右) → SVG 屏幕坐标(y 向下)。"""
    rad = math.radians(deg)
    return cx + r * math.cos(rad), cy - r * math.sin(rad)


def chrome_logo(cx, cy, r):
    """Chrome 2022 平面版 logo:三个 120° 扇形 + 白环 + 蓝芯。r = 外圆半径。"""
    rw, rb = r * 0.545, r * 0.435   # 白环外径 / 蓝芯半径
    wedges = []
    for a0, a1, color in ((30, 150, CHROME_RED),      # 顶:红
                          (150, 270, CHROME_GREEN),   # 左下:绿
                          (270, 390, CHROME_YELLOW)): # 右下:黄
        x0, y0 = _pt(cx, cy, r, a0)
        x1, y1 = _pt(cx, cy, r, a1)
        wedges.append(f'''
    <path d="M {cx:.2f} {cy:.2f} L {x0:.2f} {y0:.2f} A {r:.2f} {r:.2f} 0 0 0 {x1:.2f} {y1:.2f} Z"
          fill="{color}"/>''')
    return (f'''<g>
  {''.join(wedges)}
  <circle cx="{cx:.2f}" cy="{cy:.2f}" r="{rw:.2f}" fill="#ffffff"/>
  <circle cx="{cx:.2f}" cy="{cy:.2f}" r="{rb:.2f}" fill="{CHROME_BLUE}"/>
</g>''')


def _popped_tile(cx, cy, tile, logo_ratio=0.40):
    """选中的那一格:白 squircle + 放大的 App 圆标 + 双层投影(贴地硬影 + 远距软影)。"""
    r_tile = tile * 0.2247
    return f'''
  <g filter="url(#lift)">
    <rect x="{cx - tile / 2:.2f}" y="{cy - tile / 2:.2f}" width="{tile:.2f}" height="{tile:.2f}"
          rx="{r_tile:.2f}" fill="url(#tileSheen)"
          stroke="rgba(15,23,42,.06)" stroke-width="2"/>
  </g>
  <g filter="url(#logoShadow)">
    {chrome_logo(cx, cy, tile * logo_ratio)}
  </g>'''


def variant_d2(tile=520, lift=58, logo_ratio=0.40):
    """D2 · 单格弹起:内圈放大到 80%,整格向上浮起 58,投影拉长 —— 只靠"浮"讲选中。
    无指示点。"""
    cy = CENTER - lift
    defs = f'''
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fafbfd"/>
      <stop offset="1" stop-color="#e7eaf0"/>
    </linearGradient>
    <radialGradient id="tint" cx="0.5" cy="0.16" r="0.75">
      <stop offset="0" stop-color="#bfd9ff" stop-opacity=".55"/>
      <stop offset="1" stop-color="#bfd9ff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".9"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="tileSheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#f2f5f9"/>
    </linearGradient>
    <filter id="lift" x="-60%" y="-60%" width="220%" height="240%">
      <feDropShadow dx="0" dy="10" stdDeviation="9"  flood-color="#22304d" flood-opacity=".26"/>
      <feDropShadow dx="0" dy="46" stdDeviation="34" flood-color="#22304d" flood-opacity=".34"/>
    </filter>
    <filter id="logoShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="4" stdDeviation="6" flood-color="#1a2438" flood-opacity=".14"/>
    </filter>'''
    body = f'''
  <path d="{SQ}" fill="#0d1220" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
    <rect width="{SIZE}" height="{SIZE}" fill="url(#tint)"/>
  </g>
  {_popped_tile(CENTER, cy, tile, logo_ratio)}
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="2.5"/>'''
    return svg_shell(body, defs)


def variant_d3(tile=372, lift=118, logo_ratio=0.40, strip_w=760, strip_h=250):
    """D3 · 长条 + 弹起格:底下是切满窗的切换条(邻格只露半截),选中那格浮出条外 ——
    一眼能看出这是"窗口切换器",而不只是一个 Chrome。"""
    cy_tile = CENTER - lift
    sy = CENTER + 96                      # 条心(选中格底缘压在条上)
    sx = CENTER - strip_w / 2.0
    r_strip = 58.0

    neigh = []
    for dx in (-238, 238):
        t = 150.0
        neigh.append(f'''
      <rect x="{CENTER + dx - t / 2:.2f}" y="{sy - t / 2:.2f}" width="{t:.2f}" height="{t:.2f}"
            rx="{t * 0.24:.2f}" fill="#ffffff" opacity=".72"
            stroke="rgba(15,23,42,.07)" stroke-width="2"/>''')

    defs = f'''
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fafbfd"/>
      <stop offset="1" stop-color="#e7eaf0"/>
    </linearGradient>
    <radialGradient id="tint" cx="0.5" cy="0.16" r="0.75">
      <stop offset="0" stop-color="#bfd9ff" stop-opacity=".55"/>
      <stop offset="1" stop-color="#bfd9ff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".9"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="tileSheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#f2f5f9"/>
    </linearGradient>
    <filter id="lift" x="-60%" y="-60%" width="220%" height="240%">
      <feDropShadow dx="0" dy="10" stdDeviation="9"  flood-color="#22304d" flood-opacity=".26"/>
      <feDropShadow dx="0" dy="40" stdDeviation="30" flood-color="#22304d" flood-opacity=".32"/>
    </filter>
    <filter id="logoShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="4" stdDeviation="6" flood-color="#1a2438" flood-opacity=".14"/>
    </filter>
    <filter id="stripShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="10" stdDeviation="18" flood-color="#0b1020" flood-opacity=".18"/>
    </filter>'''
    body = f'''
  <path d="{SQ}" fill="#0d1220" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
    <rect width="{SIZE}" height="{SIZE}" fill="url(#tint)"/>
  </g>
  <g filter="url(#stripShadow)">
    <rect x="{sx:.2f}" y="{sy - strip_h / 2:.2f}" width="{strip_w:.2f}" height="{strip_h:.2f}"
          rx="{r_strip:.2f}" fill="#ffffff" fill-opacity=".62"
          stroke="rgba(15,23,42,.07)" stroke-width="2"/>
  </g>
  {''.join(neigh)}
  {_popped_tile(CENTER, cy_tile, tile, logo_ratio)}
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="2.5"/>'''
    return svg_shell(body, defs)


def variant_d4(sel=300, nei=190, strip_w=840, strip_h=280):
    """D4 · 贴实机比例的选中态:选中格 ≈ 邻格 1.58 倍,只探出条顶 ~1/3,
    底部仍坐在条内 —— 与邻格同一维度,影子落在条面上。"""
    strip_cy = CENTER + 90
    strip_top = strip_cy - strip_h / 2.0
    sx = CENTER - strip_w / 2.0
    r_strip = 58.0
    sel_cy = strip_top + 40 + sel / 2.0        # 探出条顶 ~40+... 约 sel 的 0.43
    sel_cy = strip_top - sel * 0.16 + sel / 2.0  # 顶部探出 16% 格高,更收敛

    neigh = []
    for dx in (-320, -165, 165, 320):
        neigh.append(f'''
      <rect x="{CENTER + dx - nei / 2:.2f}" y="{strip_cy - nei / 2:.2f}" width="{nei:.2f}" height="{nei:.2f}"
            rx="{nei * 0.24:.2f}" fill="#ffffff" opacity=".78"
            stroke="rgba(15,23,42,.07)" stroke-width="2"/>''')

    defs = f'''
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fafbfd"/>
      <stop offset="1" stop-color="#e7eaf0"/>
    </linearGradient>
    <radialGradient id="tint" cx="0.5" cy="0.16" r="0.75">
      <stop offset="0" stop-color="#bfd9ff" stop-opacity=".55"/>
      <stop offset="1" stop-color="#bfd9ff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".9"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="tileSheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#f2f5f9"/>
    </linearGradient>
    <filter id="popShadow" x="-50%" y="-50%" width="200%" height="200%">
      <feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#22304d" flood-opacity=".28"/>
    </filter>
    <filter id="logoShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="4" stdDeviation="6" flood-color="#1a2438" flood-opacity=".14"/>
    </filter>
    <filter id="stripShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="10" stdDeviation="18" flood-color="#0b1020" flood-opacity=".16"/>
    </filter>'''
    body = f'''
  <path d="{SQ}" fill="#0d1220" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
    <rect width="{SIZE}" height="{SIZE}" fill="url(#tint)"/>
  </g>
  <g filter="url(#stripShadow)">
    <rect x="{sx:.2f}" y="{strip_top:.2f}" width="{strip_w:.2f}" height="{strip_h:.2f}"
          rx="{r_strip:.2f}" fill="#ffffff" fill-opacity=".62"
          stroke="rgba(15,23,42,.07)" stroke-width="2"/>
  </g>
  {''.join(neigh)}
  <g filter="url(#popShadow)">
    <rect x="{CENTER - sel / 2:.2f}" y="{sel_cy - sel / 2:.2f}" width="{sel:.2f}" height="{sel:.2f}"
          rx="{sel * 0.2247:.2f}" fill="url(#tileSheen)"
          stroke="rgba(15,23,42,.06)" stroke-width="2"/>
  </g>
  <g filter="url(#logoShadow)">
    {chrome_logo(CENTER, sel_cy, sel * 0.40)}
  </g>
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="2.5"/>'''
    return svg_shell(body, defs)


def variant_d(tile=452, dot=True):
    """浅色玻璃 + 选中的 App 弹起独立成格:白 squircle 格 + Chrome logo,
    格子投下"弹起"的软影,底下带运行指示点 —— 实机 Dock 选中态的正投影。"""
    r_tile = tile * 0.2247          # macOS 图标圆角比例
    tx, ty = CENTER - tile / 2.0, CENTER - tile / 2.0
    chrome_r = tile * 0.36
    dot_y = ty + tile + 78

    dot_markup = ""
    if dot:
        dot_markup = f'''
  <circle cx="{CENTER:.2f}" cy="{dot_y:.2f}" r="21" fill="#ffffff" opacity=".95"
          filter="url(#dotShadow)"/>'''

    defs = f'''
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fafbfd"/>
      <stop offset="1" stop-color="#e7eaf0"/>
    </linearGradient>
    <radialGradient id="tint" cx="0.5" cy="0.16" r="0.75">
      <stop offset="0" stop-color="#bfd9ff" stop-opacity=".55"/>
      <stop offset="1" stop-color="#bfd9ff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".9"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="tileSheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#f4f6f9"/>
    </linearGradient>
    <filter id="popShadow" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="24" stdDeviation="26" flood-color="#22304d" flood-opacity=".30"/>
    </filter>
    <filter id="dotShadow" x="-120%" y="-120%" width="340%" height="340%">
      <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#22304d" flood-opacity=".28"/>
    </filter>
    <filter id="logoShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="4" stdDeviation="6" flood-color="#1a2438" flood-opacity=".16"/>
    </filter>'''
    body = f'''
  <path d="{SQ}" fill="#0d1220" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
    <rect width="{SIZE}" height="{SIZE}" fill="url(#tint)"/>
  </g>
  <g filter="url(#popShadow)">
    <rect x="{tx:.2f}" y="{ty:.2f}" width="{tile:.2f}" height="{tile:.2f}"
          rx="{r_tile:.2f}" fill="url(#tileSheen)"
          stroke="rgba(15,23,42,.06)" stroke-width="2"/>
  </g>
  <g filter="url(#logoShadow)">
    {chrome_logo(CENTER, CENTER, chrome_r)}
  </g>
  {dot_markup}
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="2.5"/>'''
    return svg_shell(body, defs)


CLIP = f'<clipPath id="clipSq"><path d="{SQ}"/></clipPath>'


def render(svg_markup, px, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    html = (f'<!DOCTYPE html><html><head><meta charset="utf-8"><style>html,body{{margin:0;'
            f'padding:0;background:transparent;overflow:hidden;}}</style></head><body>'
            f'{svg_markup}</body></html>')
    hp = os.path.join(OUT, "html", os.path.basename(path) + ".html")
    os.makedirs(os.path.dirname(hp), exist_ok=True)
    with open(hp, "w") as f:
        f.write(html.replace('clipPath id="clipSq"', 'clipPath id="clipSq"'))
    # clipPath 需要内联进每个 svg;小尺寸渲染时同步缩放 svg 的 width/height
    full = svg_markup.replace("<defs>", f"<defs>{CLIP}", 1)
    if px != SIZE:
        full = full.replace(f'width="{SIZE}" height="{SIZE}"',
                            f'width="{px}" height="{px}"', 1)
    with open(hp, "w") as f:
        f.write(f'<!DOCTYPE html><html><head><meta charset="utf-8"><style>html,body{{margin:0;'
                f'padding:0;background:transparent;overflow:hidden;}}</style></head><body>{full}</body></html>')
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", f"--window-size={px},{px}",
                    "--default-background-color=00000000", f"--screenshot={path}",
                    f"file://{hp}"], check=True, capture_output=True)
    return path


def main():
    os.makedirs(OUT, exist_ok=True)
    variants = {
        "A-light-glass": variant_a(),                                  # 原版(留白多)
        "A2-packed": variant_a(tile=200, gap=18, pad=26, center_scale=1.08),
        "A3-ultra": variant_a(tile=214, gap=12, pad=18, center_scale=1.06),
        "D-popped-chrome": variant_d(),
        "D2-lift": variant_d2(),
        "D3-lift-strip": variant_d3(),
        "D4-grounded": variant_d4(),
    }
    for name, svg in variants.items():
        for px in (1024, 128, 64):
            p = os.path.join(OUT, f"{name}_{px}.png")
            render(svg, px, p)
            print(p)


if __name__ == "__main__":
    main()
