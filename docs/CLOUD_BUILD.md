# Cloud build

`.github/workflows/console.yml` builds a game's whole console folder on GitHub Actions, with no
developer PC: the xsdk toolchain (GCC for `powerpc-xsdk-elf`), xsdk, LuaJIT for xsdk, the
`.xex`, the shaders (xost for Linux) and the package, with each `.ogg` converted to the
console's PCM / IMA ADPCM WAV files. Everything comes from open sources; no Microsoft SDK.

The same steps run on any Ubuntu 24.04 machine or WSL with `tools/ci/build_console.sh`:

```sh
tools/ci/build_console.sh examples/rooms dist      # dist/rooms_demo/ and dist/rooms_demo.zip
tools/ci/build_console.sh --tools-only             # only the toolchain, xost and xsdk
```

The header of the script lists the packages it needs. `CI_CACHE` (default
`~/.cache/360pc-ci`) holds the toolchain, xsdk and xost between runs.

## Running it

- **Manual run:** Actions tab, "Console build", "Run workflow": pick the branch, the game
  folder (default `examples/rooms`) and whether it is a release build.
- **On push:** pushes to `main` build `examples/rooms`. Changes to Markdown and `docs/` alone do not start a build.

The result is an artifact named `<identity>-console` on the run's page (kept 30 days): a zip
of the folder that goes to `Hdd1:/Games/<identity>/` on the console, `default.xex` included.

## Time and cost

The first run builds the toolchain: about an hour on GitHub's 4-core runner. It is cached
(`actions/cache`, keyed by `runtime/XSDK_VERSION` and the build scripts) and saved as soon as
it is built, so later runs take a few minutes. GitHub shares caches from `main` with every
branch, but not between sibling branches: a branch reuses the toolchain once `main` has built
it. The repository is private, so runs count against the account's Actions
minutes.

## Getting it onto the console

The console's FTP server (Aurora) is on the home network, which GitHub cannot reach. Ways to
install the artifact, safest first:

1. **A phone or tablet on the same Wi-Fi:** download the artifact from the run's page, unzip
   it, and upload the folder with any FTP app to `Hdd1:/Games/<identity>/` (Aurora's FTP
   user and password, usually `xboxftp` / `xboxftp`).
2. **Android/Termux, or a device that stays on at home** (Raspberry Pi, old laptop): run
   `python3 tools/deploy_android.py <game> [--branch NAME]`. It pulls the branch, downloads the
   newest successful artifact of that branch with the GitHub CLI (`gh auth login`) and uploads
   it with `tools/install_ftp.py` in safe mode (one connection per file, size checked), using
   `deploy.local.ini`; only the changed files are uploaded. `--no-upload` downloads it only.
   See [DEPLOY.md](DEPLOY.md).
3. **A self-hosted runner or a VPN** (for example Tailscale on that same home device) lets the
   workflow upload to the console itself. It needs that device anyway, plus a secret token.
4. **Opening the console's FTP to the internet** (port forwarding) is not recommended: FTP
   sends the password in clear text and Aurora's server is not built to face the internet.
