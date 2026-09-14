#!/usr/bin/env python3
"""Glance 图标 v3 —— 放弃拟物,做纯 logo 标记。

v2 的死穴:横向长条塞进圆角方,上下必然剩两块死白(几何决定,调比例没救)。
v3 改用对角线构图填满画布,母题从"面板"抽象为"玻璃 / 窗 / 光":

  A glint    斜掠光:一块玻璃 + 一道从角到角的蓝光(Glance = 光透过玻璃)
  B deck     叠窗:三扇窗沿对角线叠压,最前那扇是蓝的 —— 一堆窗里选中一扇
  C inset    格中格:外框是屏,内格浮起(选中那扇窗浮在其余之上)

配色仍是一源:聚焦蓝 #0A84FF + 中性灰白。
"""

import math
import os
import subprocess

SIZE = 1024
HALF = 412.0
CENTER = SIZE / 2.0
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "build", "v3")

A_TOP, A_BOT = "#3f9dff", "#0a6cff"


def squircle(cx=CENTER, cy=CENTER, half=HALF, n=5.0, steps=240):
    pts = []
    for i in range(steps):
        t = 2.0 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        pts.append(f"{cx + half * math.copysign(abs(ct) ** (2.0 / n), ct):.2f} "
                   f"{cy + half * math.copysign(abs(st) ** (2.0 / n), st):.2f}")
    return "M " + " L ".join(pts) + " Z"


SQ = squircle()
CLIP = f'<clipPath id="clipSq"><path d="{SQ}"/></clipPath>'

BASE_DEFS = f'''
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fafbfd"/>
      <stop offset="1" stop-color="#e7eaf0"/>
    </linearGradient>
    <radialGradient id="tint" cx="0.5" cy="0.14" r="0.8">
      <stop offset="0" stop-color="#c3daff" stop-opacity=".55"/>
      <stop offset="1" stop-color="#c3daff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".9"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <linearGradient id="accent" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{A_TOP}"/>
      <stop offset="1" stop-color="{A_BOT}"/>
    </linearGradient>
    <filter id="iconShadow" x="-25%" y="-25%" width="150%" height="150%">
      <feDropShadow dx="0" dy="14" stdDeviation="22" flood-color="#05060a" flood-opacity=".30"/>
    </filter>
    <filter id="soft" x="-40%" y="-40%" width="180%" height="180%">
      <feDropShadow dx="0" dy="12" stdDeviation="16" flood-color="#22304d" flood-opacity=".22"/>
    </filter>'''


def shell(body, extra_defs=""):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}"
     viewBox="0 0 {SIZE} {SIZE}">
  <defs>{BASE_DEFS}{extra_defs}{CLIP}</defs>
  <path d="{SQ}" fill="#0d1220" filter="url(#iconShadow)"/>
  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
    <rect width="{SIZE}" height="{SIZE}" fill="url(#tint)"/>
  </g>
{body}
  <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="2.5"/>
</svg>'''


# ---------------------------------------------------------------- A · glint 斜掠光

def v_glint():
    pane = 600.0
    r = pane * 0.2247
    x, y = CENTER - pane / 2, CENTER - pane / 2
    return shell(f'''
  <g filter="url(#soft)">
    <rect x="{x:.1f}" y="{y:.1f}" width="{pane:.1f}" height="{pane:.1f}" rx="{r:.1f}"
          fill="#ffffff" fill-opacity=".82" stroke="rgba(15,23,42,.07)" stroke-width="2"/>
  </g>
  <g clip-path="url(#clipPane)">
    <g transform="rotate(-45 {CENTER} {CENTER})">
      <rect x="{CENTER - 700:.1f}" y="{CENTER - 40:.1f}" width="1400" height="118"
            rx="59" fill="url(#accent)"/>
      <rect x="{CENTER - 700:.1f}" y="{CENTER + 118:.1f}" width="1400" height="46"
            rx="23" fill="url(#accent)" opacity=".55"/>
    </g>
  </g>''', f'''
    <clipPath id="clipPane">
      <rect x="{x:.1f}" y="{y:.1f}" width="{pane:.1f}" height="{pane:.1f}" rx="{r:.1f}"/>
    </clipPath>''')


# ---------------------------------------------------------------- B · deck 叠窗

def v_deck():
    t = 430.0
    r = t * 0.24
    layers = [(-104, 104, 0.30), (0, 0, 0.52), (104, -104, None)]
    out = []
    for dx, dy, op in layers:
        x, y = CENTER + dx - t / 2, CENTER + dy - t / 2
        if op is None:                        # 最前那扇:蓝
            out.append(f'''
  <g filter="url(#soft)">
    <rect x="{x:.1f}" y="{y:.1f}" width="{t:.1f}" height="{t:.1f}" rx="{r:.1f}"
          fill="url(#accent)"/>
  </g>''')
        else:
            out.append(f'''
  <rect x="{x:.1f}" y="{y:.1f}" width="{t:.1f}" height="{t:.1f}" rx="{r:.1f}"
        fill="#ffffff" fill-opacity="{op}" stroke="rgba(15,23,42,.08)" stroke-width="2"/>''')
    return shell(''.join(out))


# ---------------------------------------------------------------- C · inset 格中格

def v_inset():
    outer = 620.0
    ro = outer * 0.2247
    inner = 300.0
    ri = inner * 0.2247
    ox, oy = CENTER - outer / 2, CENTER - outer / 2
    ix = CENTER - inner / 2 + 88
    iy = CENTER - inner / 2 - 88
    return shell(f'''
  <g filter="url(#soft)">
    <rect x="{ox:.1f}" y="{oy:.1f}" width="{outer:.1f}" height="{outer:.1f}" rx="{ro:.1f}"
          fill="#ffffff" fill-opacity=".78" stroke="rgba(15,23,42,.07)" stroke-width="2"/>
  </g>
  <g filter="url(#soft)">
    <rect x="{ix:.1f}" y="{iy:.1f}" width="{inner:.1f}" height="{inner:.1f}" rx="{ri:.1f}"
          fill="url(#accent)"/>
  </g>''')


def render(svg, px, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    full = svg if px == SIZE else svg.replace(f'width="{SIZE}" height="{SIZE}"',
                                              f'width="{px}" height="{px}"', 1)
    hp = os.path.join(OUT, "html", os.path.basename(path) + ".html")
    os.makedirs(os.path.dirname(hp), exist_ok=True)
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
    for name, svg in {"A-glint": v_glint(), "B-deck": v_deck(), "C-inset": v_inset()}.items():
        for px in (1024, 128, 64):
            print(render(svg, px, os.path.join(OUT, f"{name}_{px}.png")))


if __name__ == "__main__":
    main()
