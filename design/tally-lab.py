#!/usr/bin/env python3
"""窗数记号(记账法)实验台 —— 短横该多大?

病例(2026-09-15 用户实拍):短横 7.68×2.0pt 的**面积(15pt²)比圆点(18pt²)还小** ✗,
于是代表 5 的记号看起来比代表 1 的还弱 —— 层级反了。

口径(用户定):短横与圆点**同一个体量**,但因为它是"长条",视觉上应当**比圆点大**。
这里把四档摆在一起(真尺寸 ×4 放大),并各配"6 扇(横+点)"与"20 扇(四个横)"两种实况。

    python3 design/tally-lab.py     # 出 design/窗数记号实验台.html + /tmp/tally-lab.png
"""
import os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

DOT, GAP, CELL = 4.8, 3.6, 105.6          # PanelMetrics @scale 1.2
Z = 4                                      # 放大倍数
VARIANTS = [
    ("今天(改前)", 1.60, 0.42),
    ("A  2.0× / 0.50×", 2.00, 0.50),
    ("B  2.5× / 0.60×  ← 采用", 2.50, 0.60),
    ("C  3.0× / 0.70×", 3.00, 0.70),
]

def marks(dash_w, dash_h, n):
    dashes, dots = n // 5, n % 5
    out = []
    for _ in range(dashes):
        out.append(f'<i class="dash" style="width:{dash_w*Z:.1f}px;height:{dash_h*Z:.1f}px"></i>')
    for _ in range(dots):
        out.append(f'<i class="dot"></i>')
    return "".join(out)

rows = []
for label, wf, hf in VARIANTS:
    dw, dh = DOT * wf, DOT * hf
    area = dw * dh
    dot_area = 3.14159 * (DOT / 2) ** 2
    for n in (6, 20):
        rows.append(f'''<div class="row">
      <div class="lab">{label}<span class="sub">{n} 扇 · 横 {dw:.1f}×{dh:.1f}pt · 面积 {area:.0f}(圆点 {dot_area:.0f})</span></div>
      <div class="cell">{marks(dw, dh, n)}</div></div>''')

html = f'''<!DOCTYPE html><html><head><meta charset="utf-8"><style>
  html,body{{margin:0;background:#F6F5F3;font:13px -apple-system,"PingFang SC",sans-serif;color:#3A3A3C}}
  h1{{font-size:15px;font-weight:600;margin:20px 24px 4px}}
  p.note{{margin:0 24px 14px;color:#8A8A8E;font-size:12px;line-height:1.5}}
  .row{{display:flex;align-items:center;gap:16px;margin:0 24px 10px}}
  .lab{{width:250px;flex:none;font-variant-numeric:tabular-nums}}
  .sub{{display:block;color:#9A9A9E;font-size:11px}}
  .cell{{width:{CELL*Z:.0f}px;height:34px;flex:none;background:#FFFFFF;border-radius:9px;
        box-shadow:0 1px 3px rgba(0,0,0,.07);display:flex;align-items:center;justify-content:center;gap:{GAP*Z:.1f}px}}
  .dot{{width:{DOT*Z:.1f}px;height:{DOT*Z:.1f}px;border-radius:50%;background:#6E6E73;flex:none}}
  .dash{{border-radius:999px;background:#6E6E73;flex:none}}
</style></head><body>
<h1>窗数记号:短横该多大</h1>
<p class="note">圆点 = 1 扇、短横 = 5 扇。白条 = 一格(105.6pt ×4 放大);颜色/形状/间距都是当前实现。<br>
判据:短横要"与圆点同体量",但因为长,应当看起来**比圆点大** —— 看 6 扇那一行(横+点)最直观。</p>
{"".join(rows)}
</body></html>'''

hp = os.path.join(HERE, "窗数记号实验台.html")
open(hp, "w").write(html)
out = "/tmp/tally-lab.png"
subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                "--force-device-scale-factor=2", "--window-size=760,700",
                f"--screenshot={out}", f"file://{hp}"], check=True, capture_output=True)
print("出图:", out, "| 实验台:", hp)
