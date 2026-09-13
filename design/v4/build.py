#!/usr/bin/env python3
"""把 assets-src/ 里的素材 base64 内嵌进 template.html,产出自包含单文件原型。
产物带版本号文件名(Glance 面板 v1.x.html)——file:// 下浏览器缓存极顽固,
同名文件会被旧缓存顶替(评审已三连中招),一版一名,缓存无处可藏。"""
import base64, json, pathlib, re

here = pathlib.Path(__file__).parent
assets = here / "assets-src"

data = {}
for f in sorted(assets.iterdir()):
    mime = "image/png" if f.suffix == ".png" else "image/jpeg"
    data[f.stem] = f"data:{mime};base64," + base64.b64encode(f.read_bytes()).decode()

tpl = (here / "template.html").read_text(encoding="utf-8")
assert "/* __ASSETS__ */" in tpl, "模板缺少占位符"
m = re.search(r"<!-- proto-version: ([\d.]+) -->", tpl)
assert m, "模板缺少 <!-- proto-version: x.y --> 版本标记"
ver = m.group(1)

out = tpl.replace("/* __ASSETS__ */", "const D = " + json.dumps(data) + ";")

dest = here / f"Glance 面板 v{ver}.html"
dest.write_text(out, encoding="utf-8")
# 清理旧版本产物:只留当前版,防打开历史文件评审
for old in here.glob("Glance 面板 v*.html"):
    if old != dest:
        old.unlink()
        print(f"清理旧版 {old.name}")
print(f"OK {dest.name}  {dest.stat().st_size/1e6:.2f} MB  素材 {len(data)} 件")
