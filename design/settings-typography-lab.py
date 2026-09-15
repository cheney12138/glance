#!/usr/bin/env python3
"""设置窗排版实验台:组标题该多"主标题"。

病例(2026-09-15 用户实拍"关于"页):组标题是 4pt 小圆点 + 11pt 灰字,而它管着的行标题是 13pt 墨字
—— **层级是反的**,"版本信息"没有主标题的感觉,整页看着没有主次。

改法:组标题 13pt 半粗 + 上墨色 + 一圈发丝边框胶囊;行标题 13 不动,说明 11.5→12、数值 12.5→13;
组间距 20→26。下面按真实 token 出"改前 / 改后"两张纸窗对照(600×480,demo 同尺寸)。

    python3 design/settings-typography-lab.py   # 出 design/设置排版实验台.html + /tmp/settings-type.png
"""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 真实 token:SettingsTheme / SettingsMetrics / SettingsFont
PAPER = "#ECEEF2"
INK = "#16171C"
INK2 = "rgba(22,23,28,.56)"
HAIR = "rgba(22,23,28,.09)"
LABEL_BORDER = "rgba(22,23,28,.15)"
PRISM = ("linear-gradient(90deg,#FF6B6B 0%,#FFB648 16%,#FFE066 32%,#4ADE80 48%,"
         "#38BDF8 66%,#8B7CF6 84%,#FF6B6B 100%)")


def label(text, after):
    """组标题:改前 = 4pt 圆点 + 11pt 灰;改后 = 13pt 半粗 + 墨色 + 发丝边框胶囊"""
    if not after:
        return (f'<div style="font-size:11px;color:{INK2}">'
                f'<i style="width:4px;height:4px;border-radius:50%;background:{INK2};'
                f'display:inline-block;margin-right:6px;vertical-align:middle"></i>{text}</div>')
    return (f'<div style="display:inline-block;font-size:13px;font-weight:600;color:{INK};'
            f'padding:4px 9px;border:1px solid {LABEL_BORDER};border-radius:8px">{text}</div>')


def row(title, desc, value, after, top_hair, badge=False):
    desc_px, value_px = (12, 13) if after else (11.5, 12.5)
    sub = (f'<div style="color:{INK2};font-size:{desc_px}px;line-height:1.55;margin-top:4px">'
           f'{desc}</div>') if desc else ''
    if badge:
        tail = (f'<div style="display:flex;align-items:center;gap:6px;color:{INK2};font-size:{value_px}px">'
                f'<i style="width:8px;height:8px;border-radius:50%;background:#34C759;'
                f'display:inline-block"></i>已授权</div>')
    elif value:
        tail = f'<div style="color:{INK2};font-size:{value_px}px">{value}</div>'
    else:
        tail = ''
    hair = f'border-bottom:1px solid {HAIR};' if top_hair else ''
    return (f'<div style="display:flex;align-items:center;justify-content:space-between;'
            f'padding:13px 0;{hair}"><div><div style="color:{INK};font-size:13px">{title}</div>'
            f'{sub}</div>{tail}</div>')


def page(after):
    gap = 26 if after else 20
    label_gap = 10 if after else 7
    content = (
        f'<div style="margin-bottom:{label_gap}px">{label("版本信息", after)}</div>'
        + row("名称", None, "Glance", after, True)
        + row("版本", None, "0.1.0", after, False)
        + f'<div style="margin-top:{gap}px;margin-bottom:{label_gap}px">{label("权限", after)}</div>'
        + row("辅助功能", "用于读取与聚焦窗口。缺失时切换器无法工作。", None, after, True, badge=True)
        + row("屏幕录制", "用于生成窗口预览。", None, after, False, badge=True)
    )
    return f'''<div class="win">
  <div class="lights"><i style="background:#FF5F57"></i><i style="background:#FEBC2E"></i><i style="background:#28C840"></i></div>
  <div class="prism"></div>
  <div class="tabs"><span>通用</span><span>快捷键</span><span class="on">关于</span></div>
  <div class="content">{content}</div>
</div>'''


HTML = f'''<!DOCTYPE html><html><head><meta charset="utf-8"><style>
 html,body{{margin:0;background:#F6F5F3;font:13px -apple-system,"PingFang SC",sans-serif}}
 h1{{font-size:15px;font-weight:600;margin:20px 24px 12px;color:#3A3A3C}}
 .wrap{{display:flex;gap:24px;padding:0 24px 24px}}
 .lab{{font-size:12px;color:#8A8A8E;margin:0 0 6px}}
 .win{{width:600px;height:480px;background:{PAPER};border-radius:10px;position:relative;overflow:hidden;
      box-shadow:0 2px 10px rgba(0,0,0,.08)}}
 .lights{{display:flex;gap:8px;padding:13px 0 0 14px}}
 .lights i{{width:12px;height:12px;border-radius:50%;display:block}}
 .prism{{position:absolute;top:38px;left:0;right:0;height:1px;background:{PRISM}}}
 .tabs{{display:flex;justify-content:center;gap:4px;margin-top:22px}}
 .tabs span{{font-size:12.5px;font-weight:500;color:{INK};padding:7px 14px;border-radius:9px}}
 .tabs .on{{background:rgba(255,255,255,.55);box-shadow:0 1px 2px rgba(0,0,0,.06)}}
 .content{{padding:26px 28px 0}}
</style></head><body>
<h1>设置窗排版:组标题该多"主标题"</h1>
<div class="wrap">
  <div><div class="lab">改前:组标题 11pt 灰 + 4pt 圆点 —— 比它管着的行标题还轻</div>{page(False)}</div>
  <div><div class="lab">改后:组标题 13pt 半粗 + 墨色 + 发丝边框胶囊;组间距与行距同步松开</div>{page(True)}</div>
</div>
</body></html>'''


def main():
    hp = os.path.join(HERE, "设置排版实验台.html")
    with open(hp, "w") as f:
        f.write(HTML)
    out = "/tmp/settings-type.png"
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", "--window-size=1290,600",
                    f"--screenshot={out}", f"file://{hp}"], check=True, capture_output=True)
    print("出图:", out, "| 实验台:", hp)


if __name__ == "__main__":
    main()
