#!/usr/bin/env python3
"""
make-icon.py — 生成 SnipShot 的 macOS 应用图标（Resources/AppIcon.icns + iconset 源图）

尺寸规范（**实测**自系统内真实 App 的 .icns，不是凭记忆猜的）：
    画布      1024 × 1024（透明）
    主体      824 × 824 居中 → 四边留白 100px
    圆角半径  185.4 = 824 × 0.225
    投影      参考图标里都烘焙了一层极淡投影（alpha>0 向外扩 ~25px，向下偏 ~12px）

轮廓模型验证：把参考图标每个深度 d 处的左侧内缩量逐点量出来，与
「圆角矩形 r=185.4」在中段（d=32/64/96/128）完全吻合，且顶边中点与主体顶边齐平
（若是超椭圆会有鼓包）→ 所以用圆角矩形，不用超椭圆。

图标构成：
    · 石墨渐变 squircle 底（顶部受光 + 内描边高光）
    · 白色四角取景框 —— 与菜单栏 statusItem 的代码绘制图标同一套视觉语言
    · 中心蓝紫渐变方块 —— 「被截下来 / 被钉住的那一块」，色取自 App 自身
      权限引导页的 Color.blue → Color.purple

小尺寸（≤32px）会自动切到「加粗版」：框线更粗、方块更大。
1024 下 46px 的框线缩到 16px 只剩 0.7px，会糊成一团 —— Apple 自家图标也是
在小尺寸换简化稿，这是必要的一步。

用法：
    python3 scripts/make-icon.py            # 生成 iconset + icns
    python3 scripts/make-icon.py --preview  # 额外输出预览图
"""

import argparse
import math
import os
import subprocess
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit("需要 Pillow：/Users/taoliu/.workbuddy/binaries/python/envs/default/bin/pip install Pillow")

try:
    import numpy as np
except ImportError:
    sys.exit("需要 numpy：/Users/taoliu/.workbuddy/binaries/python/envs/default/bin/pip install numpy")

# ---------------------------------------------------------------------------
# 规范常量（以 1024 画布为基准）
# ---------------------------------------------------------------------------
CANVAS = 1024
BODY = 824                      # squircle 主体边长
MARGIN = (CANVAS - BODY) // 2   # 100
RADIUS = 185.4                  # = BODY * 0.225

SS = 4                          # 超采样倍数：4096 渲染后降采样，保证边缘抗锯齿

# 配色
BG_TOP = (56, 63, 78)           # 石墨灰（偏冷）
BG_MID = (34, 39, 50)
BG_BOT = (17, 20, 25)
ACCENT_A = (168, 184, 255)      # 蓝紫·亮（方块顶部）  #A8B8FF
ACCENT_B = (124, 77, 214)       # 蓝紫·深（方块底部）  #7C4DD6
ACCENT_GLOW = (140, 118, 252)   # 辉光


def _lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _vertical_gradient(size, stops):
    """stops: [(位置0..1, (r,g,b)), ...]（按位置升序）——用 numpy 生成平滑竖向渐变。"""
    h = size
    arr = np.zeros((h, 3), dtype=np.float64)
    for y in range(h):
        t = y / max(h - 1, 1)
        lo, hi = stops[0], stops[-1]
        for i in range(len(stops) - 1):
            if stops[i][0] <= t <= stops[i + 1][0]:
                lo, hi = stops[i], stops[i + 1]
                break
        span = max(hi[0] - lo[0], 1e-9)
        k = (t - lo[0]) / span
        for c in range(3):
            arr[y, c] = lo[1][c] + (hi[1][c] - lo[1][c]) * k
    return np.repeat(arr[:, None, :], size, axis=1)


def _rounded_mask(size, box, radius):
    """白色填充的圆角矩形 alpha 遮罩（L 模式），box=(l,t,r,b) 已是像素坐标。"""
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def _clip(layer, mask):
    """把 layer 按 mask 裁剪（保留 layer 自己的 alpha）。"""
    out = layer.copy()
    a = out.getchannel("A")
    out.putalpha(Image.composite(a, Image.new("L", out.size, 0), mask))
    return out


def render(size_px, bold=False):
    """渲染一张 size_px 见方的图标。bold=True → 小尺寸加粗版。"""
    S = size_px * SS
    k = S / CANVAS                      # 相对 1024 基准的缩放系数
    body = round(BODY * k)
    margin = (S - body) // 2
    radius = RADIUS * k
    box = (margin, margin, margin + body, margin + body)

    # ---- 主体遮罩 ----
    body_mask = _rounded_mask(S, box, radius)

    # ---- 底色：竖向渐变 ----
    grad = _vertical_gradient(S, [(0.0, BG_TOP), (0.45, BG_MID), (1.0, BG_BOT)])
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    base.paste(Image.fromarray(grad.astype("uint8"), "RGB"), (0, 0))
    base = _clip(base, body_mask)

    # ---- 顶部受光（Big Sur 那种「自上而下打光」）----
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh = np.zeros((S, S, 4), dtype=np.uint8)
    top, end = margin, margin + round(body * 0.52)
    for y in range(S):
        if top <= y < end:
            t = (y - top) / max(end - top, 1)
            sh[y, :, :3] = 255
            sh[y, :, 3] = int(30 * (1 - t) ** 1.6)
    sheen = Image.fromarray(sh, "RGBA")
    sheen = _clip(sheen, body_mask)
    base = Image.alpha_composite(base, sheen)

    d = ImageDraw.Draw(base)

    # ---- 内描边：顶亮底暗，制造厚度 ----
    stroke_w = max(1, round(2.6 * k))
    d.rounded_rectangle(box, radius=radius,
                        outline=(255, 255, 255, 34), width=stroke_w)

    # ---- 参数 ----
    # normal：框线偏细、臂偏长，视觉更轻；bold（≤32px）大幅加粗并简化，
    # 否则 1024 下 40px 的框线缩到 16px 只剩 0.6px，会糊成一坨。
    if bold:
        arm = body * 0.300
        line = body * 0.112
        inset = body * 0.125
        blk = body * 0.300
        blk_r = blk * 0.300
    else:
        arm = body * 0.226
        line = body * 0.042
        inset = body * 0.152
        blk = body * 0.200
        blk_r = blk * 0.310

    fl, ft = box[0] + inset, box[1] + inset
    fr, fb = box[2] - inset, box[3] - inset

    # ---- 中心方块：极淡的同色辉光 + 竖向渐变瓷片 ----
    # 小尺寸不加辉光：16px 下那圈雾会让整块糊掉，宁可干净利落。
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    if not bold:
        glow_pad = blk * 0.16
        glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(glow).rounded_rectangle(
            (cx - blk / 2 - glow_pad, cy - blk / 2 - glow_pad,
             cx + blk / 2 + glow_pad, cy + blk / 2 + glow_pad),
            radius=blk_r + glow_pad, fill=ACCENT_GLOW + (46,))
        glow = _clip(glow.filter(ImageFilter.GaussianBlur(blk * 0.13)), body_mask)
        base = Image.alpha_composite(base, glow)

    b_l, b_t = round(cx - blk / 2), round(cy - blk / 2)
    b_r, b_b = round(cx + blk / 2), round(cy + blk / 2)
    blk_mask = _rounded_mask(S, (b_l, b_t, b_r, b_b), blk_r)

    # 竖向渐变（顶部亮 → 底部深），做成一块有厚度的瓷片而不是平涂色块。
    # 不要在上面再叠「顶部高光块」—— 那会让方块变成一颗玻璃胶囊，很小气。
    blk_rgb = np.zeros((S, S, 3), dtype=np.float64)
    span = np.clip((np.arange(S)[:, None] - b_t) / max(b_b - b_t, 1), 0, 1)
    for c in range(3):
        blk_rgb[:, :, c] = ACCENT_A[c] + (ACCENT_B[c] - ACCENT_A[c]) * span
    blk_img = _clip(Image.fromarray(blk_rgb.astype("uint8"), "RGB").convert("RGBA"),
                    blk_mask)
    # 仅保留一圈极细的内描边高光，交代边缘厚度
    if not bold:
        bs = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(bs).rounded_rectangle(
            (b_l, b_t, b_r, b_b), radius=blk_r,
            outline=(255, 255, 255, 48), width=max(1, round(1.6 * k)))
        blk_img = Image.alpha_composite(blk_img, _clip(bs, blk_mask))
    base = Image.alpha_composite(base, blk_img)

    # ---- 四角取景框 ----
    br = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(br)
    white = (255, 255, 255, 242)
    w2 = line / 2
    # 把线端收进去半个线宽，让外侧边缘正好落在 frame 边界上
    for (px, py, dx, dy) in ((fl, ft, 1, 1), (fr, ft, -1, 1),
                             (fl, fb, 1, -1), (fr, fb, -1, -1)):
        bd.line([(px, py), (px + dx * (arm - w2), py)], fill=white,
                width=round(line))
        bd.line([(px, py), (px, py + dy * (arm - w2))], fill=white,
                width=round(line))
        r = w2
        bd.ellipse((px - r, py - r, px + r, py + r), fill=white)
    br = _clip(br.filter(ImageFilter.GaussianBlur(max(0.4, 0.8 * k))), body_mask)
    base = Image.alpha_composite(base, br)

    # ---- 烘焙投影（参考图标均有；macOS 不会自动加）----
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh_mask = _rounded_mask(S, (box[0], box[1] + round(12 * k),
                                box[2], box[3] + round(12 * k)), radius)
    sh_mask = sh_mask.filter(ImageFilter.GaussianBlur(11 * k))
    shadow.putalpha(sh_mask.point(lambda v: int(v * 0.26)))
    out = Image.alpha_composite(shadow, base)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true", help="额外输出预览图")
    ap.add_argument("--out", default=None, help="输出目录（默认项目 Resources/）")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = args.out or os.path.join(root, "Resources")
    iconset = os.path.join(out_dir, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)

    # iconutil 需要的 10 个尺寸
    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
             (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

    # 每个「实际输出像素尺寸」只渲染一次主图（同一尺寸可能被多个条目复用）
    targets = sorted({base_px * scale for base_px, scale in specs})
    masters = {}
    print("渲染主图 …")
    for target in targets:
        bold = target <= 32          # ≤32px 用加粗版，否则框线缩到亚像素会糊掉
        masters[target] = render(target, bold=bold)
        print(f"  {target:>4}x{target:<4} 渲染于 {target * SS}px"
              f"  {'(加粗版)' if bold else ''}")

    print("\n输出 iconset …")
    for base_px, scale in specs:
        name = f"icon_{base_px}x{base_px}{'@2x' if scale == 2 else ''}.png"
        target = base_px * scale
        masters[target].resize((target, target), Image.LANCZOS).save(
            os.path.join(iconset, name))
        print(f"  {name:<24} {target}x{target}")

    icns = os.path.join(out_dir, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print(f"\n✅ {icns}  ({os.path.getsize(icns)} bytes)")
    print(f"✅ {iconset}/  (源图，可再次 iconutil 重打包)")

    if args.preview:
        # 上排：各尺寸按真实像素显示（模拟 Dock/访达里的观感）
        # 下排：16/32/64 放大 6 倍（检查小尺寸有没有糊成一坨）
        W, H = 1240, 560
        pv = Image.new("RGBA", (W, H), (246, 246, 248, 255))
        d = ImageDraw.Draw(pv)
        d.text((30, 26), "实际尺寸 (1:1)", fill=(60, 60, 70, 255))
        x = 30
        for p in (16, 32, 64, 128, 256, 512):
            src = masters[min(masters, key=lambda m: abs(m - p))]
            im = src.resize((p, p), Image.LANCZOS)
            pv.alpha_composite(im, (x, 60 + (256 - p) // 2))
            x += p + 26

        d.text((30, 350), "放大 6× 检查小尺寸可读性", fill=(60, 60, 70, 255))
        x = 30
        for p in (16, 32, 64):
            src = masters[min(masters, key=lambda m: abs(m - p))]
            z = p * 6
            im = src.resize((z, z), Image.NEAREST).resize((z, z), Image.LANCZOS)
            im = src.resize((z, z), Image.LANCZOS)
            pv.alpha_composite(im, (x, 380 + (160 - z) // 2))
            x += z + 34
        pv_path = os.path.join(out_dir, "AppIcon-preview.png")
        pv.convert("RGB").save(pv_path)
        print(f"✅ {pv_path}")


if __name__ == "__main__":
    main()
