#!/usr/bin/env python3
"""Deploys the latest successful cloud build of a game to the console, from a phone.

    python3 tools/deploy_android.py <game folder> [--branch NAME] [--config FILE]
        [--no-pull] [--no-upload] [--force] [--dry-run]

The .xex is not built here: on a phone or tablet that cannot build it, this script

    1. updates the local branch with `git pull --ff-only` (a different --branch is fetched and
       checked out first; --no-pull skips every git command);
    2. finds the newest successful "Console build" run of the branch on GitHub and downloads its
       <identity>-console artifact with the GitHub CLI (`gh`);
    3. extracts it into dist/android/<identity> and uploads it with tools/install_ftp.py in safe
       mode (one FTP connection per file and a size check), which sends only the files that
       changed and never touches saves or default.log.

If the newest successful build is not of the branch's latest commit (a newer run is still going,
or it failed), it says so and installs that older build anyway.

The console's settings come from the usual untracked deploy.local.ini (tools/deploy.example.ini
shows every key), or from the X360_FTP_* environment variables. The script needs `gh` logged in
(`gh auth login`) and fetches no token of its own. Python 3.8 or later, standard library only.
Runs on Android/Termux, Linux and Windows.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
TOOLS = BASE / "tools"
sys.path.insert(0, str(TOOLS))
import deploy  # noqa: E402  (find_config, load_config, console_target, upload_command)
import package  # noqa: E402  (read_config: the game's identity)

WORKFLOW = "Console build"


def _default_runner(argv, cwd=None, env=None):
    return subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True)


def _call(runner, argv, cwd=None, env=None):
    try:
        result = runner(argv, cwd=str(cwd or BASE), env=env)
    except FileNotFoundError:
        raise deploy.DeployError("%s is not installed; install it or add it to PATH" % argv[0])
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise deploy.DeployError("%s failed%s" % (" ".join(argv), (": " + detail) if detail else ""))
    return result


def _git(runner, *args):
    return _call(runner, ["git", *args]).stdout.strip()


def _gh(runner, *args):
    return _call(runner, ["gh", *args]).stdout


def current_branch(runner):
    branch = _git(runner, "rev-parse", "--abbrev-ref", "HEAD")
    if not branch or branch == "HEAD":
        raise deploy.DeployError("the repository is in a detached HEAD; pass --branch")
    return branch


def update_repo(runner, branch, pull, log):
    """Pulls (and checks out a different branch) when asked; refuses a dirty tracked tree."""
    if not pull:
        return
    dirty = _git(runner, "status", "--porcelain", "--untracked-files=no")
    if dirty:
        raise deploy.DeployError("the repository has uncommitted changes; commit or stash them, or pass --no-pull")
    if branch != current_branch(runner):
        log("checking out %s" % branch)
        _git(runner, "fetch", "origin", branch)
        _git(runner, "checkout", branch)
    log("pulling %s" % branch)
    _git(runner, "pull", "--ff-only")


def latest_artifact(artifacts, successful_runs, branch):
    """The newest artifact of a successful run of `branch`, or None. Pure: easy to test."""
    best = None
    for artifact in artifacts:
        if artifact.get("expired"):
            continue
        run = artifact.get("workflow_run") or {}
        try:
            run_id = int(run.get("id"))
        except (TypeError, ValueError):
            continue
        if run.get("head_branch") != branch or run_id not in successful_runs:
            continue
        if best is None or artifact.get("created_at", "") > best.get("created_at", ""):
            best = artifact
    return best


def find_artifact(runner, branch, artifact_name, log):
    """(artifact, run id) of the newest successful run with that artifact, or an error."""
    repo = json.loads(_gh(runner, "repo", "view", "--json", "nameWithOwner"))["nameWithOwner"]
    runs = json.loads(_gh(runner, "run", "list", "--workflow", WORKFLOW, "--branch", branch,
      "--status", "success", "--limit", "100", "--json", "databaseId,conclusion"))
    successful = {int(r["databaseId"]) for r in runs if r.get("conclusion") == "success"}
    if not successful:
        raise deploy.DeployError("no successful \"%s\" run on branch %s; run the workflow first" % (WORKFLOW, branch))
    query = urllib.parse.urlencode({"name": artifact_name, "per_page": "100"})
    path = "repos/%s/actions/artifacts?%s" % (repo, query)
    artifacts = json.loads(_gh(runner, "api", path)).get("artifacts", [])
    artifact = latest_artifact(artifacts, successful, branch)
    if not artifact:
        raise deploy.DeployError("the successful runs of %s have no %s artifact; is the game folder right?"
          % (branch, artifact_name))
    log("artifact %s from run %s (%s)" % (artifact_name, artifact["workflow_run"]["id"], artifact["created_at"]))
    return artifact


def local_commit(runner, branch):
    """The commit the branch points to here (origin's copy first), or None."""
    for ref in ("origin/" + branch, branch):
        try:
            sha = _git(runner, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
        except deploy.DeployError:
            continue
        if sha:
            return sha
    return None


def warn_if_stale(runner, artifact, branch, log):
    """Warns when the build is of an older commit than the branch's latest. Returns True then."""
    built = (artifact.get("workflow_run") or {}).get("head_sha")
    latest = local_commit(runner, branch)
    if not built or not latest or built == latest:
        return False
    log("WARNING: this build is of commit %s, but %s is at %s. A newer build may still be running "
        "or may have failed (GitHub: Actions, Console build); installing the older build."
        % (built[:7], branch, latest[:7]))
    return True


def download(runner, artifact_name, run_id, identity, log):
    """Extracts the artifact into dist/android/<identity> and returns that folder."""
    folder = (BASE / "dist" / "android" / identity).resolve()
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    _call(runner, ["gh", "run", "download", str(run_id), "-n", artifact_name, "-D", str(folder)])
    if not (folder / "default.xex").is_file():
        inner = folder / artifact_name
        if (inner / "default.xex").is_file():
            folder = inner
        else:
            raise deploy.DeployError("the artifact has no default.xex; is it a console folder?")
    if not (folder / "package_manifest.txt").is_file():
        raise deploy.DeployError("the artifact has no package_manifest.txt; it is not a package")
    log("downloaded to %s" % folder)
    return folder


def upload(runner, game, folder, cfg, config, force, dry_run, env, log):
    path = deploy.find_config(str(game), config)
    if not path:
        raise deploy.DeployError("no deploy.local.ini; copy tools/deploy.example.ini to the game "
          "folder or the repository root, or pass --config")
    cp = deploy.load_config(path, env=env)
    target = deploy.console_target(cp, cfg)
    argv, upload_env = deploy.upload_command(cp, folder, target, force=force, dry_run=dry_run, safe=True)
    result = _call(runner, argv, env=upload_env)
    if result.stdout.strip():
        log(result.stdout.strip())
    log("uploaded to %s" % target)


def main(argv=None, log=print, runner=None, env=None):
    parser = argparse.ArgumentParser(description="Download the latest successful console build "
      "and upload it over FTP.")
    parser.add_argument("game", help="game folder, for example examples/rooms")
    parser.add_argument("--branch", help="branch to deploy (default: the current one)")
    parser.add_argument("--config", help="deploy.local.ini (default: the game folder, then the base)")
    parser.add_argument("--no-pull", action="store_true", help="do not fetch or pull the repository")
    parser.add_argument("--no-upload", action="store_true", help="download the artifact only")
    parser.add_argument("--force", action="store_true", help="upload every file, changed or not")
    parser.add_argument("--dry-run", action="store_true", help="show what the FTP upload would do")
    args = parser.parse_args(argv)
    runner = runner or _default_runner
    env = os.environ if env is None else env
    game = Path(args.game).resolve()
    branch = args.branch or current_branch(runner)
    if args.no_pull and args.branch and args.branch != current_branch(runner):
        log("note: %s is not the current checkout; only the artifact comes from it" % branch)
    update_repo(runner, branch, not args.no_pull, log)
    cfg = package.read_config(str(game), log=log)
    artifact_name = cfg["identity"] + "-console"
    artifact = find_artifact(runner, branch, artifact_name, log)
    warn_if_stale(runner, artifact, branch, log)
    folder = download(runner, artifact_name, artifact["workflow_run"]["id"], cfg["identity"], log)
    if args.no_upload:
        log("not uploaded (--no-upload): %s" % folder)
        return 0
    upload(runner, game, folder, cfg, args.config, args.force, args.dry_run, env, log)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (deploy.DeployError, package.PackageError) as e:
        print("deploy_android: " + str(e), file=sys.stderr)
        sys.exit(2)
