"""An in-memory stand-in for ftplib.FTP that behaves like Aurora's FTP server: drives at the
root, LIST lines in Unix style, errors as ftplib.error_perm. Folders are dicts, files bytes."""
import ftplib


class FakeFTP:
    def __init__(self, root=None, fail_connect=False, list_style="unix"):
        self.root = root if root is not None else {"Hdd1": {}, "Usb0": {}}
        self.path = []
        self.commands = []
        self.fail_connect = fail_connect
        self.list_style = list_style
        self.connected = self.logged_in = self.closed = False

    def __call__(self):          # so that an instance can be passed as the ftp_factory
        return self

    # -- helpers
    def _dir(self, path=None):
        node = self.root
        for name in (self.path if path is None else path):
            node = node[self._key(node, name)]
        return node

    @staticmethod
    def _key(node, name):
        for k in node:
            if k.lower() == name.lower():
                return k
        raise ftplib.error_perm("550 %s: no such file or folder" % name)

    # -- ftplib.FTP's interface, as far as the installer uses it
    def connect(self, host, port=21, timeout=None):
        self.commands.append("CONNECT %s:%s" % (host, port))
        if self.fail_connect:
            raise OSError("connection refused")
        self.connected = True

    def login(self, user="", passwd=""):
        self.commands.append("USER %s PASS %s" % (user, passwd))
        if (user, passwd) != ("xboxftp", "xboxftp"):
            raise ftplib.error_perm("530 login incorrect")
        self.logged_in = True

    def set_pasv(self, on):
        pass

    def cwd(self, name):
        self.commands.append("CWD " + name)
        if name == "/":
            self.path = []
            return
        if name == "..":
            if not self.path:
                raise ftplib.error_perm("550 already at the root")
            self.path.pop()
            return
        base = [] if name.startswith("/") else list(self.path)
        for part in [p for p in name.split("/") if p]:
            node = self._dir(base)
            key = self._key(node, part)
            if not isinstance(node[key], dict):
                raise ftplib.error_perm("550 %s is not a folder" % part)
            base.append(key)
        self.path = base

    def mkd(self, name):
        self.commands.append("MKD " + name)
        node = self._dir()
        if not self.path:
            raise ftplib.error_perm("550 cannot create a drive")
        if any(k.lower() == name.lower() for k in node):
            raise ftplib.error_perm("550 %s exists" % name)
        node[name] = {}

    def retrlines(self, cmd, callback=None):
        self.commands.append(cmd)
        assert cmd == "LIST"
        for name, value in sorted(self._dir().items()):
            is_dir = isinstance(value, dict)
            size = 0 if is_dir else len(value)
            if self.list_style == "unix":
                callback("%srwxrwxrwx   1 root  root  %12d Jan 01  2000 %s" % ("d" if is_dir else "-", size, name))
            else:
                callback(name)

    def nlst(self):
        return sorted(self._dir())

    def storbinary(self, cmd, f):
        self.commands.append(cmd)
        assert cmd.startswith("STOR ")
        name = cmd[5:]
        node = self._dir()
        if not self.path:
            raise ftplib.error_perm("550 cannot write at the root")
        existing = [k for k in node if k.lower() == name.lower()]
        node[existing[0] if existing else name] = f.read()

    def retrbinary(self, cmd, callback):
        self.commands.append(cmd)
        assert cmd.startswith("RETR ")
        node = self._dir()
        value = node[self._key(node, cmd[5:])]
        if isinstance(value, dict):
            raise ftplib.error_perm("550 is a folder")
        callback(value)

    def sendcmd(self, cmd):
        self.commands.append(cmd)
        if cmd == "CDUP":
            self.path.pop()
            return "250"
        raise ftplib.error_perm("500 unknown command")

    def quit(self):
        self.closed = True

    def close(self):
        self.closed = True

    # -- for the tests
    def changes(self):
        return [c for c in self.commands if c.split(" ")[0] in ("STOR", "MKD", "DELE", "RMD", "RNFR", "RNTO")]
