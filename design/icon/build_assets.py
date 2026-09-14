#!/usr/bin/env python3
"""把设计草图渲染成 Xcode 要的资产目录。

产物:`Sources/mac-switcher/Assets.xcassets`
  · AppIcon.appiconset   —— macOS 十档(16…1024),每档都从 SVG 直接栅格化,crisp
  · MenuBarIcon.imageset —— 18/36/54(1x/2x/3x),`template` 渲染:
      形状由 alpha 定,颜色由系统给(深色栏白 / 浅色栏黑)—— 这就是"必须是白色"的正解
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from make_icon import build_svg, render, OUT          # noqa: E402
from make_menubar import cand_strip                    # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CATALOG = os.path.join(REPO, "Sources", "mac-switcher", "Assets.xcassets")

# 档位 → 像素(macOS 十格共用 7 种像素)
ICON_SLOTS = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

APPICON_JSON = {
    "images": [
        {"idiom": "mac", "scale": "1x", "size": "16x16", "filename": "icon_16x16.png"},
        {"idiom": "mac", "scale": "2x", "size": "16x16", "filename": "icon_16x16@2x.png"},
        {"idiom": "mac", "scale": "1x", "size": "32x32", "filename": "icon_32x32.png"},
        {"idiom": "mac", "scale": "2x", "size": "32x32", "filename": "icon_32x32@2x.png"},
        {"idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128x128.png"},
        {"idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128x128@2x.png"},
        {"idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256x256.png"},
        {"idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256x256@2x.png"},
        {"idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512x512.png"},
        {"idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512x512@2x.png"},
    ],
    "info": {"author": "xcode", "version": 1},
}

MENUBAR_JSON = {
    "images": [
        {"idiom": "universal", "scale": "1x", "filename": "menubar_18.png"},
        {"idiom": "universal", "scale": "2x", "filename": "menubar_36.png"},
        {"idiom": "universal", "scale": "3x", "filename": "menubar_54.png"},
    ],
    "info": {"author": "xcode", "version": 1},
    "properties": {"template-rendering-intent": "template"},
}

ROOT_JSON = {"info": {"author": "xcode", "version": 1}}


def dump(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main():
    appicon = os.path.join(CATALOG, "AppIcon.appiconset")
    menubar = os.path.join(CATALOG, "MenuBarIcon.imageset")
    os.makedirs(appicon, exist_ok=True)
    os.makedirs(menubar, exist_ok=True)

    dump(os.path.join(CATALOG, "Contents.json"), ROOT_JSON)
    dump(os.path.join(appicon, "Contents.json"), APPICON_JSON)
    dump(os.path.join(menubar, "Contents.json"), MENUBAR_JSON)

    # App 图标:每个像素档都从矢量直接出图
    for filename, px in ICON_SLOTS:
        render(build_svg(pixel=px), px, os.path.join(appicon, filename))
        print("appicon", filename, px)

    # 菜单栏:18pt 的 1x/2x/3x
    body = cand_strip()
    for filename, px in [("menubar_18.png", 18), ("menubar_36.png", 36),
                         ("menubar_54.png", 54)]:
        markup = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" '
                  f'viewBox="0 0 36 36">{body}</svg>')
        render(markup, px, os.path.join(menubar, filename))
        print("menubar", filename, px)

    print("→", CATALOG)


if __name__ == "__main__":
    main()
