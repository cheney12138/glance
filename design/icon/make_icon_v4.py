#!/usr/bin/env python3
"""Glance 图标 v4 · 玻璃斜掠光(jimeng 方向矢量化).

特点:超椭圆玻璃底 + 两道对角掠光(宽蓝束 + 细高光),
      全程 SVG 渐变/模糊/发光,无水印,任意分辨率重栅格化。
"""

import math
import os
import subprocess

SIZE = 1024
HALF = 412.0
CENTER = SIZE / 2.0
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "build", "v4")


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


def shell(body, extra_defs=""):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}"
     viewBox="0 0 {SIZE} {SIZE}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#f3f7fd"/>
      <stop offset="0.5" stop-color="#e1e9f4"/>
      <stop offset="1" stop-color="#d7e0ec"/>
    </linearGradient>

    <linearGradient id="glass" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".72"/>
      <stop offset="0.45" stop-color="#ffffff" stop-opacity=".18"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity=".10"/>
    </linearGradient>

    <radialGradient id="glowA" cx="0.5" cy="0.5" r="0.55">
      <stop offset="0" stop-color="#4cc8ff" stop-opacity=".95"/>
      <stop offset="0.35" stop-color="#3aa2ff" stop-opacity=".62"/>
      <stop offset="0.75" stop-color="#1b7dff" stop-opacity=".22"/>
      <stop offset="1" stop-color="#1b7dff" stop-opacity="0"/>
    </radialGradient>

    <linearGradient id="beamA" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#0a6cff" stop-opacity="0"/>
      <stop offset="0.18" stop-color="#0a6cff" stop-opacity=".70"/>
      <stop offset="0.50" stop-color="#38c6ff" stop-opacity=".95"/>
      <stop offset="0.82" stop-color="#0a6cff" stop-opacity=".70"/>
      <stop offset="1" stop-color="#0a6cff" stop-opacity="0"/>
    </linearGradient>

    <linearGradient id="beamB" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0"/>
      <stop offset="0.35" stop-color="#c9f0ff" stop-opacity=".90"/>
      <stop offset="0.55" stop-color="#ffffff" stop-opacity="1"/>
      <stop offset="0.75" stop-color="#c9f0ff" stop-opacity=".90"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>

    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff" stop-opacity=".92"/>
      <stop offset="0.45" stop-color="#ffffff" stop-opacity=".45"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>

    <filter id="iconShadow" x="-25%" y="-25%" width="150%" height="150%">
      <feDropShadow dx="0" dy="14" stdDeviation="22" flood-color="#05060a" flood-opacity=".28"/>
    </filter>

    <filter id="blurA" x="-80%" y="-80%" width="260%" height="260%">
      <feGaussianBlur stdDeviation="42"/>
    </filter>

    <filter id="blurB" x="-80%" y="-80%" width="260%" height="260%">
      <feGaussianBlur stdDeviation="12"/>
    </filter>

    <filter id="blurC" x="-80%" y="-80%" width="260%" height="260%">
      <feGaussianBlur stdDeviation="22"/>
    </filter>

    {CLIP}
    {extra_defs}
  </defs>

  <path d="{SQ}" fill="#0d1220" filter="url(#iconShadow)"/>

  <g clip-path="url(#clipSq)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>

    <!-- 底层宽蓝掠光 -->
    <g transform="rotate(-45 {CENTER} {CENTER})" filter="url(#blurA)">
      <rect x="-300" y="{CENTER - 110}" width="{SIZE + 600}" height="220" rx="110" fill="url(#beamA)"/>
    </g>
    <g transform="rotate(-45 {CENTER} {CENTER})">
      <rect x="-300" y="{CENTER - 54}" width="{SIZE + 600}" height="108" rx="54" fill="url(#beamA)" opacity=".65"/>
    </g>

    <!-- 细高光掠光 -->
    <g transform="rotate(-45 {CENTER} {CENTER})" filter="url(#blurB)">
      <rect x="-300" y="{CENTER - 22}" width="{SIZE + 600}" height="44" rx="22" fill="url(#beamB)" opacity=".90"/>
    </g>
    <g transform="rotate(-45 {CENTER} {CENTER})">
      <rect x="-300" y="{CENTER - 8}" width="{SIZE + 600}" height="16" rx="8" fill="#ffffff" opacity=".55"/>
    </g>

    <!-- 玻璃高光层 -->
    <rect width="{SIZE}" height="{SIZE}" fill="url(#glass)"/>

    <!-- 边缘发丝高光 -->
    <path d="{SQ}" fill="none" stroke="url(#rim)" stroke-width="3"/>
    <path d="{SQ}" fill="none" stroke="#000000" stroke-opacity=".10" stroke-width="1.5" transform="translate(0,1.5)"/>
  </g>
</svg>'''


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
    svg = shell("")
    with open(os.path.join(OUT, "glance-icon-v4.svg"), "w") as f:
        f.write(svg)
    for px in (1024, 512, 256, 128, 64):
        print(render(svg, px, os.path.join(OUT, f"glance-icon-v4_{px}.png")))


if __name__ == "__main__":
    main()
