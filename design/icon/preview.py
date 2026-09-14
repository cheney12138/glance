import os, subprocess
from make_icon import build_svg, render, OUT
from make_menubar import cand_strip
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
# 用资产目录里已生成的 PNG 拼预览
CAT="/Users/qychen/code/Glance/Sources/mac-switcher/Assets.xcassets"
icon=f"file://{CAT}/AppIcon.appiconset/icon_512x512@2x.png"
mb=f"file://{CAT}/MenuBarIcon.imageset/menubar_36.png"
html=f"""<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body{{margin:0;width:900px;background:#f4f5f7;font:12px -apple-system;color:#3a3d44;}}
.card{{padding:34px 40px;}}
h1{{font:600 15px -apple-system;margin:0 0 4px;}}
p{{margin:0 0 22px;color:#7a7f88;}}
.sizes{{display:flex;align-items:flex-end;gap:26px;margin-bottom:8px;}}
.sizes figure{{margin:0;text-align:center;}} .sizes img{{display:block;}}
.cap{{color:#9aa0a6;font-size:10.5px;margin-top:6px;}}
.bars{{display:flex;flex-direction:column;gap:14px;margin-top:6px;}}
.bar{{height:30px;border-radius:7px;display:flex;align-items:center;justify-content:flex-end;
 padding:0 12px;gap:14px;}}
.dark{{background:#1d1d1f;}}
.light{{background:#eceef1;border:1px solid #d9dbe0;}}
.dark .ph{{background:#4a4d52;}} .light .ph{{background:#b9bcc3;}}
.ph{{width:18px;height:18px;border-radius:4px;opacity:.55;}}
.mg{{image-rendering:pixelated;}}
</style></head><body><div class="card">
<h1>Glance · App 图标</h1>
<p>1024 画布 / squircle 824(Apple 80.5% 安全区)· 玻璃长条 + 三格,中间格选中(聚焦蓝)</p>
<div class="sizes">
  <figure><img src="{icon}" width="256"><div class="cap">256</div></figure>
  <figure><img src="{icon}" width="128"><div class="cap">128</div></figure>
  <figure><img src="{icon}" width="64"><div class="cap">64</div></figure>
  <figure><img src="{icon}" width="32"><div class="cap">32</div></figure>
  <figure><img src="{icon}" width="16"><div class="cap">16</div></figure>
</div>
<h1 style="margin-top:30px">菜单栏图标 · template</h1>
<p>深色栏 = 白(系统给色);浅色栏 = 黑。同一份资产,靠 alpha 定形</p>
<div class="bars">
  <div class="bar dark"><span class="ph"></span><span class="ph"></span>
    <img src="{mb}"><span class="ph"></span></div>
  <div class="bar light"><span class="ph"></span><span class="ph"></span>
    <img src="{mb}" style="filter:invert(1)"><span class="ph"></span></div>
</div>
<div class="sizes" style="margin-top:18px">
  <figure><img class="mg" src="{mb}" width="108"><div class="cap">18pt @3x 放大</div></figure>
  <figure><img class="mg" src="{mb}" width="36"><div class="cap">@2x 实尺寸</div></figure>
  <figure><img src="{mb}" width="18"><div class="cap">@1x 实尺寸</div></figure>
</div>
</div></body></html>"""
p=os.path.join(OUT,"preview.html"); open(p,"w").write(html)
subprocess.run([CHROME,"--headless=new","--disable-gpu","--hide-scrollbars","--force-device-scale-factor=2",
  "--window-size=900,720","--default-background-color=ffffffff",
  f"--screenshot={os.path.join(OUT,'preview.png')}",f"file://{p}"],check=True,capture_output=True)
print(os.path.join(OUT,"preview.png"))
