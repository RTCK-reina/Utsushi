#!/usr/bin/env python3
"""アプリアイコンを生成する。

外部の素材を持ち込まず、その場で描く。生成物（Resources/AppIcon.icns）は
リポジトリに入れてあるので、通常のビルドでこれを走らせる必要はない。
意匠を変えたいときだけ:

    python3 script/make_icon.py && bash script/build_and_run.sh release

意匠: 濃紺の角丸四角に波形。中央の1本だけ色を変えてあるのは、
「全部を均一に流すのではなく1箇所を見つける」というアプリの役どころ。
"""
import math
import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources"

S = 1024
MARGIN = 100          # macOS のアイコンは周囲に余白を取る慣習
RADIUS = 210
BG_TOP = (32, 40, 68)
BG_BOTTOM = (18, 22, 38)
BAR = (232, 236, 246)
ACCENT = (255, 176, 74)


def rounded_mask(size: int, box: tuple[int, int, int, int], radius: int) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def render() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 縦のグラデーション
    grad = Image.new("RGB", (1, S))
    for y in range(S):
        t = y / (S - 1)
        grad.putpixel((0, y), tuple(
            int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)))
    grad = grad.resize((S, S))

    box = (MARGIN, MARGIN, S - MARGIN, S - MARGIN)
    img.paste(grad, (0, 0), rounded_mask(S, box, RADIUS))

    d = ImageDraw.Draw(img)

    # 波形。中央に向かって高くなる形にして、真ん中の1本だけ色を変える。
    n = 13
    inner_w = (S - 2 * MARGIN) * 0.62
    left = (S - inner_w) / 2
    step = inner_w / (n - 1)
    bar_w = step * 0.38
    center_y = S / 2
    max_h = (S - 2 * MARGIN) * 0.46

    for i in range(n):
        x = left + i * step
        # 中央が高い、緩やかに揺れる形
        u = (i - (n - 1) / 2) / ((n - 1) / 2)
        h = max_h * (0.30 + 0.70 * math.cos(u * math.pi / 2) ** 2) \
            * (0.72 + 0.28 * math.cos(i * 1.9))
        h = max(h, max_h * 0.16)
        color = ACCENT if i == n // 2 else BAR
        d.rounded_rectangle(
            (x - bar_w / 2, center_y - h / 2, x + bar_w / 2, center_y + h / 2),
            radius=bar_w / 2, fill=color)

    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    base = render()
    base.save(OUT / "AppIcon.png")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        # iconutil が要求する組み合わせ
        for size in (16, 32, 128, 256, 512):
            base.resize((size, size), Image.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            base.resize((size * 2, size * 2), Image.LANCZOS).save(
                iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset),
                        "-o", str(OUT / "AppIcon.icns")], check=True)
    print("wrote", OUT / "AppIcon.icns")


if __name__ == "__main__":
    main()
