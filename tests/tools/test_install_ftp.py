"""tools/install_ftp.py against an in-memory FTP server that answers like Aurora's (fake_ftp.py)."""
import io
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import install_ftp  # noqa: E402
import package  # noqa: E402
from fake_ftp import FakeFTP  # noqa: E402


def write(path, data=b"x"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data if isinstance(data, bytes) else data.encode())
    return path


class InstallCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.folder = self.tmp / "my_game"
        self.files = {"default.xex": b"XEX2" + b"\1" * 100, "game.lua": b"return {}", "main.lua": b"print(1)",
                      "engine/init.lua": b"-- engine", "engine/modules/procgen/init.lua": b"-- procgen",
                      "l360/boot.lua": b"-- boot", "shaders/l360_default.psu": b"psu"}
        for rel, data in self.files.items():
            write(self.folder / rel, data)
        self.write_manifest()
        self.ftp = FakeFTP()
        self.lines = []

    def write_manifest(self):
        entries = sorted((p.relative_to(self.folder).as_posix(), p.stat().st_size, package.crc32_of(p))
                         for p in self.folder.rglob("*") if p.is_file() and p.name != package.MANIFEST
                         and p.relative_to(self.folder).parts[0] != "save")
        cfg = {"name": "My Game", "title_id": "0x4D47AA01", "identity": "my_game", "save_dir": "save"}
        (self.folder / package.MANIFEST).write_text(package.manifest_text(cfg, entries))

    def install(self, **kw):
        kw.setdefault("host", "192.168.0.20")
        return install_ftp.install(self.folder, log=self.lines.append, ftp_factory=self.ftp, **kw)

    def remote(self, *path):
        node = self.ftp.root
        for p in path:
            node = node[p]
        return node


class TestInstall(InstallCase):
    def test_first_install(self):
        stats = self.install()
        game = self.remote("Hdd1", "Games", "my_game")
        for rel, data in self.files.items():
            node = game
            for part in rel.split("/"):
                node = node[part]
            self.assertEqual(node, data, rel)
        self.assertEqual(game[package.MANIFEST], (self.folder / package.MANIFEST).read_bytes())
        self.assertEqual(stats["uploaded"], len(self.files) + 1)
        self.assertEqual(stats["unchanged"], 0)
        self.assertEqual(stats["target"], "Hdd1:/Games/my_game/")
        self.assertEqual(self.ftp.changes()[-1], "STOR " + package.MANIFEST)       # the manifest goes last
        self.assertIn("CONNECT 192.168.0.20:21", self.ftp.commands)
        self.assertNotIn("LIST", self.ftp.commands)       # Aurora's LIST hangs on an empty folder
        self.assertTrue(self.ftp.closed)

    def test_safe_mode_reconnects_per_file(self):
        root = self.ftp.root
        connections = []

        def factory():
            ftp = FakeFTP(root=root)
            connections.append(ftp)
            return ftp

        stats = install_ftp.install(self.folder, host="192.168.0.20", log=self.lines.append,
            ftp_factory=factory, safe=True)
        self.assertEqual(stats["uploaded"], len(self.files) + 1)
        self.assertGreaterEqual(len(connections), len(self.files) + 2)     # the first and one per file
        game = self.remote("Hdd1", "Games", "my_game")
        self.assertEqual(game["engine"]["init.lua"], self.files["engine/init.lua"])
        self.assertEqual(game["default.xex"], self.files["default.xex"])
        self.assertEqual(game[package.MANIFEST], (self.folder / package.MANIFEST).read_bytes())

    def test_second_install_uploads_nothing(self):
        self.install()
        self.ftp.commands.clear()
        stats = self.install()
        self.assertEqual((stats["uploaded"], stats["unchanged"]), (0, len(self.files) + 1))
        self.assertEqual(self.ftp.changes(), [])

    def test_only_changed_files(self):
        self.install()
        write(self.folder / "main.lua", b"print(22222)")                 # another size
        write(self.folder / "engine/init.lua", b"-- ENGINE")             # same size, another content
        write(self.folder / "states/play.lua", b"return {}")             # new, in a new folder
        self.write_manifest()
        self.ftp.commands.clear()
        stats = self.install()
        self.assertEqual(self.ftp.changes(), ["STOR main.lua", "STOR init.lua", "MKD states", "STOR play.lua", "STOR " + package.MANIFEST])
        self.assertEqual(stats["uploaded"], 4)
        game = self.remote("Hdd1", "Games", "my_game")
        self.assertEqual(game["engine"]["init.lua"], b"-- ENGINE")
        self.assertEqual(game["states"]["play.lua"], b"return {}")
        self.assertEqual(game["default.xex"], self.files["default.xex"])

    def test_size_only_without_a_manifest(self):
        self.install()
        del self.remote("Hdd1", "Games", "my_game")[package.MANIFEST]
        write(self.folder / "main.lua", b"print(22222)")
        self.write_manifest()
        self.ftp.commands.clear()
        self.install()
        self.assertEqual(self.ftp.changes(), ["STOR main.lua", "STOR " + package.MANIFEST])
        self.assertTrue(any("comparing sizes only" in l for l in self.lines))

    def test_force(self):
        self.install()
        self.ftp.commands.clear()
        stats = self.install(force=True)
        self.assertEqual(stats["uploaded"], len(self.files) + 1)

    def test_dry_run(self):
        stats = self.install(dry_run=True)                               # nothing on the console yet
        self.assertEqual(self.ftp.changes(), [])
        self.assertEqual(self.remote("Hdd1"), {})
        self.assertEqual(stats["uploaded"], len(self.files) + 1)
        self.assertTrue(any(l.strip().startswith("would upload engine/modules/procgen/init.lua") for l in self.lines))
        self.install()
        write(self.folder / "main.lua", b"print(22222)")
        self.write_manifest()
        self.ftp.commands.clear()
        self.lines.clear()
        stats = self.install(dry_run=True)
        self.assertEqual(self.ftp.changes(), [])
        self.assertEqual(stats["uploaded"], 2)
        self.assertEqual([l.strip().split(" (")[0] for l in self.lines if "would upload" in l],
                         ["would upload main.lua", "would upload " + package.MANIFEST])
        self.assertEqual(self.remote("Hdd1", "Games", "my_game")["main.lua"], b"print(1)")

    def test_saves_and_log_are_never_touched(self):
        self.install()
        game = self.remote("Hdd1", "Games", "my_game")
        game["save"] = {"run.sav": b"console save"}
        game["default.log"] = b"console log"
        game["old.lua"] = b"left from an earlier version"
        write(self.folder / "save" / "run.sav", b"pc save that must not go")
        write(self.folder / "default.log", b"pc log")
        self.ftp.commands.clear()
        stats = self.install(force=True)
        self.assertEqual(game["save"], {"run.sav": b"console save"})
        self.assertEqual(game["default.log"], b"console log")
        self.assertEqual(game["old.lua"], b"left from an earlier version")       # nothing is deleted
        self.assertNotIn("CWD save", self.ftp.commands)
        self.assertEqual(stats["extra"], 1)
        self.assertTrue(any("left alone): old.lua" in l for l in self.lines))
        self.assertFalse(any(c.split()[0] in ("DELE", "RMD", "RNFR") for c in self.ftp.commands))

    def test_targets(self):
        self.assertEqual(install_ftp.parse_target("Hdd1:/Games/My Game"), ["Hdd1", "Games", "My Game"])
        self.assertEqual(install_ftp.parse_target("Usb0:\\Homebrew\\x\\"), ["Usb0", "Homebrew", "x"])
        self.assertEqual(install_ftp.parse_target("/Hdd1/Games/x"), ["Hdd1", "Games", "x"])
        for bad in ("Hdd1:", "Hdd1:/../x", ""):
            with self.assertRaises(install_ftp.InstallError):
                install_ftp.parse_target(bad)
        stats = self.install(target="Usb0:\\Homebrew\\Other Name")
        self.assertEqual(stats["target"], "Usb0:/Homebrew/Other Name/")
        self.assertEqual(self.remote("Usb0", "Homebrew", "Other Name")["main.lua"], b"print(1)")
        with self.assertRaises(install_ftp.InstallError) as e:
            self.install(target="Hdd9:/Games/x")
        self.assertIn("no drive Hdd9", str(e.exception))

    def test_listing_formats(self):
        p = install_ftp.parse_list_line
        self.assertEqual(p("-rwxrwxrwx   1 root  root        1234 Jan 01  2000 my file.lua"), ("my file.lua", 1234, False))
        self.assertEqual(p("drwxrwxrwx   1 root  root           0 Jan 01 12:30 Games"), ("Games", 0, True))
        self.assertEqual(p("01-01-00  12:00AM       <DIR>          save"), ("save", None, True))
        self.assertEqual(p("01-01-00  12:00AM                 77 main.lua"), ("main.lua", 77, False))
        self.assertEqual(p("main.lua"), ("main.lua", None, None))
        self.assertIsNone(p("  "))
        # a server that only gives names: SIZE still gives the sizes, so only the manifest goes
        self.install()
        self.ftp.list_style = "names"
        del self.remote("Hdd1", "Games", "my_game")[package.MANIFEST]
        self.ftp.commands.clear()
        self.assertEqual(self.install()["uploaded"], 1)

    def test_errors(self):
        with self.assertRaises(install_ftp.InstallError) as e:
            install_ftp.install(self.folder, "192.168.0.20", ftp_factory=FakeFTP(fail_connect=True), log=self.lines.append)
        self.assertIn("Aurora", str(e.exception))
        with self.assertRaises(install_ftp.InstallError):
            self.install(password="wrong")
        with self.assertRaises(install_ftp.InstallError):
            self.install(host="")
        (self.folder / "main.lua").unlink()
        with self.assertRaises(install_ftp.InstallError) as e:
            self.install()
        self.assertIn("package.py", str(e.exception))


class TestCommandLine(InstallCase):
    def run_main(self, *args):
        err = io.StringIO()
        with redirect_stderr(err):
            code = install_ftp.main([str(self.folder), *args], log=self.lines.append, ftp_factory=self.ftp)
        return code, err.getvalue()

    def test_arguments(self):
        code, err = self.run_main("--host", "ftp://10.0.0.5/", "--port", "2121", "--target", "Usb0:/Games/g", "--dry-run")
        self.assertEqual((code, err), (0, ""))
        self.assertIn("CONNECT 10.0.0.5:2121", self.ftp.commands)
        self.assertEqual(self.ftp.changes(), [])
        code, err = self.run_main("--host", "10.0.0.5", "--password", "nope")
        self.assertEqual(code, 1)
        self.assertIn("could not connect", err)

    def test_environment(self):
        old = dict(os.environ)
        os.environ.update(X360_FTP_HOST="10.1.1.1", X360_FTP_PORT="2100", X360_FTP_TARGET="Usb0:/Apps/env_game",
                          X360_FTP_USER="xboxftp", X360_FTP_PASSWORD="xboxftp")
        try:
            code, _ = self.run_main()
        finally:
            os.environ.clear(); os.environ.update(old)
        self.assertEqual(code, 0)
        self.assertIn("CONNECT 10.1.1.1:2100", self.ftp.commands)
        self.assertEqual(self.remote("Usb0", "Apps", "env_game")["main.lua"], b"print(1)")
        code, err = self.run_main()                       # no host anywhere
        self.assertEqual(code, 1)
        self.assertIn("--host", err)


class TestPackageThenInstall(unittest.TestCase):
    def test_template_end_to_end(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        out = tmp / "new_game"
        code = package.main([str(ROOT / "template"), "--no-xex", "--no-shaders", "--out", str(out)], log=lambda s: None)
        self.assertEqual(code, 0)
        ftp = FakeFTP()
        stats = install_ftp.install(out, "192.168.0.20", log=lambda s: None, ftp_factory=ftp)
        game = ftp.root["Hdd1"]["Games"]["new_game"]
        self.assertEqual(game["states"]["play.lua"], (ROOT / "template/states/play.lua").read_bytes())
        self.assertEqual(game["l360"]["boot.lua"], (ROOT / "runtime/lua/boot.lua").read_bytes())
        self.assertIn("ui.lua", game["engine"])
        self.assertEqual(stats["uploaded"], sum(1 for p in out.rglob("*") if p.is_file()))
        self.assertEqual(install_ftp.install(out, "192.168.0.20", log=lambda s: None, ftp_factory=ftp)["uploaded"], 0)


if __name__ == "__main__":
    unittest.main()
