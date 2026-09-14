#!/usr/bin/env python3
"""Glance App 图标 —— macOS 原生风探索(DockDoor 同语言,但换构图)。

DockDoor 的配方:squircle + 柔和浅渐变底 + 一张奶油白窗口 + 一个深色简笔图形(笑脸)
+ 左上三颗红绿灯。macOS 识别度就来自这套;花哨来自多色 —— 这里只保留:
  · 浅冷灰底(单一色系,不铺彩虹)
  · 白窗口 + 深灰细节 + 一颗系统聚焦蓝(唯一强调色)

避开与 DockDoor 重复:不做"单窗 + 笑脸"。Glance 是**窗口级切换器**,主场是"多扇窗,
挑一扇" —— 所以主体一律是**多张窗口**。
"""

import math
import os
import subprocess

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "build")

S = 1024.0
HALF = 412.0                 # squircle 内容 824(Apple 80.5% 安全区)
ACCENT = "#0A84FF"           # 系统聚焦蓝(唯一强调色)
LIGHT = ["#FF5F57", "#FEBC2E", "#28C840"]   # 红绿灯(系统规格)


def squircle(half=HALF, n=5.0, steps=260, cx=S / 2, cy=S / 2):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + half * math.copysign(abs(ct) ** (2 / n), ct)
        y = cy + half * math.copysign(abs(st) ** (2 / n), st)
        pts.append(f"{x:.2f} {y:.2f}")
    return "M " + " L ".join(pts) + " Z"


def win(cx, cy, w, h, r, selected=False, dots=True, face="#ffffff"):
    """一张窗口卡:标题栏 + 三颗灯 + 内容区。selected = 聚焦蓝双环。"""
    x, y = cx - w / 2, cy - h / 2
    tb = h * 0.24
    g = [f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{r:.1f}" '
         f'fill="{face}"/>']
    # 内容区淡线(示意"有内容",不是装饰)
    inner_w = w * 0.52
    for i, fy in enumerate((0.52, 0.68, 0.84)):
        lw = inner_w if i != 2 else inner_w * 0.62
        g.append(f'<rect x="{x + w*0.14:.1f}" y="{y + h*fy - 6:.1f}" width="{lw:.1f}" '
                 f'height="11" rx="5.5" fill="#c9d2df"/>')
    # 标题栏
    g.append(f'<path d="M{x:.1f} {y+tb:.1f} V{y+r:.1f} Q{x:.1f} {y:.1f} {x+r:.1f} {y:.1f} '
             f'H{x+w-r:.1f} Q{x+w:.1f} {y:.1f} {x+w:.1f} {y+r:.1f} V{y+tb:.1f} Z" '
             f'fill="#f3f6fa"/>')
    g.append(f'<rect x="{x:.1f}" y="{y+tb-1:.1f}" width="{w:.1f}" height="2" fill="#e3e8ef"/>')
    if dots:
        rr = tb * 0.15
        for i, c in enumerate(LIGHT):
            g.append(f'<circle cx="{x + w*0.13 + i*(rr*3.1):.1f}" cy="{y + tb/2:.1f}" '
                     f'r="{rr:.1f}" fill="{c}"/>')
    g.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{r:.1f}" '
             f'fill="none" stroke="#c3cddf" stroke-width="3"/>')
    body = "".join(g)
    if selected:
        ring = (f'<rect x="{x-9:.1f}" y="{y-9:.1f}" width="{w+18:.1f}" height="{h+18:.1f}" '
                f'rx="{r+9:.1f}" fill="none" stroke="#ffffff" stroke-width="8"/>'
                f'<rect x="{x-13:.1f}" y="{y-13:.1f}" width="{w+26:.1f}" height="{h+26:.1f}" '
                f'rx="{r+13:.1f}" fill="none" stroke="{ACCENT}" stroke-width="8"/>')
        body = f'<g filter="url(#cardShadowSel)">{body}</g>{ring}'
    else:
        body = f'<g filter="url(#cardShadow)">{body}</g>'
    return body


def background():
    return f'''
    <defs>
      <linearGradient id="bg" x1="0.12" y1="0" x2="0.88" y2="1">
        <stop offset="0" stop-color="#f4f8ff"/>
        <stop offset="0.5" stop-color="#dde7f6"/>
        <stop offset="1" stop-color="#bfcfe6"/>
      </linearGradient>
      <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#ffffff" stop-opacity=".9"/>
        <stop offset="0.5" stop-color="#ffffff" stop-opacity=".15"/>
        <stop offset="1" stop-color="#8194ad" stop-opacity=".28"/>
      </linearGradient>
      <filter id="iconShadow" x="-25%" y="-25%" width="150%" height="150%">
        <feDropShadow dx="0" dy="18" stdDeviation="26" flood-color="#2a3550" flood-opacity=".26"/>
      </filter>
      <filter id="cardShadow" x="-30%" y="-30%" width="160%" height="160%">
        <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#33415c" flood-opacity=".26"/>
      </filter>
      <filter id="cardShadowSel" x="-40%" y="-40%" width="180%" height="180%">
        <feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#33415c" flood-opacity=".36"/>
      </filter>
      <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
        <feGaussianBlur stdDeviation="90"/>
      </filter>
      <clipPath id="sq"><path d="{squircle()}"/></clipPath>
    </defs>
    <path d="{squircle()}" fill="#dfe5ef" filter="url(#iconShadow)"/>
    <g clip-path="url(#sq)">
      <rect x="0" y="0" width="{S}" height="{S}" fill="url(#bg)"/>
      <ellipse cx="330" cy="250" rx="430" ry="330" fill="#ffffff" opacity=".55"
               filter="url(#soft)"/>
    </g>
    <path d="{squircle()}" fill="none" stroke="url(#rim)" stroke-width="3"/>'''


def bg_blur_filter():
    return ""


# --- 候选 ---------------------------------------------------------------

def a_row3():
    """一横排三扇窗(切换器的主场),中间那扇聚焦 = 当前"""
    return (win(256, 540, 232, 164, 24)
            + win(512, 540, 232, 164, 24, selected=True)
            + win(768, 540, 232, 164, 24))


def b_stack3():
    """三扇窗斜向叠放,最前那扇聚焦"""
    return (win(452, 452, 470, 320, 34)
            + win(512, 500, 470, 320, 34)
            + win(572, 548, 470, 320, 34, selected=True))


def c_pair():
    """两扇窗:一前一后(最少元素)"""
    return (win(452, 470, 500, 340, 36)
            + win(560, 556, 500, 340, 36, selected=True))


def d_grid4():
    """2×2 四扇窗,左上那扇聚焦(Mission Control 式)"""
    return (win(377, 407, 266, 186, 26, selected=True)
            + win(647, 407, 266, 186, 26)
            + win(377, 617, 266, 186, 26)
            + win(647, 617, 266, 186, 26))


def e_film():
    """细长条窗(更接近 Glance 预览托盘的比例),一排在底、一扇在上聚焦"""
    return (win(300, 500, 300, 200, 30)
            + win(512, 560, 300, 200, 30, selected=True)
            + win(724, 500, 300, 200, 30))


CANDIDATES = {
    "A-row3": a_row3,
    "B-stack3": b_stack3,
    "C-pair": c_pair,
    "D-grid4": d_grid4,
    "E-film": e_film,
}


def svg(body, px=S):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" '
            f'viewBox="0 0 {S} {S}">{background()}{body}</svg>')


def render(markup, px, path):
    html = (f'<!DOCTYPE html><html><head><meta charset="utf-8"><style>html,body{{margin:0;'
            f'background:transparent;overflow:hidden}}</style></head><body>{markup}</body></html>')
    hp = os.path.join(OUT, "_" + os.path.basename(path) + ".html")
    open(hp, "w").write(html)
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", f"--window-size={px},{px}",
                    "--default-background-color=00000000", f"--screenshot={path}",
                    f"file://{hp}"], check=True, capture_output=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    rows = []
    for name, fn in CANDIDATES.items():
        body = fn()
        for px in (256, 64, 32, 16):
            render(svg(body, px), px, os.path.join(OUT, f"mac_{name}_{px}.png"))
        rows.append(
            f'<div class="row"><span class="lbl">{name}</span>'
            f'<img src="mac_{name}_256.png" width="190">'
            f'<img src="mac_{name}_64.png" width="64">'
            f'<img class="pix" src="mac_{name}_32.png" width="48">'
            f'<img class="pix" src="mac_{name}_16.png" width="32"></div>')
    html = ('<!DOCTYPE html><html><head><meta charset="utf-8"><style>'
            'body{margin:0;background:#eceef2;font:12px -apple-system;color:#5a616b;padding:20px}'
            '.row{display:flex;align-items:flex-end;gap:24px;margin-bottom:14px}'
            '.lbl{width:76px}.pix{image-rendering:pixelated}img{display:block}'
            '</style></head><body>' + "".join(rows) + '</body></html>')
    p = os.path.join(OUT, "mac_sheet.html")
    open(p, "w").write(html)
    out = os.path.join(OUT, "mac_sheet.png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", "--window-size=560,760",
                    "--default-background-color=ffffffff", f"--screenshot={out}",
                    f"file://{p}"], check=True, capture_output=True)
    print(out)


if __name__ == "__main__":
    main()
