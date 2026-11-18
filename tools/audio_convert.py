#!/usr/bin/env python3
"""Converts a game's .ogg files into the WAV files the console plays (used by tools/package.py).

The console runtime plays WAV only: 16-bit PCM, or mono IMA ADPCM (4 times smaller). A game keeps
asking for "x.ogg"; on the console the runtime loads "x.wav" next to it, and a "stream" Source
whose "x.idx" exists is streamed in chunks ("x.p000.wav", "x.p001.wav", ...) while the game runs,
so a whole track is never in memory (runtime/lua/boot.lua, "music in chunks").

What each .ogg becomes (settings from game.lua's `audio` table, docs/GAME_CONFIG.md):

    music (path matches `music`, default "music/*" and "*/music/*")
        mono IMA ADPCM, split into chunks of `chunk_seconds` (10) plus x.idx
    effects longer than `long_seconds` (2)
        one mono IMA ADPCM x.wav
    shorter effects
        one mono 16-bit PCM x.wav (cheap to decode; short, so small anyway)

All at `rate` Hz (22050). Results are cached by the source's bytes and the settings, so
packaging again only converts what changed. Needs ffmpeg (on the PATH, or --ffmpeg).

The chunk splitter comes from Love360 (herramientas/pc/partir_musica.py, same author, MIT): each
IMA ADPCM block starts with its own predictor and step index, so splitting between blocks does
not change a sample: the chunks played in a row decode exactly like the whole track.

    python tools/audio_convert.py <file.ogg> <out folder> [--music] [--rate 22050]

Python 3.8 or later, standard library only; runs on Windows and Linux.
"""
import argparse
import fnmatch
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULTS = {"rate": 22050, "long_seconds": 2.0, "chunk_seconds": 10.0, "music": ["music/*", "*/music/*"]}
FORMAT_PCM = 1
FORMAT_IMA_ADPCM = 0x11
CACHE_VERSION = "1"


class AudioError(Exception):
    """A conversion that failed; the message is for the user."""


def find_ffmpeg(ffmpeg=None):
    return ffmpeg or shutil.which("ffmpeg")


def is_music(rel, patterns):
    rel = rel.replace("\\", "/").lower()
    return any(fnmatch.fnmatchcase(rel, p.lower()) for p in patterns)


# ---------------------------------------------------------------------------------------------
# WAV files
# ---------------------------------------------------------------------------------------------

def chunks(data):
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise AudioError("not a WAV file")
    pos = 12
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        yield cid, data[pos + 8:pos + 8 + size]
        pos += 8 + size + (size & 1)


def wav_info(data):
    """format tag, channels, rate, block_align, frames and the data bytes of a WAV"""
    fmt = fact = body = None
    for cid, c in chunks(data):
        if cid == b"fmt ":
            fmt = c
        elif cid == b"fact" and len(c) >= 4:
            fact = struct.unpack("<I", c[:4])[0]
        elif cid == b"data":
            body = c
    if fmt is None or body is None or len(fmt) < 16:
        raise AudioError("WAV without fmt or data chunk")
    tag, channels, rate = struct.unpack("<HHI", fmt[:8])
    block_align, bits = struct.unpack("<HH", fmt[12:16])
    if tag == FORMAT_PCM:
        frames = len(body) // block_align
    elif tag == FORMAT_IMA_ADPCM:
        spb = 1 + 2 * (block_align // channels - 4)
        frames = ((len(body) + block_align - 1) // block_align) * spb
        if fact and fact < frames:
            frames = fact
    else:
        raise AudioError("WAV format 0x%X: expected PCM or IMA ADPCM" % tag)
    return {"tag": tag, "channels": channels, "rate": rate, "block_align": block_align, "bits": bits,
            "frames": frames, "fmt": fmt, "body": body}


def wav_bytes(fmt, frames, body):
    out = b"fmt " + struct.pack("<I", len(fmt)) + fmt
    if len(fmt) & 1:
        out += b"\0"
    out += b"fact" + struct.pack("<II", 4, frames)
    out += b"data" + struct.pack("<I", len(body)) + body
    return b"RIFF" + struct.pack("<I", 4 + len(out)) + b"WAVE" + out


def split_adpcm(data, base, secs=10.0):
    """[(file name, bytes)]: the chunks base.pNNN.wav and base.idx of a mono IMA ADPCM WAV"""
    info = wav_info(data)
    if info["tag"] != FORMAT_IMA_ADPCM or info["channels"] != 1:
        raise AudioError("expected mono IMA ADPCM to split")
    rate, block_align, body = info["rate"], info["block_align"], info["body"]
    spb = 1 + 2 * (block_align - 4)
    frames = info["frames"]
    blocks = (frames + spb - 1) // spb
    per = max(1, round(secs * rate / spb))
    parts = max(1, (blocks + per - 1) // per)
    out = []
    for i in range(parts):
        b0, b1 = i * per, min(blocks, (i + 1) * per)
        nframes = min(frames, b1 * spb) - b0 * spb
        out.append(("%s.p%03d.wav" % (base, i), wav_bytes(info["fmt"], nframes, body[b0 * block_align:b1 * block_align])))
    idx = ("rate=%d\nchannels=1\nblock_align=%d\nframes=%d\nparts=%d\nblocks_per_part=%d\n"
           % (rate, block_align, frames, parts, per))
    out.append(("%s.idx" % base, idx.encode("ascii")))
    return out


# ---------------------------------------------------------------------------------------------
# Conversion
# ---------------------------------------------------------------------------------------------

def run_ffmpeg(ffmpeg, src, dest, codec, rate):
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(src), "-vn", "-map_metadata", "-1",
           "-acodec", codec, "-ar", str(rate), "-ac", "1", str(dest)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        raise AudioError("could not run ffmpeg: %s" % e)
    if r.returncode != 0 or not Path(dest).is_file():
        raise AudioError("ffmpeg failed on %s: %s" % (Path(src).name, (r.stderr or r.stdout).strip()[:300]))
    return Path(dest).read_bytes()


def convert(src, music, settings, ffmpeg):
    """[(file name, bytes)] for one .ogg: names are relative to the .ogg's folder"""
    base = Path(src).stem
    rate = settings["rate"]
    with tempfile.TemporaryDirectory(prefix="360pc_audio_") as tmp:
        if music:
            data = run_ffmpeg(ffmpeg, src, Path(tmp) / "a.wav", "adpcm_ima_wav", rate)
            return split_adpcm(data, base, settings["chunk_seconds"])
        data = run_ffmpeg(ffmpeg, src, Path(tmp) / "p.wav", "pcm_s16le", rate)
        info = wav_info(data)
        if info["frames"] > settings["long_seconds"] * info["rate"]:
            data = run_ffmpeg(ffmpeg, src, Path(tmp) / "a.wav", "adpcm_ima_wav", rate)
        return [(base + ".wav", data)]


def cache_key(src_bytes, music, settings):
    h = hashlib.sha1()
    h.update(("%s|%s|%d|%r|%r|" % (CACHE_VERSION, music, settings["rate"], settings["long_seconds"],
                                   settings["chunk_seconds"])).encode("ascii"))
    h.update(src_bytes)
    return h.hexdigest()


def convert_cached(src, music, settings, ffmpeg, cache_dir):
    """like convert, but the results are files in cache_dir/<key>/: returns [(file name, path)]"""
    key = cache_key(Path(src).read_bytes(), music, settings)
    folder = Path(cache_dir) / key
    done = folder / "done.txt"
    if done.is_file():
        names = [n for n in done.read_text(encoding="utf-8").splitlines() if n]
        if all((folder / n).is_file() for n in names):
            return [(n, folder / n) for n in names]
    if not find_ffmpeg(ffmpeg):
        raise AudioError("ffmpeg is needed to convert %s for the console: put it on the PATH, give --ffmpeg, "
                         "or package with --no-audio-convert" % Path(src).name)
    outputs = convert(src, music, settings, find_ffmpeg(ffmpeg))
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    for name, data in outputs:
        (folder / name).write_bytes(data)
    done.write_text("\n".join(n for n, _ in outputs) + "\n", encoding="utf-8")
    return [(n, folder / n) for n, _ in outputs]


def settings_from(cfg_audio=None):
    s = {k: (list(v) if isinstance(v, list) else v) for k, v in DEFAULTS.items()}
    for k, v in (cfg_audio or {}).items():
        if k in s and v is not None:
            s[k] = v
    return s


def main(argv=None):
    ap = argparse.ArgumentParser(description="Convert an .ogg into the WAV files the console plays.")
    ap.add_argument("src", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--music", action="store_true", help="split into streamed chunks (x.p000.wav... and x.idx)")
    ap.add_argument("--rate", type=int, default=DEFAULTS["rate"])
    ap.add_argument("--long-seconds", type=float, default=DEFAULTS["long_seconds"])
    ap.add_argument("--chunk-seconds", type=float, default=DEFAULTS["chunk_seconds"])
    ap.add_argument("--ffmpeg")
    args = ap.parse_args(argv)
    ffmpeg = find_ffmpeg(args.ffmpeg)
    if not ffmpeg:
        print("audio_convert: ffmpeg not found", file=sys.stderr)
        return 1
    settings = {"rate": args.rate, "long_seconds": args.long_seconds, "chunk_seconds": args.chunk_seconds}
    try:
        outputs = convert(args.src, args.music, settings, ffmpeg)
    except AudioError as e:
        print("audio_convert: %s" % e, file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    for name, data in outputs:
        (args.out / name).write_bytes(data)
        print("%10d  %s" % (len(data), name))
    return 0


if __name__ == "__main__":
    sys.exit(main())
