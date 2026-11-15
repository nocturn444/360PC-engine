-- Guardado de partidas (love.filesystem). Lua 5.1 / LuaJIT sin JIT.
-- Cada archivo de guardado vive en el pendrive de la consola (l360.save_read / save_write, en
-- <usb>:/love360/guardado/) o, si no hay, en la PC (tftp\love360\balatro\, por TFTP). Tiene dos
-- ranuras (.a y .b) que se escriben por turno. Cada ranura lleva al final una linea de control con
-- un numero de secuencia, el largo y la suma adler32: al leer se usa la ranura valida mas nueva.
-- Si una escritura se corta a la mitad queda la anterior; si las dos estan rotas el archivo se da
-- por inexistente (y se deja una copia .corrupto para mirarla).
-- Detalle en docs/tareas/04_guardado.md.
local M = {}

local PREFIX = 'l360save_'
local TRAILER = '\n--l360save '

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s, 4096 do
    local bytes = {s:byte(i, math.min(i + 4095, #s))}
    for j = 1, #bytes do
      a = a + bytes[j]
      b = b + a
    end
    a, b = a % 65521, b % 65521
  end
  return b * 65536 + a
end
M.adler32 = adler32

-- '1/save.jkr' -> 'l360save_1_save.jkr' (todo plano en una carpeta)
local function remote_name(path)
  return PREFIX .. path:gsub('^%./', ''):gsub('[/\\]', '_'):gsub('[^%w_%.%-]', '-')
end
M.remote_name = remote_name

local function pack(data, seq, deleted)
  return data .. TRAILER .. string.format('%d %d %d %s\n', seq, #data, adler32(data), deleted and 'x' or 'f')
end
M.pack = pack

-- contenido de una ranura -> datos, secuencia, borrado; nil si esta rota
local function unpack_slot(raw)
  local at
  local from = 1
  while true do -- la ultima linea de control (los datos pueden contener el texto)
    local i = raw:find(TRAILER, from, true)
    if not i then break end
    at, from = i, i + 1
  end
  if not at then return nil end
  local seq, len, sum, flag = raw:sub(at + #TRAILER):match('^(%d+) (%d+) (%d+) ([fx])\n$')
  if not seq then return nil end
  local data = raw:sub(1, at - 1)
  if #data ~= tonumber(len) or adler32(data) ~= tonumber(sum) then return nil end
  return data, tonumber(seq), flag == 'x'
end
M.unpack_slot = unpack_slot

-- Donde guardar. choice: el texto de love360/guardado.txt ('pendrive', 'pc' o nada = automatico).
-- Automatico: el pendrive si el ELF lo ofrece y hay USB; si no, la PC por TFTP.
function M.backend(native, choice)
  choice = choice and choice:lower():match('%a+') or 'auto'
  local pc = { get = native.read, put = function(n, d) return native.upload('balatro/' .. n, d) end }
  local pc_where = 'PC over TFTP (tftp\\love360\\balatro\\)'
  if choice == 'pc' then return pc, pc_where .. ', chosen in guardado.txt' end
  local dir = native.save_dir and native.save_dir()
  if dir then
    return { get = native.save_read, put = native.save_write }, 'USB drive (' .. dir .. ')'
  end
  if choice == 'pendrive' then return pc, pc_where .. ': guardado.txt asks for the USB drive but there is none' end
  return pc, pc_where
end

-- backend: tabla con get(nombre) -> datos o nil y put(nombre, datos) -> true si salio bien
-- clock (opcional, segundos): con el, cada escritura anota cuanto tardo armar la ranura (suma de
-- control) y cuanto entregarla al backend (tarea 12: medir los tirones del guardado).
function M.new(backend, log, clock)
  log = log or function() end
  local files = {}  -- ruta -> { data = string o false, seq = n }
  local api = {}

  local function load(path)
    local f = files[path]
    if f then return f end
    local base = remote_name(path)
    local best, broken = nil, nil
    for _, slot in ipairs({'a', 'b'}) do
      local raw = backend.get(base .. '.' .. slot)
      if raw then
        local data, seq, deleted = unpack_slot(raw)
        if data then
          if not best or seq > best.seq then best = { data = not deleted and data, seq = seq } end
        else
          broken = raw
        end
      end
    end
    if broken then
      log('  [save] broken slot in ' .. path .. (best and ' (using the other one)' or ' (treating it as missing)'))
      if not best then backend.put(base .. '.corrupto', broken) end
    end
    f = best or { data = false, seq = 0 }
    files[path] = f
    return f
  end

  local function store(path, data, deleted)
    local f = load(path)
    local seq = f.seq + 1
    f.seq, f.data = seq, not deleted and data
    local name = remote_name(path) .. (seq % 2 == 1 and '.a' or '.b')
    local t0 = clock and clock()
    local slot = pack(deleted and '' or data, seq, deleted)
    local t1 = clock and clock()
    local ok = backend.put(name, slot)
    if not ok then log('  [save] could not write ' .. name .. ' (kept in memory only)') end
    if clock then
      log(string.format('  [save] %s: %d KB, checksum %.0f ms, save_write %.0f ms',
        name, math.floor(#slot / 1024), (t1 - t0) * 1000, (clock() - t1) * 1000))
    end
    return ok
  end

  function api.read(path)
    local d = load(path).data
    return d or nil
  end
  function api.exists(path) return load(path).data ~= false end
  function api.write(path, data) store(path, tostring(data)) return true end
  function api.append(path, data) store(path, (api.read(path) or '') .. tostring(data)) return true end
  function api.remove(path)
    if not api.exists(path) then return false end
    store(path, '', true)
    return true
  end
  function api.isdir(path)
    local pre = path .. '/'
    for p, f in pairs(files) do
      if f.data and p:sub(1, #pre) == pre then return true end
    end
    return false
  end
  return api
end

return M
