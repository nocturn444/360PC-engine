"""tools/audio_convert.py and the audio step of tools/package.py: .ogg into the console's WAV files.

The splitter and the packaging rules run everywhere (WAV bytes made here). The real conversions
need ffmpeg with a Vorbis encoder and are skipped without it.
"""
import io
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import audio_convert as ac  # noqa: E402
import package  # noqa: E402

FFMPEG = shutil.which("ffmpeg")


def adpcm_wav(blocks, block_align=256, rate=22050):
    """a mono IMA ADPCM WAV whose blocks are filled with their own index (not real audio)"""
    spb = 1 + 2 * (block_align - 4)
    fmt = struct.pack("<HHIIHHHH", ac.FORMAT_IMA_ADPCM, 1, rate, rate * block_align // spb, block_align, 4, 2, spb)
    body = b"".join(bytes([i % 256]) * block_align for i in range(blocks))
    return ac.wav_bytes(fmt, blocks * spb - 7, body)


def make_ogg(path, seconds, freq=440):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                    "sine=frequency=%d:duration=%s:sample_rate=44100" % (freq, seconds), "-ac", "2",
                    "-c:a", "libvorbis", str(path)], check=True)
    return path


def has_vorbis():
    if not FFMPEG:
        return False
    r = subprocess.run([FFMPEG, "-hide_banner", "-encoders"], capture_output=True, text=True)
    return "libvorbis" in r.stdout and "adpcm_ima_wav" in r.stdout


class SplitCase(unittest.TestCase):
    def test_chunks_keep_every_block(self):
        data = adpcm_wav(200)
        info = ac.wav_info(data)
        spb = 1 + 2 * (256 - 4)
        out = ac.split_adpcm(data, "song", secs=spb * 50 / 22050)   # 50 blocks a chunk
        names = [n for n, _ in out]
        self.assertEqual(names, ["song.p000.wav", "song.p001.wav", "song.p002.wav", "song.p003.wav", "song.idx"])
        bodies = [ac.wav_info(b) for n, b in out if n.endswith(".wav")]
        self.assertEqual(b"".join(b["body"] for b in bodies), info["body"], "the chunks in a row are the track")
        self.assertEqual(sum(b["frames"] for b in bodies), info["frames"], "frames add up (the fact chunk)")
        idx = dict(line.split("=") for line in out[-1][1].decode().split())
        self.assertEqual(idx, {"rate": "22050", "channels": "1", "block_align": "256", "frames": str(info["frames"]),
                               "parts": "4", "blocks_per_part": "50"})

    def test_short_track_is_one_chunk(self):
        out = ac.split_adpcm(adpcm_wav(3), "jingle")
        self.assertEqual([n for n, _ in out], ["jingle.p000.wav", "jingle.idx"])

    def test_refuses_pcm(self):
        fmt = struct.pack("<HHIIHH", ac.FORMAT_PCM, 1, 22050, 44100, 2, 16)
        with self.assertRaises(ac.AudioError):
            ac.split_adpcm(ac.wav_bytes(fmt, 4, b"\0" * 8), "x")

    def test_music_patterns(self):
        pats = ac.DEFAULTS["music"]
        self.assertTrue(ac.is_music("music/cave.ogg", pats))
        self.assertTrue(ac.is_music("assets/Music/boss.ogg", pats))
        self.assertFalse(ac.is_music("sfx/music_box.ogg", pats))
        self.assertTrue(ac.is_music("sfx/music_box.ogg", ["*music_box*"]))

    def test_settings(self):
        s = ac.settings_from({"rate": 32000, "music": ["bgm/*"]})
        self.assertEqual((s["rate"], s["music"], s["chunk_seconds"]), (32000, ["bgm/*"], 10.0))
        self.assertEqual(ac.DEFAULTS["music"], ["music/*", "*/music/*"], "defaults untouched")


@unittest.skipUnless(has_vorbis(), "needs ffmpeg with libvorbis")
class ConvertCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.s = ac.settings_from()

    def test_short_effect_is_pcm_mono(self):
        out = ac.convert(make_ogg(self.tmp / "jump.ogg", 0.5), False, self.s, FFMPEG)
        self.assertEqual([n for n, _ in out], ["jump.wav"])
        info = ac.wav_info(out[0][1])
        self.assertEqual((info["tag"], info["channels"], info["rate"], info["bits"]), (ac.FORMAT_PCM, 1, 22050, 16))
        self.assertAlmostEqual(info["frames"] / 22050, 0.5, delta=0.05)

    def test_long_effect_is_adpcm(self):
        out = ac.convert(make_ogg(self.tmp / "roar.ogg", 3), False, self.s, FFMPEG)
        info = ac.wav_info(out[0][1])
        self.assertEqual((info["tag"], info["channels"]), (ac.FORMAT_IMA_ADPCM, 1))
        self.assertLess(len(out[0][1]), 3 * 22050 * 2 / 3, "about a quarter of 16-bit PCM")

    def test_music_in_chunks(self):
        out = ac.convert(make_ogg(self.tmp / "cave.ogg", 25), True, self.s, FFMPEG)
        names = [n for n, _ in out]
        self.assertEqual(names, ["cave.p000.wav", "cave.p001.wav", "cave.p002.wav", "cave.idx"])
        idx = dict(line.split("=") for line in out[-1][1].decode().split())
        self.assertEqual((idx["parts"], idx["channels"], idx["rate"]), ("3", "1", "22050"))
        self.assertAlmostEqual(int(idx["frames"]) / 22050, 25, delta=0.1)

    def test_cache(self):
        src = make_ogg(self.tmp / "hit.ogg", 0.3)
        cache = self.tmp / "cache"
        first = ac.convert_cached(src, False, self.s, FFMPEG, cache)
        with mock.patch.object(ac, "convert", side_effect=AssertionError("converted again")):
            again = ac.convert_cached(src, False, self.s, FFMPEG, cache)
        self.assertEqual(first, again, "the same bytes and settings come from the cache")
        other = ac.convert_cached(src, False, dict(self.s, rate=16000), FFMPEG, cache)
        self.assertNotEqual(first[0][1], other[0][1], "other settings, another entry")
        self.assertEqual(ac.wav_info(other[0][1].read_bytes())["rate"], 16000)


class PackageAudioCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        g = self.game = self.tmp / "game"
        (g / "sfx").mkdir(parents=True)
        (g / "music").mkdir()
        (g / "game.lua").write_text('return { name = "Audio Test", title_id = "0x4D47AA02" }\n')
        (g / "main.lua").write_text("-- main\n")
        (g / "conf.lua").write_text("-- conf\n")
        (g / "sfx" / "jump.ogg").write_bytes(b"OggS jump")
        (g / "sfx" / "coin.ogg").write_bytes(b"OggS coin")
        (g / "sfx" / "coin.wav").write_bytes(b"RIFF own")
        (g / "music" / "cave.ogg").write_bytes(b"OggS cave")
        self.cfg = package.read_config(g, log=lambda *_: None)
        self.calls = []

        def fake_convert(src, music, settings, ffmpeg, cache_dir):
            self.calls.append((Path(src).name, music, settings["rate"]))
            stem = Path(src).stem
            if music:
                return [(stem + ".p000.wav", src), (stem + ".idx", src)]
            return [(stem + ".wav", src)]
        self.fake = fake_convert

    def plan(self, **kw):
        logs = []
        with mock.patch.object(ac, "convert_cached", self.fake):
            plan, warnings = package.make_plan(self.game, self.cfg, None, None, log=logs.append,
                                               audio_cache=self.tmp / "cache", **kw)
        return [rel for rel, _ in plan], warnings, logs

    def test_ogg_replaced(self):
        rels, warnings, logs = self.plan()
        self.assertIn("sfx/jump.wav", rels)
        self.assertIn("music/cave.p000.wav", rels)
        self.assertIn("music/cave.idx", rels)
        self.assertFalse([r for r in rels if r.endswith(".ogg")], "no .ogg ships to the console")
        self.assertIn(("cave.ogg", True, 22050), self.calls)
        self.assertIn(("jump.ogg", False, 22050), self.calls)
        self.assertTrue(any("own sfx/coin.wav" in w for w in warnings), "the game's own .wav wins")
        self.assertEqual(rels.count("sfx/coin.wav"), 1)
        self.assertTrue(any("2 .ogg converted" in line for line in logs))

    @unittest.skipUnless(shutil.which("luajit"), "game.lua's audio table is read with LuaJIT")
    def test_game_lua_settings(self):
        (self.game / "game.lua").write_text('return { name = "Audio Test", title_id = "0x4D47AA02",\n'
                                            '  audio = { rate = 32000, music = { "sfx/jump*" }, chunk_seconds = 5 } }\n')
        self.cfg = package.read_config(self.game, log=lambda *_: None)
        self.assertEqual(self.cfg["audio"], {"rate": 32000, "music": ["sfx/jump*"], "chunk_seconds": 5.0})
        self.plan()
        self.assertIn(("jump.ogg", True, 32000), self.calls)
        self.assertIn(("cave.ogg", False, 32000), self.calls, "the game's patterns replace the defaults")

    @unittest.skipUnless(shutil.which("luajit"), "game.lua is checked with LuaJIT")
    def test_bad_audio_settings(self):
        for bad in ('audio = { rate = 100 }', 'audio = { volume = 1 }', 'audio = { music = "music/*" }'):
            (self.game / "game.lua").write_text('return { name = "A", title_id = "0x4D47AA02", %s }\n' % bad)
            with self.assertRaises(package.PackageError, msg=bad):
                package.read_config(self.game, log=lambda *_: None)

    def test_no_convert(self):
        rels, warnings, _ = self.plan(audio=False)
        self.assertIn("sfx/jump.ogg", rels)
        self.assertFalse(self.calls)
        self.assertTrue(any("--no-audio-convert" in w for w in warnings))

    def test_missing_ffmpeg(self):
        with mock.patch.object(ac, "find_ffmpeg", return_value=None):
            with self.assertRaises(package.PackageError) as e:
                package.make_plan(self.game, self.cfg, None, None, log=lambda *_: None,
                                  audio_cache=self.tmp / "cache")
        self.assertIn("ffmpeg", str(e.exception))

    def test_cli_flag(self):
        err = io.StringIO()
        with redirect_stderr(err):
            code = package.main([str(self.game), "--no-xex", "--no-shaders", "--dry-run", "--no-audio-convert"],
                                log=lambda *_: None)
        self.assertEqual(code, 0, err.getvalue())


if __name__ == "__main__":
    unittest.main()
