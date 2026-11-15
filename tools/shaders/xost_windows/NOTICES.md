# Notices for 360PC-Engine's shader compiler (xost for Windows)

This file lists what ships with `xsc.dll`, `glslang.exe` and the Python bridge.
The build appends **the complete original license texts** below it; this summary
does not replace them. Keep the resulting `THIRD_PARTY_NOTICES.txt` beside the
executables when redistributing the package.

- **xsdk / xost**: https://github.com/xenosworks/xsdk,
  commit `2c4599b31066efcf67be099673287fbec786ef14`, MIT, copyright 2026 Mena.
  `xsc.dll` is built from its sources without patches, and `_xsc_native.py` is an
  unmodified copy of `xenos-toolchain/xsc/native.py`. `build_shaders.py` changes
  `LIBRARY` at run time; xsdk's file is not edited.
- **xsdk's notices**: `THIRD_PARTY_NOTICES.md` is kept whole, including Xenia
  (3-clause BSD), whose layouts xost's encoder follows, and its other sections,
  even where they are not part of this host compiler.
- **glslang-xenon**: https://github.com/xenosworks/glslang-xenon,
  commit `d2f00185cf5feaa449f6e15c1894fb232b2b6bcd`. `LICENSE.txt` is kept whole,
  with its BSD, MIT and Apache licenses and historical notices. 360PC-Engine does
  not change its sources. Do not infer a single license from a summary or remove
  sections of the original text.
- **SPIRV-Tools**, linked into glslang to optimize HLSL:
  https://github.com/KhronosGroup/SPIRV-Tools,
  commit `2ec8457ab33d539b6f1fecc998360c0b8b05ed4f`, Apache-2.0.
- **SPIRV-Headers**, used by SPIRV-Tools:
  https://github.com/KhronosGroup/SPIRV-Headers,
  commit `1a22b167081842915a1c78a0b5b5a353a23284aa`. Its complete license is kept,
  with the per-file exceptions it lists.
- **MinGW/GCC runtime**: static linking does not remove its notices. Whoever
  builds the package adds the texts for their toolchain (MinGW-w64, winpthreads
  if linked, GCC/libgcc/libstdc++ and the GCC Runtime Library Exception). GCC,
  CMake, Ninja and Git are not distributed.

These licenses belong to their respective authors. This package contains no
game sources, shaders, textures, sounds or other game data. 360PC-Engine's own
code is MIT licensed (see `LICENSE`).
