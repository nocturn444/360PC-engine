# tests/

| Path | What it is |
|---|---|
| `console/xsdk_numeros.lua` | LuaJIT interpreter number check (from Love360). Run on PC with `luajit -joff tests/console/xsdk_numeros.lua`; on the console the log has to end with `== numeros: 0 de 36 mal ==`. |

PC tests for the runtime with a fake xsdk GPU, audio and file system (from Love360's
`pruebas/`) will be brought in with objective 2, once the runtime no longer depends on Balatro.
