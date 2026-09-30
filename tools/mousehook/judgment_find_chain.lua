--=============================================================================
-- Gears of War: Judgment (Xbox 360 / Xenia mousehook)
-- Поиск языко-независимой цепочки указателей на объект камеры.
--
-- ЗАПУСКАТЬ НА АНГЛИЙСКОЙ ВЕРСИИ TU0 (той, где мышь сейчас работает),
-- НАХОДЯСЬ В ИГРЕ - не в меню, камера должна существовать.
--
-- ЗАЧЕМ: default.xex у английской и русской версии одинаковый (сравни
-- "Module Hash" в логе Xenia), а раскладка кучи (0x40000000-0x50000000)
-- отличается из-за файлов локализации. Адрес слота камеры 0x448F2840 -
-- это адрес в куче, поэтому на русской версии он невалиден. Зато все
-- статические адреса внутри образа default.xex общие. Скрипт ищет цепочку
-- "статический слот -> ... -> слот с указателем на камеру", которую затем
-- можно использовать на любой языковой версии.
--
-- КАК РАБОТАЕТ: ищет от слота камеры назад. Сначала находятся все слоты,
-- которые содержат указатель на камеру, потом все слоты, которые ведут на
-- объект-владелец такого слота, и так далее, пока цепочка не упрётся в
-- статический адрес внутри default.xex.
--
-- РЕЗУЛЬТАТ выглядит так:
--   root=0x8358ABEA  chain: {0x4A0, 0x0, 0x40}
-- и вставляется в supported_builds (GearsOfWars.cc) как:
--   gengine_address = 0x8358ABEA, chain_offset_1 = 0x4A0,
--   chain_offset_2 = 0x0, chain_offset_3 = 0x40
-- Цепочки короче 3 хопов дополняются 0xFFFFFFFF (см. ResolvePointerChain).
--
-- Для TU4 поменяй CAM_SLOT на 0x42943440 и IMG_STOP по её логу загрузки.
--=============================================================================

local BASE = 0x100000000   -- смещение гостевой памяти в процессе Xenia

-- Адрес слота, в котором на английской TU0 лежит указатель на камеру
local CAM_SLOT = 0x448F2840
-- Образ default.xex: Load Address + Image Size из лога загрузки модуля
local IMG_START = 0x82000000
local IMG_STOP = 0x836B0000   -- 0x82000000 + 0x16B0000
-- Куча, которую просматриваем (тот же диапазон, что проверяет хук)
local HEAP_START = 0x40000000
local HEAP_STOP = 0x50000000

-- Насколько далеко от слота искать владельца/предыдущий объект
local O1_MAX = 0x1000   -- смещение внутри объекта 1-го уровня
local O2_MAX = 0x400    -- ... 2-го уровня
local O3_MAX = 0x400    -- ... 3-го уровня (от объекта до слота камеры)

local SCAN_CHUNK = 0x100000
local MAX_A3 = 100      -- до 100 слотов с камерой; в EN TU0 было около 75
local MAX_A2 = 40       -- сколько слотов на уровень разбирать
local MAX_PRINT = 40

-- В GoW3 найденный статический GEngine root лежал в этом диапазоне; это
-- только эвристика для ранжирования Judgment-кандидатов, не жёсткий фильтр.
local LIKELY_GENGINE_START = 0x83400000
local LIKELY_GENGINE_STOP = 0x83480000

local NO_MORE = 0xFFFFFFFF

local cam = nil
local chains = {}
local seen_chains = {}

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function rd32(a)
  local b = readBytes(a, 4, true)
  if not b then return nil end
  return ((b[1]*256 + b[2])*256 + b[3])*256 + b[4]
end

local function isHeap(v) return v and v >= 0x40000000 and v < 0x50000000 end
local function isStatic(v) return v and v >= IMG_START and v < IMG_STOP end

local function copyOffs(offs)
  local t = {}
  for i = 1, #offs do t[i] = offs[i] end
  return t
end

local function fmtOffs(offs)
  local parts = {}
  for i = 1, #offs do
    if offs[i] == NO_MORE then
      parts[i] = "-"
    else
      parts[i] = string.format("0x%X", offs[i])
    end
  end
  return table.concat(parts, ", ")
end

-- Дополняет цепочку sentinel'ами до 3 элементов (формат supported_builds)
local function padOffs(offs)
  local t = copyOffs(offs)
  while #t < 3 do t[#t+1] = NO_MORE end
  return t
end

-- Резолв ровно как ResolvePointerChain в GearsOfWars.cc
local function resolveChain(root, offs)
  local a = root
  for i = 1, #offs do
    if offs[i] == NO_MORE then break end
    if a < 0x40000000 or a >= 0x90000000 then return nil end
    local v = rd32(BASE + a)
    if not v then return nil end
    if v < 0x40000000 or v >= 0x50000000 then return nil end
    a = v + offs[i]
  end
  return a
end

-- Цепочек может быть тысячи: почти все - варианты одного и того же пути
-- через одни и те же объекты. Оставляем по одной на уникальный путь.
local seen_paths = {}
local function addChain(root, offs)
  local key = string.format("%08X", root)
  for i = 1, #offs do key = key .. "_" .. string.format("%X", offs[i]) end
  if seen_chains[key] then return end
  seen_chains[key] = true
  local slot = resolveChain(root, offs)
  if not slot then return end
  if rd32(BASE + slot) ~= cam then return end
  -- Сохраняем отдельный вариант для каждого статического root и конечного
  -- слота: разные globals/поля могут совпадать в EN, но различаться на RU.
  -- Внутри одного root и одного конечного слота схлопываем дубликаты по
  -- объектам, без смещений.
  local path = string.format("root=%08X|slot=%08X|", root, slot)
  local a = root
  for i = 1, #offs do
    if offs[i] == NO_MORE then break end
    local v = rd32(BASE + a)
    if not v then return end
    path = path .. string.format("%08X>", v)
    a = v + offs[i]
  end
  if seen_paths[path] then return end
  seen_paths[path] = true
  chains[#chains+1] = {root = root, offs = copyOffs(offs), slot = slot}
end

local function yield_ui()
  if sleep then pcall(sleep, 0) end
end

---------------------------------------------------------------------------
-- Сканирование диапазона: все 4-байтные слоты, значение которых попадает
-- в окно [wstart, wend). Фильтр по первому байту, чтобы не разбирать всё.
---------------------------------------------------------------------------
local function scanWindow(wstart, wend, start, stop)
  local res = {}
  if wend <= wstart then return res end
  local first_bytes = {}
  for a = wstart, wend - 4, 4 do
    first_bytes[math.floor(a / 0x1000000)] = true
  end
  local addr = start
  while addr < stop do
    local len = math.min(SCAN_CHUNK, stop - addr)
    local b = readBytes(BASE + addr, len, true)
    if b then
      local n = #b
      local i = 1
      while i <= n - 3 do
        local fb = b[i]
        if first_bytes[fb] then
          local v = ((fb*256 + b[i+1])*256 + b[i+2])*256 + b[i+3]
          if v >= wstart and v < wend then
            res[#res+1] = {slot = addr + i - 1, val = v}
          end
        end
        i = i + 4
      end
    end
    addr = addr + len
    yield_ui()
  end
  return res
end

---------------------------------------------------------------------------
-- Обратный поиск от слота A3 (слот, содержащий указатель на камеру)
---------------------------------------------------------------------------
local static_by_val = {}

-- Одним проходом сканирует кучу сразу для многих узких окон значений.
-- Старый scanWindow перечитывал все 256 MiB кучи отдельно для каждого A1,
-- что превращало 75 слотов * 40 A2 в тысячи полных проходов.
local function scanManyWindows(windows, start, stop)
  if #windows == 0 then return end
  local buckets = {}
  local bucket_size = 0x1000
  for i = 1, #windows do
    local w = windows[i]
    w.hits = {}
    local first_bucket = math.floor(w.wstart / bucket_size)
    local last_bucket = math.floor((w.wend - 1) / bucket_size)
    for bucket = first_bucket, last_bucket do
      local list = buckets[bucket]
      if not list then list = {} buckets[bucket] = list end
      list[#list+1] = w
    end
  end

  local addr = start
  while addr < stop do
    local len = math.min(SCAN_CHUNK, stop - addr)
    local b = readBytes(BASE + addr, len, true)
    if b then
      local n = #b
      local i = 1
      while i <= n - 3 do
        local v = ((b[i]*256 + b[i+1])*256 + b[i+2])*256 + b[i+3]
        if isHeap(v) then
          local list = buckets[math.floor(v / bucket_size)]
          if list then
            local slot = addr + i - 1
            for j = 1, #list do
              local w = list[j]
              if v >= w.wstart and v < w.wend then
                w.hits[#w.hits+1] = {slot = slot, val = v}
              end
            end
          end
        end
        i = i + 4
      end
    end
    addr = addr + len
    yield_ui()
  end
end

local function addOneHopRoots(A3)
  if isStatic(A3) then addChain(A3, {}) end
  for p3 = A3 - O3_MAX, A3, 4 do
    local roots = static_by_val[p3]
    if roots then
      for i = 1, #roots do addChain(roots[i], {A3 - p3}) end
    end
  end
end

---------------------------------------------------------------------------
-- main
---------------------------------------------------------------------------
cam = rd32(BASE + CAM_SLOT)
if not isHeap(cam) then
  print("!!! Слот " .. string.format("%08X", CAM_SLOT) ..
        " не содержит указателя на кучу (" .. tostring(cam) .. ").")
  print("    Запущено на английской TU0? Ты в игре, а не в меню?")
  return
end
print(string.format("camera object = %08X", cam))

-- собираем статические слоты образа default.xex
print("сканирую образ default.xex " .. string.format("%08X-%08X", IMG_START, IMG_STOP))
local statics_count = 0
local addr = IMG_START
while addr < IMG_STOP do
  local len = math.min(SCAN_CHUNK, IMG_STOP - addr)
  local b = readBytes(BASE + addr, len, true)
  if b then
    local n = #b
    local i = 1
    while i <= n - 3 do
      local v = ((b[i]*256 + b[i+1])*256 + b[i+2])*256 + b[i+3]
      if isHeap(v) then
        statics_count = statics_count + 1
        local lst = static_by_val[v]
        if not lst then lst = {} static_by_val[v] = lst end
        lst[#lst+1] = addr + i - 1
      elseif v == cam then
        addChain(addr + i - 1, {})
      end
      i = i + 4
    end
  end
  addr = addr + len
  yield_ui()
end
print(string.format("статических слотов с указателем на кучу: %d", statics_count))

-- все слоты, содержащие указатель на камеру
print("ищу слоты с указателем на камеру в куче...")
local a3list = scanWindow(cam, cam + 4, HEAP_START, HEAP_STOP)
print(string.format("найдено слотов с камерой: %d", #a3list))

-- известный слот 0x448F2840 разбираем первым: цепочка до него самая
-- "каноничная" (её же использует английская версия)
table.sort(a3list, function(x, y)
  if (x.slot == CAM_SLOT) ~= (y.slot == CAM_SLOT) then
    return x.slot == CAM_SLOT
  end
  return x.slot < y.slot
end)

local slots_to_scan = math.min(#a3list, MAX_A3)
print(string.format("разбираю до %d из %d слотов с камерой (CAM_SLOT первым)",
                    slots_to_scan, #a3list))

-- Собираем однократные и двуххоповые варианты, а также окна для поиска A2.
local a3windows = {}
for i = 1, slots_to_scan do
  local a3 = a3list[i].slot
  print(string.format("подготовка слота %08X (%d/%d)", a3, i, slots_to_scan))
  addOneHopRoots(a3)
  a3windows[#a3windows+1] = {
    a3 = a3, wstart = a3 - O3_MAX, wend = a3 + 4,
  }
end

print("один проход по куче: ищу все слоты A2...")
scanManyWindows(a3windows, HEAP_START, HEAP_STOP)

-- Накапливаем окна A1 для всех A2 и сохраняем их владельцев/смещения.
local a1windows = {}
for i = 1, #a3windows do
  local a3w = a3windows[i]
  local a2list = a3w.hits
  if #a2list > MAX_A2 then
    print(string.format("  слот %08X: A2=%d, ограничиваю до %d",
                        a3w.a3, #a2list, MAX_A2))
  end
  for ia = 1, math.min(#a2list, MAX_A2) do
    local a2 = a2list[ia]
    local item = {a3 = a3w.a3, slot = a2.slot, val = a2.val,
                  o3 = a3w.a3 - a2.val}
    item.window = {wstart = a2.slot - O2_MAX, wend = a2.slot + 4}
    a1windows[#a1windows+1] = item.window
    a2.owner = item
  end
  -- Keep the selected A2 records on the window for the assembly pass.
  a3w.selected_a2 = {}
  for ia = 1, math.min(#a2list, MAX_A2) do
    a3w.selected_a2[ia] = a2list[ia]
  end
end

print(string.format("один проход по куче: ищу A1 для %d окон...", #a1windows))
scanManyWindows(a1windows, HEAP_START, HEAP_STOP)

-- Сопоставляем найденные указатели A1/A2 со статическими roots.
for i = 1, #a3windows do
  local a3w = a3windows[i]
  for ia = 1, #a3w.selected_a2 do
    local a2 = a3w.selected_a2[ia]
    local item = a2.owner
    local o3 = item.o3

    -- глубина 2: статический слот сразу содержит P2
    for o2 = 0, O2_MAX - 4, 4 do
      local p2 = a2.slot - o2
      local roots = static_by_val[p2]
      if roots then
        for ir = 1, #roots do addChain(roots[ir], {o2, o3}) end
      end
    end

    -- глубина 3: A1 хранит P2, а A2 = P2 + o2
    for ib = 1, #item.window.hits do
      local a1 = item.window.hits[ib]
      local p2 = a1.val
      local o2 = a2.slot - p2
      if o2 >= 0 and o2 < O2_MAX then
        for o1 = 0, O1_MAX - 4, 4 do
          local p1 = a1.slot - o1
          local roots = static_by_val[p1]
          if roots then
            for ir = 1, #roots do addChain(roots[ir], {o1, o2, o3}) end
          end
        end
      end
    end
  end
end
print(string.format("сборка цепочек завершена; уникальных кандидатов: %d", #chains))

-- Сначала roots в эвристическом диапазоне GEngine, затем альтернативные
-- camera slots (не CAM_SLOT), короткие цепочки и маленькие смещения.
table.sort(chains, function(a, b)
  local a_likely = a.root >= LIKELY_GENGINE_START and a.root < LIKELY_GENGINE_STOP
  local b_likely = b.root >= LIKELY_GENGINE_START and b.root < LIKELY_GENGINE_STOP
  if a_likely ~= b_likely then return a_likely end
  local a_known_slot = a.slot == CAM_SLOT
  local b_known_slot = b.slot == CAM_SLOT
  if a_known_slot ~= b_known_slot then return not a_known_slot end
  if #a.offs ~= #b.offs then return #a.offs < #b.offs end
  local sa, sb = 0, 0
  for i = 1, #a.offs do sa = sa + a.offs[i] end
  for i = 1, #b.offs do sb = sb + b.offs[i] end
  if sa ~= sb then return sa < sb end
  return a.root < b.root
end)

print("")
if #chains == 0 then
  print("=== НИЧЕГО НЕ НАЙДЕНО ===")
  print("Что могло пойти не так:")
  print(" - запущено не на английской TU0 или не в геймплее;")
  print(" - цепочка длиннее 3 хопов (в supported_builds их максимум 3);")
  print(" - O1_MAX/O2_MAX/O3_MAX малы - увеличь;")
  print(" - тогда используй Pointer Scanner в CE, см. tools/mousehook/README.md.")
else
  print(string.format("=== НАЙДЕНО ЦЕПОЧЕК: %d ===", #chains))
  for i = 1, math.min(#chains, MAX_PRINT) do
    local c = chains[i]
    if i > MAX_PRINT then break end
    -- промежуточные значения для проверки глазами
    local hops = {}
    local a = c.root
    for k = 1, #c.offs do
      if c.offs[k] == NO_MORE then break end
      local v = rd32(BASE + a)
      hops[#hops+1] = string.format("[%08X]=%08X", a, v or 0)
      a = v + c.offs[k]
    end
    print(string.format("root=%08X  chain: {%s}", c.root, fmtOffs(padOffs(c.offs))))
    print(string.format("    %s -> slot %08X (cam=%08X)",
                        table.concat(hops, " "), c.slot, cam))
  end
  print("")
  print("Готовые строки для supported_builds в GearsOfWars.cc:")
  for i = 1, math.min(#chains, MAX_PRINT) do
    local c = chains[i]
    local o = padOffs(c.offs)
    print(string.format("  gengine_address = 0x%08X, chain_offset_1 = 0x%X, " ..
                        "chain_offset_2 = 0x%X, chain_offset_3 = 0x%X",
                        c.root, o[1], o[2], o[3]))
  end
end
print("-----")
