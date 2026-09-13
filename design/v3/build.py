#!/usr/bin/env python3
"""把 assets-src/ 里的素材 base64 内嵌进 template.html,产出自包含单文件原型。"""
import base64, json, pathlib

here = pathlib.Path(__file__).parent
assets = here / "assets-src"

data = {}
for f in sorted(assets.iterdir()):
    mime = "image/png" if f.suffix == ".png" else "image/jpeg"
    data[f.stem] = f"data:{mime};base64," + base64.b64encode(f.read_bytes()).decode()

tpl = (here / "template.html").read_text(encoding="utf-8")
assert "/* __ASSETS__ */" in tpl, "模板缺少占位符"
out = tpl.replace("/* __ASSETS__ */", "const D = " + json.dumps(data) + ";")

dest = here / "Glance 面板原型 v1.html"
dest.write_text(out, encoding="utf-8")
print(f"OK {dest.name}  {dest.stat().st_size/1e6:.2f} MB  素材 {len(data)} 件")
