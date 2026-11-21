#!/usr/bin/env python3
"""Uploads a packaged game (the folder tools/package.py writes) to the console over FTP.

    python tools/install_ftp.py dist/my_game --host 192.168.0.20
        [--target Hdd1:/Games/my_game] [--port 21] [--user xboxftp] [--password xboxftp]
        [--dry-run] [--force] [--fast]

The console must be on with Aurora running and its FTP server enabled (the defaults above are
Aurora's). Only files that changed are uploaded: a file is left alone when the console has it
with the same size and, if the last install left a package_manifest.txt there, the same CRC-32.
--force uploads everything. Nothing is ever deleted or renamed on the console, and the save
folder and default.log are never touched.

Some Aurora FTP servers mix the data of consecutive files, so by default every file gets a fresh
connection and its size is checked on the console, retrying with another connection if it is
wrong. --fast keeps one connection for the whole install (quicker, but only for FTP servers known
not to mix files). --safe is still accepted and is the default.

Every option can also come from the environment: X360_FTP_HOST, X360_FTP_PORT, X360_FTP_USER,
X360_FTP_PASSWORD, X360_FTP_TARGET. Python 3.8 or later, standard library only.
"""
import argparse
import ftplib
import os
import re
import sys
import zlib
from pathlib import Path

DEFAULT_PORT = 21
DEFAULT_USER = "xboxftp"          # Aurora's defaults
DEFAULT_PASSWORD = "xboxftp"
DEFAULT_DRIVE_PATH = "Hdd1:/Games"
MANIFEST = "package_manifest.txt"
MANIFEST_HEADER = "# 360PC-Engine package v1"
PROTECTED_FILES = ("default.log",)

# A Unix-style LIST line (what Aurora's FTP answers, also to NLST), and a DOS-style one.
_LIST_UNIX = re.compile(r"^([dl-])[rwxsStT-]{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\S+\s+\d+\s+[\d:]+\s+(.+)$")
_LIST_DOS = re.compile(r"^\d\d-\d\d-\d\d+\s+\d\d:\d\d(?:[AP]M)?\s+(<DIR>|\d+)\s+(.+)$")


class InstallError(Exception):
    """Something that stops the install; the message is for the user."""


def parse_target(target):
    """'Hdd1:/Games/My Game', 'Hdd1:\\Games\\My Game' and '/Hdd1/Games/My Game' -> ['Hdd1', 'Games', 'My Game']"""
    parts = [p for p in target.replace("\\", "/").split("/") if p]
    if parts and parts[0].endswith(":"):
        parts[0] = parts[0][:-1]
    if len(parts) < 2 or any(p in (".", "..") for p in parts):
        raise InstallError("the target must be a drive and a folder, like Hdd1:/Games/my_game: %s" % target)
    return parts


def clean_host(host):
    """accepts '192.168.0.20' and 'ftp://192.168.0.20/'"""
    host = (host or "").strip()
    if host.lower().startswith("ftp://"):
        host = host[6:]
    return host.strip("/")


def crc32_of(path):
    crc = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            crc = zlib.crc32(chunk, crc)
    return crc & 0xFFFFFFFF


def parse_manifest(text):
    """{path: (size, crc)} and the header fields; None if the text is not a package manifest"""
    if not text or not text.startswith(MANIFEST_HEADER):
        return None
    files, fields = {}, {}
    for line in text.splitlines()[1:]:
        if line.startswith("# "):
            k, _, v = line[2:].partition("=")
            fields[k] = v
            continue
        parts = line.split(" ", 2)
        if len(parts) == 3:
            try:
                files[parts[2]] = (int(parts[0]), int(parts[1], 16))
            except ValueError:
                return None
    return {"files": files, "fields": fields}


def parse_list_line(line):
    """(name, size or None, is_dir) of one line of a listing, or None"""
    line = line.rstrip("\r\n")
    if not line.strip():
        return None
    m = _LIST_UNIX.match(line)
    if m:
        return m.group(3), int(m.group(2)), m.group(1) == "d"
    m = _LIST_DOS.match(line.strip())
    if m:
        is_dir = m.group(1) == "<DIR>"
        return m.group(2), None if is_dir else int(m.group(1)), is_dir
    name = line.strip().replace("\\", "/").rstrip("/").rsplit("/", 1)[-1]      # a bare name
    return (name, None, None) if name else None


def local_tree(folder, protected_dirs):
    """{'': [(name, path)], 'sub/dir': [...]} of the package, without the console's own files"""
    folder = Path(folder)
    tree = {}
    for root, dirs, files in os.walk(folder):
        rel = Path(root).relative_to(folder).as_posix()
        rel = "" if rel == "." else rel
        if rel == "":
            dirs[:] = [d for d in dirs if d.lower() not in protected_dirs]
            files = [f for f in files if f.lower() not in PROTECTED_FILES]
        dirs.sort()
        tree[rel] = [(f, Path(root) / f) for f in sorted(files)]
    return tree


class Installer:
    """Mirrors a package folder into the current FTP folder. Only CWD, MKD, LIST, RETR of the
    manifest and STOR: never DELE, RMD or RNFR."""

    def __init__(self, ftp, log=print, dry_run=False, force=False, reconnect=None, safe=True):
        self.ftp, self.log, self.dry_run, self.force = ftp, log, dry_run, force
        self.reconnect, self.safe = reconnect, safe
        self.path = []                  # the folders from the drive down to the current one
        self.stats = {"uploaded": 0, "unchanged": 0, "bytes": 0, "folders_created": 0, "extra": 0}

    # -- moving around -------------------------------------------------------------------
    def _cwd(self, name):
        try:
            self.ftp.cwd(name)
            return True
        except ftplib.error_perm:
            return False

    def enter_drive(self, drive):
        """the drive as the server names it: 'Hdd1', '/Hdd1' or 'Hdd1:'"""
        self._cwd("/")
        for name in (drive, "/" + drive, drive + ":"):
            if self._cwd(name):
                self.path = [name]
                return
        raise InstallError("the console's FTP has no drive %s (Aurora shows Hdd1, Usb0, Usb1...)" % drive)

    def enter(self, name):
        """into a folder, creating it if needed. False (dry run only): it does not exist yet."""
        if self._cwd(name):
            self.path.append(name)
            return True
        if self.dry_run:
            return False
        try:
            self.ftp.mkd(name)
        except ftplib.error_perm:
            pass                    # the cwd below says whether it is usable anyway
        if not self._cwd(name):
            raise InstallError("could not create or open the folder %s on the console" % name)
        self.path.append(name)
        self.stats["folders_created"] += 1
        return True

    def up(self):
        if not self._cwd(".."):
            try:
                self.ftp.sendcmd("CDUP")
            except ftplib.all_errors as e:
                raise InstallError("could not go back to the parent folder on the console: %s" % e)
        if self.path:
            self.path.pop()

    def _reopen(self):
        """A fresh connection at the current folder (safe mode: Aurora can mix two files)."""
        if not self.reconnect:
            return False
        try:
            self.ftp.quit()
        except ftplib.all_errors:
            try:
                self.ftp.close()
            except Exception:
                pass
        self.ftp = self.reconnect()
        self._cwd("/")
        for name in self.path:
            if not self._cwd(name):
                raise InstallError("could not go back to /%s after reconnecting" % "/".join(self.path))
        return True

    # -- reading the console ---------------------------------------------------------------
    def listing(self):
        """{lower-case name: (name, size or None, is_dir or None)} of the current folder"""
        lines = []
        try:
            self.ftp.retrlines("LIST", lines.append)
        except ftplib.all_errors:
            try:
                lines = list(self.ftp.nlst())
            except ftplib.all_errors:
                lines = []
        out = {}
        for line in lines:
            entry = parse_list_line(line)
            if entry and entry[0] not in (".", ".."):
                out[entry[0].lower()] = entry
        return out

    def remote_size(self, name):
        """The size of a file on the console, or None when it is not there (no LIST needed)."""
        try:
            return self.ftp.size(name)
        except ftplib.all_errors:
            return None

    def remote_manifest(self):
        chunks = []
        try:
            self.ftp.retrbinary("RETR " + MANIFEST, chunks.append)
        except ftplib.all_errors:
            return None
        return parse_manifest(b"".join(chunks).decode("utf-8", "replace"))

    # -- uploading -------------------------------------------------------------------------
    def _store(self, name, path, rel):
        size = path.stat().st_size
        if self.dry_run:
            self.log("  would upload %s (%d bytes)" % (rel, size))
        else:
            attempts = 2 if self.safe else 1
            got = None
            for attempt in range(1, attempts + 1):
                if self.safe:
                    self._reopen()
                try:
                    with open(path, "rb") as f:
                        self.ftp.storbinary("STOR " + name, f)
                except ftplib.all_errors as e:
                    raise InstallError("could not upload %s: %s" % (rel, e))
                if not self.safe:
                    break
                got = self.remote_size(name)
                if got == size:
                    break
                self.log("  %s: the console says %s bytes, expected %d; retrying" % (rel, got, size))
            if self.safe and got != size:
                raise InstallError("could not upload %s: the console says %s bytes, expected %d"
                  % (rel, got, size))
            self.log("  uploaded %s (%d bytes)" % (rel, size))
        self.stats["uploaded"] += 1
        self.stats["bytes"] += size

    def mirror(self, folder, protected_dirs=("save",)):
        """uploads what changed of <folder> into the current remote folder; returns the stats"""
        protected = {d.lower() for d in protected_dirs}
        tree = local_tree(folder, protected)
        known = self.remote_manifest()
        known_files = known["files"] if known else {}
        if known is None:
            self.log("  no package manifest on the console: comparing sizes only")
        self._mirror_dir(tree, "", True, known_files, protected, known is not None)
        manifest = Path(folder) / MANIFEST
        if manifest.is_file():
            # last, so that an interrupted install never leaves a manifest that claims too much
            text = manifest.read_text(encoding="utf-8", errors="replace")
            same = known is not None and known == parse_manifest(text)
            if self.stats["uploaded"] or not same or self.force:
                self._store(MANIFEST, manifest, MANIFEST)
            else:
                self.stats["unchanged"] += 1
        return self.stats

    def _mirror_dir(self, tree, rel, exists, known_files, protected, list_remote):
        # Aurora's LIST hangs on an empty folder (it opens the data connection and never ends
        # it). A first install has no manifest, so it compares sizes with SIZE and never lists;
        # later installs have a manifest and their folders are not empty, so LIST is safe.
        remote = self.listing() if exists and list_remote else {}
        prefix = rel + "/" if rel else ""
        local_names = set()
        for name, path in tree.get(rel, []):
            local_names.add(name.lower())
            if rel == "" and name == MANIFEST:
                continue
            size = path.stat().st_size
            if not exists or self.force:
                changed = True
            elif list_remote:
                there = remote.get(name.lower())
                changed = there is None or there[1] != size
            else:
                changed = self.remote_size(name) != size
            if not changed and prefix + name in known_files:
                changed = known_files[prefix + name] != (size, crc32_of(path))
            if changed:
                self._store(name, path, prefix + name)
            else:
                self.stats["unchanged"] += 1
        subdirs = sorted(d[len(prefix):] for d in tree if d and d.startswith(prefix) and "/" not in d[len(prefix):])
        for d in subdirs:
            local_names.add(d.lower())
            entered = self.enter(d)
            self._mirror_dir(tree, prefix + d, entered, known_files, protected, list_remote)
            if entered:
                self.up()
        if list_remote:
            for key, entry in sorted(remote.items()):
                if key in local_names or (rel == "" and (key in protected or key in PROTECTED_FILES)):
                    continue
                self.stats["extra"] += 1
                self.log("  on the console but not in the package (left alone): %s%s" % (prefix, entry[0]))


def connect(host, port=DEFAULT_PORT, user=DEFAULT_USER, password=DEFAULT_PASSWORD, timeout=30,
            ftp_factory=ftplib.FTP):
    host = clean_host(host)
    if not host:
        raise InstallError("give the console's IP with --host (Aurora shows it), or set X360_FTP_HOST")
    ftp = ftp_factory()
    try:
        ftp.connect(host, int(port), timeout=timeout)
        ftp.login(user, password)
        ftp.set_pasv(True)
    except ftplib.all_errors as e:
        try:
            ftp.close()
        except Exception:
            pass
        raise InstallError(
            "could not connect to the console's FTP (%s:%s): %s\n"
            "Keep the console on with Aurora running and its FTP server enabled (Aurora's default\n"
            "user and password are %s/%s), and the PC and the console on the same network."
            % (host, port, e, DEFAULT_USER, DEFAULT_PASSWORD))
    return ftp


def install(folder, host, target=None, port=DEFAULT_PORT, user=DEFAULT_USER, password=DEFAULT_PASSWORD,
            dry_run=False, force=False, timeout=30, log=print, ftp_factory=ftplib.FTP, safe=True):
    """uploads the package in <folder>; returns the stats, with "target" as the path used"""
    folder = Path(folder)
    if not (folder / "main.lua").is_file():
        raise InstallError("%s is not a packaged game (no main.lua): run tools/package.py first" % folder)
    manifest = parse_manifest((folder / MANIFEST).read_text(encoding="utf-8", errors="replace")) \
        if (folder / MANIFEST).is_file() else None
    save_dir = (manifest or {}).get("fields", {}).get("save_dir", "save")
    parts = parse_target(target or "%s/%s" % (DEFAULT_DRIVE_PATH, folder.resolve().name))
    shown = "%s:/%s/" % (parts[0], "/".join(parts[1:]))
    log("%s -> %s on %s%s" % (folder, shown, clean_host(host), " (dry run)" if dry_run else ""))
    def opener():
        return connect(host, port, user, password, timeout, ftp_factory)
    ftp = opener()
    inst = None
    try:
        inst = Installer(ftp, log, dry_run, force, reconnect=opener, safe=safe)
        inst.enter_drive(parts[0])
        exists = True
        for name in parts[1:]:
            exists = exists and inst.enter(name)
        if exists:
            stats = inst.mirror(folder, protected_dirs={"save", save_dir})
        else:
            # dry run of a first install: nothing is there, so everything would go
            inst.listing = lambda: {}
            inst.remote_manifest = lambda: None
            inst.enter = lambda name: False
            stats = inst.mirror(folder, protected_dirs={"save", save_dir})
        stats["target"] = shown
        log("%s%d uploaded (%.1f KB), %d unchanged%s" % (
            "dry run: " if dry_run else "", stats["uploaded"], stats["bytes"] / 1024, stats["unchanged"],
            ", %d on the console that are not in the package" % stats["extra"] if stats["extra"] else ""))
        return stats
    finally:
        current = inst.ftp if inst else ftp
        try:
            current.quit()
        except ftplib.all_errors:
            try:
                current.close()
            except ftplib.all_errors:
                pass


def main(argv=None, log=print, ftp_factory=ftplib.FTP):
    env = os.environ
    ap = argparse.ArgumentParser(description="Upload a packaged 360PC-Engine game to the console over FTP.")
    ap.add_argument("folder", type=Path, help="the packaged game (output of tools/package.py)")
    ap.add_argument("--host", default=env.get("X360_FTP_HOST"), help="the console's IP (or X360_FTP_HOST)")
    ap.add_argument("--port", type=int, default=int(env.get("X360_FTP_PORT") or DEFAULT_PORT))
    ap.add_argument("--user", default=env.get("X360_FTP_USER") or DEFAULT_USER)
    ap.add_argument("--password", default=env.get("X360_FTP_PASSWORD") or DEFAULT_PASSWORD)
    ap.add_argument("--target", default=env.get("X360_FTP_TARGET"),
                    help="folder on the console (default: %s/<package folder name>)" % DEFAULT_DRIVE_PATH)
    ap.add_argument("--dry-run", action="store_true", help="list what would be uploaded; change nothing")
    ap.add_argument("--force", action="store_true", help="upload every file, changed or not")
    ap.add_argument("--safe", action="store_true", help="one connection per file and a size check (the default)")
    ap.add_argument("--fast", action="store_true", help="one connection for the whole install, no size check")
    ap.add_argument("--timeout", type=float, default=30)
    args = ap.parse_args(argv)
    try:
        if not args.folder.is_dir():
            raise InstallError("%s is not a folder" % args.folder)
        install(args.folder, args.host, args.target, args.port, args.user, args.password, args.dry_run,
                args.force, args.timeout, log, ftp_factory, safe=not args.fast)
        return 0
    except InstallError as e:
        print("install_ftp: " + str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
