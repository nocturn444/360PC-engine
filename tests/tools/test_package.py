"""tools/package.py: the console folder assembled from a game folder, a .xex and built shaders."""
import io
import shutil
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import package  # noqa: E402

GAME_LUA = '''-- a game
return {
  name = "Pack Test",          -- shown by Aurora
  title_id = "0x4d47aa01",
  save_dir = "saves",
  --[[ title_id = "0x00000001", ]]
  aurora = { icon = "aurora/icon.png" },
  shaders = { tint = "shaders/tint.glsl", glow = { pixel = "fx/glow.frag" } },
}
'''
MAIN_LUA = '''local engine = require("engine")
local platformer = require("engine.modules.platformer")
engine.run({})
'''


def write(path, text="x"):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(text, bytes):
        path.write_bytes(text)
    else:
        path.write_text(text, encoding="utf-8")
    return path


class PackageCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        g = self.game = self.tmp / "game"
        write(g / "game.lua", GAME_LUA)
        write(g / "main.lua", MAIN_LUA)
        write(g / "conf.lua", "function love.conf(t) end\n")
        write(g / "states" / "play.lua", "return {}\n")
        write(g / "assets" / "hero.png", b"\x89PNG")
        write(g / "shaders" / "tint.glsl", "vec4 effect() {}")
        write(g / "fx" / "glow.frag", "vec4 effect() {}")
        # development files and the console's own
        write(g / "README.md"); write(g / ".gitignore"); write(g / ".git" / "config")
        write(g / "assets" / "hero.aseprite"); write(g / "notes" / "todo.md")
        write(g / "levels" / "world.ldtk"); write(g / "levels" / "world" / "Start.ldtkl")
        write(g / "levels" / "world.lvl")
        write(g / "saves" / "run.sav"); write(g / "default.log"); write(g / "default.xex", b"old")
        write(g / "dist" / "old" / "main.lua"); write(g / "tests" / "t.lua"); write(g / "build.bat")
        # the base as a submodule
        write(g / "base" / "runtime" / "lua" / "boot.lua"); write(g / "base" / "engine" / "init.lua")
        self.xex = write(self.tmp / "game.xex", b"XEX2" + b"\0" * 60)
        self.shaders = self.tmp / "built"
        for n in package.BUILTIN_SHADERS + ["tint.psu", "tint.meta.lua", "glow.psu", "glow.meta.lua"]:
            write(self.shaders / n, n)
        write(self.shaders / "tint.hlsl")
        self.out = self.tmp / "out" / "pack_test"
        self.lines = []

    def run_main(self, *args):
        err = io.StringIO()
        with redirect_stderr(err):
            code = package.main([str(self.game), *args], log=self.lines.append)
        return code, err.getvalue()

    def full(self, *extra):
        return self.run_main("--xex", str(self.xex), "--shaders", str(self.shaders), "--out", str(self.out), *extra)

    def packaged(self):
        return sorted(p.relative_to(self.out).as_posix() for p in self.out.rglob("*") if p.is_file())


class TestConfig(PackageCase):
    def test_luajit_and_parser_agree(self):
        fields, shaders = package.parse_game_lua(GAME_LUA)
        cfg = package.validate_config(fields)
        self.assertEqual(cfg, {"name": "Pack Test", "title_id": "0x4D47AA01", "identity": "pack_test",
                               "save_dir": "saves"})
        self.assertEqual(sorted(shaders), ["glow", "tint"])
        if package.find_lua():
            full = package.read_config(self.game, log=self.lines.append)
            for k, v in cfg.items():
                self.assertEqual(full[k], v)
            self.assertEqual(full["shaders"], ["glow", "tint"])
            self.assertFalse(full["debug"])

    def test_parser_only(self):
        orig = package.find_lua
        package.find_lua = lambda lua=None: None
        try:
            cfg = package.read_config(self.game, log=self.lines.append)
        finally:
            package.find_lua = orig
        self.assertEqual((cfg["title_id"], cfg["identity"], cfg["shaders"]), ("0x4D47AA01", "pack_test", ["glow", "tint"]))
        self.assertTrue(any("built-in parser" in l for l in self.lines))

    def test_parser_details(self):
        fields, shaders = package.parse_game_lua(
            "return { name = 'A -- b', debug = true, -- c\n aurora = { name = \"no\" }, shaders = {} }")
        self.assertEqual(fields, {"name": "A -- b", "debug": True})
        self.assertEqual(shaders, {})

    def test_invalid(self):
        for bad in ({}, {"name": "x"}, {"name": "x", "title_id": "0x12"}, {"name": 'a"b', "title_id": "0x4D470001"},
                    {"name": "x", "title_id": "00000000"}, {"name": "x", "title_id": "0x4D470001", "save_dir": "l360"},
                    {"name": "x", "title_id": "0x4D470001", "identity": "a b"}):
            with self.assertRaises(package.PackageError):
                package.validate_config(bad)

    def test_missing_title_id_stops(self):
        write(self.game / "game.lua", 'return { name = "x" }\n')
        code, err = self.full()
        self.assertEqual(code, 1)
        self.assertIn("title_id", err)
        self.assertFalse(self.out.exists())


class TestPackage(PackageCase):
    def test_folder(self):
        code, err = self.full("--zip")
        self.assertEqual((code, err), (0, ""))
        files = self.packaged()
        for f in ["default.xex", "game.lua", "main.lua", "conf.lua", "states/play.lua", "assets/hero.png",
                  "shaders/tint.glsl", "fx/glow.frag", "engine/init.lua", "engine/state.lua",
                  "engine/modules/platformer/init.lua", "lib/bump/bump.lua", "lib/bump/MIT-LICENSE.txt",
                  "l360/boot.lua", "l360/config.lua", "shaders/l360_default.psu", "shaders/l360_love.vsu",
                  "shaders/tint.psu", "shaders/tint.meta.lua", "shaders/glow.meta.lua", package.MANIFEST]:
            self.assertIn(f, files)
        # the .xex is the built one, not the stale file in the game folder
        self.assertEqual((self.out / "default.xex").read_bytes()[:4], b"XEX2")
        # no development files, nothing of the console's, no whole base, no unused modules or libs
        for f in files:
            self.assertFalse(f.endswith((".md", ".aseprite", ".bat", ".hlsl", ".log", ".ldtk", ".ldtkl")), f)
            self.assertFalse(f.split("/")[0] in ("saves", "save", "dist", "tests", "base", ".git", "notes"), f)
            self.assertFalse(f.startswith(("engine/modules/combat", "engine/modules/procgen", "lib/anim8")), f)
        # the converted level file ships; the LDtk project does not
        self.assertIn("levels/world.lvl", files)
        # every engine and runtime file is the base's, byte for byte
        self.assertEqual((self.out / "l360/boot.lua").read_bytes(), (ROOT / "runtime/lua/boot.lua").read_bytes())
        self.assertEqual({f for f in files if f.startswith("l360/")},
                         {"l360/" + p.name for p in (ROOT / "runtime/lua").glob("*.lua")})
        self.assertEqual({f for f in files if f.startswith("engine/") and f.count("/") == 1},
                         {"engine/" + p.name for p in (ROOT / "engine").glob("*.lua")})
        # the manifest lists every other file with its size and CRC
        manifest = package.parse_manifest((self.out / package.MANIFEST).read_text())
        self.assertEqual(sorted(manifest["files"]), [f for f in files if f != package.MANIFEST])
        self.assertEqual(manifest["fields"]["title_id"], "0x4D47AA01")
        self.assertEqual(manifest["fields"]["save_dir"], "saves")
        size, crc = manifest["files"]["main.lua"]
        self.assertEqual((size, crc), (len(MAIN_LUA), package.crc32_of(self.game / "main.lua")))
        # the zip holds the same files under the folder's name
        with zipfile.ZipFile(self.out.with_name("pack_test.zip")) as z:
            self.assertEqual(sorted(z.namelist()), sorted("pack_test/" + f for f in files))

    def test_dry_run_writes_nothing(self):
        code, _ = self.full("--dry-run")
        self.assertEqual(code, 0)
        self.assertFalse(self.out.exists())
        listed = [l.split()[-1] for l in self.lines if l[:10].strip().isdigit()]
        self.assertIn("default.xex", listed)
        self.assertIn("engine/modules/platformer/controller.lua", listed)
        self.assertNotIn("README.md", listed)
        self.assertTrue(self.lines[-1].startswith("dry run: %d files" % len(listed)))

    def test_repackage_and_foreign_folder(self):
        self.assertEqual(self.full()[0], 0)
        write(self.out / "stale.lua")
        self.assertEqual(self.full()[0], 0)                     # our own folder is replaced
        self.assertNotIn("stale.lua", self.packaged())
        other = self.tmp / "precious"
        write(other / "thesis.doc")
        code, err = self.run_main("--xex", str(self.xex), "--shaders", str(self.shaders), "--out", str(other))
        self.assertEqual(code, 1)
        self.assertIn("--force", err)
        self.assertTrue((other / "thesis.doc").exists())

    def test_xex_and_shaders_are_checked(self):
        code, err = self.run_main("--shaders", str(self.shaders))
        self.assertEqual(code, 1); self.assertIn("--xex", err)
        code, err = self.run_main("--xex", str(self.xex))
        self.assertEqual(code, 1); self.assertIn("--shaders", err)
        write(self.xex, b"MZ not a xex")
        code, err = self.full()
        self.assertEqual(code, 1); self.assertIn("XEX2", err)
        write(self.xex, b"XEX2....")
        (self.shaders / "glow.meta.lua").unlink()
        (self.shaders / "l360_love.psu").unlink()
        code, err = self.full()
        self.assertEqual(code, 1)
        self.assertIn("glow.meta.lua", err); self.assertIn("l360_love.psu", err)
        self.assertFalse(self.out.exists())

    def test_partial_package(self):
        code, _ = self.run_main("--no-xex", "--no-shaders", "--out", str(self.out))
        self.assertEqual(code, 0)
        files = self.packaged()
        self.assertNotIn("default.xex", files)
        self.assertFalse(any(f.endswith(".psu") for f in files))
        self.assertTrue(any("warning: no default.xex" in l for l in self.lines))

    def test_options(self):
        check = write(self.tmp / "level_hash_check.lua", "-- check")
        code, _ = self.full("--exclude", "fx/*", "--exclude", "*.png", "--module", "procgen", "--lib", "anim8",
                            "--extra", str(check), "--extra", "%s=l360/number_check.lua" % check, "--no-shaders")
        self.assertEqual(code, 0)
        files = self.packaged()
        self.assertNotIn("fx/glow.frag", files); self.assertNotIn("assets/hero.png", files)
        for f in ["engine/modules/procgen/seeds.lua", "lib/anim8/anim8.lua", "level_hash_check.lua",
                  "l360/number_check.lua"]:
            self.assertIn(f, files)

    def test_own_engine_copy_and_no_engine(self):
        write(self.game / "engine" / "init.lua", "-- pinned copy")
        write(self.game / "lib" / "mylib" / "mylib.lua", "-- mine")
        self.assertEqual(self.full()[0], 0)
        self.assertEqual((self.out / "engine/init.lua").read_text(), "-- pinned copy")
        files = self.packaged()
        self.assertEqual([f for f in files if f.startswith("engine/")], ["engine/init.lua"])
        self.assertEqual([f for f in files if f.startswith("lib/")], ["lib/mylib/mylib.lua"])
        shutil.rmtree(self.game / "engine"); shutil.rmtree(self.game / "lib")
        write(self.game / "main.lua", "function love.draw() end\n")
        self.assertEqual(self.full()[0], 0)
        self.assertFalse(any(f.startswith(("engine/", "lib/")) for f in self.packaged()))

    def test_problems(self):
        write(self.game / "main.lua", MAIN_LUA + 'require("engine.modules.nope")\n')
        code, err = self.full()
        self.assertEqual(code, 1); self.assertIn("engine.modules.nope", err)
        write(self.game / "main.lua", MAIN_LUA)
        write(self.game / "l360" / "x.lua")
        code, err = self.full()
        self.assertEqual(code, 1); self.assertIn("l360", err)
        shutil.rmtree(self.game / "l360")
        (self.game / "main.lua").unlink()
        code, err = self.full()
        self.assertEqual(code, 1); self.assertIn("main.lua", err)

    def test_warnings(self):
        write(self.game / "game.lua", GAME_LUA.replace('save_dir = "saves",', 'save_dir = "saves", debug = true,')
              .replace("0x4d47aa01", "0xFFFF0360"))
        self.assertEqual(self.full()[0], 0)
        text = "\n".join(self.lines)
        self.assertIn("debug = true", text)
        self.assertIn("development Title ID", text)

    def test_repository_games(self):
        for game, wanted, unwanted in (("template", "states/play.lua", "README.md"),
                                       ("examples/engine_demo", "lib/anim8/anim8.lua", "lib/bump/bump.lua")):
            lines = []
            code = package.main([str(ROOT / game), "--no-xex", "--no-shaders", "--dry-run"], log=lines.append)
            self.assertEqual(code, 0)
            listed = [l.split()[-1] for l in lines if l[:10].strip().isdigit()]
            self.assertIn(wanted, listed); self.assertNotIn(unwanted, listed)
            self.assertIn("engine/init.lua", listed); self.assertIn("l360/boot.lua", listed)


if __name__ == "__main__":
    unittest.main()
