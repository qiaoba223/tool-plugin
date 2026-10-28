#!/usr/bin/env python3
"""生成应用图标，并写入 Android / iOS 平台工程。

图标：深色圆角底板 + 三个带拼接口的方块（主题青），表示「插件工具箱」。
不依赖 SVG 渲染器，只用 Pillow，CI 里 pip install pillow 即可。

用法：
    python3 tool/gen_icon.py          # 生成并应用
"""
import json
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit('需要 Pillow：pip install pillow')

SIZE = 1024
CYAN = (42, 169, 201, 255)       # 与 app_theme 的 seed 一致
CYAN_LIGHT = (104, 220, 240, 255)
WHITE = (255, 255, 255, 255)
BG_TOP = (34, 56, 68)
BG_BOTTOM = (16, 27, 34)


def _rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1],
                                           radius=radius, fill=255)
    return mask


def _plug(canvas: Image.Image, cx: float, cy: float, size: float, color,
          rot: float = -10.0, filled: bool = True) -> None:
    """画一个带右侧拼接口凸起的圆角方块，围绕自身中心旋转后叠加。"""
    lay = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lay)
    radius = size * 0.24
    x0, y0 = cx - size / 2, cy - size / 2
    x1, y1 = x0 + size, y0 + size
    if filled:
        ld.rounded_rectangle([x0, y0, x1, y1], radius=radius, fill=color)
    else:
        ld.rounded_rectangle([x0, y0, x1, y1], radius=radius,
                             outline=color, width=int(size * 0.085))
    # 右侧凸起（插件拼接口）
    pw, ph = size * 0.26, size * 0.17
    ld.rounded_rectangle([x1 - pw * 0.6, cy - ph / 2, x1 + pw * 0.6, cy + ph / 2],
                         radius=ph * 0.4, fill=color)
    if rot:
        lay = lay.rotate(rot, resample=Image.BICUBIC, center=(cx, cy))
    canvas.alpha_composite(lay)


def render_master() -> Image.Image:
    """画 1024×1024 主图。"""
    img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))

    # 圆角底板渐变
    bg = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bg)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        bd.line([(0, y), (SIZE, y)],
                fill=tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t)
                           for i in range(3)) + (255,))
    mask = _rounded_mask(SIZE, int(SIZE * 0.225))
    img.paste(bg, (0, 0), mask)

    # 左上青色光晕
    glow = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    radius = int(SIZE * 0.52)
    for r in range(radius, 0, -4):
        alpha = int(26 * (1 - r / radius) ** 1.4)
        gd.ellipse([SIZE * 0.30 - r, SIZE * 0.24 - r,
                    SIZE * 0.30 + r, SIZE * 0.24 + r],
                   fill=CYAN[:3] + (alpha,))
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    img.alpha_composite(
        Image.composite(glow, Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0)), mask))

    # 三个插件方块：主体 / 已装 / 待装
    _plug(img, SIZE * 0.415, SIZE * 0.435, SIZE * 0.375, CYAN)
    _plug(img, SIZE * 0.695, SIZE * 0.305, SIZE * 0.165, CYAN_LIGHT)
    _plug(img, SIZE * 0.615, SIZE * 0.700, SIZE * 0.235, WHITE, filled=False)

    return img.filter(ImageFilter.SMOOTH)


def _resize(master: Image.Image, size: int) -> Image.Image:
    return master.resize((size, size), Image.LANCZOS)


def apply_android(master: Image.Image) -> int:
    """写入 mipmap 各密度 + 自适应图标前景。"""
    root = 'android/app/src/main/res'
    if not os.path.isdir(root):
        print(f'[SKIP] {root} 不存在（本次未生成 Android 工程）')
        return 0
    densities = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
    for dpi, size in densities.items():
        path = os.path.join(root, f'mipmap-{dpi}', 'ic_launcher.png')
        os.makedirs(os.path.dirname(path), exist_ok=True)
        _resize(master, size).save(path)
    # 自适应图标前景：108dp 画布，内容区 72dp 居中（四周留安全边距）
    for dpi, canvas in {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216,
                        'xxhdpi': 324, 'xxxhdpi': 432}.items():
        fg = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
        inner = int(canvas * 2 / 3)
        fg.alpha_composite(_resize(master, inner), ((canvas - inner) // 2,) * 2)
        path = os.path.join(root, f'mipmap-{dpi}', 'ic_launcher_foreground.png')
        fg.save(path)
    return len(densities) * 2


def apply_ios(master: Image.Image) -> int:
    """按 Contents.json 声明的每个条目生成图标。

    iOS 图标要求不透明、无 alpha 通道；且模板里除 1024 外还有多个小尺寸，
    只覆盖 1024 会让小图标仍是 Flutter 默认 logo，所以这里逐个生成。
    """
    appicon = os.path.join('ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    contents = os.path.join(appicon, 'Contents.json')
    if not os.path.isdir(appicon):
        print('[SKIP] iOS AppIcon.appiconset 不存在（本次未生成 iOS 工程）')
        return 0

    # 用 alpha 合成到实底，去掉透明通道
    flat = Image.new('RGB', (SIZE, SIZE), BG_BOTTOM)
    flat.paste(master, (0, 0), master)

    written = 0
    names = []
    if os.path.exists(contents):
        with open(contents, encoding='utf-8') as f:
            meta = json.load(f)
        for item in meta.get('images', []):
            fn = item.get('filename')
            scale = item.get('scale', '1x').rstrip('x')
            size = item.get('size', '1024x1024')
            if not fn:
                continue
            try:
                pt = float(size.split('x')[0])
                px = int(round(pt * float(scale)))
            except (ValueError, IndexError):
                continue
            if px <= 0:
                continue
            out = os.path.join(appicon, fn)
            if px == SIZE:
                flat.save(out)
            else:
                flat.resize((px, px), Image.LANCZOS).save(out)
            written += 1
            names.append(f'{fn}({px})')

    if written == 0:
        # Contents.json 缺失：至少把 1024 写进去
        flat.save(os.path.join(appicon, 'Icon-App-1024x1024@1x.png'))
        written = 1
        names = ['Icon-App-1024x1024@1x.png(1024)']

    print(f'  iOS: {", ".join(names[:6])}{" ..." if len(names) > 6 else ""}')
    return written


def main() -> None:
    master = render_master()
    n_android = apply_android(master)
    n_ios = apply_ios(master)
    print(f'图标已应用：Android {n_android} 个文件，iOS {n_ios} 个文件')
    if n_android == 0 and n_ios == 0:
        sys.exit('未找到任何平台工程，图标未应用')


if __name__ == '__main__':
    main()
