"""NOTE: the SHIPPED icon is the user's own artwork at assets/icon/icon.png
(do not overwrite it). This script only recreates an approximation for
reference and writes to assets/icon/icon_generated*.png so it can't clobber
the real file. Run: python tool/make_icon.py
"""
import math
import numpy as np
from PIL import Image, ImageDraw

S = 1024
GREEN_MID = (26, 61, 53)     # centre
GREEN_EDGE = (14, 38, 33)    # vignette corners
CREAM = (233, 228, 208)
DARK = (11, 38, 34)          # chevrons
GOLD = (217, 166, 42)        # beam-end dots


def vignette_bg():
    yy, xx = np.mgrid[0:S, 0:S]
    d = np.sqrt((xx - S / 2) ** 2 + (yy - S / 2) ** 2) / (S / 2 * 1.05)
    d = np.clip(d, 0, 1)[..., None]
    mid = np.array(GREEN_MID); edge = np.array(GREEN_EDGE)
    arr = (mid * (1 - d) + edge * d).astype(np.uint8)
    return Image.fromarray(np.dstack([arr, np.full((S, S), 255, np.uint8)]), "RGBA")


def draw_design(bg_transparent):
    img = (Image.new("RGBA", (S, S), (0, 0, 0, 0)) if bg_transparent else vignette_bg())
    # Supersample for smooth curves.
    ss = 2
    big = Image.new("RGBA", (S * ss, S * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)

    # Winding cream canal: a vertical band with a gentle S-curve.
    half = 150 * ss
    cx = S / 2 * ss
    left, right = [], []
    for i in range(0, S * ss + 1, 6):
        wob = math.sin(i / (S * ss) * math.pi * 2.1) * 60 * ss
        left.append((cx - half + wob, i))
        right.append((cx + half + wob, i))
    d.polygon(left + right[::-1], fill=CREAM)

    # Two upward chevrons (lock gates) with gold beam-ends.
    lw = 30 * ss
    def chevron(apex_y):
        ax = cx
        span, drop = 200 * ss, 78 * ss
        lend = (ax - span, apex_y + drop)
        rend = (ax + span, apex_y + drop)
        apex = (ax, apex_y)
        d.line([lend, apex, rend], fill=DARK, width=lw, joint="curve")
        r = 30 * ss
        for (ex, ey) in (lend, rend):
            d.ellipse([ex - r, ey - r, ex + r, ey + r], fill=GOLD)
            d.ellipse([ex - r, ey - r, ex + r, ey + r], outline=DARK, width=6 * ss)
    chevron(int(S * 0.40 * ss))
    chevron(int(S * 0.62 * ss))

    big = big.resize((S, S), Image.LANCZOS)
    img.alpha_composite(big)
    return img


if __name__ == "__main__":
    import os
    os.makedirs("assets/icon", exist_ok=True)
    draw_design(bg_transparent=False).save("assets/icon/icon_generated.png")
    print("wrote assets/icon/icon_generated.png (reference only; NOT shipped)")
