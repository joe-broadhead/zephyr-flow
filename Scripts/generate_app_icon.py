#!/usr/bin/env python3
"""Generate branded ZephyrFlow.icns — flow mark on deep-navy UI chrome (no letterforms)."""
from __future__ import annotations

import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT_ICNS = ROOT / "Resources" / "AppIcon.icns"
OUT_PNG = ROOT / "docs" / "images" / "app-icon-1024.png"
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def gradient_background(size: int) -> Image.Image:
    """
    Match Setup UI: bgDeep navy (~11,13,20) with low-alpha violet/cyan radials.
    Not a solid candy-purple fill.
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = y / max(1, size - 1)
            # ZephyrTheme.bgDeep → slight lift
            r = int(lerp(11, 16, t))
            g = int(lerp(13, 18, t))
            b = int(lerp(20, 28, t))

            # top-trailing violet wash (~0.18 opacity in UI)
            dv = math.hypot(x - size * 0.92, y - size * 0.10) / (size * 1.1)
            violet = max(0.0, 1.0 - min(1.0, dv)) ** 2 * 0.20
            r = int(min(255, r + 140 * 0.50 * violet))
            g = int(min(255, g + 102 * 0.35 * violet))
            b = int(min(255, b + 250 * 0.50 * violet))

            # bottom-leading cyan wash (~0.12)
            dc = math.hypot(x - size * 0.10, y - size * 0.90) / (size * 1.1)
            cyan = max(0.0, 1.0 - min(1.0, dc)) ** 2 * 0.14
            r = int(min(255, r + 77 * 0.30 * cyan))
            g = int(min(255, g + 230 * 0.30 * cyan))
            b = int(min(255, b + 242 * 0.40 * cyan))

            # center card lift (bgCard-ish)
            d0 = math.hypot(x - size * 0.5, y - size * 0.5) / (size * 0.58)
            lift = max(0.0, 1.0 - min(1.0, d0)) ** 2 * 0.14
            r = int(min(255, r + 14 * lift))
            g = int(min(255, g + 16 * lift))
            b = int(min(255, b + 24 * lift))

            px[x, y] = (r, g, b, 255)

    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.223), fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, mask=mask)
    return out


def draw_flow_mark(draw: ImageDraw.ImageDraw, size: int) -> None:
    """Three flowing ribbons + core orb — no letterforms."""
    s = float(size)
    cx, cy = s * 0.50, s * 0.52

    orb_r = s * 0.13
    for i, a in ((0.22, 36), (0.17, 64), (0.13, 100)):
        r = s * i
        draw.ellipse(
            (cx - r, cy - r, cx + r, cy + r),
            outline=(180, 220, 255, a),
            width=max(1, int(s * 0.012)),
        )
    draw.ellipse(
        (cx - orb_r, cy - orb_r, cx + orb_r, cy + orb_r),
        fill=(230, 240, 255, 230),
    )
    hr = orb_r * 0.45
    draw.ellipse(
        (cx - hr * 0.6, cy - orb_r * 0.55, cx + hr * 1.1, cy - orb_r * 0.05),
        fill=(255, 255, 255, 90),
    )

    ribbons = [
        (0.34, 0.055, 0.0, 0.055, 230),
        (0.50, 0.07, 0.8, 0.065, 245),
        (0.66, 0.055, 1.6, 0.055, 220),
    ]
    for y_mid, amp, phase, wfrac, alpha in ribbons:
        width = max(2, int(s * wfrac))
        pts: list[tuple[float, float]] = []
        steps = 48
        x0, x1 = s * 0.14, s * 0.86
        for i in range(steps + 1):
            t = i / steps
            x = lerp(x0, x1, t)
            y = s * y_mid + s * amp * math.sin(t * math.pi * 2.1 + phase)
            y += s * 0.02 * math.sin(t * math.pi)
            pts.append((x, y))
        color = (236, 244, 255, alpha)
        draw.line(pts, fill=color, width=width, joint="curve")
        rad = width / 2
        for pt in (pts[0], pts[-1]):
            draw.ellipse((pt[0] - rad, pt[1] - rad, pt[0] + rad, pt[1] + rad), fill=color)

    spark_x, spark_y = s * 0.82, s * 0.36
    sr = s * 0.028
    draw.ellipse(
        (spark_x - sr, spark_y - sr, spark_x + sr, spark_y + sr),
        fill=(180, 255, 250, 240),
    )


def render(size: int) -> Image.Image:
    base = gradient_background(size)
    # Soft corner washes only (UI-matched opacity)
    for color, cx, cy, blur, rad_f in (
        ((140, 102, 250, 24), 0.88, 0.10, 0.16, 0.50),
        ((77, 230, 242, 18), 0.10, 0.90, 0.16, 0.48),
    ):
        glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        rad = int(size * rad_f)
        cxi, cyi = int(size * cx), int(size * cy)
        gd.ellipse((cxi - rad, cyi - rad, cxi + rad, cyi + rad), fill=color)
        glow = glow.filter(ImageFilter.GaussianBlur(radius=size * blur))
        base = Image.alpha_composite(base, glow)

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_flow_mark(ImageDraw.Draw(layer), size)
    if size >= 256:
        layer = layer.filter(ImageFilter.GaussianBlur(radius=0.35))
    return Image.alpha_composite(base, layer)


def main() -> None:
    OUT_ICNS.parent.mkdir(parents=True, exist_ok=True)
    OUT_PNG.parent.mkdir(parents=True, exist_ok=True)

    master = render(1024)
    master.save(OUT_PNG, "PNG")
    print(f"wrote {OUT_PNG}")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        mapping = {
            16: ["icon_16x16.png"],
            32: ["icon_16x16@2x.png", "icon_32x32.png"],
            64: ["icon_32x32@2x.png"],
            128: ["icon_128x128.png"],
            256: ["icon_128x128@2x.png", "icon_256x256.png"],
            512: ["icon_256x256@2x.png", "icon_512x512.png"],
            1024: ["icon_512x512@2x.png"],
        }
        for size in SIZES:
            img = render(size)
            for name in mapping.get(size, []):
                img.save(iconset / name, "PNG")
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(OUT_ICNS)],
            check=True,
        )
    print(f"wrote {OUT_ICNS}")


if __name__ == "__main__":
    main()
