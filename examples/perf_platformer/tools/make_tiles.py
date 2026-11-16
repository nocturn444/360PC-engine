#!/usr/bin/env python3
"""Writes tiles.png, the only image of examples/perf_platformer: placeholder tiles, two frames
for the player and for the enemies, a particle, and a 3x5 pixel font (ASCII 32 to 95) that the
overlay draws with a SpriteBatch, so it shows on the console without a TTF.

    python3 examples/perf_platformer/tools/make_tiles.py

Layout (128x32, RGBA), which perf/atlas.lua mirrors:
    y = 0, 16x16 cells: solid, one-way, background, player a, player b, enemy a, enemy b,
                        then an 8x8 particle at x = 112 and an 8x8 white block at x = 120
    y = 16 and y = 22, 4x6 cells: the glyphs of ASCII 32..63 and 64..95

Python 3, standard library only. The output is the same on every run.
"""
import struct
import zlib
from pathlib import Path

W, H = 128, 32
pixels = [[(0, 0, 0, 0)] * W for _ in range(H)]


def put(x, y, c):
    pixels[y][x] = c


def rect(x, y, w, h, c):
    for j in range(y, y + h):
        for i in range(x, x + w):
            put(i, j, c)


def solid(x0):
    rect(x0, 0, 16, 16, (104, 78, 62, 255))
    rect(x0, 0, 16, 2, (150, 190, 96, 255))          # grass
    rect(x0, 2, 16, 1, (86, 120, 60, 255))
    for i, j in ((3, 6), (10, 5), (6, 10), (12, 12), (2, 13)):
        rect(x0 + i, j, 2, 1, (84, 62, 50, 255))      # pebbles


def one_way(x0):
    rect(x0, 0, 16, 4, (196, 160, 96, 255))
    rect(x0, 0, 16, 1, (232, 204, 140, 255))
    rect(x0, 4, 16, 1, (120, 92, 56, 255))
    rect(x0 + 7, 0, 1, 4, (150, 118, 70, 255))        # plank joint


def background(x0):
    rect(x0, 0, 16, 16, (34, 40, 62, 255))
    rect(x0, 15, 16, 1, (28, 33, 52, 255))
    rect(x0 + 15, 0, 1, 16, (28, 33, 52, 255))
    put(x0 + 4, 5, (52, 60, 90, 255))
    put(x0 + 11, 10, (52, 60, 90, 255))


def actor(x0, body, dark, frame):
    """a 10x12 body inside the 16x16 cell, at (3, 4), feet on the cell's bottom edge"""
    rect(x0 + 3, 4, 10, 10, body)
    rect(x0 + 3, 4, 10, 1, dark)
    rect(x0 + 9, 7, 2, 2, (255, 255, 255, 255))       # eye, on the side it faces (right)
    put(x0 + 10, 8, (0, 0, 0, 255))
    if frame == 0:                                    # legs: two frames of a walk
        rect(x0 + 4, 14, 2, 2, dark)
        rect(x0 + 10, 14, 2, 2, dark)
    else:
        rect(x0 + 6, 14, 2, 2, dark)
        rect(x0 + 8, 14, 2, 2, dark)


def particle(x0):
    alpha = [0, 60, 150, 255, 255, 150, 60, 0]
    for j in range(8):
        for i in range(8):
            a = min(alpha[i], alpha[j])
            if a:
                put(x0 + i, j, (255, 255, 255, a))


GLYPHS = {
    "0": ".#. #.# #.# #.# .#.", "1": ".#. ##. .#. .#. ###", "2": "### ..# ### #.. ###",
    "3": "### ..# ### ..# ###", "4": "#.# #.# ### ..# ..#", "5": "### #.. ### ..# ###",
    "6": "### #.. ### #.# ###", "7": "### ..# ..# ..# ..#", "8": "### #.# ### #.# ###",
    "9": "### #.# ### ..# ###",
    "A": "### #.# ### #.# #.#", "B": "##. #.# ##. #.# ##.", "C": "### #.. #.. #.. ###",
    "D": "##. #.# #.# #.# ##.", "E": "### #.. ### #.. ###", "F": "### #.. ### #.. #..",
    "G": "### #.. #.# #.# ###", "H": "#.# #.# ### #.# #.#", "I": "### .#. .#. .#. ###",
    "J": "..# ..# ..# #.# ###", "K": "#.# #.# ##. #.# #.#", "L": "#.. #.. #.. #.. ###",
    "M": "#.# ### ### #.# #.#", "N": "##. #.# #.# #.# #.#", "O": "### #.# #.# #.# ###",
    "P": "### #.# ### #.. #..", "Q": "### #.# #.# ### ..#", "R": "##. #.# ##. #.# #.#",
    "S": ".## #.. .#. ..# ##.", "T": "### .#. .#. .#. .#.", "U": "#.# #.# #.# #.# ###",
    "V": "#.# #.# #.# #.# .#.", "W": "#.# #.# ### ### #.#", "X": "#.# #.# .#. #.# #.#",
    "Y": "#.# #.# .#. .#. .#.", "Z": "### ..# .#. #.. ###",
    ".": "... ... ... ... .#.", ",": "... ... ... .#. #..", ":": "... .#. ... .#. ...",
    "-": "... ... ### ... ...", "+": "... .#. ### .#. ...", "/": "..# ..# .#. #.. #..",
    "%": "#.# ..# .#. #.. #.#", "(": ".#. #.. #.. #.. .#.", ")": ".#. ..# ..# ..# .#.",
    "=": "... ### ... ### ...", "*": "... #.# .#. #.# ...", "#": "#.# ### #.# ### #.#",
    "!": ".#. .#. .#. ... .#.", "?": "### ..# .#. ... .#.", "_": "... ... ... ... ###",
    "<": "..# .#. #.. .#. ..#", ">": "#.. .#. ..# .#. #..",
}


def glyphs():
    for ch, rows in GLYPHS.items():
        code = ord(ch)
        assert 32 <= code <= 95, ch
        x0 = ((code - 32) % 32) * 4
        y0 = 16 + ((code - 32) // 32) * 6
        for j, row in enumerate(rows.split()):
            assert len(row) == 3, ch
            for i, bit in enumerate(row):
                if bit == "#":
                    put(x0 + i, y0 + j, (255, 255, 255, 255))


def png(path):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(v for px in row for v in px) for row in pixels)
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    Path(path).write_bytes(data)
    return len(data)


def main():
    solid(0)
    one_way(16)
    background(32)
    actor(48, (90, 170, 255, 255), (40, 90, 170, 255), 0)
    actor(64, (90, 170, 255, 255), (40, 90, 170, 255), 1)
    actor(80, (230, 90, 80, 255), (140, 40, 40, 255), 0)
    actor(96, (230, 90, 80, 255), (140, 40, 40, 255), 1)
    particle(112)
    rect(120, 0, 8, 8, (255, 255, 255, 255))
    glyphs()
    out = Path(__file__).resolve().parent.parent / "tiles.png"
    print("wrote %s (%dx%d, %d bytes)" % (out, W, H, png(out)))


if __name__ == "__main__":
    main()
