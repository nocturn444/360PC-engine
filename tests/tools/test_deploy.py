"""tools/deploy.py: the steps it runs, its local config, and the XBDM launch against a fake server."""
import io
import shutil
import socket
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import deploy  # noqa: E402

GAME_LUA = 'return {\n  name = "Deploy Test",\n  title_id = "0x4D47AA02",\n}\n'
INI = """[console]
host = 10.0.0.5
password = s3cret
[xex]
mode = native
xsdk = ~/xsdk
[shaders]
tools = C:\\xost
"""


class FakeRunner:
    def __init__(self, fail_step=None):
        self.calls = []
        self.fail_step = fail_step

    def __call__(self, argv, cwd=None, env=None):
        self.calls.append(SimpleNamespace(argv=argv, cwd=cwd, env=env))
        name = Path(argv[1]).name if len(argv) > 1 else argv[0]
        return SimpleNamespace(returncode=1 if self.fail_step and self.fail_step in (argv[0], name) else 0)


class FakeXBDM:
    """A TCP server that greets like XBDM and records the commands it gets."""

    def __init__(self, answer=b"200- OK\r\n"):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.lines = []
        self.answer = answer
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        conn, _ = self.sock.accept()
        with conn:
            f = conn.makefile("rwb", buffering=0)
            f.write(b"201- connected\r\n")
            for line in iter(f.readline, b""):
                self.lines.append(line.decode().strip())
                if line.startswith(b"bye"):
                    break
                f.write(self.answer)
        self.sock.close()


class DeployCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.game = self.tmp / "game"
        self.game.mkdir()
        (self.game / "game.lua").write_text(GAME_LUA)
        (self.game / "main.lua").write_text("")
        (self.game / "deploy.local.ini").write_text(INI)
        self.lines = []

    def run_main(self, *args, runner=None, ini=None, **kw):
        if ini is not None:
            (self.game / "deploy.local.ini").write_text(ini)
        self.runner = runner or FakeRunner()
        err = io.StringIO()
        with redirect_stderr(err):
            code = deploy.main([str(self.game), *args], log=self.lines.append, runner=self.runner, env={}, **kw)
        return code, err.getvalue()

    def steps(self):
        return [Path(c.argv[1]).name if c.argv[0] == sys.executable else c.argv[0] for c in self.runner.calls]


class TestSteps(DeployCase):
    def test_full_run_in_order(self):
        code, err = self.run_main()
        self.assertEqual(code, 0, err)
        self.assertEqual(self.steps(), ["bash", "build_shaders.py", "package.py", "install_ftp.py"])
        build = self.runner.calls[0].argv[2]
        self.assertIn("-DGAME_TITLE_ID=0x4D47AA02", build)
        self.assertIn("-DGAME_NAME='Deploy Test'", build)
        self.assertIn('-DCMAKE_TOOLCHAIN_FILE="$HOME"/xsdk/cmake/xsdk.cmake', build)
        self.assertIn("runtime/build/deploy_test", build)
        self.assertEqual(self.runner.calls[0].cwd, str(deploy.BASE))
        pkg = self.runner.calls[2].argv
        self.assertIn(str(deploy.BASE / "runtime/build/deploy_test/game.xex"), pkg)
        self.assertIn(str(self.game / "dist" / "deploy_test"), pkg)
        up = self.runner.calls[3]
        self.assertIn("Hdd1:/Games/deploy_test", up.argv)
        self.assertIn("10.0.0.5", up.argv)
        self.assertNotIn("s3cret", " ".join(up.argv))        # password only in the environment
        self.assertEqual(up.env["X360_FTP_PASSWORD"], "s3cret")
        self.assertTrue(any("start it from Aurora" in l for l in self.lines))

    def test_wsl_command(self):
        cp = deploy.load_config(self.game / "deploy.local.ini", env={})
        cp.set("xex", "mode", "auto")
        cp.set("xex", "wsl_distro", "Ubuntu")
        argv, cwd, _ = deploy.xex_command(cp, {"identity": "g", "title_id": "0x4D47AA02", "name": "G"}, "win32")
        self.assertEqual(argv[:7], ["wsl.exe", "-d", "Ubuntu", "--cd", str(deploy.BASE), "-e", "bash"])
        self.assertNotIn("\n", argv[-1])
        self.assertIsNone(cwd)

    def test_skips_and_failures(self):
        code, err = self.run_main("--skip-xex")
        self.assertEqual(code, 1)
        self.assertIn("build it once", err)
        code, err = self.run_main(runner=FakeRunner(fail_step="package.py"))
        self.assertEqual(code, 1)
        self.assertIn("package failed", err)
        self.assertEqual(self.steps(), ["bash", "build_shaders.py", "package.py"])

    def test_no_shader_tools_reuses_output(self):
        ini = INI.replace("tools = C:\\xost", "tools =")
        code, err = self.run_main(ini=ini)
        self.assertEqual(code, 1)
        self.assertIn("[shaders] tools", err)
        (self.game / "build" / "shaders").mkdir(parents=True)
        code, err = self.run_main(ini=ini)
        self.assertEqual(code, 0, err)
        self.assertEqual(self.steps(), ["bash", "package.py", "install_ftp.py"])

    def test_no_upload_and_dry_run(self):
        code, err = self.run_main("--no-upload")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.steps()[-1], "package.py")
        code, err = self.run_main("--dry-run", "--skip-xex", "--skip-shaders")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.runner.calls, [])

    def test_config_errors(self):
        code, err = self.run_main(ini="[xex]\nmode = native\n")
        self.assertIn("[xex] xsdk", err)
        code, err = self.run_main(ini=INI.replace("host = 10.0.0.5", ""))
        self.assertIn("[console] host", err)
        code, err = self.run_main(ini=INI + "[launch]\nmethod = magic\n")
        self.assertIn("[launch] method", err)
        code, err = self.run_main("--config", str(self.tmp / "nope.ini"))
        self.assertIn("not found", err)

    def test_environment_overrides(self):
        cp = deploy.load_config(self.game / "deploy.local.ini", env={"X360_FTP_HOST": "10.0.0.9"})
        self.assertEqual(cp.get("console", "host"), "10.0.0.9")


class TestLaunch(DeployCase):
    def test_paths(self):
        cp = deploy.load_config(None, env={})
        self.assertEqual(deploy.xbdm_paths(cp, "Hdd1:/Games/my game"),
                         ("Hdd:\\Games\\my game\\default.xex", "Hdd:\\Games\\my game\\"))
        self.assertEqual(deploy.xbdm_paths(cp, "Usb0:/Games/x")[0], "Usb0:\\Games\\x\\default.xex")
        cp.set("launch", "path", "Hdd:/Apps/x/")
        self.assertEqual(deploy.xbdm_paths(cp, "Hdd1:/Games/x")[1], "Hdd:\\Apps\\x\\")

    def test_magicboot(self):
        srv = FakeXBDM()
        ini = INI.replace("10.0.0.5", "127.0.0.1") + "[launch]\nmethod = xbdm\nport = %d\n" % srv.port
        code, err = self.run_main(ini=ini)
        self.assertEqual(code, 0, err)
        srv.thread.join(5)
        self.assertEqual(srv.lines[0], 'magicboot title="Hdd:\\Games\\deploy_test\\default.xex" '
                                       'directory="Hdd:\\Games\\deploy_test\\"')

    def test_refused_and_unreachable(self):
        srv = FakeXBDM(answer=b"402- file not found\r\n")
        with self.assertRaises(deploy.DeployError) as e:
            deploy.xbdm_launch("127.0.0.1", srv.port, "Hdd:\\x\\default.xex", "Hdd:\\x\\")
        self.assertIn("402", str(e.exception))

        def refuse(addr, timeout):
            raise ConnectionRefusedError("refused")
        with self.assertRaises(deploy.DeployError) as e:
            deploy.xbdm_launch("10.0.0.5", 730, "a", "b", connect=refuse)
        self.assertIn("xbdm.xex", str(e.exception))

    def test_no_launch_flag_wins(self):
        code, err = self.run_main("--no-launch", ini=INI + "[launch]\nmethod = xbdm\n")
        self.assertEqual(code, 0, err)


if __name__ == "__main__":
    unittest.main()
