# xost for Windows x64

The shader compiler that `tools/shaders/build_shaders.py` runs on the developer's PC: xsdk's
xost compiler (`xsc.dll`), glslang-xenon (`glslang.exe`) and xsdk's Python bridge
(`_xsc_native.py`). Brought over from Love360. Build it once; the output folder is what
`build_shaders.py --tools <folder>` takes. Using it needs only standard 64-bit Python (3.9 or
later): no shell, pip, XNA, WSL, network or installed xsdk. The whole shader flow is in
[docs/SHADERS.md](../../../docs/SHADERS.md).

## Building from Linux (or WSL)

Dependencies: `mingw-w64`, CMake 3.25 or later, Ninja, Git and Python 3.11 or later. Get the
sources once (no Xbox toolchain needed):

```sh
git clone https://github.com/xenosworks/xsdk.git xsdk
git -C xsdk checkout 2c4599b31066efcf67be099673287fbec786ef14
git clone https://github.com/xenosworks/glslang-xenon.git glslang-xenon
git -C glslang-xenon checkout d2f00185cf5feaa449f6e15c1894fb232b2b6bcd
(cd glslang-xenon && python3 update_glslang_sources.py)
TOOLCHAIN_NOTICES=/path/to/mingw-gcc-notices bash tools/shaders/xost_windows/build.sh /path/to/xsdk /path/to/glslang-xenon /path/to/output /path/to/build
```

The build downloads nothing. It checks the revisions (xsdk's is the one in
`runtime/XSDK_VERSION`), rejects modified sources, takes `XSC_SOURCES` and `XSC_HEADERS` from
xsdk's Makefile and computes `XSC_VERSION` exactly as xsdk does (SHA-256 of sources and headers
without CR, first 16 characters). `CC`, `CXX` and `JOBS` change the MinGW compilers and the
parallelism.

glslang is built with **`ENABLE_OPT=ON`**: SPIRV-Tools inlines HLSL functions and removes local
variables, and xost rejects the SPIR-V without that step. The SPIRV-Tools and SPIRV-Headers
revisions come from the pinned glslang's `known_good.json` and are checked before building.

The output folder holds `xsc.dll`, a statically linked `glslang.exe`, xsdk's `_xsc_native.py`
**unmodified**, `THIRD_PARTY_NOTICES.txt` and `versions.json` (revisions and SHA-256). Copy that
folder to the Windows PC as it is; do not ship the build folder.

For tools that run on Linux instead (`libxsc.so` and `glslang`, which `build_shaders.py` uses the
same way), call `build.py` with `--native --cc gcc --cxx g++` and the same other arguments.
Compare the `.psu`/`.vsu` files between platforms, not the DLL against the `.so`.

## Notices to distribute

The build writes **`THIRD_PARTY_NOTICES.txt` beside the DLL and EXE**: [NOTICES.md](NOTICES.md)
followed by the complete original texts of xsdk's MIT license and `THIRD_PARTY_NOTICES.md`,
glslang's license, SPIRV-Tools' Apache-2.0 and SPIRV-Headers' license, keeping any NOTICE files.
`versions.json` records its SHA-256. Keep it with the tools if you pass them on. None of this
code is in this repository or in a game's package: only the compiled shaders are.

`TOOLCHAIN_NOTICES` must be a folder with the notices of the statically linked runtime: MinGW-w64
(including winpthreads if linked), GCC (GPL-3) and the **GCC Runtime Library Exception** for
libgcc/libstdc++. Take them from the same toolchain you build with. On Debian, see the
`copyright` files of the mingw/gcc packages in `/usr/share/doc/` and
`/usr/share/common-licenses/GPL-3`; with w64devkit, include `COPYING.MinGW-w64-runtime.txt` plus
`COPYING3` and `COPYING.RUNTIME` from its GCC. The script requires the folder and rejects empty
files, but cannot decide whether the notices you provide are complete.

## Tests

`python3 -m unittest discover -s tests/shaders` (from the repository root) covers the translator
and the notices file; it needs neither these tools nor Windows.
