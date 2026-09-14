#!/usr/bin/env python3
"""Glance 菜单栏图标的候选草图。

菜单栏图标是 **template image**(`isTemplate = true`):只画形状,颜色由系统给 ——
深色菜单栏上是白、浅色菜单栏上是黑。所以这里一律纯白,靠 SVG 的 alpha 定形。

口径:viewBox 36(= 18pt @2x),渲染 36px 出 @2x、18px 出 @1x。
先出草图放大看形态,定稿再按尺寸导出。
"""

import os
import subprocess

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "build")

S = 36.0


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" '
            f'viewBox="0 0 {S} {S}">{body}</svg>')


def rr(x, y, w, h, r, fill="none", stroke="#fff", sw=2.4, opacity=1):
    st = (f'stroke="{stroke}" stroke-width="{sw}" stroke-linejoin="round"'
          if stroke else "")
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" ry="{r}" '
            f'fill="{fill}" {st} opacity="{opacity}"/>')


# A —— 长条玻璃的直译:胶囊 + 三格实心,中间那格更大(选中)
def cand_strip():
    b = [rr(2.0, 9.0, 32.0, 18.0, 6.4, fill="none", sw=2.8)]
    # 胶囊内区 3.4…32.6;两侧 6.6、中 8.8,边距 2.2、缝 1.4
    b.append(rr(5.6, 14.7, 6.6, 6.6, 2.0, fill="#fff", stroke=None))
    b.append(rr(13.6, 13.6, 8.8, 8.8, 2.4, fill="#fff", stroke=None))
    b.append(rr(23.8, 14.7, 6.6, 6.6, 2.0, fill="#fff", stroke=None))
    return "".join(b)


# E —— 不要胶囊:三块实心圆角方块,中间抬起放大(最简剪影)
def cand_blocks():
    b = []
    for i, x in enumerate([1.8, 12.8, 23.8]):
        sel = i == 1
        y, w, h = (8.6, 10.4, 15.6) if sel else (12.6, 10.4, 9.6)
        b.append(rr(x, y, w, h, 2.8, fill="#fff", stroke=None))
    return "".join(b)


# F —— 胶囊 + 三格实心(等高),中间格上下留出缝 = 选中(挖槽读法)
def cand_slot():
    b = [rr(2.6, 11.0, 30.8, 14.0, 5.0, fill="#fff", stroke=None)]
    for x in [7.4, 15.0, 22.6]:
        b.append(rr(x, 14.2, 6.0, 7.6, 1.8, fill="none", stroke="#000", sw=0,
                    opacity=0))
    # 用三块"挖空"表示格子:直接在实心胶囊上叠深色不可行(template 只用 alpha),
    # 所以改成胶囊只描边、三格实心等高
    b = [rr(2.6, 11.0, 30.8, 14.0, 5.0, fill="none", sw=2.6)]
    for x in [7.6, 15.0, 22.4]:
        b.append(rr(x, 14.0, 6.0, 8.0, 1.8, fill="#fff", stroke=None))
    return "".join(b)


# B —— 不要胶囊,只三格;中间抬起实心,两侧描边
def cand_panes():
    b = []
    for i, x in enumerate([2.6, 13.6, 24.6]):
        sel = i == 1
        y, h = (8.6, 18.8) if sel else (12.2, 11.6)
        b.append(rr(x, y, 8.8, h, 2.6, fill="#fff" if sel else "none",
                    stroke=None if sel else "#fff", sw=2.4))
    return "".join(b)


# C —— 两扇窗:后排描边、前排实心,叠一点(层叠/切换)
def cand_stack():
    b = [rr(6.0, 4.6, 17.2, 17.2, 4.4, fill="none", sw=2.4)]
    b.append(rr(13.0, 13.0, 17.0, 17.0, 4.4, fill="#fff", stroke=None))
    return "".join(b)


# D —— 用户贴的那张:左两小格(上下)+ 右一竖格
def cand_tiling():
    b = [rr(3.4, 7.0, 13.4, 8.4, 2.6, fill="#fff", stroke=None),
         rr(3.4, 18.4, 9.6, 10.6, 2.6, fill="#fff", stroke=None),
         rr(20.2, 7.0, 12.4, 22.0, 3.0, fill="#fff", stroke=None)]
    return "".join(b)


CANDIDATES = {
    "A-strip": cand_strip,
    "B-panes": cand_panes,
    "C-stack": cand_stack,
    "D-tiling": cand_tiling,
    "E-blocks": cand_blocks,
    "F-slot": cand_slot,
}


def _render(name, body, px, path):
    html = (f'<!DOCTYPE html><html><head><meta charset="utf-8"><style>html,body{{margin:0;'
            f'background:transparent;overflow:hidden}}</style></head><body>'
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" '
            f'viewBox="0 0 {S} {S}">{body}</svg></body></html>')
    hp = os.path.join(OUT, f"_{name}_{px}.html")
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
        p18 = os.path.join(OUT, f"mb_{name}_1x.png")
        p36 = os.path.join(OUT, f"mb_{name}_2x.png")
        _render(name, body, 18, p18)
        _render(name, body, 36, p36)
        rows.append(
            f'<div class="row"><span class="lbl">{name}</span>'
            f'<span class="bar">'
            f'<img class="pix" src="mb_{name}_1x.png" width="72" height="72">'
            f'<img class="pix" src="mb_{name}_2x.png" width="72" height="72"></span>'
            f'<span class="bar"><img src="mb_{name}_1x.png">'
            f'<img src="mb_{name}_2x.png" style="height:18px;width:auto"></span>'
            f'</div>'
        )
    html = (
        '<!DOCTYPE html><html><head><meta charset="utf-8"><style>'
        'body{margin:0;background:#2b2b2e;font:11px -apple-system;color:#9aa0a6;padding:18px;}'
        '.row{display:flex;align-items:center;gap:24px;margin-bottom:12px;}'
        '.lbl{width:72px}.bar{background:#1c1c1e;border-radius:6px;padding:4px 10px;'
        'display:flex;align-items:center;gap:8px;}.pix{image-rendering:pixelated}'
        'img{display:block}'
        '</style></head><body>' + "".join(rows) + '</body></html>'
    )
    p = os.path.join(OUT, "menubar_sheet.html")
    open(p, "w").write(html)
    png = os.path.join(OUT, "menubar_sheet.png")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", "--window-size=640,470",
                    "--default-background-color=00000000", f"--screenshot={png}",
                    f"file://{p}"], check=True, capture_output=True)
    print(png)


if __name__ == "__main__":
    main()
