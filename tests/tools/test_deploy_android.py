"""tools/deploy_android.py: picking the latest successful artifact and the upload it drives."""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import deploy  # noqa: E402
import deploy_android  # noqa: E402
import package  # noqa: E402

GAME_LUA = 'return {\n  name = "Deploy Android Test",\n  title_id = "0x4D47AA03",\n}\n'
INI = "[console]\nhost = 10.0.0.5\npassword = s3cret\n"


def result(stdout=""):
    return SimpleNamespace(returncode=0, stdout=stdout, stderr="")


class FakeRunner:
    """Answers the git and gh commands; on `gh run download` it writes a tiny package."""

    def __init__(self, branch="main", runs=None, artifacts=None, dirty=""):
        self.branch, self.runs, self.artifacts, self.dirty = branch, runs or [], artifacts or [], dirty
        self.calls = []

    def __call__(self, argv, cwd=None, env=None):
        self.calls.append(SimpleNamespace(argv=argv, cwd=cwd, env=env))
        if argv[0] == "git":
            if argv[1:3] == ["rev-parse", "--abbrev-ref"]:
                return result(self.branch + "\n")
            if argv[1:3] == ["status", "--porcelain"]:
                return result(self.dirty)
            return result()
        if argv[0] == "gh":
            if argv[1:3] == ["repo", "view"]:
                return result(json.dumps({"nameWithOwner": "owner/repo"}))
            if argv[1:3] == ["run", "list"]:
                return result(json.dumps(self.runs))
            if argv[1] == "api":
                return result(json.dumps({"artifacts": self.artifacts}))
            if argv[1:3] == ["run", "download"]:
                folder = Path(argv[argv.index("-D") + 1])
                folder.mkdir(parents=True, exist_ok=True)
                (folder / "default.xex").write_bytes(b"x")
                (folder / "package_manifest.txt").write_text("")
                return result()
        return result()

    def named(self, name):
        return [c for c in self.calls if len(c.argv) > 1 and Path(c.argv[1]).name == name]


def artifact(run_id, branch="main", created="2026-01-01T00:00:00Z", expired=False):
    return {"created_at": created, "expired": expired,
            "workflow_run": {"id": run_id, "head_branch": branch}}


class DeployAndroidCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.game = self.tmp / "game"
        self.game.mkdir()
        (self.game / "game.lua").write_text(GAME_LUA)
        (self.game / "main.lua").write_text("")
        self.ini = self.game / "deploy.local.ini"
        self.ini.write_text(INI)
        self.old_base = deploy_android.BASE
        deploy_android.BASE = self.tmp
        self.addCleanup(setattr, deploy_android, "BASE", self.old_base)
        self.lines = []
        self.identity = package.read_config(str(self.game), log=lambda s: None)["identity"]

    def run_main(self, *args, runner=None):
        return deploy_android.main([str(self.game), "--config", str(self.ini), *args],
            log=self.lines.append, runner=runner, env={})

    def test_latest_artifact(self):
        arts = [artifact(7, created="2026-01-05T00:00:00Z", expired=True),
                artifact(8, created="2026-01-04T00:00:00Z"),
                artifact(9, branch="dev", created="2026-01-06T00:00:00Z"),
                artifact(10, created="2026-01-03T00:00:00Z")]
        success = {8, 9, 10}
        self.assertEqual(deploy_android.latest_artifact(arts, success, "main")["workflow_run"]["id"], 8)
        self.assertIsNone(deploy_android.latest_artifact(arts, {8, 9, 10}, "other"))

    def test_downloads_and_uploads(self):
        runner = FakeRunner(runs=[{"databaseId": 10, "conclusion": "success"}], artifacts=[artifact(10)])
        self.assertEqual(self.run_main(runner=runner), 0)
        args = [c.argv for c in runner.calls]
        self.assertTrue(any(a[:3] == ["git", "pull", "--ff-only"] for a in args), "pulls the branch")
        self.assertTrue(any(a[0] == "gh" and a[1:3] == ["run", "download"] for a in args), "downloads")
        up = runner.named("install_ftp.py")
        self.assertEqual(len(up), 1, "uploads once")
        self.assertTrue((deploy_android.BASE / "dist" / "android" / self.identity / "default.xex").is_file())
        self.assertEqual(up[0].env["X360_FTP_PASSWORD"], "s3cret")
        self.assertIn("Hdd1:/Games/" + self.identity, up[0].argv)
        self.assertNotIn("s3cret", " ".join(up[0].argv))

    def test_no_upload_stops_after_download(self):
        runner = FakeRunner(runs=[{"databaseId": 10, "conclusion": "success"}], artifacts=[artifact(10)])
        self.assertEqual(self.run_main("--no-upload", runner=runner), 0)
        self.assertFalse(runner.named("install_ftp.py"))

    def test_no_pull_allows_a_dirty_tree(self):
        runner = FakeRunner(runs=[{"databaseId": 10, "conclusion": "success"}],
            artifacts=[artifact(10)], dirty=" M main.lua\n")
        self.assertEqual(self.run_main("--no-pull", "--no-upload", runner=runner), 0)
        self.assertFalse(any(c.argv[:3] == ["git", "pull", "--ff-only"] for c in runner.calls))

    def test_dirty_tree_refuses_to_pull(self):
        runner = FakeRunner(runs=None, dirty=" M main.lua\n")
        with self.assertRaises(deploy.DeployError):
            self.run_main(runner=runner)

    def test_branch_is_fetched_and_checked_out(self):
        runner = FakeRunner(branch="main", runs=[{"databaseId": 11, "conclusion": "success"}],
            artifacts=[artifact(11, branch="dev")])
        self.assertEqual(self.run_main("--branch", "dev", "--no-upload", runner=runner), 0)
        self.assertTrue(any(c.argv[:3] == ["git", "fetch", "origin"] and c.argv[3] == "dev"
            for c in runner.calls))
        self.assertTrue(any(c.argv[:3] == ["git", "checkout", "dev"] for c in runner.calls))
        self.assertTrue(any(c.argv[:3] == ["gh", "run", "list"] and "dev" in c.argv for c in runner.calls))

    def test_no_successful_run(self):
        runner = FakeRunner(runs=[], artifacts=[])
        with self.assertRaises(deploy.DeployError):
            self.run_main(runner=runner)


if __name__ == "__main__":
    unittest.main()
