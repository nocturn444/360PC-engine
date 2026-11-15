-- Love360: prueba de numeros del interprete de LuaJIT (la que encontro los errores de GPR64 en la
-- consola, PR #23). Cada cuenta toma sus valores de argumentos, asi el parser no la resuelve antes
-- (con constantes sueltas, 17+3 se vuelve 20 al compilar y no prueba el interprete).
-- En la PC:     luajit -joff tests/console/xsdk_numeros.lua      (tiene que dar 0 mal)
-- En la consola: copiarlo a Love360\balatro\love360\xsdk_numeros.lua; runtime_xsdk/main.c lo corre
-- antes del juego si esta, y deja cada linea en el registro y en pantalla ([ok] o [MAL]).
local log = (l360 and l360.log) or print
local bad, total = 0, 0

local function check(name, got, want)
  total = total + 1
  local ok = got == want or (type(got) == "number" and type(want) == "number" and got ~= got and want ~= want)
  if not ok then bad = bad + 1 end
  log(string.format("%s %s = %s (esperado %s)", ok and "[ok] " or "[MAL]", name, tostring(got), tostring(want)))
end

local function run(o, one, big, neg, half, s, k3, k1000)
  -- constantes enteras del bytecode (KSHORT/KNUM y las VN)
  check("o+3 (o=17)", o + 3, 20)
  check("o-3", o - 3, 14)
  check("o*256+5", o * 256 + 5, 4357)
  check("1.5*1000 (con variable)", half * 3 * k1000, 1500)
  check("o*1000", o * 1000, 17000)
  check("10/4", (o - 7) / 4, 2.5)
  check("1/3 * 3", one / 3 * 3, 1)
  check("7%3", (o - 10) % 3, 1)
  check("-7%3", (10 - o) % 3, 2)
  check("-5-3", -5 - k3, -8)
  check("k3 == 3", k3 == 3, true)
  check("k1000 == 1000", k1000 == 1000, true)
  -- desbordes de enteros: tienen que pasar a double, no dar la vuelta
  check("2147483647+1", big + one, 2147483648)
  check("-2147483648-1", neg - one, -2147483649)
  check("65536*65536", (big + one) / 32768 * 65536, 4294967296)
  check("65536*65536 (enteros)", (o - 17 + 65536) * 65536, 4294967296)
  check("-(-2147483648)", -neg, 2147483648)
  local n = 0
  for _ = big - 2, big + 1 do n = n + 1 end   -- el indice desborda en la ultima vuelta
  check("for de 2147483645 a 2147483648 (vueltas)", n, 4)
  local acc = 0
  for i = 1, 1000 do acc = acc + i end
  check("suma 1..1000", acc, 500500)
  -- numeros a enteros en C (lj_vm_num2int_check): claves de tablas, string.byte/sub, lexer
  local t = {}
  t[k3] = "tres"
  check("t[3.0] es t[3]", t[3.0], "tres")
  local arr = { 10, 20, 30 }
  check("#{10,20,30}", #arr, 3)
  check("ipairs de {10,20,30}", (function() local c = 0 for _ in ipairs(arr) do c = c + 1 end return c end)(), 3)
  check("byte(s, o-16, o-13) cuenta", select("#", s:byte(o - 16, o - 13)), 4)
  check("sub(2,3)", s:sub(2, 3), "el")
  check("tonumber('1000')", tonumber("1000"), 1000)
  check("tonumber('3') + 1", tonumber("3") + one, 4)
  -- numeros a 64 bits en C (lj_vm_num2i64/num2u64): string.format
  check("format %d de 42", string.format("%d", o + 25), "42")
  check("format %d de 3e9", string.format("%d", 3e9), "3000000000")
  check("format %x de 255", string.format("%x", o + 238), "ff")
  check("format %.0f", string.format("%.0f", 1234.4), "1234")
  check("floor(2.7)", math.floor(half + 2.2), 2)
  check("floor(-2.5)", math.floor(-half - 2), -3)
  check("sqrt(16)", math.sqrt(o - 1), 4)
  check("2^10", 2 ^ (o - 7), 1024)
  check("tostring(o)", tostring(o), "17")
  check("bit.band(0xff0, 0x0ff)", bit and bit.band(4080, 255 + o - 17) or 240, 240)
end

run(17, 1, 2147483647, -2147483648, 0.5, "hello", 3, 1000)
log(string.format("== numeros: %d de %d mal ==", bad, total))
return bad
