# 360PC-Engine third-party notices

Keep this file **beside every `.xex` built with the base** (the packaging script will place it
there). xsdk requires notices "in its documentation, or in a notices file beside the `.xex`".

The license texts below are **copied in full from their sources**, without abridgement:

| Section | Source |
|---|---|
| 1 | 360PC-Engine `LICENSE` (repository root). The console runtime starts from Love360 (`nocturn444/love360-xbox360`, commit `e46bc8f`), under the same MIT license and copyright holder; so does the music chunk splitter in `tools/audio_convert.py` (Love360's `herramientas/pc/partir_musica.py`). ffmpeg, which that tool runs, is not part of this repository or of any package. |
| 2 | xsdk `LICENSE`, commit `2c4599b31066efcf67be099673287fbec786ef14` (`runtime/XSDK_VERSION`) |
| 3 | xsdk `THIRD_PARTY_NOTICES.md`, same commit |
| 4 | LuaJIT `COPYRIGHT`, commit `a4c064539ea931274d407e1249b4bb575424a0f4` (`toolchain/build_luajit_xsdk.sh`) |
| 5 | End of `runtime/third_party/stb/stb_image.h` (v2.30) and `stb_truetype.h` (v1.26) |
| 6 | Header of LÖVE's `src/modules/graphics/ParticleSystem.cpp`, tag `11.5` (https://github.com/love2d/love) |
| 7 | anim8 `MIT-LICENSE.txt`, tag `v2.3.1`, commit `c1c12ec45fde28ffd2d6967675adcb3c3e501fa7` (https://github.com/kikito/anim8), copied to `lib/anim8/` |
| 8 | bump.lua `MIT-LICENSE.txt`, tag `v3.1.7`, commit `72d6b13dfa525564f6e1a533d71eaa8235a5e96c` (https://github.com/kikito/bump.lua), copied to `lib/bump/` |
| 9 | AndroidX WebKit `1.12.1` (Apache-2.0), used only by the Android room editor app in `android/room_editor/`; it is not part of any `.xex` |

Update these full texts when updating xsdk, LuaJIT, stb, the code adapted from LÖVE or a library in `lib/`. Each third-party Lua library in `lib/`
is listed here with its pinned commit; `tools/check_libs.lua` checks it (objective 16).

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

## 7. anim8 v2.3.1 (MIT)

`lib/anim8/anim8.lua`, unchanged from tag `v2.3.1` (commit
`c1c12ec45fde28ffd2d6967675adcb3c3e501fa7`). Only in games that use animations (`engine.anim`).

```
Copyright (c) 2011 Enrique García Cota

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## 8. bump.lua v3.1.7 (MIT)

`lib/bump/bump.lua`, unchanged from tag `v3.1.7` (commit
`72d6b13dfa525564f6e1a533d71eaa8235a5e96c`). Only in games that use the platformer module
(`engine/modules/platformer`).

```
Copyright (c) 2012 Enrique García Cota

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## 9. AndroidX WebKit 1.12.1 (Apache-2.0)

`androidx.webkit:webkit:1.12.1`, declared in `android/room_editor/app/build.gradle`. It is used
only by the Android room editor app (`android/room_editor/`) for `WebViewAssetLoader`; it is not
distributed with any game or `.xex`.

```
Copyright (C) 2015 The Android Open Source Project

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

Apache License
Version 2.0, January 2004
http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

"License" shall mean the terms and conditions for use, reproduction, and distribution as defined
by Sections 1 through 9 of this document.

"Licensor" shall mean the copyright owner or entity authorized by the copyright owner that is
granting the License.

"Legal Entity" shall mean the union of the acting entity and all other entities that control, are
controlled by, or are under common control with that entity. For the purposes of this definition,
"control" means (i) the power, direct or indirect, to cause the direction or management of such
entity, whether by contract or otherwise, or (ii) ownership of fifty percent (50%) or more of the
outstanding shares, or (iii) beneficial ownership of such entity.

"You" (or "Your") shall mean an individual or Legal Entity exercising permissions granted by this
License.

"Source" form shall mean the preferred form for making modifications, including but not limited to
software source code, documentation source, and configuration files.

"Object" form shall mean any form resulting from mechanical transformation or translation of a
Source form, including but not limited to compiled object code, generated documentation, and
conversions to other media types.

"Work" shall mean the work of authorship, whether in Source or Object form, made available under
the License, as indicated by a copyright notice that is included in or attached to the work (an
example is provided in the Appendix below).

"Derivative Works" shall mean any work, whether in Source or Object form, that is based on (or
derived from) the Work and for which the editorial revisions, annotations, elaborations, or other
modifications represent, as a whole, an original work of authorship. For the purposes of this
License, Derivative Works shall not include works that remain separable from, or merely link (or
bind by name) to the interfaces of, the Work and Derivative Works thereof.

"Contribution" shall mean any work of authorship, including the original version of the Work and
any modifications or additions to that Work or Derivative Works thereof, that is intentionally
submitted to Licensor for inclusion in the Work by the copyright owner or by an individual or
Legal Entity authorized to submit on behalf of the copyright owner. For the purposes of this
definition, "submitted" means any form of electronic, verbal, or written communication sent to the
Licensor or its representatives, including but not limited to communication on electronic mailing
lists, source code control systems, and issue tracking systems that are managed by, or on behalf
of, the Licensor for the purpose of discussing and improving the Work, but excluding communication
that is conspicuously marked or otherwise designated in writing by the copyright owner as "Not a
Contribution."

"Contributor" shall mean Licensor and any individual or Legal Entity on behalf of whom a
Contribution has been received by Licensor and subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of this License, each
Contributor hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free,
irrevocable copyright license to reproduce, prepare Derivative Works of, publicly display,
publicly perform, sublicense, and distribute the Work and such Derivative Works in Source or
Object form.

3. Grant of Patent License. Subject to the terms and conditions of this License, each Contributor
hereby grants to You a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable
(except as stated in this section) patent license to make, have made, use, offer to sell, sell,
import, and otherwise transfer the Work, where such license applies only to those patent claims
licensable by such Contributor that are necessarily infringed by their Contribution(s) alone or
by combination of their Contribution(s) with the Work to which such Contribution(s) was submitted.
If You institute patent litigation against any entity (including a cross-claim or counterclaim in
a lawsuit) alleging that the Work or a Contribution incorporated within the Work constitutes
direct or contributory patent infringement, then any patent licenses granted to You under this
License for that Work shall terminate as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the Work or Derivative Works thereof
in any medium, with or without modifications, and in Source or Object form, provided that You meet
the following conditions:

(a) You must give any other recipients of the Work or Derivative Works a copy of this License; and

(b) You must cause any modified files to carry prominent notices stating that You changed the
files; and

(c) You must retain, in the Source form of any Derivative Works that You distribute, all
copyright, patent, trademark, and attribution notices from the Source form of the Work, excluding
those notices that do not pertain to any part of the Derivative Works; and

(d) If the Work includes a "NOTICE" text file as part of its distribution, then any Derivative
Works that You distribute must include a readable copy of the attribution notices contained within
such NOTICE file, excluding those notices that do not pertain to any part of the Derivative Works,
in at least one of the following places: within a NOTICE text file distributed as part of the
Derivative Works; within the Source form or documentation, if provided along with the Derivative
Works; or, within a display generated by the Derivative Works, if and wherever such third-party
notices normally appear. The contents of the NOTICE file are for informational purposes only and
do not modify the License. You may add Your own attribution notices within Derivative Works that
You distribute, alongside or as an addendum to the NOTICE text from the Work, provided that such
additional attribution notices cannot be construed as modifying the License.

You may add Your own copyright statement to Your modifications and may provide additional or
different license terms and conditions for use, reproduction, or distribution of Your
modifications, or for any such Derivative Works as a whole, provided Your use, reproduction, and
distribution of the Work otherwise complies with the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise, any Contribution
intentionally submitted for inclusion in the Work by You to the Licensor shall be under the terms
and conditions of this License, without any additional terms or conditions. Notwithstanding the
above, nothing herein shall supersede or modify the terms of any separate license agreement you
may have executed with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade names, trademarks, service
marks, or product names of the Licensor, except as required for reasonable and customary use in
describing the origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or agreed to in writing, Licensor
provides the Work (and each Contributor provides its Contributions) on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied, including, without limitation,
any warranties or conditions of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
PARTICULAR PURPOSE. You are solely responsible for determining the appropriateness of using or
redistributing the Work and assume any risks associated with Your exercise of permissions under
this License.

8. Limitation of Liability. In no event and under no legal theory, whether in tort (including
negligence), contract, or otherwise, unless required by applicable law (such as deliberate and
grossly negligent acts) or agreed to in writing, shall any Contributor be liable to You for
damages, including any direct, indirect, special, incidental, or consequential damages of any
character arising as a result of this License or out of the use or inability to use the Work
(including but not limited to damages for loss of goodwill, work stoppage, computer failure or
malfunction, or any and all other commercial damages or losses), even if such Contributor has
been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing the Work or Derivative Works
thereof, You may choose to offer, and charge a fee for, acceptance of support, warranty, indemnity,
or other liability obligations and/or rights consistent with this License. However, in accepting
such obligations, You may act only on Your own behalf and on Your sole responsibility, not on
behalf of any other Contributor, and only if You agree to indemnify, defend, and hold each
Contributor harmless for any liability incurred by, or claims asserted against, such Contributor by
reason of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

APPENDIX: How to apply the Apache License to your work.

To apply the Apache License to your work, attach the following boilerplate notice, with the fields
enclosed by brackets "[]" replaced with your own identifying information. (Do not include the
brackets!) The text should be enclosed in the appropriate comment syntax for the file format. We
also recommend that a file or class name and description of purpose be included on the same
"printed page" as the copyright notice for easier identification within third-party archives.

```
Copyright [yyyy] [name of copyright owner]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
