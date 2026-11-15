# 360PC-Engine third-party notices

Keep this file **beside every `.xex` built with the base** (the packaging script will place it
there). xsdk requires notices "in its documentation, or in a notices file beside the `.xex`".

The license texts below are **copied in full from their sources**, without abridgement:

| Section | Source |
|---|---|
| 1 | 360PC-Engine `LICENSE` (repository root). The console runtime starts from Love360 (`nocturn444/love360-xbox360`, commit `e46bc8f`), under the same MIT license and copyright holder. |
| 2 | xsdk `LICENSE`, commit `2c4599b31066efcf67be099673287fbec786ef14` (`runtime/XSDK_VERSION`) |
| 3 | xsdk `THIRD_PARTY_NOTICES.md`, same commit |
| 4 | LuaJIT `COPYRIGHT`, commit `a4c064539ea931274d407e1249b4bb575424a0f4` (`toolchain/build_luajit_xsdk.sh`) |
| 5 | End of `runtime/third_party/stb/stb_image.h` (v2.30) and `stb_truetype.h` (v1.26) |
| 6 | Header of LÖVE's `src/modules/graphics/ParticleSystem.cpp`, tag `11.5` (https://github.com/love2d/love) |

Update these full texts when updating xsdk, LuaJIT, stb or the code adapted from LÖVE. Third-party Lua libraries in `lib/`
will be added here as they are copied in (objective 8).

## 1. 360PC-Engine (MIT)

```
MIT License

Copyright (c) 2026 nocturn4

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. xsdk (MIT)

Every `.xex` built with the base is an xsdk title: it is built with xsdk (https://github.com/xenosworks/xsdk), the
base of the executable.

```
MIT License

Copyright (c) 2026 Mena

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 3. libXenon and Xenia, as reproduced by xsdk (3-clause BSD)

Full text of xsdk's `THIRD_PARTY_NOTICES.md`:

# Third-party notices

xsdk is under the MIT licence (LICENSE). A few of its files carry code from other projects under their own licences,
and those files keep their notices.

## In every title built with xsdk

`libxsdk.a` includes code from libxenon and from Xenia, both under the 3-clause BSD licence, which asks that a program
distributed as a binary carry the notice in its documentation. A game or homebrew title built with xsdk meets that by
shipping this section with it: in its documentation, or in a notices file beside the `.xex`.

### libxenon

In `src/gpu_draw.c`, `src/gpu_resolve.c`, `src/gpu_setup.c`, `src/shader.c` and `src/texture.c`, from libxenon's
`drivers/xenos/xe.c`.

```
Copyright (c) 2009, free60.org
USB Stack Copyright (c) 2000,2001,2002,2003,2005, Broadcom Corporation

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the copyright holder nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY free60.org ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL free60.org BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE
```

### Xenia

In `src/texture_layout.c` and `src/tiled.c`, from Xenia's `src/xenia/gpu/texture_util.cc`, `texture_util.h` and
`texture_address.h`.
xost's shader encoder (`src/xsc_*.c`) also follows the instruction layouts in Xenia's microcode definitions.

```
Copyright (c) 2015, Ben Vanik.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the project nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL BEN VANIK BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## In titles that draw text, needing no notice

`assets/fonts/10x20.bdf`, and `src/text_font.h` that tools/gen_font.py generates from it, which `libxsdk.a` links into
a title that calls `text.h`: X11's misc-fixed 10x20, Markus Kuhn's ISO 10646 font, as X.Org's font-misc-misc 1.1.3
release ships it (https://www.x.org/releases/individual/font/font-misc-misc-1.1.3.tar.xz). It's in the public domain:
its COPYRIGHT property and the release's COPYING read "Public domain font.  Share and enjoy." A title ships nothing for
it.

## In the repository only

Not linked into titles, so nothing for a game to ship:

- `tests/tiled_index.h` and `tests/probe_display.c`: `tiled_index` from libxenon's `drivers/console/console.c`,
  copyright 2009 Georg Lukas, under the 3-clause BSD licence; the files carry the notice.
- `xenos-toolchain/xdis/xenos_ucode.py`: transcribed from Xenia's microcode definitions, under Xenia's licence above;
  the file carries the notice.

## The toolchain

`tools/toolchain/` builds GCC, binutils and newlib, and its patches change those projects, so the patches are under
their licences: GCC's and binutils' GPL version 3 or later, and newlib's own licences (its `COPYING.NEWLIB`). Building
a title with the toolchain doesn't put the title under the GPL: GCC's runtime library exception covers the libgcc and
libstdc++ code linked into it. newlib's C library, also linked into every title, is under the permissive licences
listed in its `COPYING.NEWLIB`.

## 4. LuaJIT 2.1 (MIT), Lua 5.1/5.2 and dlmalloc

Every `.xex` includes the LuaJIT 2.1 interpreter. Full `COPYRIGHT` text:

```
===============================================================================
LuaJIT -- a Just-In-Time Compiler for Lua. https://luajit.org/

Copyright (C) 2005-2026 Mike Pall. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

[ MIT license: https://www.opensource.org/licenses/mit-license.php ]

===============================================================================
[ LuaJIT includes code from Lua 5.1/5.2, which has this license statement: ]

Copyright (C) 1994-2012 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

===============================================================================
[ LuaJIT includes code from dlmalloc, which has this license statement: ]

This is a version (aka dlmalloc) of malloc/free/realloc written by
Doug Lea and released to the public domain, as explained at
https://creativecommons.org/licenses/publicdomain

===============================================================================
```

## 5. stb_image v2.30 and stb_truetype v1.26 (MIT, alternative A)

`runtime/l360_gfx.c` includes stb_image and stb_truetype in the `.xex`.
360PC-Engine chooses **alternative A (MIT)**. Full text (identical in both files):

```
------------------------------------------------------------------------------
This software is available under 2 licenses -- choose whichever you prefer.
------------------------------------------------------------------------------
ALTERNATIVE A - MIT License
Copyright (c) 2017 Sean Barrett
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
```

## 6. LÖVE 11.5 (zlib)

`runtime/l360_particles.c`, the particle simulation behind `love.graphics.newParticleSystem`, is
adapted from LÖVE's `ParticleSystem.cpp`, rewritten in C with a different random generator and
fixed limits. It is an altered version, not the original software. No other LÖVE code is in the
runtime.

```
/**
 * Copyright (c) 2006-2023 LOVE Development Team
 *
 * This software is provided 'as-is', without any express or implied
 * warranty.  In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 **/
```
