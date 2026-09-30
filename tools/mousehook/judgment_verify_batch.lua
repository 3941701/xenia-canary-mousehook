--=============================================================================
-- Gears of War: Judgment (Xbox 360 / Xenia mousehook)
-- Пакетная проверка цепочек на РУССКОЙ версии (TU0).
--
-- Вбей в CANDIDATES несколько цепочек из результата judgment_find_chain.lua
-- (запускать его на английской версии), запусти этот скрипт на русской версии
-- в геймплее.
--
-- Скрипт проверит каждую цепочку, покажет объект камеры для каждой, а потом
-- MONITOR_SECONDS секунд будет следить за углами (+0x62/+0x66) всех цепочек
-- сразу. Пошевели мышью или правым стиком - углы меняются только у той
-- цепочки, которая ведёт к реальной камере.
--=============================================================================

local BASE = 0x100000000

-- {root, offset_1, offset_2, offset_3}; 0xFFFFFFFF = цепочка закончилась
local CANDIDATES = {
  -- {0x83549E20, 0x588, 0x1FC, 0x3DC},
}

local MONITOR_SECONDS = 40

-- адреса английской TU0, для диагностики
local CAM_SLOT = 0x448F2840
local LOOKRIGHT_STATIC = 0x41DE7054

local NO_MORE = 0xFFFFFFFF

---------------------------------------------------------------------------
local function rd32(a)
  local b = readBytes(a, 4, true)
  if not b then return nil end
  return ((b[1]*256 + b[2])*256 + b[3])*256 + b[4]
end

local function rd16(a)
  local b = readBytes(a, 2, true)
  if not b then return nil end
  return b[1]*256 + b[2]
end

local function isHeap(v) return v and v >= 0x40000000 and v < 0x50000000 end
local function isStatic(v) return v and v >= 0x82000000 and v < 0x836B0000 end

-- резолв как ResolvePointerChain в GearsOfWars.cc; возвращает slot, cam, err
local function resolve(root, offs)
  local a = root
  for i = 1, #offs do
    local o = offs[i]
    if o == NO_MORE then break end
    if a < 0x40000000 or a >= 0x90000000 then
      return nil, nil, string.format("хоп %d: адрес %08X вне диапазона", i, a)
    end
    local v = rd32(BASE + a)
    if not v then
      return nil, nil, string.format("хоп %d: не читается %08X", i, a)
    end
    if v < 0x40000000 or v >= 0x50000000 then
      return nil, nil, string.format("хоп %d: [%08X] = %08X не указатель на кучу", i, a, v)
    end
    a = v + o
  end
  local cam = rd32(BASE + a)
  if not isHeap(cam) then
    return nil, nil, string.format("слот %08X = %s не указатель на кучу", a, tostring(cam))
  end
  return a, cam, nil
end

local function fmtOffs(offs)
  local parts = {}
  for i = 1, #offs do
    if offs[i] == NO_MORE then parts[i] = "-" else parts[i] = string.format("0x%X", offs[i]) end
  end
  return table.concat(parts, ", ")
end

---------------------------------------------------------------------------
print("=== диагностика старого (английского) слота ===")
local old = rd32(BASE + CAM_SLOT)
print(string.format("  [%08X] = %s   %s", CAM_SLOT, tostring(old),
                    isHeap(old) and "(указатель на кучу)" or "<-- НЕ указатель на кучу"))
print(string.format("  [%08X] (LookRightScale) = %s", LOOKRIGHT_STATIC,
                    tostring(rd32(BASE + LOOKRIGHT_STATIC))))

print("")
print(string.format("=== проверка %d кандидатов ===", #CANDIDATES))
if #CANDIDATES == 0 then
  print("!!! Заполни CANDIDATES в начале скрипта")
  return
end

local working = {}
for i = 1, #CANDIDATES do
  local c = CANDIDATES[i]
  local root, offs = c[1], {c[2], c[3], c[4]}
  local slot, cam, err = resolve(root, offs)
  if err then
    print(string.format("  #%-2d root=%08X {%s} -> НЕ РАБОТАЕТ: %s",
                        i, root, fmtOffs(offs), err))
  else
    working[#working+1] = {idx = i, cam = cam, slot = slot}
    print(string.format("  #%-2d root=%08X {%s} -> cam=%08X %s",
                        i, root, fmtOffs(offs), cam,
                        isStatic(rd32(BASE + cam)) and "(UObject)" or ""))
  end
end

if #working == 0 then
  print("")
  print("=== НИ ОДНА ЦЕПОЧКА НЕ РАБОТАЕТ ===")
  return
end

print("")
print(string.format("=== монитор углов %d сек ===", MONITOR_SECONDS))
print("    пошевели мышью/правым стиком: углы меняются только у реальной камеры")
local start = getTickCount()
local lastx, lasty = {}, {}
local lines = {}
for i = 1, #working do lastx[i] = -1 lasty[i] = -1 lines[i] = "" end
while getTickCount() - start < MONITOR_SECONDS * 1000 do
  local changed = false
  for i = 1, #working do
    local w = working[i]
    local x = rd16(BASE + w.cam + 0x66)
    local y = rd16(BASE + w.cam + 0x62)
    if x ~= lastx[i] or y ~= lasty[i] then
      lastx[i] = x
      lasty[i] = y
      lines[i] = string.format("  #%-2d cam=%08X  X(+66) = %5d   Y(+62) = %5d",
                               w.idx, w.cam, x or -1, y or -1)
      changed = true
    end
  end
  if changed then
    for i = 1, #working do print(lines[i]) end
    print("  ---")
  end
  sleep(50)
end
print("-----")
