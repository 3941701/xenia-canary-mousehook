--=============================================================================
-- Gears of War: Judgment (Xbox 360 / Xenia mousehook)
-- Проверка цепочки указателей на РУССКОЙ версии (TU0).
--
-- Заполни ROOT и OFFSETS результатом из judgment_find_chain.lua (его надо
-- один раз прогнать на АНГЛИЙСКОЙ версии), запусти на русской версии в игре.
--
-- Скрипт:
--  1) покажет, что стало со старым слотом 0x448F2840 (на русской версии он
--     должен быть невалиден - в этом и была причина поломки мыши);
--  2) прогонит цепочку хоп за хопом с проверками;
--  3) 30 секунд будет показывать углы камеры (+0x62/+0x66), пошевели мышью
--     или правым стиком - значения должны меняться.
--=============================================================================

local BASE = 0x100000000

local ROOT = 0x00000000                 -- <-- root из результата поиска
local OFFSETS = {0x000, 0x000, 0x000}   -- <-- chain из результата поиска
                                         --     0xFFFFFFFF = цепочка закончилась

local MONITOR_SECONDS = 30

-- адреса английской TU0, для диагностики
local CAM_SLOT = 0x448F2840
local LOOKRIGHT_STATIC = 0x41DE7054      -- статический LookRightScale
local FOV_OFFSET = 0x3AC                 -- float fov scale от объекта камеры
local LIVE_OFF_1 = 0x6D4                 -- живой LookRightScale: [cam+0x6D4]+0x154
local LIVE_OFF_2 = 0x154

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

-- big-endian float
local function rdf32(a)
  local b = readBytes(a, 4, true)
  if not b then return nil end
  local u = ((b[1]*256 + b[2])*256 + b[3])*256 + b[4]
  if u == 0 then return 0.0 end
  local sign = 1
  if u >= 0x80000000 then sign = -1 u = u - 0x80000000 end
  local exp = math.floor(u / 0x800000)
  local mant = u % 0x800000
  if exp == 255 then return nil end   -- inf/nan
  if exp == 0 then return sign * mant * 2^-149 end
  return sign * (1 + mant / 0x800000) * 2^(exp - 127)
end

local function isHeap(v) return v and v >= 0x40000000 and v < 0x50000000 end
local function isStatic(v) return v and v >= 0x82000000 and v < 0x836B0000 end

---------------------------------------------------------------------------
print("=== диагностика старого (английского) слота ===")
local old = rd32(BASE + CAM_SLOT)
print(string.format("  [%08X] = %s   %s", CAM_SLOT, tostring(old),
                    isHeap(old) and "(указатель на кучу)" or "<-- НЕ указатель на кучу"))
local lrs = rdf32(BASE + LOOKRIGHT_STATIC)
print(string.format("  [%08X] (LookRightScale) = %s", LOOKRIGHT_STATIC, tostring(lrs)))

---------------------------------------------------------------------------
print("")
print("=== резолв цепочки ===")
if ROOT == 0 then
  print("!!! Заполни ROOT и OFFSETS в начале скрипта")
  return
end
print(string.format("  root = %08X %s", ROOT, isStatic(ROOT) and "(статический)" or "(НЕ статический - подозрительно)"))

local a = ROOT
local ok = true
for i = 1, #OFFSETS do
  local o = OFFSETS[i]
  if o == NO_MORE then
    print(string.format("  хоп %d: конец цепочки", i))
    break
  end
  if a < 0x40000000 or a >= 0x90000000 then
    print(string.format("  хоп %d: адрес %08X вне допустимого диапазона", i, a))
    ok = false
    break
  end
  local v = rd32(BASE + a)
  if not v then
    print(string.format("  хоп %d: не могу прочитать %08X", i, a))
    ok = false
    break
  end
  if v < 0x40000000 or v >= 0x50000000 then
    print(string.format("  хоп %d: [%08X] = %08X - не указатель на кучу", i, a, v))
    ok = false
    break
  end
  print(string.format("  хоп %d: [%08X] = %08X  -> слот %08X", i, a, v, v + o))
  a = v + o
end
if not ok then
  print("=== ЦЕПОЧКА НЕ РАБОТАЕТ НА ЭТОЙ ВЕРСИИ ===")
  return
end

local slot = a
local cam = rd32(BASE + slot)
print(string.format("  слот камеры = %08X", slot))
if not isHeap(cam) then
  print(string.format("!!! [%08X] = %s - не указатель на кучу", slot, tostring(cam)))
  return
end
print(string.format("  объект камеры = %08X  %s", cam,
                    isStatic(rd32(BASE + cam)) and "(похоже на UObject: vtable)" or ""))

print(string.format("  углы сейчас: X(+66) = %s   Y(+62) = %s",
                    tostring(rd16(BASE + cam + 0x66)), tostring(rd16(BASE + cam + 0x62))))
print(string.format("  fov scale [+%X] = %s", FOV_OFFSET, tostring(rdf32(BASE + cam + FOV_OFFSET))))

local live_mid = rd32(BASE + cam + LIVE_OFF_1)
if isHeap(live_mid) then
  local live = live_mid + LIVE_OFF_2
  print(string.format("  живой LookRightScale: [cam+%X] = %08X -> %08X = %s",
                      LIVE_OFF_1, live_mid, live, tostring(rdf32(BASE + live))))
else
  print(string.format("  живой LookRightScale: [cam+%X] = %s (не указатель)",
                      LIVE_OFF_1, tostring(live_mid)))
end

print("")
print(string.format("=== монитор углов %d сек (шевели мышью/стиком) ===", MONITOR_SECONDS))
local start = getTickCount()
local lastx, lasty = -1, -1
while getTickCount() - start < MONITOR_SECONDS * 1000 do
  local x = rd16(BASE + cam + 0x66)
  local y = rd16(BASE + cam + 0x62)
  if x ~= lastx or y ~= lasty then
    print(string.format("  X(+66) = %5d   Y(+62) = %5d", x or -1, y or -1))
    lastx, lasty = x, y
  end
  sleep(50)
end
print("-----")
