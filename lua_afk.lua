-- lua_afk.lua
-- Скрипт для SA-MP (MoonLoader): меню, авто спавн, бот дальнобойщик, автообновление
-- Требуется: MoonLoader, SAMPFUNCS, mimgui. Для чекпоинтов бота: SAMP.Lua (lib/samp/events)
-- @changelog: Прицеп: /pricep спавнит визуальный прицеп фуры (591), /lhitch - бот сам встаёт перед ним, выравнивается, сдаёт задом и цепляет. Кнопки во вкладке Авто фарм.

script_name('lua_afk')
script_author('denismaslov769-lab')
script_version('2.3.0')

local imgui    = require('mimgui')
local encoding = require('encoding')
local inicfg   = require('inicfg')
local ffi      = require('ffi')
local dlstatus = require('moonloader').download_status
local hasSampev, sampev = pcall(require, 'lib.samp.events')

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local SCRIPT_VERSION = '2.3.0'
local REPO       = 'denismaslov769-lab/lua_afk'
local SCRIPT_URL = 'https://raw.githubusercontent.com/' .. REPO .. '/main/lua_afk.lua'
local API_COMMIT = 'https://api.github.com/repos/' .. REPO .. '/commits/main'
local RAW_BY_SHA = 'https://raw.githubusercontent.com/' .. REPO .. '/%s/lua_afk.lua'
local TAG = '{33AAFF}[lua_afk]{FFFFFF} '

--==============================================================
-- Конфиг: moonloader/config/lua_afk.ini
--==============================================================
local INI = 'lua_afk.ini'
local cfg = inicfg.load({
    spawn = {
        enabled = false,
        mode    = 0,        -- 0 = кнопка Spawn, 1 = пункт в диалоге
        delay   = 1000,     -- мс
        item    = 1,        -- номер пункта (с 1)
        keyword = 'спавн',  -- слово в заголовке диалога
    },
    bot = {
        enabled  = false,
        source   = 0,       -- 0 = авто, 1 = чекпоинт, 2 = метка на карте
        speed    = 25,      -- м/с, 61 = без ограничения
        style    = 0,       -- 0 = обычный, 1 = аккуратный
        radius   = 12,      -- радиус прибытия, м
        takeover = true,    -- W / S забирают управление
        lane     = false,   -- держаться своей (правой) полосы
        laneOff  = 2.5,     -- смещение от оси дороги, м
        turn     = true,    -- разворот к метке
        gps      = true,    -- маршрут по дорогам GTA (встроенный поиск пути игры)
    },
    theme = {
        accent     = '#3F99FF',
        bg         = '#12141C',
        childAlpha = 0.80,
        rounding   = 12,
    },
    particles = {
        enabled = true,
        count   = 70,
        speed   = 60,
        size    = 2.0,
        alpha   = 0.60,
        color   = '#FFFFFF',
        rainbow = false,
    },
    update = {
        auto = true,
    },
}, INI)
local function saveCfg() inicfg.save(cfg, INI) end
local function num(v, d) return tonumber(v) or d end

--==============================================================
-- Утилиты
--==============================================================
-- Текст в файле в UTF-8, чат и лог игры в CP1251
local function msg(text) sampAddChatMessage(TAG .. u8:decode(text), -1) end
local function log(text) print(u8:decode(text)) end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function isNewer(remote, current)
    local function parse(v)
        local t = {}
        for n in tostring(v):gmatch('%d+') do t[#t + 1] = tonumber(n) end
        return t
    end
    local a, b = parse(remote), parse(current)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function hexToRGB(hex)
    local n = tonumber((tostring(hex):gsub('#', '')), 16) or 0xFFFFFF
    return math.floor(n / 65536) % 256 / 255, math.floor(n / 256) % 256 / 255, n % 256 / 255
end

local function rgbToHex(r, g, b)
    local function c(v) return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end
    return string.format('#%02X%02X%02X', c(r), c(g), c(b))
end

local function hsv(h, s, v)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    i = i % 6
    if i == 0 then return v, t, p elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v else return v, p, q end
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local RU_MAP = {}
do
    local up, lo = {}, {}
    for ch in ('АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'):gmatch('[\208\209][\128-\191]') do up[#up + 1] = ch end
    for ch in ('абвгдеёжзийклмнопрстуфхцчшщъыьэюя'):gmatch('[\208\209][\128-\191]') do lo[#lo + 1] = ch end
    for i = 1, #up do RU_MAP[up[i]] = lo[i] end
end
local function ruLower(s)
    local r = tostring(s):lower():gsub('[\208\209][\128-\191]', RU_MAP)
    return r
end

--==============================================================
-- Загрузка файлов: строго по одной. Файл читается не в колбэке загрузки,
-- а в отдельном потоке после её завершения (иначе MoonLoader может уронить игру).
--==============================================================
local TMP_DIR = getWorkingDirectory() .. '\\config'

-- ВАЖНО: downloadUrlToFile вызывается только из ОДНОГО постоянного потока, который
-- всё время живёт и ждёт в wait(). MoonLoader возвращает колбэк загрузки в тот поток,
-- откуда её запустили. Если поток уже завершился или в этот момент работает другой
-- код - "cannot resume non-suspended coroutine" и вылет игры (так было в 1.5.3-2.0.2:
-- вторая загрузка запускалась из короткоживущего потока сразу после спавна).
local net = { queue = {}, busy = false }

local function download(url, path, onProgress, onDone)
    net.queue[#net.queue + 1] = { url = url, path = path, onProgress = onProgress, onDone = onDone }
    return true
end

local function netThread()
    while true do
        wait(50)
        local job = table.remove(net.queue, 1)
        if job then
            net.busy = true
            if not doesDirectoryExist(TMP_DIR) then createDirectory(TMP_DIR) end
            os.remove(job.path)
            local state = { finished = false, progress = nil }
            downloadUrlToFile(job.url, job.path, function(id, status, p1, p2)
                -- только запоминаем, никакого другого кода в колбэке
                if status == dlstatus.STATUS_DOWNLOADINGDATA then
                    if p2 and p2 > 0 then state.progress = p1 / p2 end
                elseif status == dlstatus.STATUS_ENDDOWNLOADDATA then
                    state.finished = true
                end
            end)
            local t = os.clock()
            while not state.finished and os.clock() - t < 30 do
                wait(50)
                if job.onProgress and state.progress then job.onProgress(state.progress) end
            end
            wait(500)
            local data = readFile(job.path)
            os.remove(job.path)
            net.busy = false
            if data == '' then data = nil end
            local ok, err = pcall(job.onDone, data)
            if not ok then log('[update] ошибка: ' .. tostring(err)) end
        end
    end
end

--==============================================================
-- Автообновление.
-- Ветка main на raw.githubusercontent.com кэшируется до 5 минут, поэтому сначала узнаём
-- хэш последнего коммита (API) и качаем файл по хэшу - такая ссылка всегда свежая.
--==============================================================
local TMP_SHA    = TMP_DIR .. '\\lua_afk_sha.tmp'
local TMP_CHECK  = TMP_DIR .. '\\lua_afk_check.tmp'
local TMP_SCRIPT = TMP_DIR .. '\\lua_afk_update.tmp'

local upd = {
    window = imgui.new.bool(false),
    state = 'idle',        -- idle | prompt | downloading | installing | error
    latest = nil, changelog = nil, url = nil,
    progress = 0.0, shown = 0.0, newCode = nil, error = nil, dismissed = nil,
}

local function isScript(data)
    return data and data:find("script_version%('") and data:find('function main', 1, true)
end

local function checkUpdates(manual, periodic)
    if not manual and not cfg.update.auto then return end
    if upd.state == 'prompt' or upd.state == 'downloading' or upd.state == 'installing' then return end
    if manual then msg('Проверка обновлений...') end

    local function onScript(data)
        if not isScript(data) then
            log('[update] не удалось получить скрипт с GitHub')
            if manual then msg('Не удалось связаться с GitHub. Попробуйте позже.') end
            return
        end
        local v = data:match("script_version%('([^']+)'%)")
        log('[update] на GitHub ' .. tostring(v) .. ', установлена ' .. SCRIPT_VERSION)
        if isNewer(v, SCRIPT_VERSION) then
            if periodic and upd.dismissed == v then return end
            upd.latest, upd.changelog = v, data:match('%-%- @changelog: ([^\r\n]+)')
            upd.state, upd.window[0] = 'prompt', true
            msg('Доступно обновление ' .. v .. '!')
        elseif manual then
            msg('У вас последняя версия (' .. SCRIPT_VERSION .. ').')
        end
    end

    if net.busy or #net.queue > 0 then
        if manual then msg('Загрузка уже идёт, подождите пару секунд.') end
        return
    end
    download(API_COMMIT .. '?t=' .. os.time(), TMP_SHA, nil, function(info)
        local sha = info and info:match('"sha"%s*:%s*"(%x+)"')
        upd.url = sha and RAW_BY_SHA:format(sha) or (SCRIPT_URL .. '?t=' .. os.time())
        download(upd.url, TMP_CHECK, nil, onScript)   -- просто в очередь, загрузит тот же поток
    end)
end

local function startDownload()
    upd.state, upd.progress, upd.shown, upd.error, upd.newCode = 'downloading', 0.0, 0.0, nil, nil
    download(upd.url or (SCRIPT_URL .. '?t=' .. os.time()), TMP_SCRIPT,
        function(f) upd.progress = math.min(f, 0.99) end,
        function(data)
            if isScript(data) then
                upd.newCode, upd.progress, upd.state = data, 1.0, 'installing'
            else
                upd.state, upd.error = 'error', 'Не удалось скачать обновление.'
            end
        end)
end

local function installUpdate()
    local f = io.open(thisScript().path, 'wb')
    if not f then
        upd.state, upd.error = 'error', 'Не удалось записать файл скрипта.'
        return false
    end
    f:write(upd.newCode)
    f:close()
    msg('Обновлено до версии ' .. upd.latest .. '. Перезапуск...')
    log('[update] файл записан, перезапуск')
    return true
end

-- Проверки: после входа, после каждого перезахода на сервер и каждые 5 минут
local function updateScheduler()
    local t = os.time()
    while not sampIsLocalPlayerSpawned() and os.time() - t < 20 do wait(500) end
    wait(2000)
    checkUpdates(false)
    local last, offSince = os.time(), nil
    while true do
        wait(1000)
        if not sampIsLocalPlayerSpawned() then
            offSince = offSince or os.time()
        elseif offSince then
            if os.time() - offSince >= 10 then
                wait(3000)
                last = os.time()
                checkUpdates(false)
            end
            offSince = nil
        end
        if os.time() - last >= 300 then
            last = os.time()
            checkUpdates(false, true)
        end
    end
end

--==============================================================
-- Авто спавн
--==============================================================
local function autoSpawnThread()
    local lastSpawn, lastDialogId, lastDialogTime = 0, -1, 0
    while true do
        wait(200)
        if cfg.spawn.enabled then
            if num(cfg.spawn.mode, 0) == 0 then
                local connected = sampGetPlayerIdByCharHandle(PLAYER_PED)
                if connected and not sampIsLocalPlayerSpawned() and not sampIsDialogActive()
                   and os.clock() - lastSpawn > 3 then
                    wait(num(cfg.spawn.delay, 1000))
                    if not sampIsLocalPlayerSpawned() and not sampIsDialogActive() then
                        sampSendRequestSpawn()
                        sampSpawnPlayer()
                        lastSpawn = os.clock()
                        msg('Авто спавн: персонаж заспавнен.')
                    end
                end
            elseif sampIsDialogActive() then
                local id = sampGetCurrentDialogId()
                if id ~= lastDialogId or os.clock() - lastDialogTime > 3 then
                    local caption = u8(sampGetDialogCaption() or ''):gsub('{%x+}', '')
                    local kw = ruLower(cfg.spawn.keyword)
                    if kw ~= '' and ruLower(caption):find(kw, 1, true) then
                        lastDialogId, lastDialogTime = id, os.clock()
                        wait(num(cfg.spawn.delay, 1000))
                        if sampIsDialogActive() and sampGetCurrentDialogId() == id then
                            sampSetCurrentDialogListItem(num(cfg.spawn.item, 1) - 1)
                            sampCloseCurrentDialogWithButton(1)
                            msg('Авто спавн: выбран пункт ' .. cfg.spawn.item .. '.')
                        end
                    end
                end
            end
        end
    end
end

--==============================================================
-- Бот дальнобойщик: собственный автопилот.
-- Управляет только виртуальными клавишами (руль, газ, тормоз/задний ход).
-- Ничего не делает, пока бот не включён в меню или командой /ltruck.
--==============================================================
local KEY_STEER, KEY_GAS, KEY_BRAKE = 0, 16, 14
local SPEED_NO_LIMIT = 61 -- ползунок скорости в крайнем правом положении

local bot = {
    status = 'Выключен', active = false, cp = nil,
    tx = nil, ty = nil, best = nil, bestTime = 0, gaveUp = false, arrived = false, pauseUntil = 0,
    wx = nil, wy = nil, nextPlan = 0, turnAt = nil, vt = nil, lastCtl = nil,
    stuckSince = nil, recover = nil, man = nil, manCooldown = 0,
}

if hasSampev then
    function sampev.onSetCheckpoint(pos)        bot.cp = { pos.x, pos.y, pos.z } end
    function sampev.onDisableCheckpoint()       bot.cp = nil end
    function sampev.onSetRaceCheckpoint(t, pos) bot.cp = { pos.x, pos.y, pos.z } end
    function sampev.onDisableRaceCheckpoint()   bot.cp = nil end
end

local arz = { t = -100, v = false }
local function isArizona()
    if os.clock() - arz.t < 5 then return arz.v end
    arz.t = os.clock()
    local ok, name = pcall(sampGetCurrentServerName)
    if not ok or type(name) ~= 'string' then arz.v = false return false end
    local n = ruLower(u8(name))
    arz.v = n:find('arizona', 1, true) ~= nil or n:find('аризона', 1, true) ~= nil
    return arz.v
end

local function botTarget()
    local src = num(cfg.bot.source, 0)
    if src ~= 2 and bot.cp then return bot.cp[1], bot.cp[2], bot.cp[3], 'чекпоинт' end
    if src ~= 1 then
        local ok, x, y, z = getTargetBlipCoordinates()
        if ok then
            if not z or z == 0 then z = getGroundZFor3dCoord(x, y, 1000.0) end
            if not z or z == 0 then local _, _, pz = getCharCoordinates(PLAYER_PED) z = pz end
            return x, y, z, 'метка на карте'
        end
    end
end

-- Клавиши ---------------------------------------------------------------
local function pedal(v) return math.floor(clamp(v or 0, 0, 1) * 255) end

local function keys(steer, gas, brake)
    setGameKeyState(KEY_STEER, math.floor(clamp(steer, -1, 1) * 128))
    setGameKeyState(KEY_GAS, pedal(gas))
    setGameKeyState(KEY_BRAKE, pedal(brake))
    bot.active = true
end

-- Отпустить всё и забыть маршрут. Клавиши трогаем только если бот ими управлял.
local function botRelease()
    if bot.active then
        setGameKeyState(KEY_STEER, 0)
        setGameKeyState(KEY_GAS, 0)
        setGameKeyState(KEY_BRAKE, 0)
        bot.active = false
    end
    bot.wx, bot.wy, bot.vt, bot.turnAt = nil, nil, nil, nil
    bot.man, bot.recover, bot.stuckSince, bot.commit, bot.route = nil, nil, nil, nil, nil
end

-- Геометрия -------------------------------------------------------------
local geoCache = {}
local function geo(car)
    local m = getCarModel(car)
    local g = geoCache[m]
    if not g then
        local minX, minY, _, maxX, maxY = getModelDimensions(m)
        g = { front = maxY or 3, back = math.abs(minY or -3),
              half = math.max(math.abs(minX or -1.2), maxX or 1.2) }
        geoCache[m] = g
    end
    return g
end

-- Векторы машины: вперёд (fx, fy) и вправо (rx, ry)
local function carBasis(car)
    local h = math.rad(getCarHeading(car))
    return -math.sin(h), math.cos(h), math.cos(h), math.sin(h)
end

-- Точка в координатах машины: lx > 0 - справа, ly > 0 - впереди
local function toLocal(car, x, y)
    local cx, cy = getCarCoordinates(car)
    local fx, fy, rx, ry = carBasis(car)
    local dx, dy = x - cx, y - cy
    return dx * rx + dy * ry, dx * fx + dy * fy
end

local function minOf(...)
    local m
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        if v and (not m or v < m) then m = v end
    end
    return m
end

-- Лучи ------------------------------------------------------------------
-- Все лучи начинаются СНАРУЖИ машины (не изнутри кузова и не у земли) - так
-- processLineOfSight работает стабильно. Битые и нулевые лучи не пускаем.
local function fin(v) return type(v) == 'number' and v == v and v > -1e5 and v < 1e5 end
local function los(x1, y1, z1, x2, y2, z2, cars)
    if not (fin(x1) and fin(y1) and fin(z1) and fin(x2) and fin(y2) and fin(z2)) then return false end
    local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
    local l2 = dx * dx + dy * dy + dz * dz
    if l2 < 0.04 or l2 > 150 * 150 then return false end
    return processLineOfSight(x1, y1, z1, x2, y2, z2, true, cars, cars, true, false, false, false, false)
end

-- Прямая видимость (здания и объекты)
local function clearLine(x1, y1, z1, x2, y2, z2)
    return not los(x1, y1, z1, x2, y2, z2, false)
end

-- Луч в координатах машины (x вправо, y вперёд) на высоте +0.3. Расстояние до препятствия или nil.
-- Почти горизонтальные поверхности (подъём дороги) препятствием не считаются.
local function cast(car, ax, ay, bx, by, cars)
    local x1, y1, z1 = getOffsetFromCarInWorldCoords(car, ax, ay, 0.3)
    local x2, y2, z2 = getOffsetFromCarInWorldCoords(car, bx, by, 0.3)
    local hit, cp = los(x1, y1, z1, x2, y2, z2, cars)
    if not hit or not cp or not cp.pos then return nil end
    if cp.normal and cp.normal[3] and cp.normal[3] > 0.7 then return nil end
    return getDistanceBetweenCoords2d(x1, y1, cp.pos[1], cp.pos[2])
end

-- Датчики спереди: fl/fc/fr - лучи вперёд от бампера длиной len,
-- cl/cr - лучи от передних углов наружу (видят угол дома или столб на повороте)
local function senseFront(car, len)
    local g = geo(car)
    local h, f = g.half - 0.2, g.front + 0.2
    local s = {
        fl = cast(car, -h, f, -h * 1.15, f + len, true),
        fc = cast(car, 0, f, 0, f + len, true),
        fr = cast(car, h, f, h * 1.15, f + len, true),
    }
    for _, sd in ipairs({ -1, 1 }) do
        local ox, oy = sd * (g.half + 0.15), g.front - 0.3
        local best
        for _, a in ipairs({ 50 }) do
            local r = math.rad(a)
            best = minOf(best, cast(car, ox, oy, ox + sd * math.sin(r) * 2.8, oy + math.cos(r) * 2.8, false))
        end
        if sd < 0 then s.cl = best else s.cr = best end
    end
    return s
end

-- Датчики сзади: bl/bc/br - назад от заднего бампера, rl/rr - от задних углов наружу
local function senseRear(car)
    local g = geo(car)
    local h, b = g.half - 0.2, -(g.back + 0.2)
    local s = {
        bl = cast(car, -h, b, -h * 1.15, b - 4, true),
        bc = cast(car, 0, b, 0, b - 4, true),
        br = cast(car, h, b, h * 1.15, b - 4, true),
    }
    for _, sd in ipairs({ -1, 1 }) do
        local ox, oy = sd * (g.half + 0.15), -(g.back - 0.3)
        local best
        for _, a in ipairs({ 50 }) do
            local r = math.rad(a)
            best = minOf(best, cast(car, ox, oy, ox + sd * math.sin(r) * 2.8, oy - math.cos(r) * 2.8, false))
        end
        if sd < 0 then s.rl = best else s.rr = best end
    end
    return s
end

-- Проезд по ширине машины: линии вдоль левого и правого борта до точки.
-- Линия из центра не видит угол дома, о который цепляется край машины.
local function corridorClear(car, x, y, z)
    local cx, cy, cz = getCarCoordinates(car)
    local g = geo(car)
    local hw = g.half + 0.5
    local dx, dy = x - cx, y - cy
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 2 then return true end
    local px, py = dy / l * hw, -dx / l * hw
    local ez = (z and fin(z) and math.abs(z - cz) < 30) and z + 0.8 or cz
    for _, sd in ipairs({ -1, 1 }) do
        for _, h in ipairs({ 0.2, 0.7 }) do
            if not clearLine(cx + px * sd, cy + py * sd, cz + h, x + px * sd, y + py * sd, ez + h) then
                return false
            end
        end
    end
    return true
end

-- Маршрут ---------------------------------------------------------------
-- Дорожные узлы игры впереди (прямо и под углами), до которых есть прямой проезд.
-- От узлов прямо по курсу смотрим ещё на шаг вперёд: так бот заранее видит поворот
-- на перекрёстке, который ведёт к метке, сбрасывает скорость и поворачивает.
local ANGLES = { 0, 20, -20, 45, -45, 75, -75, 90, -90 }
local AHEAD  = { 0, 45, -45, 70, -70, 90, -90 }

local function nodeNear(sx, sy, z, R)
    local nx, ny, nz = getClosestCarNode(sx, sy, z)
    if nx and fin(nx) and fin(ny) and (nx ~= 0 or ny ~= 0) and getDistanceBetweenCoords2d(nx, ny, sx, sy) < R * 0.6 then
        return nx, ny, (nz and fin(nz)) and nz or z
    end
end

local function planWaypoint(car, tx, ty, tz)
    local cx, cy, cz = getCarCoordinates(car)
    bot.turnAt = nil
    -- Цель рядом и к ней есть проезд - едем прямо к ней
    local dist = getDistanceBetweenCoords2d(cx, cy, tx, ty)
    if dist < 45 and clearLine(cx, cy, cz + 0.6, tx, ty, tz + 0.6) and corridorClear(car, tx, ty, tz) then
        return tx, ty, true
    end
    local fx, fy, rx, ry = carBasis(car)
    local R = clamp(10 + getCarSpeed(car) * 0.8, 12, 30)
    local list = {}
    for _, a in ipairs(ANGLES) do
        local ar = math.rad(a)
        local dx = fx * math.cos(ar) + rx * math.sin(ar)
        local dy = fy * math.cos(ar) + ry * math.sin(ar)
        local Ra = (math.abs(a) >= 75) and R * 0.7 or R
        local nx, ny, nz = nodeNear(cx + dx * Ra, cy + dy * Ra, cz, Ra)
        if nx then
            local _, ly = toLocal(car, nx, ny)
            if ly > 3 and clearLine(cx, cy, cz + 0.6, nx, ny, nz + 0.6) then
                local c = { x = nx, y = ny, z = nz, a = a, d = getDistanceBetweenCoords2d(nx, ny, tx, ty) }
                -- Шаг вперёд от узла прямо по курсу: куда можно повернуть дальше
                if math.abs(a) <= 20 then
                    local hx, hy = nx - cx, ny - cy
                    local hl = math.sqrt(hx * hx + hy * hy)
                    if hl > 1 then
                        hx, hy = hx / hl, hy / hl
                        local straight, best, ex, ey, eb = c.d, nil, nil, nil, nil
                        for _, b in ipairs(AHEAD) do
                            local br = math.rad(b)
                            local ux = hx * math.cos(br) + hy * math.sin(br)
                            local uy = hy * math.cos(br) - hx * math.sin(br)
                            local mx, my, mz = nodeNear(nx + ux * 18, ny + uy * 18, nz, 18)
                            if mx and getDistanceBetweenCoords2d(mx, my, nx, ny) > 6
                                and clearLine(nx, ny, nz + 0.6, mx, my, mz + 0.6) then
                                local d2 = getDistanceBetweenCoords2d(mx, my, tx, ty)
                                if b == 0 then straight = math.min(straight, d2) end
                                if not best or d2 + math.abs(b) * 0.05 < best then
                                    best, ex, ey, eb = d2 + math.abs(b) * 0.05, mx, my, b
                                end
                            end
                        end
                        if best and best < c.d then
                            c.d = best
                            if math.abs(eb) >= 45 and straight - best >= 8 then
                                c.turn = { x = nx, y = ny, ex = ex, ey = ey }
                            end
                        end
                    end
                end
                c.score = c.d + math.abs(a) * 0.35
                list[#list + 1] = c
            end
        end
    end
    if #list == 0 then return nil end
    table.sort(list, function(p, q) return p.score < q.score end)
    local pick = list[1]
    for k = 1, math.min(2, #list) do
        if corridorClear(car, list[k].x, list[k].y, list[k].z) then pick = list[k] break end
    end
    bot.turnAt = pick.turn
    return pick.x, pick.y, false
end

-- Маршрут по дорогам GTA (как у машин трафика) ---------------------------------
-- Встроенный поиск пути игры CPathFind::DoPathSearch (GTA SA 1.0 US). Он знает все
-- дороги и перекрёстки вокруг, поэтому бот поворачивает туда, куда реально ведёт дорога.
-- Только чтение и вызов функции игры, память игры не меняется. Если что-то не так -
-- функция отключается и бот ездит по старому способу.
ffi.cdef[[
typedef struct { uint16_t area; uint16_t node; } lafk_naddr;
]]
local GPS_FN, PATHS = 0x4515D0, 0x96F050
local gps = { ok = true, res = nil, cnt = nil, dist = nil, fn = nil }

local function gpsSearch(x1, y1, z1, x2, y2, z2)
    if not gps.ok then return nil end
    if not gps.fn then
        local ok = pcall(function()
            gps.fn = ffi.cast('void(__thiscall*)(void*, uint32_t, float, float, float, uint32_t, float, float, float, '
                .. 'lafk_naddr*, int16_t*, int32_t, float*, float, lafk_naddr*, float, uint32_t, uint32_t, uint32_t, uint32_t)', GPS_FN)
            gps.res  = ffi.new('lafk_naddr[?]', 512)
            gps.cnt  = ffi.new('int16_t[1]')
            gps.dist = ffi.new('float[1]')
        end)
        if not ok then gps.ok = false return nil end
    end
    gps.cnt[0] = 0
    gps.fn(ffi.cast('void*', PATHS), 0, x1, y1, z1, 0xFFFFFFFF, x2, y2, z2,
           gps.res, gps.cnt, 500, gps.dist, 999999.0, nil, 999999.0, 0, 0xFFFFFFFF, 0, 0)
    local n = tonumber(gps.cnt[0]) or 0
    if n <= 0 or n > 500 then return nil end
    local lists = ffi.cast('uint8_t**', PATHS + 0x804)
    local pts = {}
    for i = 0, n - 1 do
        local a = gps.res[i]
        if a.area >= 72 then break end
        local base = lists[a.area]
        if base == nil then break end
        local node = base + a.node * 0x1C
        -- проверка, что структура узла та, что мы ожидаем (номер области и узла внутри узла)
        local ids = ffi.cast('uint16_t*', node + 0x12)
        if ids[0] ~= a.area or ids[1] ~= a.node then
            log('[gps] неожиданная структура узлов, маршрут по дорогам GTA отключён')
            gps.ok = false
            return nil
        end
        local p = ffi.cast('int16_t*', node + 0x8)
        pts[#pts + 1] = { x = p[0] / 8, y = p[1] / 8, z = p[2] / 8 }
    end
    if #pts < 2 then return nil end
    -- порядок: от машины к цели
    local f, l = pts[1], pts[#pts]
    if getDistanceBetweenCoords2d(f.x, f.y, x1, y1) > getDistanceBetweenCoords2d(l.x, l.y, x1, y1) then
        local r = {}
        for i = #pts, 1, -1 do r[#r + 1] = pts[i] end
        pts = r
    end
    return pts
end

local function routeLen(pts, i0)
    local L = 0
    for i = math.max(1, i0 or 1), #pts - 1 do
        L = L + getDistanceBetweenCoords2d(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
    end
    return L
end

-- Маршрут начинается назад (нужен разворот)?
local function startsBehind(car, pts)
    local cx, cy = getCarCoordinates(car)
    for i = 1, math.min(#pts, 8) do
        if getDistanceBetweenCoords2d(cx, cy, pts[i].x, pts[i].y) >= 10 then
            local lx, ly = toLocal(car, pts[i].x, pts[i].y)
            return math.abs(math.deg(math.atan2(lx, ly))) > 100
        end
    end
    return false
end

-- Обновление маршрута. Маршрут НЕ меняется без причины: только если машина ушла с него,
-- сменилась метка, он заканчивается, или раз в 8 с - и то лишь если новый заметно короче.
-- Так бот не мечется между несколькими почти одинаковыми дорогами к метке.
-- Разворот назад выбирается, только если путь вперёд длиннее больше чем на 250 м.
local function routeUpdate(car, tx, ty, tz, now, speed)
    local r = bot.route
    local moved = r and getDistanceBetweenCoords2d(r.tx, r.ty, tx, ty) > 10
    local nearEnd = r and (#r.pts - r.idx) < 4 and getDistanceBetweenCoords2d(r.pts[#r.pts].x, r.pts[#r.pts].y, tx, ty) > 40
    local periodic = r and now - r.t > 8
    if r and not (r.off or moved or nearEnd or periodic) then return end
    if r and r.fail and now - r.fail < 2 then return end
    if not r and bot.routeFail and now - bot.routeFail < 1 then return end

    local cx, cy, cz = getCarCoordinates(car)
    local gx, gy, gz = tx, ty, tz
    local pts = gpsSearch(cx, cy, cz, gx, gy, gz)
    local D = getDistanceBetweenCoords2d(cx, cy, tx, ty)
    if not pts and D > 300 then
        -- метка слишком далеко (дороги там ещё не загружены) - промежуточная цель 300 м в её сторону
        local ix, iy = cx + (tx - cx) / D * 300, cy + (ty - cy) / D * 300
        local nx, ny, nz = getClosestCarNode(ix, iy, cz)
        if nx and fin(nx) and (nx ~= 0 or ny ~= 0) then
            gx, gy, gz = nx, ny, nz or cz
            pts = gpsSearch(cx, cy, cz, gx, gy, gz)
        end
    end

    -- Путь требует разворота - пробуем путь от точки впереди машины
    if pts and startsBehind(car, pts) then
        local fx, fy = carBasis(car)
        local ax, ay = cx + fx * 25, cy + fy * 25
        local alt = gpsSearch(ax, ay, cz, gx, gy, gz)
        if alt and getDistanceBetweenCoords2d(alt[1].x, alt[1].y, ax, ay) < 15
            and clearLine(cx, cy, cz + 0.6, alt[1].x, alt[1].y, alt[1].z + 1.2)
            and not startsBehind(car, alt)
            and routeLen(alt) + 25 <= routeLen(pts) + 250 then
            pts = alt
        end
    end

    if not pts then
        bot.routeFail = now
        if r then r.fail = now end
        if not r or r.off then bot.route = nil end
        return
    end
    -- Держимся текущего маршрута, если новый не короче хотя бы на 15%
    if r and not r.off and not moved and not nearEnd then
        if routeLen(pts) > routeLen(r.pts, r.idx) * 0.85 then r.t = now return end
    end
    bot.route = { pts = pts, t = now, tx = tx, ty = ty, idx = 1 }
end

-- Точка маршрута для руления + расстояние до ближайшего крутого поворота по маршруту
local function routeWaypoint(car, speed, tx, ty)
    local r = bot.route
    if not r then return nil end
    local now = os.clock()
    if r.cache and now < r.cache.till then return r.cache.x, r.cache.y, r.cache.turn end
    local pts = r.pts
    local cx, cy, cz = getCarCoordinates(car)
    -- ближайшая точка маршрута (ищем вперёд от прошлой)
    local bi, bd = r.idx, 1e9
    for i = math.max(1, r.idx - 2), math.min(#pts, r.idx + 25) do
        local d = getDistanceBetweenCoords2d(cx, cy, pts[i].x, pts[i].y)
        if d < bd then bi, bd = i, d end
    end
    r.idx = bi
    if bd > 30 then r.off, r.cache = true, nil return nil end
    -- первая точка дальше R, затем назад до той, к которой есть проезд
    local R = clamp(8 + speed * 0.7, 10, 28)
    local pick = #pts
    for i = bi, #pts do
        if getDistanceBetweenCoords2d(cx, cy, pts[i].x, pts[i].y) >= R then pick = i break end
    end
    while pick > bi + 1 do
        local p = pts[pick]
        if clearLine(cx, cy, cz + 0.6, p.x, p.y, p.z + 1.2) and corridorClear(car, p.x, p.y, p.z + 0.4) then break end
        pick = pick - 1
    end
    if pick == bi and bi < #pts and bd < 6 then pick = bi + 1 end
    local p = pts[pick]
    -- конец маршрута рядом с меткой - дальше едем прямо к метке
    if pick == #pts and getDistanceBetweenCoords2d(p.x, p.y, tx, ty) < 40 and getDistanceBetweenCoords2d(cx, cy, p.x, p.y) < 12 then
        return nil
    end
    -- крутой поворот впереди (до 70 м по маршруту)
    local fx, fy = carBasis(car)
    local along, turnDist = bd, nil
    for i = bi, math.min(#pts - 1, bi + 20) do
        local a, b = pts[i], pts[i + 1]
        local sx, sy = b.x - a.x, b.y - a.y
        local sl = math.sqrt(sx * sx + sy * sy)
        if sl > 2 then
            local cosv = (sx * fx + sy * fy) / sl
            if cosv < 0.7 then turnDist = along break end   -- больше ~45 градусов от курса
        end
        along = along + sl
        if along > 70 then break end
    end
    r.cache = { x = p.x, y = p.y, turn = turnDist, till = now + 0.15 }
    return p.x, p.y, turnDist
end

-- Разворот к метке --------------------------------------------------------
-- Метка сзади или сбоку (или впереди стена). Если перед машиной есть место -
-- разворачиваемся вперёд с полным рулём. Иначе сдаём назад с рулём в обратную
-- сторону (нос уходит к метке). Фаза меняется, когда до препятствия меньше метра,
-- когда машина упёрлась (педаль нажата, а не едет) или когда нос уже смотрит на метку.
local function maneuver(car, tx, ty, dist, s, now, speed, routed)
    if cfg.bot.turn == false then bot.man = nil return false end
    local lx, ly = toLocal(car, tx, ty)
    local ang = math.deg(math.atan2(lx, ly))   -- > 0 справа, 180 - сзади
    local a = math.abs(ang)
    local m = bot.man

    if not m then
        if now < bot.manCooldown then return false end
        local frontGap = minOf(s.fl, s.fc, s.fr)
        local behind  = a > 110 and dist < 400 and speed < 12
        local side    = a > 65 and dist < 60 and speed < 6
        if side then
            -- сбоку разворачиваемся носом к метке, только если к ней правда можно проехать напрямую
            local cx, cy, cz = getCarCoordinates(car)
            side = clearLine(cx, cy, cz + 0.6, tx, ty, cz + 0.6)
        end
        local blocked = frontGap and frontGap < 4 and a > 30 and speed < 2 and dist < 100
        if not (behind or side or blocked) then return false end
        local dir = ang >= 0 and 1 or -1
        local cornerGap = (dir > 0) and s.cr or s.cl
        local room = (not frontGap or frontGap > 3.5) and (not cornerGap or cornerGap > 1.5)
        m = { dir = dir, phase = room and 'fwd' or 'back', since = now, start = now, n = 0 }
        -- Метка сзади и далеко (проехали поворот): разворачиваемся вдоль дороги на 180 градусов,
        -- а не носом в сторону метки (там обычно дома). Дальше поворот найдёт маршрут.
        if behind and dist > 45 and not routed then
            local cx, cy = getCarCoordinates(car)
            local fx, fy = carBasis(car)
            m.gx, m.gy = cx - fx * 60, cy - fy * 60
        end
        bot.man = m
    end
    if m.gx then
        lx, ly = toLocal(car, m.gx, m.gy)
        ang = math.deg(math.atan2(lx, ly))
        a = math.abs(ang)
    end

    if a < 25 or now - m.start > 45 or m.n > 16 then
        bot.man = nil
        bot.manCooldown = now + ((a < 25) and 3 or 8)
        bot.wx, bot.nextPlan = nil, 0
        return false
    end

    local t = now - m.since
    if speed > 0.6 then m.moved = now end
    local stalled = t > 1.0 and now - (m.moved or m.since) > 0.8
    local dir = m.dir

    if m.phase == 'fwd' then
        local frontGap = minOf(s.fl, s.fc, s.fr)
        local cornerGap = (dir > 0) and s.cr or s.cl
        if t > 0.4 and ((frontGap and frontGap < 1.0) or (cornerGap and cornerGap < 0.6) or stalled) then
            m.phase, m.since, m.n, m.moved = 'back', now, m.n + 1, nil
            keys(0, 0, 1)
            return true
        end
        keys(dir, (speed < 4.5) and 0.5 or 0, 0)
        bot.status = string.format('Разворот: вперёд, %d м', math.floor(dist))
        return true
    end

    -- Назад: при развороте носом к dir зад уходит в сторону -dir, его угол и проверяем
    local r = senseRear(car)
    local rearGap = minOf(r.bl, r.bc, r.br)
    local cornerGap = (dir > 0) and r.rl or r.rr
    if t > 0.4 and ((rearGap and rearGap < 1.0) or (cornerGap and cornerGap < 0.6) or stalled or a < 30 or t > 6) then
        m.phase, m.since, m.n, m.moved = 'fwd', now, m.n + 1, nil
        keys(0, 0, 0)
        return true
    end
    local slow = (rearGap and rearGap < 3) or (cornerGap and cornerGap < 1.5)
    keys(-dir, 0, (speed < (slow and 1.8 or 4)) and 0.6 or 0)
    bot.status = string.format('Разворот: назад, %d м', math.floor(dist))
    return true
end

-- Управление (каждый кадр) -------------------------------------------------
local function botControl(car, tx, ty, tz, dist)
    local now = os.clock()
    local careful = num(cfg.bot.style, 0) == 1
    local vmax = num(cfg.bot.speed, 25)
    local speed = getCarSpeed(car)
    local decel = careful and 5 or 7      -- комфортное замедление
    local aLat  = careful and 6 or 8      -- боковое ускорение в повороте
    local stopGap = careful and 5 or 3.5  -- сколько оставлять до препятствия

    -- 1. Отъезд назад после упора
    if bot.recover then
        local rc = bot.recover
        local r = senseRear(car)
        local rearGap = minOf(r.bl, r.bc, r.br, r.rl, r.rr)
        if speed > 0.6 then rc.moved = now end
        local stalled = now - rc.start > 1.0 and now - (rc.moved or rc.start) > 0.8
        if now > rc.till or (rearGap and rearGap < 0.8) or stalled then
            bot.recover, bot.wx, bot.nextPlan = nil, nil, 0
        else
            keys(rc.steer, 0, (speed < 3.5) and 0.6 or 0)
            bot.status = 'Отъезжаю от препятствия'
            bot.bestTime = now
            return
        end
    end

    local len = math.min(60, 6 + speed * speed / (2 * decel) + speed * 0.3)
    local s = senseFront(car, len)

    -- 2. Маршрут по дорогам GTA
    local rwx, rwy, rturn
    if cfg.bot.gps ~= false and gps.ok then
        routeUpdate(car, tx, ty, tz, now, speed)
        rwx, rwy, rturn = routeWaypoint(car, speed, tx, ty)
    end

    -- 3. Разворот: к точке маршрута (если она сзади) или к метке
    local goalX, goalY = tx, ty
    if rwx then goalX, goalY = rwx, rwy end
    if maneuver(car, goalX, goalY, dist, s, now, speed, rwx ~= nil) then
        bot.vt, bot.stuckSince, bot.bestTime = 0, nil, now
        return
    end

    if rwx then
        bot.commit, bot.turnAt = nil, nil
        if cfg.bot.lane then
            local cx, cy, cz = getCarCoordinates(car)
            local dx, dy = rwx - cx, rwy - cy
            local l = math.sqrt(dx * dx + dy * dy)
            if l > 1 then
                local off = num(cfg.bot.laneOff, 2.5)
                local sx, sy = rwx + dy / l * off, rwy - dx / l * off
                if clearLine(cx, cy, cz + 0.6, sx, sy, cz + 0.6) then rwx, rwy = sx, sy end
            end
        end
        bot.wx, bot.wy, bot.nextPlan = rwx, rwy, now + 0.25
    end

    -- 3. Точка маршрута (4 раза в секунду). На перекрёстке, где нужно повернуть,
    -- бот "заходит в поворот": едет на узел боковой дороги, пока не повернёт.
    if not rwx and bot.commit then
        local c = bot.commit
        local cx, cy = getCarCoordinates(car)
        local _, cly = toLocal(car, c.ex, c.ey)
        if now > c.till or cly < 2 or getDistanceBetweenCoords2d(cx, cy, c.ex, c.ey) < 6 then
            bot.commit, bot.nextPlan = nil, 0
        else
            bot.wx, bot.wy, bot.nextPlan = c.ex, c.ey, now + 0.25
        end
    end
    if not rwx and bot.turnAt and not bot.commit then
        local cx, cy = getCarCoordinates(car)
        local jd = getDistanceBetweenCoords2d(cx, cy, bot.turnAt.x, bot.turnAt.y)
        if jd < math.max(7, speed * 0.9) then
            bot.commit = { ex = bot.turnAt.ex, ey = bot.turnAt.ey, till = now + 4 }
            bot.wx, bot.wy, bot.turnAt, bot.nextPlan = bot.turnAt.ex, bot.turnAt.ey, nil, now + 0.25
        end
    end
    if not rwx and not bot.commit and (now >= bot.nextPlan or not bot.wx) then
        bot.nextPlan = now + 0.25
        local wx, wy, direct = planWaypoint(car, tx, ty, tz)
        if wx and cfg.bot.lane and not direct then
            -- Своя полоса: сдвигаем точку вправо от оси дороги (правостороннее движение)
            local cx, cy, cz = getCarCoordinates(car)
            local dx, dy = wx - cx, wy - cy
            local l = math.sqrt(dx * dx + dy * dy)
            if l > 1 then
                local off = num(cfg.bot.laneOff, 2.5)
                local sx, sy = wx + dy / l * off, wy - dx / l * off
                if clearLine(cx, cy, cz + 0.6, sx, sy, cz + 0.6) then wx, wy = sx, sy end
            end
        end
        bot.wx, bot.wy = wx, wy
    end

    local steer, v = 0, 4
    if bot.wx then
        local lx, ly = toLocal(car, bot.wx, bot.wy)
        local ang = math.atan2(lx, ly)
        steer = clamp(ang / 0.5, -1, 1)
        v = (vmax >= SPEED_NO_LIMIT) and 999 or vmax
        -- Поворот: скорость по радиусу дуги до точки
        local wd = math.max(5, math.sqrt(lx * lx + ly * ly))
        local sn = math.abs(math.sin(clamp(ang, -1.5, 1.5)))
        if sn > 0.02 then v = math.min(v, math.max(6, math.sqrt(aLat * wd / (2 * sn)))) end
    end

    -- Цель позади (проехали) - сбрасываем скорость, чтобы развернуться
    do
        local tlx, tly = toLocal(car, goalX, goalY)
        if math.abs(math.deg(math.atan2(tlx, tly))) > 110 and dist > num(cfg.bot.radius, 12) then v = math.min(v, 8) end
    end

    -- Подъезд к метке и к нужному повороту
    v = math.min(v, math.sqrt(2 * decel * math.max(0, dist - num(cfg.bot.radius, 12))) + 2)
    if bot.turnAt then
        local cx, cy = getCarCoordinates(car)
        local jd = getDistanceBetweenCoords2d(cx, cy, bot.turnAt.x, bot.turnAt.y)
        v = math.min(v, math.sqrt(2 * decel * math.max(0, jd - 4)) + (careful and 6 or 8))
    end
    if rturn then
        v = math.min(v, math.sqrt(2 * decel * math.max(0, rturn - 3)) + (careful and 6 or 8))
    end

    -- Препятствие прямо по курсу - настоящее торможение
    local danger = false
    if s.fc then
        v = math.min(v, math.sqrt(2 * decel * math.max(0, s.fc - stopGap)))
        danger = s.fc < stopGap + 2
    end
    -- Боковые лучи бампера - немного сбавить и подрулить
    local side = minOf(s.fl, s.fr)
    if side then v = math.min(v, math.sqrt(2 * decel * math.max(0, side - 1.5)) + 6) end
    if s.fl and not s.fr then steer = steer + 0.5 elseif s.fr and not s.fl then steer = steer - 0.5 end
    -- Углы кузова: угол дома/столб рядом - выпрямить руль, отвести машину, сбавить
    local gap = 1.0 + math.min(speed, 10) * 0.1
    local nearL = s.cl and s.cl < gap and s.cl or nil
    local nearR = s.cr and s.cr < gap and s.cr or nil
    if nearL then
        v = math.min(v, 4 + nearL * 4)
        if steer < 0 then steer = steer * 0.25 end
        if not nearR then steer = steer + 0.35 end
    end
    if nearR then
        v = math.min(v, 4 + nearR * 4)
        if steer > 0 then steer = steer * 0.25 end
        if not nearL then steer = steer - 0.35 end
    end
    steer = clamp(steer, -1, 1)

    -- Плавная желаемая скорость (кроме опасности прямо по курсу)
    local dt = math.min(0.2, now - (bot.lastCtl or now))
    bot.lastCtl = now
    bot.vt = bot.vt or speed
    if danger then bot.vt = v
    elseif v < bot.vt then bot.vt = bot.vt + (v - bot.vt) * math.min(1, dt * 4)
    else bot.vt = bot.vt + (v - bot.vt) * math.min(1, dt * 1.5) end

    -- Педали пропорционально; небольшое превышение - просто отпускаем газ
    local diff = bot.vt - speed
    local gas, brake = 0, 0
    if diff > 0.3 then gas = clamp(diff / 6, 0.25, 1)
    elseif diff < -3 then brake = clamp((-diff - 3) / 8, 0.15, 1) end
    keys(steer, gas, brake)

    -- Упёрлись: стоим 1.2 с (газ нажат или нос у препятствия) - отъезжаем назад 2 с.
    -- Руль при заднем ходе в сторону препятствия: нос уходит от него.
    if speed < 0.5 and (gas > 0 or danger or nearL or nearR) then
        bot.stuckSince = bot.stuckSince or now
        if now - bot.stuckSince > 1.2 then
            local rs
            if nearR and not nearL then rs = 1
            elseif nearL and not nearR then rs = -1
            elseif s.fr and not s.fl then rs = 1
            elseif s.fl and not s.fr then rs = -1
            else rs = (steer >= 0) and 1 or -1 end
            bot.recover, bot.stuckSince = { start = now, till = now + 2, steer = rs }, nil
        end
    else
        bot.stuckSince = nil
    end
end

--==============================================================
-- Прицеп: /pricep спавнит визуальный прицеп (виден только вам),
-- /lhitch - бот сдаёт задом к прицепу и цепляет его.
--==============================================================
local TRAILER_MODEL = 591                         -- прицеп фуры (artict3)
local TRACTORS = { [403] = true, [514] = true, [515] = true } -- Linerunner, Tanker, Roadtrain
local trailer = { handle = nil }
local hitch = { active = false, status = '' }

local function trailerExists()
    return trailer.handle ~= nil and doesVehicleExist(trailer.handle)
end

local function deleteTrailer()
    if trailerExists() then pcall(deleteCar, trailer.handle) end
    trailer.handle = nil
end

local function spawnTrailer()
    if hitch.active then msg('Сначала дождитесь конца сцепки (/lhitch - отмена).') return end
    deleteTrailer()
    requestModel(TRAILER_MODEL)
    loadAllModelsNow()
    local t = os.clock()
    while not hasModelLoaded(TRAILER_MODEL) and os.clock() - t < 5 do wait(50) end
    if not hasModelLoaded(TRAILER_MODEL) then msg('Не удалось загрузить модель прицепа.') return end
    local x, y, z, h
    if isCharInAnyCar(PLAYER_PED) then
        local car = storeCarCharIsInNoSave(PLAYER_PED)
        x, y, z = getOffsetFromCarInWorldCoords(car, 0, -(geo(car).back + 13), 0.5)
        h = getCarHeading(car)
    else
        x, y, z = getOffsetFromCharInWorldCoords(PLAYER_PED, 0, 10, 0.5)
        h = getCharHeading(PLAYER_PED)
    end
    trailer.handle = createCar(TRAILER_MODEL, x, y, z)
    setCarHeading(trailer.handle, h)
    markModelAsNoLongerNeeded(TRAILER_MODEL)
    msg('Прицеп заспавнен (виден только вам). Прицепить ботом: /lhitch, удалить: /pricep del')
end

local function hitchStop(text)
    hitch.active = false
    botRelease()
    if text then msg(text) end
end

local function hitchStart()
    if hitch.active then hitchStop('Сцепка отменена.') return end
    if not trailerExists() then msg('Нет прицепа. Заспавните: /pricep') return end
    if not isCharInAnyCar(PLAYER_PED) then msg('Сядьте за руль фуры.') return end
    local car = storeCarCharIsInNoSave(PLAYER_PED)
    if getDriverOfCar(car) ~= PLAYER_PED then msg('Сядьте за руль.') return end
    if not TRACTORS[getCarModel(car)] then msg('Нужен тягач: Linerunner, Tanker или Roadtrain.') return end
    if isTrailerAttachedToCab(trailer.handle, car) then msg('Прицеп уже прицеплен.') return end
    hitch.active, hitch.phase, hitch.st, hitch.tries, hitch.start = true, 'approach', {}, 0, os.clock()
    hitch.status = 'Сцепка: подъезд'
    msg('Бот: еду цеплять прицеп. Отмена: /lhitch или W / S.')
end

-- Разворот на месте до нужного курса (ang - угол до курса в градусах, > 0 вправо).
-- Вперёд с полным рулём, назад с обратным, смена при препятствии ближе метра или упоре.
local function turnToHeading(car, st, ang, s, now, speed)
    if math.abs(ang) < 10 then return true end
    local dir = ang >= 0 and 1 or -1
    if not st.phase then
        local fg = minOf(s.fl, s.fc, s.fr)
        st.phase, st.since = (not fg or fg > 3.5) and 'fwd' or 'back', now
    end
    local t = now - st.since
    if speed > 0.5 then st.moved = now end
    local stalled = t > 1.0 and now - (st.moved or st.since) > 0.8
    if st.phase == 'fwd' then
        local fg, cg = minOf(s.fl, s.fc, s.fr), (dir > 0) and s.cr or s.cl
        if t > 0.4 and ((fg and fg < 1.0) or (cg and cg < 0.6) or stalled or t > 6) then
            st.phase, st.since, st.moved = 'back', now, nil
            keys(0, 0, 1)
            return false
        end
        keys(dir, (speed < 3) and 0.45 or 0, 0)
    else
        local r = senseRear(car)
        local rg, cg = minOf(r.bl, r.bc, r.br), (dir > 0) and r.rl or r.rr
        if t > 0.4 and ((rg and rg < 1.0) or (cg and cg < 0.6) or stalled or t > 5) then
            st.phase, st.since, st.moved = 'fwd', now, nil
            keys(0, 0, 0)
            return false
        end
        keys(-dir, 0, (speed < 2.5) and 0.6 or 0)
    end
    return false
end

local function hitchControl(car)
    local now = os.clock()
    if not trailerExists() then return hitchStop('Прицеп пропал, сцепка отменена.') end
    local tr = trailer.handle
    if isTrailerAttachedToCab(tr, car) then return hitchStop('Бот: прицеп прицеплен!') end
    if now - hitch.start > 150 then return hitchStop('Бот: не получилось прицепиться за 2.5 минуты.') end

    local speed = getCarSpeed(car)
    local g, tg = geo(car), geo(tr)
    -- шкворень прицепа (K) и направление прицепа (T); седло тягача (H)
    local kx, ky = getOffsetFromCarInWorldCoords(tr, 0, tg.front - 1.4, 0)
    local tfx, tfy = carBasis(tr)
    local hx, hy = getOffsetFromCarInWorldCoords(car, 0, -(g.back - 1.8), 0)
    local cx, cy = getCarCoordinates(car)
    local fx, fy = carBasis(car)
    local headErr = math.deg(math.acos(clamp(fx * tfx + fy * tfy, -1, 1)))
    local dHK = getDistanceBetweenCoords2d(hx, hy, kx, ky)
    -- положение седла относительно линии прицепа: along - сколько ещё ехать назад, e - вбок
    local along = (hx - kx) * tfx + (hy - ky) * tfy
    local e = (hx - kx) * tfy - (hy - ky) * tfx

    -- Рядом и ровно - цепляем
    if (dHK < 1.6 or (dHK < 3 and speed < 0.3 and hitch.phase == 'reverse')) and headErr < 25 then
        keys(0, 0, (speed > 0.5) and 0.4 or 0)
        if speed < 0.6 then
            attachTrailerToCab(tr, car)
            hitch.status = 'Сцепка: цепляю'
        end
        return
    end

    local s = senseFront(car, 8)
    local reach = g.front + g.back + 10                      -- стартовая точка перед прицепом
    local ax, ay = kx + tfx * reach, ky + tfy * reach

    -- Уже стоим ровно перед прицепом - сразу задним ходом
    if hitch.phase == 'approach' and along > 0 and along < 25 and math.abs(e) < 1.5 and headErr < 15 then
        hitch.phase, hitch.st = 'reverse', {}
    end

    if hitch.phase == 'approach' then
        hitch.status = 'Сцепка: подъезжаю к прицепу'
        local da = getDistanceBetweenCoords2d(cx, cy, ax, ay)
        local lx, ly = toLocal(car, ax, ay)
        local ang = math.atan2(lx, ly)
        if da < 4 or (da < 15 and math.abs(math.deg(ang)) > 100) then
            hitch.phase, hitch.st = 'align', {}
            return
        end
        local v = math.min(7, math.sqrt(2 * 4 * math.max(0, da - 2)) + 1.5)
        if s.fc then v = math.min(v, math.sqrt(2 * 5 * math.max(0, s.fc - 2.5))) end
        local steer = clamp(ang / 0.5, -1, 1)
        if math.abs(math.deg(ang)) > 100 then
            -- точка сзади: разворачиваемся к ней
            turnToHeading(car, hitch.st, math.deg(ang), s, now, speed)
            return
        end
        hitch.st.moved = hitch.st.moved or now
        if speed > 0.5 then hitch.st.moved = now end
        if now - hitch.st.moved > 3 then hitch.phase, hitch.st = 'align', {} return end
        local diff = v - speed
        keys(steer, (diff > 0.3) and clamp(diff / 5, 0.25, 0.8) or 0, (diff < -2) and 0.5 or 0)
        return
    end

    if hitch.phase == 'align' then
        hitch.status = 'Сцепка: выравниваюсь'
        local lx, ly = toLocal(car, cx + tfx * 60, cy + tfy * 60)
        if turnToHeading(car, hitch.st, math.deg(math.atan2(lx, ly)), s, now, speed) then
            keys(0, 0, (speed > 0.5) and 0.6 or 0)
            if speed < 0.5 then hitch.phase, hitch.st = 'reverse', {} end
        end
        return
    end

    -- Задний ход по линии прицепа (чистое преследование точки на линии)
    hitch.status = string.format('Сцепка: сдаю назад, %.1f м', dHK)
    if along < -1.5 or (along > 4 and (math.abs(e) > 2.5 or headErr > 30)) then
        hitch.tries = hitch.tries + 1
        if hitch.tries > 4 then return hitchStop('Бот: не получилось ровно подъехать к прицепу.') end
        hitch.phase, hitch.st = 'approach', {}
        return
    end
    local L = clamp(along * 0.5, 2.5, 6)
    local px, py = kx + tfx * math.max(0, along - L), ky + tfy * math.max(0, along - L)
    local lx, ly = toLocal(car, px, py)
    local steer = clamp(math.atan2(lx, -ly) / 0.35, -1, 1)   -- задний ход: руль вправо - зад уходит вправо
    local v = (dHK > 6) and 2.0 or 1.0
    keys(steer, 0, (speed < v) and 0.5 or 0)
end

local function botThread()
    while true do
        wait((bot.active or hitch.active) and 0 or 100)
        if hitch.active then
            -- Сцепка с прицепом (работает и при выключенном боте)
            local typing = sampIsChatInputActive() or sampIsDialogActive() or isSampfuncsConsoleActive()
            if not isCharInAnyCar(PLAYER_PED) or getDriverOfCar(storeCarCharIsInNoSave(PLAYER_PED)) ~= PLAYER_PED then
                hitchStop('Сцепка отменена: вы вышли из-за руля.')
            elseif not typing and (isKeyDown(0x57) or isKeyDown(0x53)) then
                hitchStop('Сцепка отменена: управление у вас.')
            else
                hitchControl(storeCarCharIsInNoSave(PLAYER_PED))
                bot.status = hitch.status
            end
        elseif cfg.bot.enabled ~= true then
            botRelease(); bot.status = 'Выключен'
        elseif isArizona() then
            botRelease(); bot.status = 'Недоступно на Arizona RP'
        elseif not isCharInAnyCar(PLAYER_PED) then
            botRelease(); bot.status = 'Сядьте в транспорт'
        else
            local car = storeCarCharIsInNoSave(PLAYER_PED)
            if getDriverOfCar(car) ~= PLAYER_PED then
                botRelease(); bot.status = 'Сядьте за руль'
            else
                local x, y, z, name = botTarget()
                if not x then
                    botRelease(); bot.status = 'Нет метки'; bot.arrived = false
                else
                    local px, py = getCharCoordinates(PLAYER_PED)
                    local dist = getDistanceBetweenCoords2d(px, py, x, y)
                    local typing = sampIsChatInputActive() or sampIsDialogActive() or isSampfuncsConsoleActive()
                    local manual = cfg.bot.takeover and not typing and (isKeyDown(0x57) or isKeyDown(0x53))

                    if not bot.tx or getDistanceBetweenCoords2d(bot.tx, bot.ty, x, y) > 10 then
                        bot.tx, bot.ty = x, y
                        bot.best, bot.bestTime, bot.gaveUp, bot.arrived = dist, os.clock(), false, false
                        bot.man, bot.recover, bot.wx, bot.commit, bot.turnAt = nil, nil, nil, nil, nil
                    end
                    if dist < bot.best - 5 then bot.best, bot.bestTime = dist, os.clock() end

                    if dist <= num(cfg.bot.radius, 12) then
                        if getCarSpeed(car) > 1 then keys(0, 0, 1) else botRelease() end
                        if not bot.arrived then msg('Бот: прибыли (' .. name .. ').') end
                        bot.arrived, bot.status = true, 'Прибыл'
                    elseif bot.gaveUp then
                        botRelease(); bot.status = 'Ближе по дороге не подъехать'
                    elseif os.clock() - bot.bestTime > 45 then
                        botRelease(); bot.gaveUp = true
                        msg('Бот: 45 секунд не получается приблизиться к метке, остановился.')
                    elseif manual then
                        botRelease(); bot.pauseUntil = os.clock() + 3
                        bot.status = 'Управление у вас'
                    elseif os.clock() >= bot.pauseUntil then
                        bot.status = string.format('Едет: %s, %d м', name, math.floor(dist))
                        botControl(car, x, y, z, dist)
                    end
                end
            end
        end
    end
end

--==============================================================
-- Меню (mimgui)
--==============================================================
local V4  = imgui.ImVec4
local function vec(x, y) return imgui.ImVec2(x, y) end
local function U32(c) return imgui.ColorConvertFloat4ToU32(c) end
local WHITE = V4(1, 1, 1, 1)
local GRAY  = V4(0.55, 0.58, 0.65, 1)
local GREEN = V4(0.35, 0.85, 0.45, 1)
local ACCENT = V4(0.25, 0.6, 1, 1)

local function f3(hex) local r, g, b = hexToRGB(hex) return imgui.new.float[3](r, g, b) end
local function setF3(arr, hex) local r, g, b = hexToRGB(hex) arr[0], arr[1], arr[2] = r, g, b end

local menu = { window = imgui.new.bool(false), tab = 1, frames = 0, err = nil }

local ui = {
    spawnOn    = imgui.new.bool(cfg.spawn.enabled == true),
    spawnMode  = imgui.new.int(num(cfg.spawn.mode, 0)),
    spawnDelay = imgui.new.int(num(cfg.spawn.delay, 1000)),
    spawnItem  = imgui.new.int(num(cfg.spawn.item, 1)),
    spawnKw    = imgui.new.char[64](tostring(cfg.spawn.keyword or '')),

    botOn      = imgui.new.bool(cfg.bot.enabled == true),
    botSource  = imgui.new.int(num(cfg.bot.source, 0)),
    botSpeed   = imgui.new.int(num(cfg.bot.speed, 25)),
    botStyle   = imgui.new.int(num(cfg.bot.style, 0)),
    botRadius  = imgui.new.int(num(cfg.bot.radius, 12)),
    botTake    = imgui.new.bool(cfg.bot.takeover ~= false),
    botTurn    = imgui.new.bool(cfg.bot.turn ~= false),
    botGps     = imgui.new.bool(cfg.bot.gps ~= false),
    botLane    = imgui.new.bool(cfg.bot.lane == true),
    botLaneOff = imgui.new.float(num(cfg.bot.laneOff, 2.5)),

    accent     = f3(cfg.theme.accent),
    bg         = f3(cfg.theme.bg),
    childAlpha = imgui.new.float(num(cfg.theme.childAlpha, 0.8)),
    rounding   = imgui.new.int(num(cfg.theme.rounding, 12)),
    pOn        = imgui.new.bool(cfg.particles.enabled ~= false),
    pRainbow   = imgui.new.bool(cfg.particles.rainbow == true),
    pColor     = f3(cfg.particles.color),
    pCount     = imgui.new.int(num(cfg.particles.count, 70)),
    pSpeed     = imgui.new.int(num(cfg.particles.speed, 60)),
    pSize      = imgui.new.float(num(cfg.particles.size, 2.0)),
    pAlpha     = imgui.new.float(num(cfg.particles.alpha, 0.6)),

    autoUpd    = imgui.new.bool(cfg.update.auto ~= false),
}

-- Тема ------------------------------------------------------------------
local function applyTheme()
    local style = imgui.GetStyle()
    local c, col = style.Colors, imgui.Col
    local ar, ag, ab = hexToRGB(cfg.theme.accent)
    local br, bg, bb = hexToRGB(cfg.theme.bg)
    local function mix(k, a)
        if k >= 0 then return V4(ar + (1 - ar) * k, ag + (1 - ag) * k, ab + (1 - ab) * k, a or 1) end
        return V4(ar * (1 + k), ag * (1 + k), ab * (1 + k), a or 1)
    end
    local function lift(k, a) return V4(math.min(1, br + k), math.min(1, bg + k), math.min(1, bb + k), a or 1) end
    local rnd = num(cfg.theme.rounding, 12)
    ACCENT = V4(ar, ag, ab, 1)

    style.WindowPadding     = vec(14, 14)
    style.FramePadding      = vec(10, 6)
    style.ItemSpacing       = vec(10, 10)
    style.WindowRounding    = rnd
    style.ChildRounding     = rnd * 0.8
    style.FrameRounding     = rnd * 0.6
    style.GrabRounding      = rnd * 0.6
    style.ScrollbarRounding = rnd * 0.6
    style.GrabMinSize       = 14
    style.WindowBorderSize  = 1
    style.ChildBorderSize   = 1

    c[col.WindowBg]         = V4(br, bg, bb, 0.97)
    c[col.ChildBg]          = lift(0.03, num(cfg.theme.childAlpha, 0.8))
    c[col.PopupBg]          = lift(0.02, 0.98)
    c[col.Border]           = V4(ar, ag, ab, 0.40)
    c[col.Separator]        = V4(ar, ag, ab, 0.25)
    c[col.Text]             = V4(0.92, 0.94, 0.97, 1.00)
    c[col.TextDisabled]     = GRAY
    c[col.FrameBg]          = lift(0.06)
    c[col.FrameBgHovered]   = lift(0.09)
    c[col.FrameBgActive]    = lift(0.12)
    c[col.Button]           = mix(-0.15)
    c[col.ButtonHovered]    = mix(0.12)
    c[col.ButtonActive]     = mix(-0.30)
    c[col.Header]           = V4(ar, ag, ab, 0.35)
    c[col.HeaderHovered]    = V4(ar, ag, ab, 0.50)
    c[col.HeaderActive]     = V4(ar, ag, ab, 0.65)
    c[col.PlotHistogram]    = ACCENT
    c[col.SliderGrab]       = ACCENT
    c[col.SliderGrabActive] = mix(0.25)
    c[col.CheckMark]        = ACCENT
    c[col.ScrollbarBg]      = lift(0.0)
    c[col.ScrollbarGrab]    = lift(0.12)
end

-- Шрифт с кириллицей. Таблица диапазонов хранится глобально, чтобы её не собрал сборщик мусора.
local fontRanges
imgui.OnInitialize(function()
    log('[menu] инициализация...')
    local io = imgui.GetIO()
    io.IniFilename = nil
    local dir = getFolderPath(0x14)
    local file
    for _, name in ipairs({ 'trebucbd.ttf', 'segoeui.ttf', 'arial.ttf', 'tahoma.ttf' }) do
        if dir and doesFileExist(dir .. '\\' .. name) then file = dir .. '\\' .. name break end
    end
    if file then
        fontRanges = io.Fonts:GetGlyphRangesCyrillic()
        io.Fonts:Clear()
        local font = io.Fonts:AddFontFromFileTTF(file, 16.0, nil, fontRanges)
        if font == nil then io.Fonts:AddFontDefault() end
        log('[menu] шрифт: ' .. file)
    end
    local ok, err = pcall(applyTheme)
    if not ok then log('[menu] ошибка темы: ' .. tostring(err)) end
    log('[menu] инициализация готова')
end)

-- Виджеты ---------------------------------------------------------------
local anim = {}
local function approach(id, target, speed)
    local v = anim[id] or target
    v = v + (target - v) * math.min(1, imgui.GetIO().DeltaTime * (speed or 12))
    anim[id] = v
    return v
end
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpV4(a, b, t) return V4(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t), lerp(a.w, b.w, t)) end

local function section(title)
    imgui.Spacing()
    imgui.TextColored(ACCENT, title)
    imgui.Separator()
end

local function hint(text)
    imgui.PushTextWrapPos(0)
    imgui.TextDisabled(text)
    imgui.PopTextWrapPos()
end

local function centerText(text, color)
    local w = imgui.CalcTextSize(text).x
    imgui.SetCursorPosX((imgui.GetWindowWidth() - w) / 2)
    imgui.TextColored(color or WHITE, text)
end

local function toggle(id, label, ptr)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local h  = imgui.GetFrameHeight()
    local w  = h * 1.9
    local clicked = imgui.InvisibleButton(id, vec(w, h))
    if clicked then ptr[0] = not ptr[0] end
    local t = approach(id, ptr[0] and 1 or 0)
    local bg = lerpV4(V4(0.22, 0.24, 0.30, 1), ACCENT, t)
    if imgui.IsItemHovered() then bg = lerpV4(bg, WHITE, 0.08) end
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(bg), h / 2)
    dl:AddCircleFilled(vec(p.x + h / 2 + t * (w - h), p.y + h / 2), h / 2 - 3, U32(WHITE), 24)
    imgui.SameLine()
    imgui.AlignTextToFramePadding()
    imgui.Text(label)
    return clicked
end

local function segmented(id, ptr, items)
    local sp = imgui.GetStyle().ItemSpacing.x
    local w  = (imgui.GetContentRegionAvail().x - sp * (#items - 1)) / #items
    local changed = false
    for i, name in ipairs(items) do
        if i > 1 then imgui.SameLine() end
        local active = ptr[0] == i - 1
        if not active then
            imgui.PushStyleColor(imgui.Col.Button, V4(0.22, 0.24, 0.30, 1))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, V4(0.30, 0.32, 0.40, 1))
        end
        if imgui.Button(name .. '##' .. id .. i, vec(w, 30)) and not active then
            ptr[0] = i - 1
            changed = true
        end
        if not active then imgui.PopStyleColor(2) end
    end
    return changed
end

local function sliderInt(label, id, ptr, min, max, fmt)
    imgui.Text(label)
    imgui.PushItemWidth(-1)
    local changed = imgui.SliderInt(id, ptr, min, max, fmt)
    imgui.PopItemWidth()
    return changed
end

local function sliderFloat(label, id, ptr, min, max, fmt)
    imgui.Text(label)
    imgui.PushItemWidth(-1)
    local changed = imgui.SliderFloat(id, ptr, min, max, fmt)
    imgui.PopItemWidth()
    return changed
end

local function colorRow(id, label, arr)
    local changed = imgui.ColorEdit3(id, arr, imgui.ColorEditFlags.NoInputs)
    imgui.SameLine()
    imgui.Text(label)
    return changed
end

local function grayButton(label, size)
    imgui.PushStyleColor(imgui.Col.Button,        V4(0.22, 0.24, 0.30, 1))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, V4(0.30, 0.32, 0.40, 1))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  V4(0.18, 0.20, 0.25, 1))
    local pressed = imgui.Button(label, size)
    imgui.PopStyleColor(3)
    return pressed
end

-- Иконки (рисуются линиями) ------------------------------------------------
local function iconPerson(dl, c, col)
    dl:AddCircleFilled(vec(c.x, c.y - 4), 3.5, col, 16)
    dl:AddRectFilled(vec(c.x - 6, c.y + 1), vec(c.x + 6, c.y + 8), col, 4)
end

local function drawTruck(dl, x, y, s, body, cab)
    local function R(a, b, c2, d, col, r) dl:AddRectFilled(vec(x + a * s, y + b * s), vec(x + c2 * s, y + d * s), col, r or 0) end
    R(0, 4, 38, 26, body, 3 * s)          -- кузов
    R(40, 10, 56, 26, cab, 3 * s)         -- кабина
    R(44, 13, 53, 19, U32(V4(0.6, 0.8, 1, 0.9)), 1.5 * s) -- окно
    for _, wx in ipairs({ 9, 30, 48 }) do
        dl:AddCircleFilled(vec(x + wx * s, y + 28 * s), 4.5 * s, U32(V4(0.1, 0.1, 0.12, 1)), 16)
        dl:AddCircleFilled(vec(x + wx * s, y + 28 * s), 2 * s, U32(V4(0.6, 0.6, 0.65, 1)), 12)
    end
end
local function iconTruck(dl, c, col) drawTruck(dl, c.x - 9.3, c.y - 6, 0.32, col, col) end

local function iconPalette(dl, c, col)
    dl:AddCircle(c, 7.5, col, 20, 2)
    for i = 0, 2 do
        local a = i * 2.1 - 1.2
        dl:AddCircleFilled(vec(c.x + math.cos(a) * 3.8, c.y + math.sin(a) * 3.8), 1.8, col, 8)
    end
end

local function iconInfo(dl, c, col)
    dl:AddCircle(c, 7.5, col, 20, 2)
    dl:AddRectFilled(vec(c.x - 1, c.y - 1), vec(c.x + 1, c.y + 4.5), col)
    dl:AddCircleFilled(vec(c.x, c.y - 3.5), 1.3, col, 8)
end

local function iconClose(dl, c, col)
    dl:AddLine(vec(c.x - 5, c.y - 5), vec(c.x + 5, c.y + 5), col, 2)
    dl:AddLine(vec(c.x + 5, c.y - 5), vec(c.x - 5, c.y + 5), col, 2)
end

local function sidebarButton(id, name, icon, active)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    local h  = 40
    local clicked = imgui.InvisibleButton(id, vec(w, h))
    local t = approach(id, active and 1 or (imgui.IsItemHovered() and 0.45 or 0), 14)
    if t > 0.01 then
        dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(V4(ACCENT.x, ACCENT.y, ACCENT.z, 0.18 * t)), 8)
    end
    if active then dl:AddRectFilled(vec(p.x, p.y + 8), vec(p.x + 4, p.y + h - 8), U32(ACCENT), 2) end
    local col = U32(lerpV4(GRAY, WHITE, t))
    icon(dl, vec(p.x + 22, p.y + h / 2), col)
    dl:AddText(vec(p.x + 42, p.y + (h - imgui.GetTextLineHeight()) / 2), col, name)
    return clicked
end

-- Падающие частицы ---------------------------------------------------------
local particles = {}
local function newParticle(w, h, fromTop)
    return { x = math.random() * w, y = fromTop and -math.random() * 20 or math.random() * h,
             sp = 0.5 + math.random(), drift = (math.random() - 0.5) * 12,
             sz = 0.6 + math.random() * 0.8, a = 0.4 + math.random() * 0.6, hue = math.random() }
end

local function drawParticles(dl, pos, size)
    local P = cfg.particles
    if not P.enabled then return end
    local n = math.floor(clamp(num(P.count, 0), 0, 300))
    while #particles < n do particles[#particles + 1] = newParticle(size.x, size.y, false) end
    while #particles > n do particles[#particles] = nil end
    local dt, time = imgui.GetIO().DeltaTime, imgui.GetTime()
    local r, g, b = hexToRGB(P.color)
    for i = 1, #particles do
        local p = particles[i]
        p.y = p.y + num(P.speed, 60) * p.sp * dt
        p.x = p.x + p.drift * dt
        if p.y > size.y + 6 or p.x < -6 or p.x > size.x + 6 then
            p = newParticle(size.x, size.y, true)
            particles[i] = p
        end
        local cr, cg, cb = r, g, b
        if P.rainbow then cr, cg, cb = hsv((p.hue + time * 0.1) % 1, 0.65, 1) end
        dl:AddCircleFilled(vec(pos.x + p.x, pos.y + p.y), num(P.size, 2) * p.sz,
                           U32(V4(cr, cg, cb, num(P.alpha, 0.6) * p.a)), 12)
    end
end

-- Вкладки ----------------------------------------------------------------
local function drawSpawnTab()
    section('Основное')
    if toggle('##spawn_on', 'Включить авто спавн', ui.spawnOn) then
        cfg.spawn.enabled = ui.spawnOn[0]; saveCfg()
    end
    section('Режим')
    if segmented('spawn_mode', ui.spawnMode, { 'Кнопка Spawn', 'Пункт в диалоге' }) then
        cfg.spawn.mode = ui.spawnMode[0]; saveCfg()
    end
    if ui.spawnMode[0] == 0 then
        hint('Скрипт сам нажмёт Spawn, когда персонаж ещё не появился и нет открытых диалогов.')
    else
        hint('Когда откроется диалог с ключевым словом в заголовке, скрипт выберет нужный пункт.')
        imgui.Text('Ключевое слово:')
        imgui.PushItemWidth(-1)
        if imgui.InputText('##spawn_kw', ui.spawnKw, ffi.sizeof(ui.spawnKw)) then
            cfg.spawn.keyword = ffi.string(ui.spawnKw); saveCfg()
        end
        imgui.PopItemWidth()
        if sliderInt('Номер пункта:', '##spawn_item', ui.spawnItem, 1, 10, 'Пункт %d') then
            cfg.spawn.item = ui.spawnItem[0]; saveCfg()
        end
    end
    section('Задержка')
    if sliderInt('Перед спавном:', '##spawn_delay', ui.spawnDelay, 0, 5000, '%d мс') then
        cfg.spawn.delay = ui.spawnDelay[0]; saveCfg()
    end
end

local function drawFarmTab()
    section('Бот дальнобойщик')
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    local h  = 92
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(V4(ACCENT.x, ACCENT.y, ACCENT.z, 0.10)), 10)
    local sway = bot.active and math.sin(imgui.GetTime() * 12) * 0.6 or 0
    drawTruck(dl, p.x + 14, p.y + 14 + sway, 2.3, U32(V4(0.85, 0.87, 0.92, 1)), U32(ACCENT))
    dl:AddText(vec(p.x + 170, p.y + 22), U32(WHITE), 'Статус:')
    local scol = bot.active and GREEN or (cfg.bot.enabled == true and V4(1.0, 0.8, 0.35, 1) or GRAY)
    dl:AddText(vec(p.x + 170, p.y + 44), U32(scol), tostring(bot.status or ''))
    imgui.Dummy(vec(w, h))

    if toggle('##bot_on', 'Включить бота', ui.botOn) then
        cfg.bot.enabled = ui.botOn[0]; saveCfg()
    end

    section('Куда ехать')
    if segmented('bot_src', ui.botSource, { 'Авто', 'Чекпоинт', 'Метка на карте' }) then
        cfg.bot.source = ui.botSource[0]; saveCfg(); bot.tx = nil
    end
    if not hasSampev then
        hint('Для красных чекпоинтов сервера нужна библиотека SAMP.Lua (lib/samp/events). Метка на карте работает без неё.')
    end

    section('Вождение')
    if segmented('bot_style', ui.botStyle, { 'Обычный', 'Аккуратный' }) then
        cfg.bot.style = ui.botStyle[0]; saveCfg()
    end
    local speedFmt = (ui.botSpeed[0] >= SPEED_NO_LIMIT) and 'No Limit' or '%d'
    if sliderInt('Скорость:', '##bot_speed', ui.botSpeed, 5, SPEED_NO_LIMIT, speedFmt) then
        cfg.bot.speed = ui.botSpeed[0]; saveCfg()
    end
    if sliderInt('Радиус прибытия:', '##bot_radius', ui.botRadius, 3, 40, '%d м') then
        cfg.bot.radius = ui.botRadius[0]; saveCfg()
    end
    if toggle('##bot_take', 'W / S забирают управление', ui.botTake) then
        cfg.bot.takeover = ui.botTake[0]; saveCfg()
    end
    if toggle('##bot_turn', 'Разворот к метке (вперёд или задним ходом)', ui.botTurn) then
        cfg.bot.turn = ui.botTurn[0]; saveCfg()
    end
    if toggle('##bot_gps', 'Маршрут по дорогам GTA (как у трафика)', ui.botGps) then
        cfg.bot.gps = ui.botGps[0]; saveCfg(); bot.route = nil
    end
    if not gps.ok then hint('Маршрут по дорогам GTA недоступен в этой версии игры, используется обычный способ.') end

    section('Прицеп')
    local bw = (imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x * 2) / 3
    if imgui.Button('Заспавнить##tr_spawn', vec(bw, 30)) then lua_thread.create(spawnTrailer) end
    imgui.SameLine()
    if imgui.Button((hitch.active and 'Отмена' or 'Прицепить') .. '##tr_hitch', vec(bw, 30)) then hitchStart() end
    imgui.SameLine()
    if grayButton('Удалить##tr_del', vec(bw, 30)) then
        if hitch.active then hitchStop() end
        deleteTrailer()
    end
    hint('Визуальный прицеп 591 (виден только вам). Бот на тягаче (Linerunner, Tanker, Roadtrain) встаёт перед прицепом, выравнивается и сдаёт задом до сцепки. Команды: /pricep, /pricep del, /lhitch.')

    section('Полоса')
    if toggle('##bot_lane', 'Держаться своей полосы', ui.botLane) then
        cfg.bot.lane = ui.botLane[0]; saveCfg()
    end
    if ui.botLane[0] then
        if sliderFloat('Смещение от середины дороги:', '##bot_lane_off', ui.botLaneOff, 1.0, 6.0, '%.1f м') then
            cfg.bot.laneOff = ui.botLaneOff[0]; saveCfg()
        end
        hint('Задевает бордюр - уменьшите смещение, выезжает на встречку - увеличьте.')
    end
    hint('Свой автопилот: едет по дорожным узлам игры, светофоров не видит, тормозит перед препятствиями, не срезает углы, разворачивается к метке. Скорость до упора вправо - No Limit. Не работает на Arizona RP.')
end

local PRESETS = {
    { accent = '#3F99FF', bg = '#12141C' }, { accent = '#9B5CFF', bg = '#15121C' },
    { accent = '#FF4D6A', bg = '#1A1214' }, { accent = '#2ED47A', bg = '#111A15' },
    { accent = '#FFB020', bg = '#1A1610' }, { accent = '#21C7D9', bg = '#10181A' },
}

local function presetSwatches()
    local dl = imgui.GetWindowDrawList()
    local d = 30
    for i, pr in ipairs(PRESETS) do
        if i > 1 then imgui.SameLine() end
        local p = imgui.GetCursorScreenPos()
        if imgui.InvisibleButton('##preset' .. i, vec(d, d)) then
            cfg.theme.accent, cfg.theme.bg = pr.accent, pr.bg
            setF3(ui.accent, pr.accent); setF3(ui.bg, pr.bg)
            applyTheme(); saveCfg()
        end
        local r, g, b = hexToRGB(pr.accent)
        local c = vec(p.x + d / 2, p.y + d / 2)
        dl:AddCircleFilled(c, d / 2 - (imgui.IsItemHovered() and 2 or 4), U32(V4(r, g, b, 1)), 32)
        if tostring(cfg.theme.accent):upper() == pr.accent then
            dl:AddCircle(c, d / 2 - 0.5, U32(V4(1, 1, 1, 0.9)), 32, 2)
        end
    end
end

local function resetTheme()
    cfg.theme.accent, cfg.theme.bg, cfg.theme.childAlpha, cfg.theme.rounding = '#3F99FF', '#12141C', 0.80, 12
    local P = cfg.particles
    P.enabled, P.count, P.speed, P.size, P.alpha, P.color, P.rainbow = true, 70, 60, 2.0, 0.60, '#FFFFFF', false
    setF3(ui.accent, cfg.theme.accent); setF3(ui.bg, cfg.theme.bg); setF3(ui.pColor, P.color)
    ui.childAlpha[0], ui.rounding[0] = 0.80, 12
    ui.pOn[0], ui.pRainbow[0], ui.pCount[0], ui.pSpeed[0], ui.pSize[0], ui.pAlpha[0] = true, false, 70, 60, 2.0, 0.60
    applyTheme(); saveCfg()
end

local function drawThemeTab()
    section('Готовые темы')
    presetSwatches()
    section('Цвета меню')
    if colorRow('##accent', 'Основной цвет', ui.accent) then
        cfg.theme.accent = rgbToHex(ui.accent[0], ui.accent[1], ui.accent[2]); applyTheme(); saveCfg()
    end
    if colorRow('##bg', 'Цвет фона', ui.bg) then
        cfg.theme.bg = rgbToHex(ui.bg[0], ui.bg[1], ui.bg[2]); applyTheme(); saveCfg()
    end
    if sliderFloat('Прозрачность панелей:', '##childAlpha', ui.childAlpha, 0.2, 1.0, '%.2f') then
        cfg.theme.childAlpha = ui.childAlpha[0]; applyTheme(); saveCfg()
    end
    if sliderInt('Скругление:', '##rounding', ui.rounding, 0, 20, '%d px') then
        cfg.theme.rounding = ui.rounding[0]; applyTheme(); saveCfg()
    end
    section('Падающие частицы')
    local P = cfg.particles
    if toggle('##p_on', 'Включить частицы', ui.pOn) then P.enabled = ui.pOn[0]; saveCfg() end
    if toggle('##p_rainbow', 'Радужные частицы', ui.pRainbow) then P.rainbow = ui.pRainbow[0]; saveCfg() end
    if not ui.pRainbow[0] and colorRow('##p_color', 'Цвет частиц', ui.pColor) then
        P.color = rgbToHex(ui.pColor[0], ui.pColor[1], ui.pColor[2]); saveCfg()
    end
    if sliderInt('Количество:', '##p_count', ui.pCount, 0, 300, '%d шт.') then P.count = ui.pCount[0]; saveCfg() end
    if sliderInt('Скорость:', '##p_speed', ui.pSpeed, 5, 400, '%d') then P.speed = ui.pSpeed[0]; saveCfg() end
    if sliderFloat('Размер:', '##p_size', ui.pSize, 0.5, 6.0, '%.1f') then P.size = ui.pSize[0]; saveCfg() end
    if sliderFloat('Яркость:', '##p_alpha', ui.pAlpha, 0.05, 1.0, '%.2f') then P.alpha = ui.pAlpha[0]; saveCfg() end
    imgui.Spacing()
    if grayButton('Сбросить оформление', vec(-1, 34)) then resetTheme() end
end

local function drawInfoTab()
    section('Скрипт')
    imgui.Text('Версия:'); imgui.SameLine(110); imgui.TextColored(GREEN, SCRIPT_VERSION)
    imgui.Text('Автор:');  imgui.SameLine(110); imgui.TextColored(GRAY, 'denismaslov769-lab')
    section('Обновления')
    if toggle('##auto_upd', 'Автоматически проверять обновления', ui.autoUpd) then
        cfg.update.auto = ui.autoUpd[0]; saveCfg()
    end
    if imgui.Button('Проверить обновления', vec(-1, 34)) then checkUpdates(true) end
    section('Команды')
    imgui.Text('/lafk');    imgui.SameLine(110); imgui.TextDisabled('открыть / закрыть меню')
    imgui.Text('/lafkupd'); imgui.SameLine(110); imgui.TextDisabled('проверить обновления')
    imgui.Text('/ltruck');  imgui.SameLine(110); imgui.TextDisabled('вкл / выкл бота дальнобойщика')
    imgui.Text('/pricep');  imgui.SameLine(110); imgui.TextDisabled('заспавнить прицеп (del - удалить)')
    imgui.Text('/lhitch');  imgui.SameLine(110); imgui.TextDisabled('бот цепляет прицеп / отмена')
end

local TABS = {
    { name = 'Авто спавн', icon = iconPerson,  draw = drawSpawnTab },
    { name = 'Авто фарм',  icon = iconTruck,   draw = drawFarmTab  },
    { name = 'Оформление', icon = iconPalette, draw = drawThemeTab },
    { name = 'Информация', icon = iconInfo,    draw = drawInfoTab  },
}

-- Ошибка внутри вкладки ловится и показывается текстом: Begin/End всегда парные,
-- поэтому окно не ломается и игра не вылетает.
local function safe(where, fn)
    local ok, err = pcall(fn)
    if not ok then
        err = tostring(err)
        if menu.err ~= err then menu.err = err; log('[menu] ошибка (' .. where .. '): ' .. err) end
        imgui.TextColored(V4(1, 0.4, 0.4, 1), 'Ошибка: ' .. err)
    end
end

imgui.OnFrame(
    function() return menu.window[0] end,
    function()
        menu.frames = menu.frames + 1
        -- Диагностика вылетов: каждые 30 кадров пишем в moonloader.log начало и конец кадра
        local trace = menu.frames <= 3 or menu.frames % 30 == 0
        local function step(t) if trace then log('[menu] кадр ' .. menu.frames .. ': ' .. t) end end
        step('начало')
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
        imgui.SetNextWindowSize(vec(700, 480), imgui.Cond.Always)
        imgui.Begin('##lua_afk_menu', menu.window,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)

        step('окно')
        safe('частицы', function()
            drawParticles(imgui.GetWindowDrawList(), imgui.GetWindowPos(), imgui.GetWindowSize())
        end)

        step('панель')
        imgui.BeginChild('##sidebar', vec(190, 0), true)
        safe('меню слева', function()
            centerText('lua_afk', ACCENT)
            centerText('v' .. SCRIPT_VERSION, GRAY)
            imgui.Spacing(); imgui.Separator(); imgui.Spacing()
            for i, tab in ipairs(TABS) do
                if sidebarButton('##tab' .. i, tab.name, tab.icon, menu.tab == i) then menu.tab = i end
            end
            imgui.SetCursorPosY(imgui.GetWindowHeight() - 40 - imgui.GetStyle().WindowPadding.y)
            if sidebarButton('##close', 'Закрыть', iconClose, false) then menu.window[0] = false end
        end)
        imgui.EndChild()

        imgui.SameLine()

        imgui.BeginChild('##content', vec(0, 0), true)
        local tab = TABS[menu.tab] or TABS[1]
        step('вкладка ' .. menu.tab)
        safe(tab.name, function()
            imgui.TextColored(ACCENT, tab.name)
            tab.draw()
        end)
        imgui.EndChild()

        imgui.End()
        step('конец')
    end
)

--==============================================================
-- Окно обновления
--==============================================================
local UPD_W = 360
imgui.OnFrame(
    function() return upd.window[0] end,
    function()
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
        imgui.SetNextWindowSize(vec(UPD_W, 0), imgui.Cond.Always)
        imgui.Begin('lua_afk - обновление', nil, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
        safe('обновление', function()
            upd.shown = upd.shown + (upd.progress - upd.shown) * math.min(1, imgui.GetIO().DeltaTime * 6)
            if upd.state == 'prompt' then
                imgui.Text('Доступна новая версия: ')
                imgui.SameLine(); imgui.TextColored(GREEN, tostring(upd.latest))
                imgui.TextDisabled('Установлена: ' .. SCRIPT_VERSION)
                if upd.changelog then imgui.Spacing(); hint(upd.changelog) end
                imgui.Spacing()
                local bw = (imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x) / 2
                if imgui.Button('Обновить', vec(bw, 32)) then startDownload() end
                imgui.SameLine()
                if grayButton('Отмена', vec(bw, 32)) then
                    upd.dismissed, upd.state, upd.window[0] = upd.latest, 'idle', false
                end
            elseif upd.state == 'downloading' or upd.state == 'installing' then
                imgui.Text(upd.state == 'downloading' and 'Загрузка обновления...' or 'Установка...')
                imgui.ProgressBar(upd.shown, vec(-1, 22))
            elseif upd.state == 'error' then
                imgui.TextColored(V4(1, 0.45, 0.45, 1), tostring(upd.error))
                local bw = (imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x) / 2
                if imgui.Button('Повторить', vec(bw, 32)) then startDownload() end
                imgui.SameLine()
                if grayButton('Закрыть', vec(bw, 32)) then upd.state, upd.window[0] = 'idle', false end
            else
                upd.window[0] = false
            end
        end)
        imgui.End()
    end
)

--==============================================================
-- Запуск
--==============================================================
-- Защита от копий: два lua_afk одновременно (например "lua_afk (1).lua") рулят машиной
-- вдвоём и ломают меню. Самая новая копия выгружает остальные.
local function killDuplicates()
    local me = thisScript()
    local myFile = ((me.path or ''):match('[^\\/]+$') or ''):lower()
    local others = {}
    local ok, list = pcall(script.list)
    if not ok or type(list) ~= 'table' then return true end
    for _, s in ipairs(list) do
        if s.path ~= me.path and (s.name == me.name or ((s.path or ''):lower():find('lua_afk', 1, true))) then
            local v = tostring(s.version or '0')
            local file = ((s.path or ''):match('[^\\/]+$') or '')
            if isNewer(v, SCRIPT_VERSION) or (v == SCRIPT_VERSION and file:lower() == 'lua_afk.lua' and myFile ~= 'lua_afk.lua') then
                return false
            end
            others[#others + 1] = { s = s, file = file, v = v }
        end
    end
    for _, d in ipairs(others) do
        log('[lua_afk] выгружена лишняя копия ' .. d.file .. ' (v' .. d.v .. ')')
        msg('Лишняя копия скрипта: ' .. d.file .. ' (v' .. d.v .. ') отключена. Удалите этот файл из папки moonloader.')
        pcall(function() d.s:unload() end)
    end
    return true
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    if not killDuplicates() then
        log('[lua_afk] запущена более новая копия, эта отключается: ' .. tostring(thisScript().path))
        return
    end

    sampRegisterChatCommand('lafk', function() menu.window[0] = not menu.window[0] end)
    sampRegisterChatCommand('lafkupd', function() checkUpdates(true) end)
    sampRegisterChatCommand('pricep', function(arg)
        if tostring(arg):lower():find('del', 1, true) then
            if hitch.active then hitchStop() end
            deleteTrailer(); msg('Прицеп удалён.')
        else
            lua_thread.create(spawnTrailer)
        end
    end)
    sampRegisterChatCommand('lhitch', hitchStart)
    sampRegisterChatCommand('ltruck', function()
        cfg.bot.enabled = not (cfg.bot.enabled == true); ui.botOn[0] = cfg.bot.enabled; saveCfg()
        msg(cfg.bot.enabled and 'Бот дальнобойщик включён.' or 'Бот дальнобойщик выключен.')
    end)
    msg('Загружен v' .. SCRIPT_VERSION .. '. Меню: /lafk')
    log('[lua_afk] v' .. SCRIPT_VERSION .. ', файл: ' .. tostring(thisScript().path))

    lua_thread.create(netThread)
    lua_thread.create(autoSpawnThread)
    lua_thread.create(botThread)
    lua_thread.create(updateScheduler)

    local beat = os.clock()
    while true do
        wait(0)
        if menu.window[0] and os.clock() - beat > 1 then
            beat = os.clock()
            log('[main] жив, меню открыто, кадров: ' .. menu.frames)
        end
        if upd.state == 'installing' and (upd.shown >= 0.999 or not upd.window[0]) then
            -- Сначала закрываем окна и отпускаем клавиши, ждём пока mimgui перестанет рисовать,
            -- и только потом пишем файл. AutoReboot.lua сам перезапускает скрипт при изменении
            -- файла - если он это сделал, второй перезапуск не нужен (двойной перезапуск опасен).
            upd.window[0], menu.window[0] = false, false
            botRelease()
            wait(700)
            if installUpdate() then
                wait(2500)
                thisScript():reload()
                return
            end
        end
    end
end

function onScriptTerminate(s, quit)
    if s == thisScript() then
        botRelease()
        pcall(deleteTrailer)
    end
end
