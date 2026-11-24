#!/usr/bin/env python3
"""Generates the placeholder art of examples/rooms (PC only, needs Pillow).

Every PNG written here is a stand-in meant to be replaced by hand-drawn art with the same
file name and size. The console cannot make images in code (no ImageData), so placeholders
are real PNG files committed to the repo. Re-running the script overwrites them: once a file
has been replaced by real art, list it in KEEP so the script leaves it alone.

Usage: python tools/art/gen_placeholders.py [--out examples/rooms/art]
"""
import argparse
import math
import os
import random

from PIL import Image, ImageDraw

# The master palette: 32 colours for the whole game. Index order is stable (palette.lua uses it).
PALETTE = [
    "0b0d14", "1a1c2c", "2b2e42", "45475e", "6d6f85", "a3a5b5", "e4e6ee",  # 0-6 neutrals
    "0c2019", "173a3f", "2f6e66", "2f7d3a", "59b04a", "9ad65a",            # 7-12 greens/teal
    "2a1a17", "45281f", "6b3d2a", "a0673f", "d9a066",                      # 13-17 browns
    "b88a3a", "e8c25a", "fae684", "e8622c",                                # 18-21 Blob yellows, orange
    "16324a", "2a5c8a", "4f9dc7", "9fe0f0",                                # 22-25 blues
    "3b1e4f", "7a3b8f", "c46fd0",                                          # 26-28 purples
    "6e1f3c", "b8365a", "f07a8a",                                          # 29-31 reds/pinks
]
RGB = [tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) for h in PALETTE]

# Per biome: sky (4, top to bottom), far, mid, top (light, mid, dark), body (light, mid, dark),
# glow, and the silhouette style of its background layers.
BIOMES = {
    "forest":      dict(sky=[1, 22, 8, 9], far=8, mid=7, top=[12, 11, 10], body=[15, 14, 13], glow=12, bg="trees"),
    "deep_jungle": dict(sky=[0, 7, 8, 10], far=7, mid=0, top=[11, 10, 7], body=[14, 13, 0], glow=20, bg="trees"),
    "grotto":      dict(sky=[0, 1, 22, 23], far=22, mid=1, top=[25, 24, 23], body=[3, 2, 1], glow=25, bg="cave"),
    "fungal_cave": dict(sky=[0, 1, 26, 27], far=26, mid=0, top=[28, 27, 26], body=[3, 2, 1], glow=28, bg="cave"),
    "catacombs":   dict(sky=[0, 1, 2, 3], far=2, mid=1, top=[6, 5, 4], body=[16, 15, 14], glow=19, bg="columns"),
    "labs":        dict(sky=[1, 2, 3, 4], far=3, mid=2, top=[25, 5, 4], body=[4, 3, 2], glow=11, bg="columns"),
    "catastrophe": dict(sky=[0, 29, 30, 21], far=29, mid=13, top=[21, 30, 29], body=[15, 14, 13], glow=21, bg="ruins"),
}

KEEP = set()  # relative paths already replaced by hand-drawn art

W, H, T = 320, 180, 16
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def c(i):
    return RGB[i]


def save(img, out, rel):
    if rel in KEEP:
        print("keep", rel)
        return
    path = os.path.join(out, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", rel)


def sky(b):
    img = Image.new("RGB", (W, H))
    px = img.load()
    bands = [c(i) for i in b["sky"]]
    for y in range(H):
        t = y / (H * 0.85) * (len(bands) - 1)
        i = min(int(t), len(bands) - 2)
        f = t - i
        for x in range(W):
            px[x, y] = bands[i + 1] if f * 16 > BAYER[y % 4][x % 4] + 0.5 else bands[i]
    return img


def layer(style, color, base, amp, seed):
    """A 320x180 transparent silhouette that tiles horizontally (drawn wrapped around x)."""
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = random.Random(seed)
    col = color + (255,)

    def shape(x0):
        if style == "trees":
            w = r.randint(22, 44)
            top = base - r.randint(amp // 2, amp)
            for dx in (0, W, -W):
                d.ellipse([x0 + dx, top, x0 + dx + w, top + w], fill=col)
                d.rectangle([x0 + dx + w // 2 - 1, top + w // 2, x0 + dx + w // 2 + 1, H], fill=col)
            return w - r.randint(4, 10)
        if style == "cave":
            w = r.randint(14, 30)
            h = r.randint(amp // 3, amp)
            for dx in (0, W, -W):
                d.polygon([(x0 + dx, 0), (x0 + dx + w, 0), (x0 + dx + w // 2, h // 2 + 10)], fill=col)
                d.ellipse([x0 + dx, base - h // 2, x0 + dx + w * 2, base + h], fill=col)
            return w
        if style == "columns":
            w = r.randint(10, 18)
            gap = r.randint(30, 60)
            top = base - r.randint(amp // 2, amp)
            for dx in (0, W, -W):
                d.rectangle([x0 + dx, top, x0 + dx + w, H], fill=col)
                d.rectangle([x0 + dx - 3, top, x0 + dx + w + 3, top + 4], fill=col)
            return w + gap
        # ruins: jagged broken blocks
        w = r.randint(16, 40)
        top = base - r.randint(amp // 3, amp)
        for dx in (0, W, -W):
            d.polygon([(x0 + dx, H), (x0 + dx, top + r.randint(0, 12)), (x0 + dx + w // 3, top),
                       (x0 + dx + w // 2, top + r.randint(6, 18)), (x0 + dx + w, top + r.randint(0, 10)),
                       (x0 + dx + w, H)], fill=col)
        return w - 4

    x = 0
    while x < W:
        x += max(6, shape(x))
    d.rectangle([0, base, W, H], fill=col)
    return img


def tiles(b):
    """16 autotile variants in a 4x4 sheet (64x64). Variant index = mask of open sides:
    1 up, 2 right, 4 down, 8 left (a side is open when the neighbour is not solid).
    Variant i sits at column i % 4, row i // 4."""
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    px = img.load()
    top, body = [c(i) for i in b["top"]], [c(i) for i in b["body"]]
    for mask in range(16):
        ox, oy = (mask % 4) * T, (mask // 4) * T
        up, right, down, left = mask & 1, mask & 2, mask & 4, mask & 8
        r = random.Random(mask * 7 + 3)
        for y in range(T):
            for x in range(T):
                if up and left and x + y < 3: continue
                if up and right and (T - 1 - x) + y < 3: continue
                if down and left and x + (T - 1 - y) < 3: continue
                if down and right and (T - 1 - x) + (T - 1 - y) < 3: continue
                col = body[1] if (x + y) % 7 else body[0]
                if r.random() < 0.05: col = body[0]
                if (left and x == 0) or (right and x == T - 1) or (down and y >= T - 2):
                    col = body[2]
                px[ox + x, oy + y] = col + (255,)
        if up:
            for x in range(T):
                gh = 3 + r.randint(0, 2)
                for y in range(gh):
                    if left and x + y < 3: continue
                    if right and (T - 1 - x) + y < 3: continue
                    col = top[0] if y == 0 else (top[1] if y < gh - 1 else top[2])
                    px[ox + x, oy + y] = col + (255,)
    return img


def glow():
    """White soft light in 4 bands; drawn with setBlendMode("add") and tinted with setColor."""
    s = 32
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    px = img.load()
    for y in range(s):
        for x in range(s):
            k = 1 - math.hypot(x - s / 2 + 0.5, y - s / 2 + 0.5) / (s / 2)
            if k <= 0: continue
            a = 200 if k > 0.8 else 120 if k > 0.55 else 60 if k > 0.3 else 25
            px[x, y] = (255, 255, 255, a)
    return img


MUSH = ["..KKKK..", ".KAABBK.", "KAABCBBK", "KBBBBBBK", ".KKKKKK.", "..KSSK..", "..KSSK..", ".KSSSSK."]


def mob_strip():
    """Walk cycle, 4 frames of 16x16 (a mushroom drawn at 2x, bobbing)."""
    img = Image.new("RGBA", (64, 16), (0, 0, 0, 0))
    px = img.load()
    cmap = {"K": c(1), "A": c(31), "B": c(30), "C": c(6), "S": c(17)}
    for f, bob in enumerate((0, 1, 0, -1)):
        for j, row in enumerate(MUSH):
            for i, ch in enumerate(row):
                if ch not in cmap: continue
                for dy in (0, 1):
                    yy = j * 2 + dy - bob
                    if 0 <= yy < 16 and not (ch == "S" and j == 7 and dy == 1 and bob < 0):
                        px[f * 16 + i * 2, yy] = cmap[ch] + (255,)
                        px[f * 16 + i * 2 + 1, yy] = cmap[ch] + (255,)
        px[f * 16 + 6, 12 - bob] = c(0) + (255,)
        px[f * 16 + 9, 12 - bob] = c(0) + (255,)
    return img


def palette_files(out):
    img = Image.new("RGB", (len(RGB), 1))
    for i, col in enumerate(RGB):
        img.putpixel((i, 0), col)
    save(img, out, "palette.png")
    path = os.path.join(out, "palette.hex")
    with open(path, "w") as f:
        f.write("\n".join(PALETTE) + "\n")
    print("wrote palette.hex")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join("examples", "rooms", "art"))
    out = ap.parse_args().out
    palette_files(out)
    save(glow(), out, "fx/glow.png")
    save(mob_strip(), out, "enemies/mob_walk.png")
    for i, (bid, b) in enumerate(BIOMES.items()):
        save(sky(b), out, bid + "/sky.png")
        far = 120 if b["bg"] != "cave" else 150
        save(layer(b["bg"], c(b["far"]), far, 60, i * 10 + 1), out, bid + "/bg_far.png")
        save(layer(b["bg"], c(b["mid"]), far + 25, 50, i * 10 + 2), out, bid + "/bg_mid.png")
        save(tiles(b), out, bid + "/tiles.png")


if __name__ == "__main__":
    main()
