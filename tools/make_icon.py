# Generează iconița Clocking (ceas + cod QR) și resursele Android.
# Utilizare (din folderul proiectului): python tools/make_icon.py
import math
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "icon")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
S = 2048  # supersampling, scaled down to 1024

TEAL_TOP = (20, 184, 166)
TEAL_BOTTOM = (15, 118, 110)
WHITE = (255, 255, 255)
INK = (19, 78, 74)
AMBER = (251, 191, 36)


def gradient(size):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        c = tuple(int(TEAL_TOP[i] * (1 - t) + TEAL_BOTTOM[i] * t) for i in range(3))
        d.line([(0, y), (size, y)], fill=c)
    return img


def qr_pattern():
    # Model QR stilizat 9x9 (doar decorativ): trei repere de colț + module.
    return [
        "111010111",
        "101001101",
        "111010111",
        "000101000",
        "101110010",
        "010011101",
        "111001010",
        "101010110",
        "111001011",
    ]


def draw_symbol(img, cx, cy, r):
    """Cadranul de ceas + insigna QR, centrate în (cx, cy), raza cadranului r."""
    d = ImageDraw.Draw(img)
    # Cadran
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=WHITE)
    ring = int(r * 0.09)
    d.ellipse([cx - r + ring, cy - r + ring, cx + r - ring, cy + r - ring], outline=INK, width=int(r * 0.05))
    # Gradații
    for i in range(12):
        a = math.radians(i * 30)
        r1 = r * (0.70 if i % 3 == 0 else 0.76)
        r2 = r * 0.84
        w = int(r * (0.07 if i % 3 == 0 else 0.035))
        d.line([(cx + r1 * math.sin(a), cy - r1 * math.cos(a)),
                (cx + r2 * math.sin(a), cy - r2 * math.cos(a))], fill=INK, width=w)
    # Limbi: 9:00 → ora la stânga, minutarul sus (ora de intrare)
    hw = int(r * 0.11)
    d.line([(cx, cy), (cx - r * 0.42, cy)], fill=INK, width=hw)
    d.line([(cx, cy), (cx, cy - r * 0.62)], fill=INK, width=int(hw * 0.75))
    d.ellipse([cx - hw, cy - hw, cx + hw, cy + hw], fill=AMBER)

    # Insigna QR jos-dreapta
    b = r * 0.95
    bx = cx + r * 0.42
    by = cy + r * 0.42
    pad = b * 0.12
    d.rounded_rectangle([bx, by, bx + b, by + b], radius=int(b * 0.18), fill=AMBER)
    inner = b - 2 * pad
    cell = inner / 9
    for row, line in enumerate(qr_pattern()):
        for col, ch in enumerate(line):
            if ch == "1":
                x0 = bx + pad + col * cell
                y0 = by + pad + row * cell
                d.rectangle([x0, y0, x0 + cell + 1, y0 + cell + 1], fill=INK)


def main():
    # Iconița completă (fundal rotunjit + simbol)
    bg = gradient(S)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S, S], radius=int(S * 0.22), fill=255)
    full = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    full.paste(bg, (0, 0), mask)
    draw_symbol(full, S * 0.44, S * 0.44, S * 0.30)
    full.resize((1024, 1024), Image.Resampling.LANCZOS).save(OUT + "/icon.png")

    # Prim-plan pentru iconița adaptivă (zona sigură: 66% din centru)
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw_symbol(fg, S * 0.46, S * 0.46, S * 0.20)
    fg_small = fg.resize((1024, 1024), Image.Resampling.LANCZOS)
    fg_small.save(OUT + "/icon_foreground.png")

    # Android: iconița clasică (mipmap) și cea adaptivă (Android 8+).
    full_small = Image.open(OUT + "/icon.png")
    for density, scale in [("mdpi", 1), ("hdpi", 1.5), ("xhdpi", 2), ("xxhdpi", 3), ("xxxhdpi", 4)]:
        d = os.path.join(RES, "mipmap-" + density)
        os.makedirs(d, exist_ok=True)
        full_small.resize((int(48 * scale), int(48 * scale)), Image.Resampling.LANCZOS).save(
            os.path.join(d, "ic_launcher.png"))
        d = os.path.join(RES, "drawable-" + density)
        os.makedirs(d, exist_ok=True)
        fg_small.resize((int(108 * scale), int(108 * scale)), Image.Resampling.LANCZOS).save(
            os.path.join(d, "ic_launcher_foreground.png"))
    d = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "ic_launcher.xml"), "w", encoding="utf-8") as f:
        f.write(ADAPTIVE_XML)
    with open(os.path.join(RES, "values", "colors.xml"), "w", encoding="utf-8") as f:
        f.write(COLORS_XML)


ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@drawable/ic_launcher_foreground"/>
</adaptive-icon>
"""

COLORS_XML = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#0F766E</color>
</resources>
"""


main()
