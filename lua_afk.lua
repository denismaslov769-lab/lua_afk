-- lua_afk.lua
-- Скрипт для SA-MP (MoonLoader): меню, бот дальнобойщик, автообновление
-- Требуется: MoonLoader, SAMPFUNCS, mimgui. Для чекпоинтов бота: SAMP.Lua (lib/samp/events)
-- @changelog: Повороты проходит быстрее (точнее считает радиус поворота). Своя карта дорог всего штата (из файлов игры) и свой поиск пути: бот видит маршрут до далёкой метки сразу, учитывает односторонние дороги и трассы, не мечется вперёд-назад. Бот ездит только по дорогам: убрана езда напрямую. Нет продвижения - отъезжает и ищет другой маршрут по дорогам (с разворотом и без), без слепой езды. Метка в стороне от дороги - останавливается у ближайшей точки дороги. Гифки по ссылке или коду встраивания Tenor/Giphy прямо в меню (фон и частицы). Бот больше не сдаётся: если не может приблизиться к метке, пробует другие пути (напрямую вне дорог, отъезд и новый маршрут). Метка вдали от дороги - доезжает до неё по бездорожью. Развязки и развилки: бот едет по самой линии маршрута (не срезает через отбойник), не путает эстакады, быстрее замечает, что ушёл не в ту ветку, и заранее сбрасывает скорость перед изгибами. Сцепка: мало места перед прицепом - бот подъезжает ближе и сдаёт с короткого расстояния, не крутится бесконечно (останавливается с подсказкой). Новый виджет бота во вкладке Авто фарм (дорога, скорость, расстояние, прицеп, прогресс, кнопка запуска). Частицы Arizona и Hearts. ПКМ - Убрать фон у своих частиц. Сцепка: прицеп далеко или за забором - бот едет к нему в объезд и быстрее, без качелей вперёд-назад. Меню на правую кнопку мыши по файлам фона и частиц: поставить, убрать фон, удалить из папки. Кнопка Убрать фон. Меню: автоконтраст для любых тем (светлые темы теперь читаются), новая вкладка Настройки (шестерня), свой фон меню - картинки, GIF, видео и папки с кадрами, свои картинки для падающих частиц. Авто спавн удалён.

script_name('lua_afk')
script_author('denismaslov769-lab')
script_version('2.5.1')

local imgui    = require('mimgui')
local encoding = require('encoding')
local inicfg   = require('inicfg')
local ffi      = require('ffi')
local dlstatus = require('moonloader').download_status
local hasSampev, sampev = pcall(require, 'lib.samp.events')

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local SCRIPT_VERSION = '2.5.1'
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
        mode    = 0,        -- 0 = точки, 1 = свои картинки
        images  = '',       -- выбранные картинки через |
        cutbg   = '',       -- картинки, у которых убирается фон
        spin    = true,
        tint    = false,
    },
    bgimg = {
        enabled = false,
        file    = '',       -- файл или папка в config/lua_afk/backgrounds
        fit     = 0,        -- 0 = заполнить, 1 = вписать, 2 = растянуть
        dim     = 0.45,     -- затемнение в цвет темы
        speed   = 1.0,      -- скорость анимации
        fps     = 20,       -- кадров в секунду для видео
        quality = 1,        -- 0..2
        flip    = false,
    },
    update = {
        auto = true,
    },
}, INI)
cfg.spawn = nil -- авто спавн удалён: старая секция больше не сохраняется
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
        local rx0, ry0 = getClosestCarNode(tx, ty, tz)
        if rx0 and fin(rx0) and getDistanceBetweenCoords2d(rx0, ry0, tx, ty) < 15 then return tx, ty, true end
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

-- Карта дорог всего штата ---------------------------------------------------
-- Игра держит в памяти дороги только вокруг игрока, поэтому её поиск пути не
-- видит далёкую метку и бот метался. Здесь дороги читаются целиком из файлов игры
-- (nodes0..63.dat в models\gta3.img) один раз при запуске, а маршрут ищется своим
-- A* по всей карте. Учитываются односторонние дороги (на трассах встречка - это
-- отдельная дорога, по ней не поедем) и курс машины (без лишних разворотов).
local roadmap = { state = 'none', n = 0 }
do
    local function imgEntries(path)
        local f = io.open(path, 'rb')
        if not f then return nil end
        local hdr = f:read(8)
        if not hdr or #hdr < 8 or hdr:sub(1, 4) ~= 'VER2' then f:close() return nil end
        local cnt = ffi.cast('const uint32_t *', ffi.cast('const uint8_t *', hdr) + 4)[0]
        if cnt <= 0 or cnt > 100000 then f:close() return nil end
        local dir = f:read(cnt * 32)
        if not dir or #dir < cnt * 32 then f:close() return nil end
        local p = ffi.cast('const uint8_t *', dir)
        local out = {}
        for i = 0, cnt - 1 do
            local e = p + i * 32
            local name = ffi.string(e + 8, 24):match('^[^%z]*'):lower()
            local a = name:match('^nodes(%d+)%.dat$')
            if a then
                local s16 = ffi.cast('const uint16_t *', e + 4)
                local sz = (s16[1] ~= 0) and s16[1] or s16[0]
                out[tonumber(a)] = { off = ffi.cast('const uint32_t *', e)[0] * 2048, size = sz * 2048 }
            end
        end
        return f, out
    end

    function roadmap.load()
        roadmap.state = 'loading'
        local ok, err = pcall(function()
            local gd = getGameDirectory()
            local f, ent = imgEntries(gd .. '\\models\\gta3.img')
            local files = {}
            for a = 0, 63 do
                local d
                if f and ent[a] then f:seek('set', ent[a].off); d = f:read(ent[a].size) end
                if not d then
                    local lf = io.open(gd .. '\\data\\paths\\nodes' .. a .. '.dat', 'rb')
                    if lf then d = lf:read('*a'); lf:close() end
                end
                files[a] = d
                if a % 8 == 7 then wait(0) end
            end
            if f then f:close() end
            -- разметка файлов
            local A, N = {}, 0
            for a = 0, 63 do
                local d = files[a]
                if d and #d >= 20 then
                    local p = ffi.cast('const uint8_t *', d)
                    local h = ffi.cast('const uint32_t *', p)
                    local nn, nv, nnavi, nl = tonumber(h[0]), tonumber(h[1]), tonumber(h[3]), tonumber(h[4])
                    local navOff = 20 + nn * 28
                    local linkOff = navOff + nnavi * 14
                    if nn < 30000 and nv <= nn and linkOff + nl * 4 <= #d
                        and (nv == 0 or ffi.cast('const uint16_t *', p + 20 + 18)[0] == a) then
                        A[a] = { d = d, p = p, nv = nv, nnavi = nnavi, nl = nl, navOff = navOff, linkOff = linkOff, base = N }
                        N = N + nv
                    end
                end
            end
            if N < (roadmap.minNodes or 500) then error('нет данных дорог (' .. N .. ')') end
            -- где лежат ссылки на "навигационные" узлы (с полосами): после ссылок есть
            -- 768 байт запаса - проверяем оба варианта по правдоподобию
            for a, ar in pairs(A) do
                local best, bestOff = -1, nil
                for _, off in ipairs({ ar.linkOff + ar.nl * 4 + 768, ar.linkOff + ar.nl * 4 }) do
                    if off + ar.nl * 2 <= #ar.d then
                        local q, good = ffi.cast('const uint16_t *', ar.p + off), 0
                        for i = 0, math.min(ar.nl, 200) - 1 do
                            local v = q[i]
                            local na, ni = bit.rshift(v, 10), bit.band(v, 1023)
                            if A[na] and ni < A[na].nnavi then good = good + 1 end
                        end
                        if good > best then best, bestOff = good, off end
                    end
                end
                ar.naviLinkOff = (best >= math.min(ar.nl, 200) * 0.9) and bestOff or nil
            end
            local X, Y, Z = ffi.new('float[?]', N), ffi.new('float[?]', N), ffi.new('float[?]', N)
            local OFF = ffi.new('uint8_t[?]', N)
            local LS = ffi.new('int32_t[?]', N + 1)
            local to, len = {}, {}
            local E = 0
            for a = 0, 63 do
                local ar = A[a]
                if ar then
                    for i = 0, ar.nv - 1 do
                        local np = ar.p + 20 + i * 28
                        local s16 = ffi.cast('const int16_t *', np + 8)
                        local g = ar.base + i
                        X[g], Y[g], Z[g] = s16[0] / 8, s16[1] / 8, s16[2] / 8
                        local flags = ffi.cast('const uint32_t *', np + 24)[0]
                        if bit.band(flags, 0x20) ~= 0 then OFF[g] = 1 end
                    end
                end
                if a % 16 == 15 then wait(0) end
            end
            for a = 0, 63 do
                local ar = A[a]
                if ar then
                    local links = ffi.cast('const uint16_t *', ar.p + ar.linkOff)
                    local nav = ar.naviLinkOff and ffi.cast('const uint16_t *', ar.p + ar.naviLinkOff)
                    for i = 0, ar.nv - 1 do
                        local np = ar.p + 20 + i * 28
                        local g = ar.base + i
                        LS[g] = E
                        local bl = ffi.cast('const uint16_t *', np + 16)[0]
                        local flags = ffi.cast('const uint32_t *', np + 24)[0]
                        local nlk = bit.band(flags, 15)
                        if bit.band(flags, 0x80) == 0 then           -- не водный узел
                            for k = 0, nlk - 1 do
                                local li = bl + k
                                if li < ar.nl then
                                    local ta, tn = links[li * 2], links[li * 2 + 1]
                                    local tA = A[ta]
                                    if tA and tn < tA.nv then
                                        local allow = true
                                        if nav then
                                            local v = nav[li]
                                            local na, ni = bit.rshift(v, 10), bit.band(v, 1023)
                                            local nA = A[na]
                                            if nA and ni < nA.nnavi then
                                                local q = nA.p + nA.navOff + ni * 14
                                                local att = ffi.cast('const uint16_t *', q + 4)
                                                local lanes = q[11]
                                                local opp, same = bit.band(lanes, 7), bit.band(bit.rshift(lanes, 3), 7)
                                                if opp + same > 0 then
                                                    if att[0] == ta and att[1] == tn then allow = same > 0
                                                    elseif att[0] == a and att[1] == i then allow = opp > 0 end
                                                end
                                            end
                                        end
                                        if allow then
                                            local t = tA.base + tn
                                            local dx, dy, dz = X[t] - X[g], Y[t] - Y[g], Z[t] - Z[g]
                                            E = E + 1
                                            to[E] = t
                                            len[E] = math.sqrt(dx * dx + dy * dy + dz * dz) * ((OFF[t] == 1) and 1.6 or 1)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                if a % 8 == 7 then wait(0) end
            end
            LS[N] = E
            local TO, LEN = ffi.new('int32_t[?]', E + 1), ffi.new('float[?]', E + 1)
            for e = 1, E do TO[e - 1], LEN[e - 1] = to[e], len[e] end
            roadmap.X, roadmap.Y, roadmap.Z, roadmap.LS, roadmap.TO, roadmap.LEN = X, Y, Z, LS, TO, LEN
            roadmap.n, roadmap.e, roadmap.oneway = N, E, A[0] and A[0].naviLinkOff ~= nil
        end)
        if ok then
            roadmap.state = 'ok'
            log(string.format('[roads] карта дорог загружена: узлов %d, связей %d, односторонние: %s', roadmap.n, roadmap.e, tostring(roadmap.oneway)))
        else
            roadmap.state = 'fail'
            log('[roads] карта дорог не загружена: ' .. tostring(err))
        end
    end

    local function nearest(x, y, z, maxDz)
        local X, Y, Z = roadmap.X, roadmap.Y, roadmap.Z
        local best, bi = 1e18, nil
        for i = 0, roadmap.n - 1 do
            local dx, dy = X[i] - x, Y[i] - y
            local d = dx * dx + dy * dy
            if d < best then
                local dz = math.abs(Z[i] - z)
                if not maxDz or dz < maxDz then
                    if dz > 3 then d = d + (dz - 3) * (dz - 3) * 9 end
                    if d < best then best, bi = d, i end
                end
            end
        end
        return bi, math.sqrt(best)
    end

    -- Маршрут от машины до метки по дорогам: список точек или nil
    function roadmap.route(car, tx, ty, tz, allowBehind)
        if roadmap.state ~= 'ok' then return nil end
        local X, Y, Z, LS, TO, LEN = roadmap.X, roadmap.Y, roadmap.Z, roadmap.LS, roadmap.TO, roadmap.LEN
        local cx, cy, cz = getCarCoordinates(car)
        local fx, fy = carBasis(car)
        if not tz or tz == 0 or not fin(tz) then tz = cz end
        local goal = nearest(tx, ty, tz)
        if not goal then return nil end
        local gx, gy, gz = X[goal], Y[goal], Z[goal]
        -- старт: узлы рядом с машиной; те, что позади, - со штрафом за разворот
        local g, came, closed = {}, {}, {}
        local hk, hv, hn = {}, {}, 0
        local function push(v, f)
            hn = hn + 1
            local i = hn
            while i > 1 do
                local pi = math.floor(i / 2)
                if hk[pi] <= f then break end
                hk[i], hv[i] = hk[pi], hv[pi]
                i = pi
            end
            hk[i], hv[i] = f, v
        end
        local function pop()
            local rv = hv[1]
            local lk, lv = hk[hn], hv[hn]
            hk[hn], hv[hn] = nil, nil
            hn = hn - 1
            if hn > 0 then
                local i = 1
                while true do
                    local c = i * 2
                    if c > hn then break end
                    if c < hn and hk[c + 1] < hk[c] then c = c + 1 end
                    if hk[c] >= lk then break end
                    hk[i], hv[i] = hk[c], hv[c]
                    i = c
                end
                hk[i], hv[i] = lk, lv
            end
            return rv
        end
        local function h(v)
            local dx, dy = X[v] - gx, Y[v] - gy
            return math.sqrt(dx * dx + dy * dy)
        end
        local starts = 0
        for i = 0, roadmap.n - 1 do
            local dx, dy = X[i] - cx, Y[i] - cy
            local d2 = dx * dx + dy * dy
            if d2 < 28 * 28 and math.abs(Z[i] - cz) < 7 then
                -- до узла едем без дороги - это дорого (иначе срежет на соседнюю дорогу)
                local d = math.sqrt(d2)
                local ahead = dx * fx + dy * fy
                local cost = d * 2.5 + ((ahead < -4 and not allowBehind) and 150 or 0)
                if d > 6 and not clearLine(cx, cy, cz + 1, X[i], Y[i], Z[i] + 1) then cost = cost + 300 end
                if not g[i] or cost < g[i] then g[i] = cost; push(i, cost + h(i)); starts = starts + 1 end
            end
        end
        if starts == 0 then
            local s, d = nearest(cx, cy, cz)
            if not s or d > 150 then return nil end
            g[s] = d; push(s, d + h(s))
        end
        local found, iter = false, 0
        while hn > 0 do
            local v = pop()
            if not closed[v] then
                closed[v] = true
                if v == goal then found = true break end
                iter = iter + 1
                if iter > 80000 then break end
                local gv = g[v]
                for e = LS[v], LS[v + 1] - 1 do
                    local t = TO[e]
                    if not closed[t] then
                        local ng = gv + LEN[e]
                        if not g[t] or ng < g[t] then
                            g[t], came[t] = ng, v
                            push(t, ng + h(t))
                        end
                    end
                end
            end
        end
        if not found then return nil end
        local rev, v = {}, goal
        while v do
            rev[#rev + 1] = v
            v = came[v]
        end
        local pts = {}
        for k = #rev, 1, -1 do
            local i = rev[k]
            pts[#pts + 1] = { x = X[i], y = Y[i], z = Z[i] }
        end
        if #pts < 2 then
            pts[#pts + 1] = { x = tx, y = ty, z = tz }
        end
        return pts
    end
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
    local nearEnd = r and routeLen(r.pts, r.idx) < 30 and getDistanceBetweenCoords2d(r.pts[#r.pts].x, r.pts[#r.pts].y, tx, ty) > 40
    local periodic = r and now - r.t > (r.own and 20 or 8)
    if r and not (r.off or moved or nearEnd or periodic) then return end
    if r and r.fail and now - r.fail < 2 then return end
    if not r and bot.routeFail and now - bot.routeFail < 1 then return end

    local cx, cy, cz = getCarCoordinates(car)
    local gx, gy, gz = tx, ty, tz
    -- свой маршрут по всей карте дорог; если карта не загрузилась - поиск игры
    local pts = roadmap.route(car, tx, ty, tz, bot.allowBehind and now < bot.allowBehind)
    local own = pts ~= nil
    if not own then pts = gpsSearch(cx, cy, cz, gx, gy, gz) end
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
    if not own and pts and startsBehind(car, pts) and not (bot.allowBehind and now < bot.allowBehind) then
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
    -- точки через ~4 м: бот едет по самой линии маршрута
    local dense = { pts[1] }
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local l = getDistanceBetweenCoords2d(a.x, a.y, b.x, b.y)
        local k = math.floor(l / 4)
        for j = 1, k - 1 do
            local t = j / k
            dense[#dense + 1] = { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
        end
        dense[#dense + 1] = b
    end
    bot.route = { pts = dense, t = now, tx = tx, ty = ty, idx = 1, partial = (gx ~= tx or gy ~= ty), own = own }
end

-- Точка маршрута для руления + безопасная скорость по изгибам дороги впереди.
-- Маршрут разбит на точки через ~4 м, бот едет по самой линии маршрута (точка на
-- линии впереди на расстоянии упреждения), а не напрямую к дальнему узлу - поэтому
-- на развилках и съездах развязок не срезает через отбойник и не уходит не в ту ветку.
-- Ближайшая точка ищется с учётом высоты: эстакада над/под нами не путает.
local function routeWaypoint(car, speed, tx, ty)
    local r = bot.route
    if not r then return nil end
    local now = os.clock()
    if r.cache and now < r.cache.till then return r.cache.x, r.cache.y, r.cache.vcap end
    local pts = r.pts
    local n = #pts
    local cx, cy, cz = getCarCoordinates(car)
    local bi, bd, b2 = r.idx, 1e9, 1e9
    for i = math.max(1, r.idx - 3), math.min(n, r.idx + 40) do
        local p = pts[i]
        local d2 = getDistanceBetweenCoords2d(cx, cy, p.x, p.y)
        local dz = math.abs((p.z or cz) - cz)
        local d = d2 + math.max(0, dz - 1.5) * 3
        if d < bd then bi, bd, b2 = i, d, d2 end
    end
    r.idx = bi
    -- ушли с маршрута (не та ветка развилки, другой уровень развязки) - перестроить
    -- (пока ещё не выехали на маршрут, например со стоянки, - допуск больше)
    if bd < 8 then r.on = true end
    if bd > (r.on and 14 or 35) then r.off, r.cache = true, nil return nil end
    -- точка на линии маршрута впереди на расстоянии L (по самой дороге)
    local function at(L)
        local acc, i = 0, bi
        while i < n do
            local a, b = pts[i], pts[i + 1]
            local sl = getDistanceBetweenCoords2d(a.x, a.y, b.x, b.y)
            if acc + sl >= L then
                local t = (sl > 0.01) and (L - acc) / sl or 0
                return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, (a.z or cz) + ((b.z or cz) - (a.z or cz)) * t, false
            end
            acc, i = acc + sl, i + 1
        end
        local p = pts[n]
        return p.x, p.y, p.z or cz, true
    end
    -- упреждение растёт со скоростью; если сбоку от маршрута - короче, чтобы сначала вернуться на линию
    local L = clamp(6 + speed * 0.55, 8, 22) + math.min(b2, 6) * 0.5
    local px, py, pz, last = at(L)
    while L > 5 do
        if clearLine(cx, cy, cz + 0.6, px, py, pz + 1.2) and corridorClear(car, px, py, pz + 0.4) then break end
        L = L - 4
        px, py, pz, last = at(L)
    end
    -- конец маршрута рядом с меткой - дальше едем прямо к метке
    if last and getDistanceBetweenCoords2d(cx, cy, px, py) < 12 then
        if not r.partial and getDistanceBetweenCoords2d(px, py, tx, ty) >= 40 then bot.atRoadEnd = true end
        return nil
    end
    -- скорость по изгибам: на каждом участке впереди радиус поворота -> допустимая
    -- скорость, и успеваем ли до него затормозить (с запасом для фуры с прицепом)
    local careful = num(cfg.bot.style, 0) == 1
    local aLat, decel = careful and 4.5 or 6.5, careful and 5 or 6.5
    local look = 40 + speed * speed / (2 * decel)
    local vcap, acc = nil, 0
    for i = bi + 3, n - 3 do
        local p0, p1, p2 = pts[i - 3], pts[i], pts[i + 3]          -- окно ~24 м: узлы дороги стоят углами, на коротком окне радиус выходит заниженным
        local ux, uy = p1.x - p0.x, p1.y - p0.y
        local vx, vy = p2.x - p1.x, p2.y - p1.y
        local lu, lv = math.sqrt(ux * ux + uy * uy), math.sqrt(vx * vx + vy * vy)
        acc = acc + getDistanceBetweenCoords2d(pts[i - 1].x, pts[i - 1].y, p1.x, p1.y)
        if acc > look then break end
        if lu > 1 and lv > 1 then
            local cosv = clamp((ux * vx + uy * vy) / (lu * lv), -1, 1)
            local ang = math.acos(cosv)
            if ang > 0.05 then
                local radius = (lu + lv) / 2 / ang
                local vc = math.max(7, math.sqrt(aLat * radius))
                local vAllow = math.sqrt(vc * vc + 2 * decel * math.max(0, acc - 4))
                if not vcap or vAllow < vcap then vcap = vAllow end
            end
        end
    end
    r.cache = { x = px, y = py, vcap = vcap, till = now + 0.1 }
    return px, py, vcap
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
    if cfg.bot.gps ~= false and (gps.ok or roadmap.state == 'ok') then
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
        if not wx then
            local cx, cy, cz = getCarCoordinates(car)
            local nx, ny, nz = getClosestCarNode(cx, cy, cz)
            if nx and fin(nx) and (nx ~= 0 or ny ~= 0) and getDistanceBetweenCoords2d(cx, cy, nx, ny) > 4
                and corridorClear(car, nx, ny, nz) then
                wx, wy = nx, ny
            end
        end
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

    local steer, v = 0, 0                                    -- некуда ехать по дороге - стоим, а не едем вслепую
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
    if rturn then v = math.min(v, rturn) end                 -- скорость по изгибам маршрута

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
    hitch.spin, hitch.spinLast, hitch.freeT = 0, nil, nil
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
        keys(dir, (speed < 4) and 0.5 or 0, 0)
    else
        local r = senseRear(car)
        local rg, cg = minOf(r.bl, r.bc, r.br), (dir > 0) and r.rl or r.rr
        if t > 0.4 and ((rg and rg < 1.0) or (cg and cg < 0.6) or stalled or t > 5) then
            st.phase, st.since, st.moved = 'fwd', now, nil
            keys(0, 0, 0)
            return false
        end
        keys(-dir, 0, (speed < 3.5) and 0.7 or 0)
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
    local cfx, cfy = carBasis(car)
    local svx, svy = getCarSpeedVector(car)
    local vf = svx * cfx + svy * cfy                         -- скорость вдоль фуры: < 0 - едем назад
    -- шкворень прицепа (K) и направление прицепа (T); седло тягача (H)
    local kx, ky = getOffsetFromCarInWorldCoords(tr, 0, tg.front - 1.4, 0)
    local tfx, tfy = carBasis(tr)
    local hx, hy = getOffsetFromCarInWorldCoords(car, 0, -(g.back - 1.8), 0)
    local cx, cy, cz = getCarCoordinates(car)
    local fx, fy = carBasis(car)
    local headErr = math.deg(math.acos(clamp(fx * tfx + fy * tfy, -1, 1)))
    local dHK = getDistanceBetweenCoords2d(hx, hy, kx, ky)
    -- положение седла относительно линии прицепа: along - сколько ещё ехать назад, e - вбок
    local along = (hx - kx) * tfx + (hy - ky) * tfy
    local e = (hx - kx) * tfy - (hy - ky) * tfx

    -- Рядом и ровно - цепляем
    -- Рядом и ровно - цепляем (с запасом: точки седла и шкворня у моделей примерные)
    local stuck = hitch.phase == 'reverse' and speed < 0.3 and now - (hitch.st.moved or now) > 0.7
    -- attachTrailerToCab цепляет принудительно, так что точность до сантиметра не нужна
    if ((dHK < 3.2 and math.abs(e) < 1.8) or (dHK < 4.5 and stuck)) and headErr < 25 then
        -- Тормозим против хода: на заднем ходу S - это газ назад, поэтому жмём W.
        if vf < -0.3 then keys(0, 0.6, 0)
        elseif vf > 0.3 then keys(0, 0, 0.6)
        else keys(0, 0, 0) end
        -- цепляем сразу, не дожидаясь полной остановки (у шкворня скорость и так ~1-2)
        if speed < 3 then
            attachTrailerToCab(tr, car)
            hitch.status = 'Сцепка: цепляю'
            log(string.format('[hitch] цепляю: до шкворня %.1f, вбок %.2f, курс %.0f, скорость %.1f', dHK, e, headErr, speed))
        end
        return
    end

    if hitch.phase ~= hitch.lastPhase then
        hitch.lastPhase = hitch.phase
        log(string.format('[hitch] фаза %s: до шкворня %.1f, вдоль %.1f, вбок %.2f, курс %.0f', hitch.phase, dHK, along, e, headErr))
    end
    local s = senseFront(car, 8)
    local reach = g.front + g.back + 14                      -- стартовая точка перед прицепом (запас на выравнивание)
    -- Сколько свободно перед прицепом (стена, забор, столб): если меньше нужного,
    -- точку подъезда ставим ближе - сдавать задом будем с короткого расстояния.
    if not hitch.freeT or now - hitch.freeT > 0.5 then
        hitch.freeT = now
        local _, _, kz = getCarCoordinates(tr)
        local L = reach + g.front + 6
        local best = L
        for _, side in ipairs({ -1.1, 0, 1.1 }) do           -- три луча по ширине фуры
            local ox, oy = tfy * side, -tfx * side
            local x1, y1 = kx + tfx * 1.5 + ox, ky + tfy * 1.5 + oy
            local hit, cp = los(x1, y1, kz + 0.7, x1 + tfx * L, y1 + tfy * L, kz + 0.7, false)
            if hit and cp and cp.pos then best = math.min(best, 1.5 + getDistanceBetweenCoords2d(x1, y1, cp.pos[1], cp.pos[2])) end
        end
        hitch.free = best
    end
    local maxP = hitch.free - g.front - 1.0                  -- дальше этого центр фуры не встанет
    local tight = maxP < reach
    if tight then
        if maxP < g.back + 2.5 then
            return hitchStop(string.format('Бот: перед прицепом всего %.0f м свободно - фура не встанет. Отодвиньте прицеп или уберите препятствие.', hitch.free))
        end
        reach = maxP
    end
    -- Крутимся на месте слишком долго - места для разворота нет
    if hitch.spin and hitch.spin > 25 then
        return hitchStop('Бот: не хватает места развернуться у прицепа. Отъедьте на свободное место и попробуйте снова.')
    end
    local ax, ay = kx + tfx * reach, ky + tfy * reach
    -- Допустимое смещение вбок растёт с расстоянием: издалека задний ход сам
    -- выведет седло на линию прицепа (конус ~20 градусов от линии).
    local eTol = 2 + math.max(0, along) * 0.35

    -- Стоим перед прицепом и смотрим в ту же сторону - сразу задним ходом,
    -- даже если до прицепа далеко (нужен хоть какой-то разгон для выравнивания)
    -- (только если до прицепа не дальше 45 м и между седлом и прицепом нет забора/стены)
    if (hitch.phase == 'approach' or hitch.phase == 'align') and along < 45
        and ((along > 8 and math.abs(e) < eTol and headErr < 30)
          or (along > 0 and math.abs(e) < 1 and headErr < 10)
          or (tight and along > 2 and math.abs(e) < 1.6 and headErr < 15))
        and clearLine(hx, hy, cz + 0.8, kx, ky, cz + 0.8) then
        hitch.phase, hitch.st = 'reverse', {}
        log(string.format('[hitch] на линии, сдаю назад: вдоль %.1f, вбок %.2f, курс %.0f', along, e, headErr))
    end

    -- Подъезд: едем вперёд по кривой на линию прицепа (луч от шкворня по ходу прицепа)
    -- и дальше вдоль неё - так фура сама встаёт перед прицепом ровно и в ту же сторону.
    -- Без разворотов на месте, пока это возможно.
    if hitch.phase == 'approach' then
        hitch.status = 'Сцепка: подъезжаю к прицепу'
        local st = hitch.st
        -- выбирались из упора - 2 с прямо назад
        if st.recover then
            if now < st.recover then keys(0, 0, 0.8) return end
            st.recover, st.moved = nil, now
        end
        -- Далеко от прицепа или упёрлись (забор, стена) - едем обычным ботом:
        -- он объезжает препятствия, ищет дорогу и сам выбирается из упора.
        local dA = getDistanceBetweenCoords2d(cx, cy, ax, ay)
        if st.far and dA < st.farExit then
            st.far, st.moved, st.fails = nil, now, 0
            bot.wx, bot.vt, bot.man, bot.recover, bot.stuckSince, bot.commit, bot.route, bot.turnAt = nil, nil, nil, nil, nil, nil, nil, nil
            log(string.format('[hitch] доехал до прицепа ботом, до точки %.0f м', dA))
        elseif not st.far and dA > 12 and (dA > 40 or (st.fails or 0) >= 2) then
            st.far, st.farExit = true, (dA > 40) and 22 or 8
            st.best, st.bestT = dA, now
            bot.wx, bot.vt, bot.man, bot.recover, bot.stuckSince, bot.commit, bot.route, bot.turnAt = nil, nil, nil, nil, nil, nil, nil, nil
            bot.nextPlan, bot.manCooldown = 0, 0
            log(string.format('[hitch] еду к прицепу ботом: до точки %.0f м, упоров %d', dA, st.fails or 0))
        end
        if st.far then
            hitch.start = now                                -- 2.5 минуты считаем от прицепа
            if dA < st.best - 4 then st.best, st.bestT = dA, now end
            if now - st.bestT > 40 then return hitchStop('Бот: 40 секунд не получается подъехать к прицепу.') end
            hitch.status = string.format('Сцепка: еду к прицепу, %d м', math.floor(dA))
            local rad = cfg.bot.radius
            cfg.bot.radius = 3                               -- без раннего торможения у точки
            botControl(car, ax, ay, cz, dA)
            cfg.bot.radius = rad
            return
        end
        local proj = (cx - kx) * tfx + (cy - ky) * tfy       -- центр фуры вдоль линии прицепа
        local lat = (cx - kx) * tfy - (cy - ky) * tfx        -- и вбок от неё (> 0 - справа)
        local nx, ny = tfy, -tfx                             -- нормаль вправо от линии
        local tx, ty
        if math.abs(lat) < 8 and proj < reach * 0.5 then
            -- рядом с прицепом или за ним - сначала уходим вбок, чтобы не въехать в прицеп
            local sgn = (lat >= 0) and 1 or -1
            local p = clamp(proj + 10, 0, reach)
            tx, ty = kx + tfx * p + nx * sgn * 10, ky + tfy * p + ny * sgn * 10
        else
            -- точка на линии впереди (не ближе reach к шкворню), упреждение 12 м
            local p = math.min(math.max(proj + 12, reach), math.max(reach, maxP))
            tx, ty = kx + tfx * p, ky + tfy * p
        end
        local lx, ly = toLocal(car, tx, ty)
        local angD = math.deg(math.atan2(lx, ly))
        if math.abs(angD) > 100 then
            -- точка сзади (смотрим не туда) - разворот, пока не повернёмся к ней
            if hitch.spinLast and now - hitch.spinLast < 0.2 then hitch.spin = hitch.spin + (now - hitch.spinLast) end
            hitch.spinLast = now
            turnToHeading(car, st, angD, s, now, speed)
            return
        end
        st.phase = nil                                       -- сброс разворота
        st.moved = st.moved or now
        if speed > 0.5 then st.moved = now end
        if now - st.moved > 3 then st.recover, st.fails = now + 2, (st.fails or 0) + 1 return end
        local v = clamp(dA * 0.4, 6, 12)                     -- далеко - быстрее
        if math.abs(angD) > 25 then v = math.min(v, 4) end   -- крутой поворот - медленно
        if s.fc then v = math.min(v, math.sqrt(2 * 5 * math.max(0, s.fc - 2.5))) end
        local steer = clamp(angD / 28, -1, 1)
        local diff = v - speed
        keys(steer, (diff > 0.3) and clamp(diff / 5, 0.25, 0.8) or 0, (diff < -2) and 0.5 or 0)
        if now - (hitch.logT or 0) > 1 then
            hitch.logT = now
            log(string.format('[hitch] подъезд: вдоль %.1f, вбок %.1f, курс %.0f, к точке %.0f', proj, lat, headErr, angD))
        end
        return
    end

    if hitch.phase == 'align' then
        hitch.status = 'Сцепка: выравниваюсь'
        local lx, ly = toLocal(car, cx + tfx * 60, cy + tfy * 60)
        local hang = math.deg(math.atan2(lx, ly))
        if math.abs(hang) < 20 and speed < 1.5 then hitch.phase, hitch.st = 'reverse', {} return end
        if hitch.spinLast and now - hitch.spinLast < 0.2 then hitch.spin = hitch.spin + (now - hitch.spinLast) end
        hitch.spinLast = now
        if turnToHeading(car, hitch.st, hang, s, now, speed) then
            keys(0, 0, (speed > 0.5) and 0.6 or 0)
            if speed < 0.5 then hitch.phase, hitch.st = 'reverse', {} end
        end
        return
    end

    -- Короткая поправка вперёд: встать на линию прицепа и снова сдавать
    if hitch.phase == 'pull' then
        hitch.status = 'Сцепка: поправляюсь'
        local st = hitch.st
        st.from = st.from or along
        -- точка на линии прицепа впереди машины
        -- вперёд: чтобы седло ушло влево (e > 0), нос влево; руль вперёд = поворот носа
        local psi = math.deg(math.atan2(fx * tfy - fy * tfx, fx * tfx + fy * tfy))
        local psiD = clamp(-math.deg(math.atan2(e, 6)), -30, 30)
        local steer = clamp((psiD - psi) / 12, -1, 1)
        if along - st.from > 7 or (math.abs(e) < 0.4 and headErr < 6 and along - st.from > 3)
            or (s.fc and s.fc < 2) then
            keys(0, 0, (speed > 0.5) and 0.7 or 0)
            if speed < 0.5 then hitch.phase, hitch.st = 'reverse', {} end
            return
        end
        -- ещё катимся назад (после промаха) - гасим скорость газом вперёд в полную силу
        local gas = (vf < -0.3) and 1 or (speed < 3.5) and 0.55 or 0
        keys((vf < -0.3) and 0 or steer, gas, 0)
        return
    end

    -- Задний ход по линии прицепа. Опорная точка - седло (H), цель - точка на линии
    -- прицепа на расстоянии L перед шкворнем по ходу. Руль: при заднем ходе вправо -
    -- зад уходит вправо. Плюс поправка на курс, чтобы подъехать ровно, а не под углом.
    hitch.status = string.format('Сцепка: сдаю назад, %.1f м', dHK)
    -- ещё катимся вперёд (после подъезда) - сначала тормозим, иначе ниже газ разгонит вперёд
    if vf > 0.5 then keys(0, 0, 1) return end
    if speed > 0.4 then hitch.st.moved = now end
    hitch.st.moved = hitch.st.moved or now
    -- стоим и не едем назад, а до прицепа ещё далеко - упёрлись: заново подъезд (с объездом)
    if dHK > 4.5 and now - hitch.st.moved > 2.5 then
        hitch.tries = hitch.tries + 1
        if hitch.tries > 5 then return hitchStop('Бот: не получилось подъехать к прицепу задом (мешает препятствие).') end
        log(string.format('[hitch] упёрся задом: до шкворня %.1f', dHK))
        hitch.phase, hitch.st = 'approach', { fails = 2 }
        return
    end
    -- проехали шкворень, но стоим почти на линии - короткая поправка вперёд
    if along < -1 and math.abs(e) < 4 and headErr < 45 then
        hitch.tries = hitch.tries + 1
        if hitch.tries > 8 then return hitchStop('Бот: не получилось ровно подъехать к прицепу.') end
        log(string.format('[hitch] проехал шкворень: вдоль %.1f, вбок %.2f, курс %.0f, скорость %.1f', along, e, headErr, speed))
        hitch.phase, hitch.st = 'pull', {}
        keys(0, 1, 0)
        return
    end
    if along < -3 or (along > 6 and (math.abs(e) > eTol + 1 or headErr > 45)) then
        hitch.tries = hitch.tries + 1
        if hitch.tries > 5 then return hitchStop('Бот: не получилось ровно подъехать к прицепу.') end
        hitch.phase, hitch.st = 'approach', {}
        return
    end
    -- Совсем близко и явно мимо - короткая поправка вперёд вместо полного захода.
    -- (Раньше срабатывало уже при 0.9 м / 12 градусах, а регулятор сам держит угол
    -- до 13+ градусов на подходе - и бот дёргался вперёд прямо у прицепа.)
    if along < 4 and (math.abs(e) > 1.8 or headErr > 25) then
        hitch.tries = hitch.tries + 1
        if hitch.tries > 8 then return hitchStop('Бот: не получилось ровно подъехать к прицепу.') end
        hitch.phase, hitch.st = 'pull', {}
        keys(0, 0, 0)
        return
    end
    -- Каскадный регулятор: psi - угол фуры относительно прицепа (> 0 - нос правее),
    -- e - смещение седла вправо от линии прицепа. Чтобы при заднем ходе седло ушло
    -- влево (e > 0), нос должен смотреть вправо: нужный угол psiD = atan(e / дистанция).
    -- Задним ходом руль вправо поворачивает нос влево, поэтому руль = (psi - psiD).
    local psi = math.deg(math.atan2(fx * tfy - fy * tfx, fx * tfx + fy * tfy))
    -- у самого прицепа нужный угол сужается, чтобы подъехать почти ровно
    local psiMax = math.min(30, 6 + math.max(0, along) * 2.5)
    local psiD = clamp(math.deg(math.atan2(e, math.max(3, along * 0.7))), -psiMax, psiMax)
    local steer = clamp((psi - psiD) / 12, -1, 1)
    -- далеко - быстрее, у самого прицепа - аккуратно
    -- плавный профиль: скорость, с которой ещё успеваем затормозить до шкворня
    local v = clamp(0.8 + math.sqrt(2 * 0.6 * math.max(0, dHK - 2)), 0.8, 6.0)
    if math.abs(e) > 1 or math.abs(psi - psiD) > 15 then v = math.min(v, (along > 15) and 3.0 or 2.0) end
    local diff = v - speed
    -- быстрее нужного - тормозим газом вперёд (на заднем ходу S - это газ назад)
    local gas = (diff < -0.3) and clamp(-diff * 0.4, 0.25, 1) or 0
    local brake = (diff > 0.2) and clamp(0.45 + diff * 0.15, 0.45, 0.9) or 0
    keys(steer, gas, brake)
    if now - (hitch.logT or 0) > 0.5 then
        hitch.logT = now
        log(string.format('[hitch] назад: до шкворня %.1f, вдоль %.1f, вбок %.2f, угол %.1f (нужно %.1f), руль %.2f, скорость %.1f',
            dHK, along, e, psi, psiD, steer, speed))
    end
end

local function botThread()
    while true do
        wait((bot.active or hitch.active) and 0 or 100)
        do -- данные для виджета во вкладке Авто фарм
            local T = bot.tele or {}
            bot.tele = T
            if isCharInAnyCar(PLAYER_PED) then
                local car = storeCarCharIsInNoSave(PLAYER_PED)
                T.inCar, T.kmh = true, getCarSpeed(car) * 3.6
                T.hooked = trailerExists() and isTrailerAttachedToCab(trailer.handle, car)
            else
                T.inCar, T.kmh, T.hooked = false, 0, false
            end
            T.trailer = trailerExists()
            if bot.tx and T.inCar then
                local px, py = getCharCoordinates(PLAYER_PED)
                T.dist = getDistanceBetweenCoords2d(px, py, bot.tx, bot.ty)
            else
                T.dist = nil
            end
        end
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
                        bot.tx, bot.ty, bot.dist0 = x, y, dist
                        bot.best, bot.bestTime, bot.gaveUp, bot.arrived = dist, os.clock(), false, false
                        bot.progT, bot.tries, bot.altUntil, bot.atRoadEnd, bot.allowBehind = os.clock(), 0, nil, nil, nil
                        bot.man, bot.recover, bot.wx, bot.commit, bot.turnAt = nil, nil, nil, nil, nil
                    end
                    if dist < bot.best - 5 then bot.best, bot.bestTime, bot.progT = dist, os.clock(), os.clock() end
                    if manual or os.clock() < bot.pauseUntil then bot.progT = os.clock() end

                    if dist <= num(cfg.bot.radius, 12) or bot.atRoadEnd then
                        if getCarSpeed(car) > 1 then keys(0, 0, 1) else botRelease() end
                        if not bot.arrived then
                            msg(bot.atRoadEnd and ('Бот: приехал к ближайшей к метке точке дороги (' .. name .. ', ещё ' .. math.floor(dist) .. ' м без дороги).')
                                or ('Бот: прибыли (' .. name .. ').'))
                        end
                        bot.arrived, bot.status = true, bot.atRoadEnd and 'Прибыл (дальше дороги нет)' or 'Прибыл'
                    elseif manual then
                        botRelease(); bot.pauseUntil = os.clock() + 3
                        bot.status = 'Управление у вас'
                    elseif os.clock() >= bot.pauseUntil then
                        -- Не сдаёмся, но и с дороги не съезжаем: 20 с без приближения к метке -
                        -- отъезжаем назад и строим НОВЫЙ маршрут по дорогам (по очереди: вперёд
                        -- от машины / с разворотом в обратную сторону).
                        local now = os.clock()
                        if now - (bot.progT or now) > 20 then
                            bot.tries = (bot.tries or 0) + 1
                            bot.progT, bot.best, bot.altUntil = now, dist, now + 5
                            bot.route, bot.wx, bot.commit, bot.turnAt, bot.man, bot.routeFail = nil, nil, nil, nil, nil, nil
                            bot.nextPlan, bot.manCooldown, bot.stuckSince = 0, 0, nil
                            bot.allowBehind = (bot.tries % 2 == 1) and (now + 40) or nil
                            local r = senseRear(car)
                            local rg = minOf(r.bl, r.bc, r.br)
                            if not rg or rg > 2 then
                                bot.recover = { start = now, till = now + 2.5, steer = (bot.tries % 4 < 2) and 1 or -1 }
                            end
                            log(string.format('[bot] нет продвижения к метке, попытка %d: новый маршрут по дорогам%s', bot.tries, bot.allowBehind and ' (с разворотом)' or ''))
                        end
                        if bot.altUntil and now < bot.altUntil then
                            bot.status = string.format('Ищу другой путь по дороге (%d), %d м', bot.tries or 0, math.floor(dist))
                        else
                            bot.status = string.format('Едет: %s, %d м', name, math.floor(dist))
                        end
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
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpV4(a, b, t) return V4(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t), lerp(a.w, b.w, t)) end
local function mixV(a, b, t, alpha) return V4(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t), alpha or 1) end

-- Палитра. Пересчитывается в applyTheme под яркость фона: на светлой теме текст и
-- элементы тёмные, на тёмной - светлые. Все виджеты берут цвета только отсюда.
local GREEN   = V4(0.35, 0.85, 0.45, 1)
local YELLOW  = V4(1.0, 0.8, 0.35, 1)
local RED     = V4(1.0, 0.42, 0.42, 1)
local BGV     = V4(0.07, 0.08, 0.11, 1)   -- цвет фона окна
local TEXT    = V4(0.93, 0.94, 0.97, 1)   -- основной текст
local DIM     = V4(0.58, 0.61, 0.68, 1)   -- второстепенный текст
local ACCENT  = V4(0.25, 0.6, 1, 1)       -- акцент (заливки)
local ACCENT_TEXT = ACCENT                -- акцент для текста (читаемый на фоне)
local SURF, SURF_H, SURF_A = V4(0.2, 0.22, 0.28, 1), V4(0.26, 0.28, 0.35, 1), V4(0.16, 0.18, 0.22, 1)
local TRACK   = V4(0.22, 0.24, 0.30, 1)   -- дорожка выключенного переключателя
local KNOB    = V4(1, 1, 1, 1)
local KNOB_EDGE = V4(0, 0, 0, 0)
local CHILD   = V4(0.1, 0.11, 0.14, 1)
local LIGHT   = false

local function relLum(r, g, b)
    local function ch(c) return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4 end
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
end
local function contrast(a, b)
    local l1, l2 = relLum(a.x, a.y, a.z), relLum(b.x, b.y, b.z)
    if l1 < l2 then l1, l2 = l2, l1 end
    return (l1 + 0.05) / (l2 + 0.05)
end
-- Сдвигает цвет к toward, пока контраст с фоном не станет не меньше ratio
local function ensureContrast(fg, bg, ratio, toward)
    for i = 0, 20 do
        local c = mixV(fg, toward, i / 20, fg.w)
        if contrast(c, bg) >= ratio then return c end
    end
    return toward
end
-- Цвет статуса/подсветки, который читается на текущем фоне
local function readable(c) return ensureContrast(c, BGV, 3.0, TEXT) end

--==============================================================
-- Свои картинки, GIF и видео для меню.
-- Картинки и анимации декодирует Windows (WIC): png, jpg, bmp, gif, tiff, ico,
-- а также webp/heic/avif, если в системе стоят их кодеки. Видео (mp4, avi, wmv,
-- mov, mkv...) - через Media Foundation. Всё переводится в текстуры D3D9 через mimgui.
--==============================================================
local media = { ok = false, err = nil, loaders = {} }
do -- внутренности загрузчика спрятаны в блок: у Lua лимит 200 локальных переменных
local IMG_EXT = { png = 1, jpg = 1, jpeg = 1, jfif = 1, bmp = 1, gif = 1, webp = 1, tif = 1, tiff = 1,
                  ico = 1, jxr = 1, wdp = 1, heic = 1, heif = 1, avif = 1, dds = 1, tga = 1 }
local VIDEO_EXT = { mp4 = 1, m4v = 1, avi = 1, wmv = 1, mov = 1, mkv = 1, webm = 1, mpg = 1, mpeg = 1, ['3gp'] = 1, flv = 1 }

do
    local defs = {
        'typedef struct { uint32_t d1; uint16_t d2, d3; uint8_t d4[8]; } lafk_GUID;',
        'typedef struct { uint16_t vt, r1, r2, r3; union { uint8_t b; uint16_t ui; uint32_t ul; uint64_t u64; void *p; } v; } lafk_PV;',
        'long __stdcall lafk_CoInitializeEx(void *, unsigned long) __asm__("CoInitializeEx");',
        'long __stdcall lafk_CoCreateInstance(const lafk_GUID *, void *, unsigned long, const lafk_GUID *, void **) __asm__("CoCreateInstance");',
        'long __stdcall lafk_PropVariantClear(lafk_PV *) __asm__("PropVariantClear");',
        'int __stdcall lafk_MB2WC(unsigned int, unsigned long, const char *, int, uint16_t *, int) __asm__("MultiByteToWideChar");',
        'long __stdcall lafk_WICConvert(const lafk_GUID *, void *, void **) __asm__("WICConvertBitmapSource");',
        'long __stdcall lafk_MFStartup(unsigned long, unsigned long) __asm__("MFStartup");',
        'long __stdcall lafk_MFCreateAttributes(void **, uint32_t) __asm__("MFCreateAttributes");',
        'long __stdcall lafk_MFCreateMediaType(void **) __asm__("MFCreateMediaType");',
        'long __stdcall lafk_MFCreateSourceReaderFromURL(const uint16_t *, void *, void **) __asm__("MFCreateSourceReaderFromURL");',
        'void * __stdcall lafk_ShellExecuteA(void *, const char *, const char *, const char *, const char *, int) __asm__("ShellExecuteA");',
        'int __stdcall lafk_RemoveDirectoryA(const char *) __asm__("RemoveDirectoryA");',
    }
    local okAll = true
    for _, d in ipairs(defs) do
        local ok, e = pcall(ffi.cdef, d)
        if not ok then okAll = false; log('[media] cdef: ' .. tostring(e)) end
    end
    local function lib(name) local ok, l = pcall(ffi.load, name) if ok then return l end end
    media.ole32, media.wic, media.mfplat, media.mfrw, media.shell = lib('ole32'), lib('windowscodecs'), lib('mfplat'), lib('mfreadwrite'), lib('shell32')
    media.ok = okAll and media.ole32 ~= nil and media.wic ~= nil
        and imgui.CreateTextureFromFileInMemory ~= nil
    if not media.ok then media.err = 'Загрузка своих картинок недоступна в этой системе.' end
end

local function guid(s)
    local g = ffi.new('lafk_GUID')
    local a, b, c, d, e = s:match('(%x+)-(%x+)-(%x+)-(%x+)-(%x+)')
    g.d1, g.d2, g.d3 = tonumber(a, 16), tonumber(b, 16), tonumber(c, 16)
    local rest = d .. e
    for i = 0, 7 do g.d4[i] = tonumber(rest:sub(i * 2 + 1, i * 2 + 2), 16) end
    return g
end
local G = {}
if media.ok then
    G.CLSID_WIC  = guid('cacaf262-9370-4615-a13b-9f5539da4c0a')
    G.IID_WICF   = guid('ec5ec8a9-c395-4314-9c77-54d7a935ff70')
    G.PF_BGRA    = guid('6fddc324-4e03-4bfe-b185-3d77768dc90f')
    G.MF_VPROC   = guid('fb394f3d-ccf1-42ee-bbb3-f9b845d5681d') -- MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING
    G.MT_MAJOR   = guid('48eba18e-f8c9-4687-bf11-0a74c9f96a8f')
    G.MT_SUBTYPE = guid('f7e34c9a-42e8-4714-b74b-cb29d72c35e5')
    G.MT_SIZE    = guid('1652c33d-d6b2-4012-b834-72030849a37d')
    G.MT_STRIDE  = guid('644b4e48-1e02-4516-b0eb-c01ca9d49ac6')
    G.MT_VIDEO   = guid('73646976-0000-0010-8000-00aa00389b71')
    G.RGB32      = guid('00000016-0000-0010-8000-00aa00389b71')
end

-- Вызов метода COM-объекта по номеру в таблице виртуальных функций
local fnTypes = {}
local function vc(obj, idx, sig, ...)
    local t = fnTypes[sig]
    if not t then
        t = ffi.typeof('long (__stdcall *)(void *' .. (sig ~= '' and (', ' .. sig) or '') .. ')')
        fnTypes[sig] = t
    end
    local vt = ffi.cast('void ***', obj)[0]
    return ffi.cast(t, vt[idx])(obj, ...)
end
local function release(obj) if obj ~= nil then vc(obj, 2, '') end end
local function hex(hr) return string.format('%08X', hr % 4294967296) end

local function wide(s)
    local n = ffi.C.lafk_MB2WC(0, 0, s, -1, nil, 0)
    local buf = ffi.new('uint16_t[?]', n + 1)
    ffi.C.lafk_MB2WC(0, 0, s, -1, buf, n)
    return buf
end

local factory
local function wicFactory()
    if factory then return factory end
    media.ole32.lafk_CoInitializeEx(nil, 2)
    local pp = ffi.new('void *[1]')
    local hr = media.ole32.lafk_CoCreateInstance(G.CLSID_WIC, nil, 1, G.IID_WICF, pp)
    if hr < 0 then error('WIC недоступен (' .. hex(hr) .. ')', 0) end
    factory = pp[0]
    return factory
end

local function metaNum(reader, name)
    if reader == nil then return nil end
    local pv = ffi.new('lafk_PV')
    if vc(reader, 5, 'const uint16_t *, lafk_PV *', wide(name), pv) < 0 then return nil end
    local vt, v = pv.vt, nil
    if vt == 17 then v = pv.v.b elseif vt == 18 then v = pv.v.ui elseif vt == 19 then v = pv.v.ul
    elseif vt == 11 then v = (pv.v.ui ~= 0) and 1 or 0 end
    media.ole32.lafk_PropVariantClear(pv)
    return v and tonumber(v)
end

local function srcSize(src)
    local w, h = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
    if vc(src, 3, 'uint32_t *, uint32_t *', w, h) < 0 then return nil end
    return tonumber(w[0]), tonumber(h[0])
end

-- Источник WIC -> пиксели BGRA (top-down), с масштабом до dw x dh (если задан)
local function readPixels(src, dw, dh)
    local fac = wicFactory()
    local cp = ffi.new('void *[1]')
    if media.wic.lafk_WICConvert(G.PF_BGRA, src, cp) < 0 then return nil end
    local s = cp[0]
    local sw, sh = srcSize(s)
    if not sw then release(s) return nil end
    local out, scaler = s, nil
    if dw and dh and (dw ~= sw or dh ~= sh) then
        local pp = ffi.new('void *[1]')
        if vc(fac, 11, 'void **', pp) >= 0 then
            scaler = pp[0]
            if vc(scaler, 8, 'void *, uint32_t, uint32_t, int', s, dw, dh, 3) >= 0 then
                out, sw, sh = scaler, dw, dh
            else
                release(scaler); scaler = nil
            end
        end
    end
    local size = sw * sh * 4
    local buf = ffi.new('uint8_t[?]', size)
    local hr = vc(out, 7, 'void *, uint32_t, uint32_t, uint8_t *', nil, sw * 4, size, buf)
    if scaler then release(scaler) end
    release(s)
    if hr < 0 then return nil end
    return buf, sw, sh
end

local function downscale(src, w, h, dw, dh)
    if dw == w and dh == h then return src end
    local dst = ffi.new('uint8_t[?]', dw * dh * 4)
    local s32, d32 = ffi.cast('uint32_t *', src), ffi.cast('uint32_t *', dst)
    for y = 0, dh - 1 do
        local sy, row = math.floor(y * h / dh) * w, y * dw
        for x = 0, dw - 1 do d32[row + x] = s32[sy + math.floor(x * w / dw)] end
    end
    return dst
end

-- Пиксели BGRA -> текстура (через TGA в памяти: D3DX понимает его вместе с прозрачностью)
local function makeTexture(buf, w, h)
    local size = 18 + w * h * 4
    local t = ffi.new('uint8_t[?]', size)
    t[2] = 2
    t[12], t[13], t[14], t[15] = w % 256, math.floor(w / 256), h % 256, math.floor(h / 256)
    t[16], t[17] = 32, 0x28
    ffi.copy(t + 18, buf, w * h * 4)
    local tex = imgui.CreateTextureFromFileInMemory(t, size)
    if tex == nil then return nil end
    return tex
end

local function planSize(w, h, maxSide, maxPx)
    local s = math.min(1, maxSide / math.max(w, h), math.sqrt(maxPx / (w * h)))
    return math.max(1, math.floor(w * s)), math.max(1, math.floor(h * s))
end

-- Средний и самый яркий цвет картинки - для подбора темы под фон
local function analyze(m, buf, w, h)
    if m.avg then return end
    local sr, sg, sb, n, best, bs = 0, 0, 0, 0, nil, -1
    for gy = 0, 23 do
        for gx = 0, 23 do
            local i = (math.floor((gy + 0.5) * h / 24) * w + math.floor((gx + 0.5) * w / 24)) * 4
            local b, g, r = buf[i] / 255, buf[i + 1] / 255, buf[i + 2] / 255
            sr, sg, sb, n = sr + r, sg + g, sb + b, n + 1
            local mx, mn = math.max(r, g, b), math.min(r, g, b)
            local score = (mx - mn) * mx
            if score > bs then bs, best = score, { r, g, b } end
        end
    end
    m.avg = { sr / n, sg / n, sb / n }
    m.vivid = best
end

local function budget(m)
    if m.cancel then error('cancel', 0) end
    if os.clock() > m.deadline then coroutine.yield() end
    if m.cancel then error('cancel', 0) end
end

-- Убрать фон у картинки частицы: заливка от краёв по похожим соседним пикселям
-- (работает и с градиентом), потом мелкие островки (искры, надписи) тоже убираются.
local function cutBackground(src, w, h)
    local n = w * h
    local buf = ffi.new('uint8_t[?]', n * 4)
    ffi.copy(buf, src, n * 4)
    -- уже прозрачная по краям - не трогаем
    local border, clear = 0, 0
    for x = 0, w - 1 do
        for _, y in ipairs({ 0, h - 1 }) do
            border = border + 1
            if buf[(y * w + x) * 4 + 3] < 128 then clear = clear + 1 end
        end
    end
    if clear > border * 0.3 then return buf end
    local mask = ffi.new('uint8_t[?]', n)                   -- 1 = фон
    local q = ffi.new('int32_t[?]', n)
    local qh, qt = 0, 0
    local function d(i, j)
        local a, b = i * 4, j * 4
        return math.abs(buf[a] - buf[b]) + math.abs(buf[a + 1] - buf[b + 1]) + math.abs(buf[a + 2] - buf[b + 2])
    end
    local function seed(i) if mask[i] == 0 then mask[i] = 1; q[qt] = i; qt = qt + 1 end end
    for x = 0, w - 1 do seed(x); seed((h - 1) * w + x) end
    for y = 0, h - 1 do seed(y * w); seed(y * w + w - 1) end
    local TH = 34
    while qh < qt do
        local i = q[qh]; qh = qh + 1
        local x, y = i % w, math.floor(i / w)
        if x > 0 and mask[i - 1] == 0 and d(i, i - 1) < TH then seed(i - 1) end
        if x < w - 1 and mask[i + 1] == 0 and d(i, i + 1) < TH then seed(i + 1) end
        if y > 0 and mask[i - w] == 0 and d(i, i - w) < TH then seed(i - w) end
        if y < h - 1 and mask[i + w] == 0 and d(i, i + w) < TH then seed(i + w) end
    end
    -- замкнутые дырки внутри фигуры (не связаны с краем): убираем пиксели,
    -- цвет которых часто встречается в уже найденном фоне
    local bins, nbg = {}, 0
    local function bin(i) local a = i * 4 return math.floor(buf[a] / 32) * 64 + math.floor(buf[a + 1] / 32) * 8 + math.floor(buf[a + 2] / 32) end
    for i = 0, n - 1 do if mask[i] == 1 then local b = bin(i); bins[b] = (bins[b] or 0) + 1; nbg = nbg + 1 end end
    local thr = math.max(3, nbg * 0.004)
    for i = 0, n - 1 do if mask[i] == 0 and (bins[bin(i)] or 0) > thr then mask[i] = 1 end end
    -- островки: оставляем только крупные куски (>= 10% от самого большого)
    local comp = ffi.new('int32_t[?]', n)
    local sizes, nc = {}, 0
    for i0 = 0, n - 1 do
        if mask[i0] == 0 and comp[i0] == 0 then
            nc = nc + 1
            qh, qt = 0, 1; q[0] = i0; comp[i0] = nc
            while qh < qt do
                local i = q[qh]; qh = qh + 1
                local x, y = i % w, math.floor(i / w)
                local function go(j) if mask[j] == 0 and comp[j] == 0 then comp[j] = nc; q[qt] = j; qt = qt + 1 end end
                if x > 0 then go(i - 1) end
                if x < w - 1 then go(i + 1) end
                if y > 0 then go(i - w) end
                if y < h - 1 then go(i + w) end
            end
            sizes[nc] = qt
        end
    end
    local big = 0
    for _, v in ipairs(sizes) do if v > big then big = v end end
    for i = 0, n - 1 do
        if mask[i] == 1 or sizes[comp[i]] < big * 0.1 then buf[i * 4 + 3] = 0
        else
            -- край: полупрозрачность по похожести на соседний фон
            local x, y = i % w, math.floor(i / w)
            local best = 999
            if x > 0 and mask[i - 1] == 1 then best = math.min(best, d(i, i - 1)) end
            if x < w - 1 and mask[i + 1] == 1 then best = math.min(best, d(i, i + 1)) end
            if y > 0 and mask[i - w] == 1 then best = math.min(best, d(i, i - w)) end
            if y < h - 1 and mask[i + w] == 1 then best = math.min(best, d(i, i + w)) end
            if best < 999 then
                buf[i * 4 + 3] = math.floor(buf[i * 4 + 3] * math.min(1, best / 160))
            end
        end
    end
    return buf
end

local function addFrame(m, buf, w, h, delay)
    analyze(m, buf, w, h)
    if m.cutBg then buf = cutBackground(buf, w, h) end
    local tex = makeTexture(buf, w, h)
    if tex == nil then error('не удалось создать текстуру', 0) end
    m.frames[#m.frames + 1], m.delays[#m.delays + 1] = tex, delay
    m.w, m.h = w, h
end

local function openDecoder(path)
    local pp = ffi.new('void *[1]')
    local hr = vc(wicFactory(), 3, 'const uint16_t *, void *, uint32_t, int, void **', wide(path), nil, 0x80000000, 0, pp)
    if hr < 0 then return nil, hr end
    return pp[0]
end

-- Картинка или анимация (gif / анимированный webp) через WIC
local function loadImage(m, path, opt)
    local dec, hr = openDecoder(path)
    if not dec then error('формат не поддерживается системой (' .. hex(hr) .. ')', 0) end
    local ok, err = pcall(function()
        local cnt = ffi.new('uint32_t[1]')
        vc(dec, 12, 'uint32_t *', cnt)
        local n = math.max(1, tonumber(cnt[0]))
        local isGif = path:lower():match('%.gif$') ~= nil
        local picks = math.min(n, opt.maxFrames)
        local step = n / picks
        local nextPick, cw, ch, canvas, saved = 0, nil, nil, nil, nil
        if isGif and n > 1 then
            local rp = ffi.new('void *[1]')
            if vc(dec, 8, 'void **', rp) >= 0 then
                cw, ch = metaNum(rp[0], '/logscrdesc/Width'), metaNum(rp[0], '/logscrdesc/Height')
                release(rp[0])
            end
        end
        local dw, dh
        for i = 0, n - 1 do
            budget(m)
            local fp = ffi.new('void *[1]')
            if vc(dec, 13, 'uint32_t, void **', i, fp) < 0 then break end
            local fr = fp[0]
            local left, top, delay, disp = 0, 0, 10, 0
            if n > 1 then
                local rp = ffi.new('void *[1]')
                if vc(fr, 8, 'void **', rp) >= 0 then
                    left = metaNum(rp[0], '/imgdesc/Left') or 0
                    top = metaNum(rp[0], '/imgdesc/Top') or 0
                    delay = metaNum(rp[0], '/grctlext/Delay') or 10
                    disp = metaNum(rp[0], '/grctlext/Disposal') or 0
                    release(rp[0])
                end
            end
            local d = ((delay or 0) <= 1 and 10 or delay) / 100
            if canvas or (isGif and n > 1) then
                -- GIF: кадры бывают частичными - собираем полный кадр на холсте
                local px, fw, fh = readPixels(fr)
                release(fr)
                if px then
                    if not canvas then
                        cw, ch = cw or fw, ch or fh
                        canvas = ffi.new('uint8_t[?]', cw * ch * 4)
                        dw, dh = planSize(cw, ch, opt.maxSide, opt.budget / picks)
                    end
                    if disp == 3 then saved = ffi.new('uint8_t[?]', cw * ch * 4); ffi.copy(saved, canvas, cw * ch * 4) end
                    local s32, c32 = ffi.cast('uint32_t *', px), ffi.cast('uint32_t *', canvas)
                    for y = 0, fh - 1 do
                        local cy = top + y
                        if cy >= 0 and cy < ch then
                            local srow, crow = y * fw, cy * cw + left
                            for x = 0, math.min(fw, cw - left) - 1 do
                                if px[(srow + x) * 4 + 3] >= 128 then c32[crow + x] = s32[srow + x] end
                            end
                        end
                    end
                    if i >= nextPick then
                        nextPick = nextPick + step
                        addFrame(m, downscale(canvas, cw, ch, dw, dh), dw, dh, 0)
                    end
                    m.delays[#m.delays] = (m.delays[#m.delays] or 0) + d
                    if disp == 2 then
                        for y = math.max(0, top), math.min(ch, top + fh) - 1 do
                            ffi.fill(canvas + (y * cw + math.max(0, left)) * 4, math.max(0, math.min(cw, left + fw) - math.max(0, left)) * 4, 0)
                        end
                    elseif disp == 3 and saved then
                        ffi.copy(canvas, saved, cw * ch * 4)
                    end
                end
            else
                if i >= nextPick then
                    nextPick = nextPick + step
                    local fw, fh = srcSize(fr)
                    if fw then
                        dw, dh = planSize(fw, fh, opt.maxSide, opt.budget / picks)
                        local px = readPixels(fr, dw, dh)
                        if px then addFrame(m, px, dw, dh, 0) end
                    end
                end
                release(fr)
                if #m.delays > 0 then m.delays[#m.delays] = m.delays[#m.delays] + d end
            end
        end
    end)
    release(dec)
    if not ok then error(err, 0) end
end

-- Папка с кадрами (001.png, 002.png, ...) - как анимация
local function loadSequence(m, dir, files, opt)
    local picks = math.min(#files, opt.maxFrames)
    local step = #files / picks
    local i = 1
    while i <= #files and #m.frames < picks do
        budget(m)
        local dec = openDecoder(dir .. '\\' .. files[math.floor(i)])
        if dec then
            local fp = ffi.new('void *[1]')
            if vc(dec, 13, 'uint32_t, void **', 0, fp) >= 0 then
                local fw, fh = srcSize(fp[0])
                if fw then
                    local dw, dh = planSize(fw, fh, opt.maxSide, opt.budget / picks)
                    local px = readPixels(fp[0], dw, dh)
                    if px then addFrame(m, px, dw, dh, step / opt.fps) end
                end
                release(fp[0])
            end
            release(dec)
        end
        i = i + step
    end
end

-- Видео через Media Foundation: берём кадры с нужной частотой, до лимита кадров
local mfStarted = false
local function loadVideo(m, path, opt)
    local mf, mfrw = media.mfplat, media.mfrw
    if not mf or not mfrw then error('в системе нет Media Foundation', 0) end
    media.ole32.lafk_CoInitializeEx(nil, 2)
    if not mfStarted then
        local hr = mf.lafk_MFStartup(0x20070, 0)
        if hr < 0 then error('Media Foundation не запустился (' .. hex(hr) .. ')', 0) end
        mfStarted = true
    end
    local ap = ffi.new('void *[1]')
    if mf.lafk_MFCreateAttributes(ap, 1) < 0 then error('MFCreateAttributes', 0) end
    vc(ap[0], 21, 'const lafk_GUID *, uint32_t', G.MF_VPROC, 1)
    local rp = ffi.new('void *[1]')
    local hr = mfrw.lafk_MFCreateSourceReaderFromURL(wide(path), ap[0], rp)
    release(ap[0])
    if hr < 0 then error('видео не открылось - нет кодека или файл повреждён (' .. hex(hr) .. ')', 0) end
    local rd = rp[0]
    local VS = 0xFFFFFFFC
    local ok, err = pcall(function()
        vc(rd, 4, 'uint32_t, int', 0xFFFFFFFE, 0)
        vc(rd, 4, 'uint32_t, int', VS, 1)
        local tp = ffi.new('void *[1]')
        if mf.lafk_MFCreateMediaType(tp) < 0 then error('MFCreateMediaType', 0) end
        vc(tp[0], 24, 'const lafk_GUID *, const lafk_GUID *', G.MT_MAJOR, G.MT_VIDEO)
        vc(tp[0], 24, 'const lafk_GUID *, const lafk_GUID *', G.MT_SUBTYPE, G.RGB32)
        hr = vc(rd, 7, 'uint32_t, uint32_t *, void *', VS, nil, tp[0])
        release(tp[0])
        if hr < 0 then error('видео не переводится в RGB (' .. hex(hr) .. ')', 0) end
        local cp = ffi.new('void *[1]')
        if vc(rd, 6, 'uint32_t, void **', VS, cp) < 0 then error('нет формата кадра', 0) end
        local fs = ffi.new('uint32_t[2]')
        vc(cp[0], 8, 'const lafk_GUID *, uint32_t *', G.MT_SIZE, fs)
        local st = ffi.new('uint32_t[1]')
        local hasStride = vc(cp[0], 7, 'const lafk_GUID *, uint32_t *', G.MT_STRIDE, st) >= 0
        release(cp[0])
        local vw, vh = tonumber(fs[1]), tonumber(fs[0])
        if vw < 1 or vh < 1 then error('неизвестный размер кадра', 0) end
        local stride = hasStride and tonumber(ffi.cast('int32_t', st[0])) or vw * 4
        local flipV = (stride < 0) ~= (opt.flip == true)
        stride = math.abs(stride)
        local dw, dh = planSize(vw, vh, opt.maxSide, opt.budget / opt.maxFrames)
        local interval, nextT = 1 / opt.fps, 0
        local idx, flags, ts, sp = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]'), ffi.new('int64_t[1]'), ffi.new('void *[1]')
        local data, maxl, cur = ffi.new('uint8_t *[1]'), ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
        local empty = 0
        while #m.frames < opt.maxFrames do
            budget(m)
            sp[0] = nil
            hr = vc(rd, 9, 'uint32_t, uint32_t, uint32_t *, uint32_t *, int64_t *, void **', VS, 0, idx, flags, ts, sp)
            local smp = sp[0]
            if hr < 0 or bit.band(flags[0], 2) ~= 0 then release(smp) break end
            if smp == nil then
                empty = empty + 1
                if empty > 300 then break end
            else
                empty = 0
                local t = tonumber(ts[0]) / 1e7
                if t + 0.001 >= nextT then
                    nextT = math.max(nextT + interval, t)
                    local bp = ffi.new('void *[1]')
                    if vc(smp, 41, 'void **', bp) >= 0 then
                        local b = bp[0]
                        if vc(b, 3, 'uint8_t **, uint32_t *, uint32_t *', data, maxl, cur) >= 0 then
                            local sstride = stride
                            if tonumber(cur[0]) < sstride * vh then sstride = math.floor(tonumber(cur[0]) / vh) end
                            local src = data[0]
                            local px = ffi.new('uint8_t[?]', dw * dh * 4)
                            local d32 = ffi.cast('uint32_t *', px)
                            for y = 0, dh - 1 do
                                local sy = math.floor(y * vh / dh)
                                if flipV then sy = vh - 1 - sy end
                                local row = ffi.cast('uint32_t *', src + sy * sstride)
                                local base = y * dw
                                for x = 0, dw - 1 do d32[base + x] = bit.bor(row[math.floor(x * vw / dw)], 0xFF000000) end
                            end
                            vc(b, 4, '')
                            addFrame(m, px, dw, dh, interval)
                        end
                        release(b)
                    end
                end
                release(smp)
            end
        end
    end)
    release(rd)
    if not ok then error(err, 0) end
end

-- Запасной путь для dds/tga и т.п.: D3DX сам грузит файл (без анимации)
local function loadD3DX(m, path)
    local tex = imgui.CreateTextureFromFile(path)
    if tex == nil then error('файл не открылся', 0) end
    local w, h = 256, 256
    pcall(function()
        local desc = ffi.new('uint32_t[8]')
        if vc(ffi.cast('void *', tex), 17, 'uint32_t, uint32_t *', 0, desc) >= 0 then w, h = tonumber(desc[6]), tonumber(desc[7]) end
    end)
    m.frames[1], m.delays[1], m.w, m.h = tex, 1, w, h
end

local function extOf(name) return (tostring(name):match('%.([^%.\\/]+)$') or ''):lower() end

-- Список файлов папки: { name, disp, dir, video, ext }
function media.scanDir(dir)
    local list = {}
    local ok = pcall(function()
        local h, name = findFirstFile(dir .. '\\*')
        if not h then return end
        while name do
            if name ~= '.' and name ~= '..' then
                local full = dir .. '\\' .. name
                local ext = extOf(name)
                local isDir = doesDirectoryExist(full)
                if isDir or IMG_EXT[ext] or VIDEO_EXT[ext] then
                    list[#list + 1] = { name = name, disp = u8(name), dir = isDir, video = VIDEO_EXT[ext] ~= nil, ext = ext }
                end
            end
            name = findNextFile(h)
        end
        findClose(h)
    end)
    table.sort(list, function(a, b)
        if a.dir ~= b.dir then return a.dir end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

local function imagesIn(dir)
    local out = {}
    for _, f in ipairs(media.scanDir(dir)) do
        if not f.dir and not f.video then out[#out + 1] = f.name end
    end
    return out
end

-- Создать объект медиа и поставить загрузку в очередь (идёт по кусочкам в кадрах меню)
function media.load(path, opt)
    local m = { frames = {}, delays = {}, w = 1, h = 1, done = false, path = path, deadline = 0 }
    m.cutBg = opt and opt.cutBg or nil
    if not media.ok then m.done, m.err = true, media.err return m end
    local ext = extOf(path)
    m.co = coroutine.create(function()
        if doesDirectoryExist(path) then
            local files = imagesIn(path)
            if #files == 0 then error('в папке нет картинок', 0) end
            loadSequence(m, path, files, opt)
        elseif VIDEO_EXT[ext] then
            loadVideo(m, path, opt)
        else
            local ok, e = pcall(loadImage, m, path, opt)
            if not ok then
                if e == 'cancel' then error(e, 0) end
                if #m.frames == 0 and (ext == 'dds' or ext == 'tga' or ext == 'png' or ext == 'jpg' or ext == 'jpeg' or ext == 'bmp') then
                    loadD3DX(m, path)
                else
                    error(e, 0)
                end
            end
        end
    end)
    media.loaders[#media.loaders + 1] = m
    return m
end

-- Текстуры освобождаем не сразу, а через пару кадров: в текущем кадре картинка уже
-- могла попасть в список отрисовки, и удаление прямо сейчас роняет игру.
media.trash, media.tick = {}, 0
function media.free(m)
    if not m then return end
    m.cancel = true
    for _, t in ipairs(m.frames) do media.trash[#media.trash + 1] = { tex = t, tick = media.tick } end
    m.frames, m.delays = {}, {}
end

local function emptyTrash()
    local i = 1
    while i <= #media.trash do
        local e = media.trash[i]
        if media.tick - e.tick >= 2 then
            pcall(imgui.ReleaseTexture, e.tex)
            table.remove(media.trash, i)
        else
            i = i + 1
        end
    end
end

local function finish(m)
    m.done, m.co = true, nil
    local cum, total = {}, 0
    for i, d in ipairs(m.delays) do total = total + math.max(0.01, d); cum[i] = total end
    m.cum, m.total = cum, total
    if #m.frames == 0 and not m.err then m.err = 'не удалось загрузить' end
end

-- Продолжить загрузки (вызывается каждый кадр меню, ~budgetSec времени на всё)
-- Удаление файла/папки с диска. Откладывается на пару кадров, чтобы загрузчик,
-- если он ещё читал этот файл, успел его закрыть.
media.deletes = {}
function media.delete(path, isDir, done)
    media.deletes[#media.deletes + 1] = { path = path, dir = isDir, tick = media.tick, done = done }
end

local function removePath(path, isDir)
    if not isDir then return os.remove(path) ~= nil end
    local names = {}
    pcall(function()
        local h, name = findFirstFile(path .. '\\*')
        if not h then return end
        while name do
            if name ~= '.' and name ~= '..' then names[#names + 1] = name end
            name = findNextFile(h)
        end
        findClose(h)
    end)
    for _, n in ipairs(names) do os.remove(path .. '\\' .. n) end
    local ok, r = pcall(function() return ffi.C.lafk_RemoveDirectoryA(path) end)
    return ok and r ~= 0
end

local function runDeletes()
    local i = 1
    while i <= #media.deletes do
        local d = media.deletes[i]
        if media.tick - d.tick >= 3 then
            local ok = removePath(d.path, d.dir)
            table.remove(media.deletes, i)
            if d.done then pcall(d.done, ok) end
        else
            i = i + 1
        end
    end
end

function media.pump(budgetSec)
    media.tick = media.tick + 1
    emptyTrash()
    runDeletes()
    local i = 1
    while i <= #media.loaders do
        local m = media.loaders[i]
        m.deadline = os.clock() + budgetSec
        local ok, err = coroutine.resume(m.co)
        if not ok then
            if err ~= 'cancel' then m.err = tostring(err); log('[media] ' .. tostring(m.path) .. ': ' .. tostring(err)) end
        end
        if m.cancel then
            -- отменили во время загрузки - освобождаем то, что успело загрузиться
            if coroutine.status(m.co) ~= 'dead' then
                m.deadline = 0
                coroutine.resume(m.co)
            end
            media.free(m)
            table.remove(media.loaders, i)
        elseif coroutine.status(m.co) == 'dead' then
            finish(m)
            table.remove(media.loaders, i)
        else
            i = i + 1
        end
        if os.clock() > m.deadline then break end
    end
end

-- Текущий кадр анимации
function media.frame(m, t)
    local n = #m.frames
    if n == 0 then return nil end
    if n == 1 or not m.done or not m.total or m.total <= 0 then return m.frames[1] end
    local x = t % m.total
    local cum = m.cum
    local lo, hi = 1, n
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if cum[mid] < x then lo = mid + 1 else hi = mid end
    end
    return m.frames[lo]
end

-- Встроенные частицы (белые, без фона): контур рисуется в текстуру со сглаживанием
local BUILTIN = {
    arizona = { 1.000,-0.967, 0.802,-0.967, 0.637,-0.949, 0.479,-0.919, 0.240,-0.850, 0.061,-0.776, -0.116,-0.684, -0.284,-0.571, -0.428,-0.450, -0.552,-0.317, -0.666,-0.171, -0.769,-0.006, -0.861,0.185, -0.934,0.398, -0.978,0.593, -1.000,0.802, -1.000,0.963, -0.989,0.967, -0.794,0.879, -0.563,0.806, -0.358,0.761, -0.116,0.736, 0.134,0.736, 0.453,0.776, 0.743,0.853, 0.989,0.952, 0.842,0.817, 0.626,0.666, 0.479,0.589, 0.306,0.519, 0.149,0.472, -0.072,0.431, -0.215,0.420, -0.505,0.431, -0.516,0.424, -0.516,0.409, -0.450,0.207, -0.376,0.053, -0.259,-0.130, -0.123,-0.292, 0.006,-0.409, 0.174,-0.530, 0.376,-0.637, 0.519,-0.692, 0.538,-0.692, 0.541,-0.677, 0.490,-0.461, 0.468,-0.240, 0.468,-0.046, 0.486,0.134, 0.457,0.138, 0.332,0.119, 0.200,0.119, 0.057,0.138, -0.046,0.163, -0.163,0.207, -0.284,0.270, -0.350,0.317, -0.050,0.310, 0.053,0.321, 0.211,0.350, 0.372,0.398, 0.541,0.468, 0.677,0.541, 0.850,0.662, 0.996,0.798, 1.000,0.783, 0.956,0.677, 0.897,0.483, 0.839,0.226, 0.798,-0.094, 0.794,-0.314, 0.813,-0.490, 0.853,-0.651, 0.912,-0.802 },
}
do
    local hp = {}
    for i = 0, 63 do
        local t = i / 64 * 2 * math.pi
        local x = 16 * math.sin(t) ^ 3
        local y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        hp[#hp + 1] = x / 17; hp[#hp + 1] = -(y + 2.5) / 17
    end
    BUILTIN.hearts = hp
end
local function rasterPoly(pts, N)
    local cov = {}
    for i = 0, N * N - 1 do cov[i] = 0 end
    local np, SS = #pts / 2, 4
    for sy = 0, N * SS - 1 do
        local yy = ((sy + 0.5) / SS) / N * 2 - 1
        local xs = {}
        for i = 0, np - 1 do
            local j = (i + 1) % np
            local x1, y1, x2, y2 = pts[i * 2 + 1], pts[i * 2 + 2], pts[j * 2 + 1], pts[j * 2 + 2]
            if (y1 <= yy) ~= (y2 <= yy) then xs[#xs + 1] = x1 + (yy - y1) / (y2 - y1) * (x2 - x1) end
        end
        table.sort(xs)
        local row = math.floor(sy / SS) * N
        for k = 1, #xs - 1, 2 do
            local a, b = (xs[k] + 1) / 2 * N, (xs[k + 1] + 1) / 2 * N
            local ia, ib = math.max(0, math.floor(a)), math.min(N - 1, math.floor(b))
            for x = ia, ib do
                local l, r = math.max(a, x), math.min(b, x + 1)
                if r > l then cov[row + x] = cov[row + x] + (r - l) / SS end
            end
        end
    end
    local buf = ffi.new('uint8_t[?]', N * N * 4)
    for i = 0, N * N - 1 do
        buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2] = 255, 255, 255
        buf[i * 4 + 3] = math.floor(math.min(1, cov[i]) * 255 + 0.5)
    end
    return buf
end
media.builtins = {}
function media.builtin(kind)
    local m = media.builtins[kind]
    if m then return m end
    m = { frames = {}, delays = { 1 }, w = 96, h = 96, done = true, total = 1, cum = { 1 } }
    media.builtins[kind] = m
    local pts = BUILTIN[kind]
    if not pts then return m end
    local ok = pcall(function()
        local px = {}
        for i = 1, #pts, 2 do px[i], px[i + 1] = pts[i] * 0.94, pts[i + 1] * 0.94 end
        local tex = makeTexture(rasterPoly(px, 96), 96, 96)
        if tex ~= nil then m.frames[1] = tex end
    end)
    if not ok then m.err = 'не удалось создать' end
    return m
end

function media.openFolder(dir)
    if media.shell then pcall(media.shell.lafk_ShellExecuteA, nil, 'open', dir, nil, nil, 1) end
end
end -- загрузчик

local menu = { window = imgui.new.bool(false), tab = 1, frames = 0, err = nil }

local function f3(hex) local r, g, b = hexToRGB(hex) return imgui.new.float[3](r, g, b) end
local function setF3(arr, hex) local r, g, b = hexToRGB(hex) arr[0], arr[1], arr[2] = r, g, b end

local ui = {
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

    setTab     = imgui.new.int(0),
    accent     = f3(cfg.theme.accent),
    bg         = f3(cfg.theme.bg),
    childAlpha = imgui.new.float(num(cfg.theme.childAlpha, 0.8)),
    rounding   = imgui.new.int(num(cfg.theme.rounding, 12)),

    bgOn       = imgui.new.bool(cfg.bgimg.enabled == true),
    bgFit      = imgui.new.int(num(cfg.bgimg.fit, 0)),
    bgDim      = imgui.new.float(num(cfg.bgimg.dim, 0.45)),
    bgSpeed    = imgui.new.float(num(cfg.bgimg.speed, 1.0)),
    bgFps      = imgui.new.int(num(cfg.bgimg.fps, 20)),
    bgQuality  = imgui.new.int(num(cfg.bgimg.quality, 1)),
    bgFlip     = imgui.new.bool(cfg.bgimg.flip == true),
    webUrl     = imgui.new.char[4096](),

    pOn        = imgui.new.bool(cfg.particles.enabled ~= false),
    pMode      = imgui.new.int(num(cfg.particles.mode, 0)),
    pRainbow   = imgui.new.bool(cfg.particles.rainbow == true),
    pTint      = imgui.new.bool(cfg.particles.tint == true),
    pSpin      = imgui.new.bool(cfg.particles.spin ~= false),
    pColor     = f3(cfg.particles.color),
    pCount     = imgui.new.int(num(cfg.particles.count, 70)),
    pSpeed     = imgui.new.int(num(cfg.particles.speed, 60)),
    pSize      = imgui.new.float(num(cfg.particles.size, 2.0)),
    pAlpha     = imgui.new.float(num(cfg.particles.alpha, 0.6)),

    autoUpd    = imgui.new.bool(cfg.update.auto ~= false),
}

-- Папки для своих файлов: moonloader/config/lua_afk/backgrounds и /particles
local DIRS = {}
do
    local base = getWorkingDirectory() .. '\\config\\lua_afk'
    DIRS.base, DIRS.bg, DIRS.pt = base, base .. '\\backgrounds', base .. '\\particles'
    for _, d in ipairs({ getWorkingDirectory() .. '\\config', DIRS.base, DIRS.bg, DIRS.pt }) do
        if not doesDirectoryExist(d) then pcall(createDirectory, d) end
    end
end

-- Тема ------------------------------------------------------------------
local function applyTheme()
    local style = imgui.GetStyle()
    local c, col = style.Colors, imgui.Col
    local ar, ag, ab = hexToRGB(cfg.theme.accent)
    local br, bgc, bb = hexToRGB(cfg.theme.bg)
    BGV = V4(br, bgc, bb, 1)
    LIGHT = relLum(br, bgc, bb) > 0.28
    -- INK - цвет "в сторону контраста": на светлом фоне тёмный, на тёмном - белый
    local INK = LIGHT and V4(0.05, 0.06, 0.08, 1) or V4(1, 1, 1, 1)
    local function shade(k, a) return mixV(BGV, INK, k, a) end
    local rnd = num(cfg.theme.rounding, 12)

    TEXT = LIGHT and V4(0.09, 0.10, 0.13, 1) or V4(0.94, 0.95, 0.98, 1)
    DIM = ensureContrast(LIGHT and V4(0.40, 0.42, 0.48, 1) or V4(0.60, 0.63, 0.70, 1), BGV, 4.5, TEXT)
    ACCENT = V4(ar, ag, ab, 1)
    ACCENT_TEXT = ensureContrast(ACCENT, BGV, 3.5, TEXT)
    SURF, SURF_H, SURF_A = shade(0.09), shade(0.14), shade(0.19)
    TRACK = shade(LIGHT and 0.22 or 0.20)
    KNOB = V4(1, 1, 1, 1)
    KNOB_EDGE = LIGHT and V4(0, 0, 0, 0.25) or V4(0, 0, 0, 0)
    CHILD = shade(0.04)
    -- кнопки: акцент, смешанный с фоном ровно настолько, чтобы текст на них читался
    local btn = mixV(BGV, ACCENT, 0.2)
    for i = 0, 12 do
        local cand = mixV(BGV, ACCENT, 0.8 - i * 0.05)
        if contrast(cand, TEXT) >= 4.5 then btn = cand break end
    end

    style.WindowPadding     = vec(14, 14)
    style.FramePadding      = vec(10, 6)
    style.ItemSpacing       = vec(10, 10)
    style.WindowRounding    = rnd
    style.ChildRounding     = rnd * 0.8
    style.FrameRounding     = rnd * 0.6
    style.GrabRounding      = rnd * 0.6
    style.ScrollbarRounding = rnd * 0.6
    style.PopupRounding     = rnd * 0.6
    style.GrabMinSize       = 14
    style.WindowBorderSize  = 1
    style.ChildBorderSize   = 1

    c[col.WindowBg]             = V4(br, bgc, bb, 0.97)
    c[col.ChildBg]              = shade(0.04, num(cfg.theme.childAlpha, 0.8))
    c[col.PopupBg]              = shade(0.03, 0.98)
    c[col.Border]               = V4(ar, ag, ab, LIGHT and 0.55 or 0.40)
    c[col.BorderShadow]         = V4(0, 0, 0, 0)
    c[col.Separator]            = mixV(BGV, ACCENT, 0.45)
    c[col.Text]                 = TEXT
    c[col.TextDisabled]         = DIM
    c[col.TextSelectedBg]       = V4(ar, ag, ab, 0.35)
    c[col.FrameBg]              = SURF
    c[col.FrameBgHovered]       = SURF_H
    c[col.FrameBgActive]        = SURF_A
    c[col.Button]               = btn
    c[col.ButtonHovered]        = mixV(btn, INK, 0.10)
    c[col.ButtonActive]         = mixV(btn, INK, 0.20)
    c[col.Header]               = mixV(BGV, ACCENT, 0.28)
    c[col.HeaderHovered]        = mixV(BGV, ACCENT, 0.38)
    c[col.HeaderActive]         = mixV(BGV, ACCENT, 0.48)
    c[col.PlotHistogram]        = ACCENT
    c[col.SliderGrab]           = ACCENT
    c[col.SliderGrabActive]     = mixV(ACCENT, INK, 0.25)
    c[col.CheckMark]            = ACCENT_TEXT
    c[col.ScrollbarBg]          = shade(0.02, 0.6)
    c[col.ScrollbarGrab]        = shade(0.22)
    c[col.ScrollbarGrabHovered] = shade(0.30)
    c[col.ScrollbarGrabActive]  = shade(0.38)
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

local function section(title)
    imgui.Spacing()
    imgui.TextColored(ACCENT_TEXT, title)
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
    imgui.TextColored(color or TEXT, text)
end

local function toggle(id, label, ptr)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local h  = imgui.GetFrameHeight()
    local w  = h * 1.9
    local clicked = imgui.InvisibleButton(id, vec(w, h))
    if clicked then ptr[0] = not ptr[0] end
    local t = approach(id, ptr[0] and 1 or 0)
    local bg = lerpV4(TRACK, ACCENT, t)
    if imgui.IsItemHovered() then bg = lerpV4(bg, TEXT, 0.08) end
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(bg), h / 2)
    local kc = vec(p.x + h / 2 + t * (w - h), p.y + h / 2)
    dl:AddCircleFilled(kc, h / 2 - 3, U32(KNOB), 24)
    if KNOB_EDGE.w > 0 then dl:AddCircle(kc, h / 2 - 3, U32(KNOB_EDGE), 24, 1) end
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
            imgui.PushStyleColor(imgui.Col.Button, SURF)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, SURF_H)
            imgui.PushStyleColor(imgui.Col.ButtonActive, SURF_A)
        end
        if imgui.Button(name .. '##' .. id .. i, vec(w, 30)) and not active then
            ptr[0] = i - 1
            changed = true
        end
        if not active then imgui.PopStyleColor(3) end
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
    imgui.PushStyleColor(imgui.Col.Button,        SURF)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, SURF_H)
    imgui.PushStyleColor(imgui.Col.ButtonActive,  SURF_A)
    local pressed = imgui.Button(label, size)
    imgui.PopStyleColor(3)
    return pressed
end

-- Иконки (рисуются линиями) ------------------------------------------------
-- Тягач с полуприцепом (рисуется фигурами, цвета подстраиваются под тему).
-- moving - бот едет: крутятся колёса, идёт дым из трубы, горит фара.
local function drawTruck(dl, x, y, s, moving)
    local function P(a, b) return vec(x + a * s, y + b * s) end
    local function R(a, b, c2, d, col, r) dl:AddRectFilled(P(a, b), P(c2, d), col, (r or 0) * s) end
    local time = imgui.GetTime()
    local body  = U32(LIGHT and V4(1, 1, 1, 1) or V4(0.88, 0.90, 0.95, 1))
    local edge  = U32(mixV(BGV, TEXT, LIGHT and 0.45 or 0.25))
    local dark  = U32(V4(0.13, 0.14, 0.17, 1))
    local metal = U32(V4(0.62, 0.65, 0.70, 1))
    local cab   = U32(ACCENT)
    local cabDk = U32(mixV(ACCENT, V4(0, 0, 0, 1), 0.35))
    local glass = U32(V4(0.62, 0.82, 1, 0.95))

    -- тень
    R(1, 31.2, 57, 32.6, U32(V4(0, 0, 0, LIGHT and 0.12 or 0.25)), 1)
    -- рама
    R(2, 23.5, 56, 26.5, dark, 1)
    -- полуприцеп: кузов с полосой в цвет темы
    R(0, 2, 37, 24, edge, 2.2)                               -- контур
    R(0.5, 2.5, 36.5, 23.5, body, 1.9)
    R(0.6, 15, 36.4, 17.6, cab)
    for i = 1, 5 do dl:AddLine(P(i * 6.2, 3.5), P(i * 6.2, 14), edge, math.max(1, s * 0.35)) end
    -- сцепка
    R(37, 21.5, 41, 24, dark)
    -- выхлопная труба и дым
    R(40.6, 1.5, 42.2, 9, metal, 0.6)
    if moving then
        for i = 0, 2 do
            local k = (time * 0.9 + i / 3) % 1
            dl:AddCircleFilled(P(41.4 - k * 6, 1 - k * 6), (1.2 + k * 2.6) * s,
                U32(mixV(BGV, TEXT, 0.35, 0.45 * (1 - k))), 16)
        end
    end
    -- кабина: задняя часть, скошенный капот, крыша-обтекатель
    R(40, 8, 51.5, 26, cab, 1.5)
    dl:AddQuadFilled(P(51, 8), P(53.5, 8), P(57, 15.5), P(51, 15.5), cab)
    R(51, 15, 57, 26, cab, 1.2)
    dl:AddQuadFilled(P(41, 8), P(49, 8), P(48, 4.6), P(42.5, 4.6), cabDk)
    -- окно и дверь
    dl:AddQuadFilled(P(46, 10), P(52.6, 10), P(55.6, 15), P(46, 15), glass)
    dl:AddLine(P(45, 10), P(45, 24.5), cabDk, math.max(1, s * 0.45))
    R(46.2, 17.2, 48.4, 18.2, cabDk, 0.4)                    -- ручка
    -- решётка, фара, бампер
    for i = 0, 2 do R(56.2, 16.5 + i * 1.6, 57, 17.3 + i * 1.6, cabDk) end
    local lamp = moving and V4(1, 0.92, 0.55, 1) or V4(1, 0.95, 0.8, 0.85)
    R(55.4, 21, 57.4, 22.8, U32(lamp), 0.5)
    if moving then dl:AddCircleFilled(P(58.6, 21.9), 2.6 * s, U32(V4(1, 0.9, 0.5, 0.18)), 20) end
    R(52, 24.4, 58, 26.8, metal, 0.8)
    -- колёса со спицами (крутятся, когда бот едет)
    local ang = moving and time * 9 or 0
    for _, wx in ipairs({ 7, 14.5, 44, 52.5 }) do
        local c = P(wx, 28.2)
        dl:AddCircleFilled(c, 4.0 * s, dark, 24)
        dl:AddCircleFilled(c, 2.2 * s, metal, 20)
        for k = 0, 2 do
            local a = ang + k * 2.094
            dl:AddLine(c, vec(c.x + math.cos(a) * 2.0 * s, c.y + math.sin(a) * 2.0 * s), dark, math.max(1, s * 0.45))
        end
        dl:AddCircleFilled(c, 0.7 * s, dark, 10)
    end
end

-- Маленькая иконка грузовика для меню слева (одним цветом)
local function iconTruck(dl, c, col)
    local x, y = c.x - 10, c.y - 6
    dl:AddRectFilled(vec(x, y), vec(x + 12, y + 8.5), col, 1.5)            -- прицеп
    dl:AddRectFilled(vec(x + 13, y + 3), vec(x + 19, y + 8.5), col, 1.5)   -- кабина
    dl:AddRectFilled(vec(x + 18, y + 5.5), vec(x + 20, y + 8.5), col, 1)   -- капот
    for _, wx in ipairs({ 3.5, 9, 15, 18.5 }) do
        dl:AddCircleFilled(vec(x + wx, y + 10.5), 2.1, col, 12)
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

-- Шестерня: при наведении/на открытой вкладке медленно крутится
local function iconGear(dl, c, col, t)
    local rot = imgui.GetTime() * 1.6 * (t or 0)
    for i = 0, 7 do
        local a = rot + i * math.pi / 4
        local ca, sa = math.cos(a), math.sin(a)
        dl:AddLine(vec(c.x + ca * 5.2, c.y + sa * 5.2), vec(c.x + ca * 8.6, c.y + sa * 8.6), col, 3.2)
    end
    dl:AddCircle(c, 5.6, col, 24, 2.6)
    dl:AddCircleFilled(c, 1.8, col, 12)
end

local function sidebarButton(id, name, icon, active)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    local h  = 40
    local clicked = imgui.InvisibleButton(id, vec(w, h))
    local t = approach(id, active and 1 or (imgui.IsItemHovered() and 0.45 or 0), 14)
    if t > 0.01 then
        dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(V4(ACCENT.x, ACCENT.y, ACCENT.z, (LIGHT and 0.22 or 0.18) * t)), 8)
    end
    if active then dl:AddRectFilled(vec(p.x, p.y + 8), vec(p.x + 4, p.y + h - 8), U32(ACCENT), 2) end
    local col = U32(lerpV4(DIM, active and ACCENT_TEXT or TEXT, t))
    icon(dl, vec(p.x + 22, p.y + h / 2), col, t)
    dl:AddText(vec(p.x + 42, p.y + (h - imgui.GetTextLineHeight()) / 2), col, name)
    return clicked
end

-- Свой фон меню ------------------------------------------------------------
local bgState = { media = nil, file = nil }

local QUALITY = {
    { budget = 8e6,  frames = 90,  side = 1280 },
    { budget = 16e6, frames = 150, side = 1600 },
    { budget = 32e6, frames = 240, side = 1920 },
}

local function bgOptions()
    local q = QUALITY[clamp(num(cfg.bgimg.quality, 1), 0, 2) + 1]
    return { maxSide = q.side, budget = q.budget, maxFrames = q.frames,
             fps = clamp(num(cfg.bgimg.fps, 20), 5, 60), flip = cfg.bgimg.flip == true }
end

local function bgReload()
    if bgState.media then media.free(bgState.media) end
    bgState.media, bgState.file = nil, nil
    local f = tostring(cfg.bgimg.file or '')
    if cfg.bgimg.enabled and f ~= '' then
        bgState.file = f
        bgState.media = media.load(DIRS.bg .. '\\' .. f, bgOptions())
    end
end

local function drawImage(dl, tex, p0, p1, uv0, uv1, col, rounding)
    if rounding and rounding > 0 and not media.noRounded then
        local ok = pcall(function() dl:AddImageRounded(tex, p0, p1, uv0, uv1, col, rounding) end)
        if ok then return end
        media.noRounded = true -- старая версия mimgui: рисуем без скругления
    end
    dl:AddImage(tex, p0, p1, uv0, uv1, col)
end

-- Рисует фон-картинку с подгонкой под окно и затемнением в цвет темы. true - если нарисован.
local function drawBackground(dl, pos, size)
    local m = bgState.media
    if not (cfg.bgimg.enabled and m and #m.frames > 0) then return false end
    local tex = media.frame(m, imgui.GetTime() * num(cfg.bgimg.speed, 1))
    if not tex then return false end
    local rnd = num(cfg.theme.rounding, 12)
    local p0, p1 = pos, vec(pos.x + size.x, pos.y + size.y)
    local iw, ih = math.max(1, m.w), math.max(1, m.h)
    local fit = num(cfg.bgimg.fit, 0)
    local white = U32(V4(1, 1, 1, 1))
    if fit == 0 then
        -- заполнить: сохраняем пропорции, лишнее обрезаем по центру
        local ra, rw = iw / ih, size.x / size.y
        local u0, v0, u1, v1 = 0, 0, 1, 1
        if ra > rw then local k = rw / ra; u0 = (1 - k) / 2; u1 = 1 - u0
        else local k = ra / rw; v0 = (1 - k) / 2; v1 = 1 - v0 end
        drawImage(dl, tex, p0, p1, vec(u0, v0), vec(u1, v1), white, rnd)
    elseif fit == 1 then
        -- вписать: картинка целиком, поля - та же картинка, растянутая и приглушённая
        drawImage(dl, tex, p0, p1, vec(0.25, 0.25), vec(0.75, 0.75), U32(V4(1, 1, 1, 0.35)), rnd)
        local s = math.min(size.x / iw, size.y / ih)
        local w, h = iw * s, ih * s
        local a = vec(pos.x + (size.x - w) / 2, pos.y + (size.y - h) / 2)
        dl:AddImage(tex, a, vec(a.x + w, a.y + h), vec(0, 0), vec(1, 1), white)
    else
        drawImage(dl, tex, p0, p1, vec(0, 0), vec(1, 1), white, rnd)
    end
    -- затемнение в цвет фона темы: текст остаётся читаемым на любой картинке
    dl:AddRectFilled(p0, p1, U32(V4(BGV.x, BGV.y, BGV.z, clamp(num(cfg.bgimg.dim, 0.45), 0, 0.95))), rnd)
    dl:AddRect(p0, p1, U32(V4(ACCENT.x, ACCENT.y, ACCENT.z, LIGHT and 0.55 or 0.40)), rnd)
    return true
end

-- Падающие частицы ---------------------------------------------------------
local particles = {}
local ptState = { list = {}, key = nil }   -- загруженные картинки частиц

local function ptSelected()
    local set, order = {}, {}
    for name in tostring(cfg.particles.images or ''):gmatch('[^|]+') do
        if not set[name] then set[name] = true; order[#order + 1] = name end
    end
    return set, order
end

-- картинки, у которых убирается фон (ПКМ -> Убрать фон)
function ptState.cutSet()
    local set = {}
    for name in tostring(cfg.particles.cutbg or ''):gmatch('[^|]+') do set[name] = true end
    return set
end

local function ptReload()
    local _, order = ptSelected()
    local cut = ptState.cutSet()
    local ids = {}
    for i, name in ipairs(order) do ids[i] = name .. (cut[name] and '#cut' or '') end
    local key = table.concat(ids, '|')
    if key == ptState.key then return end
    local old = {}
    for _, e in ipairs(ptState.list) do old[e.id or e.name] = e end
    local list = {}
    for i, name in ipairs(order) do
        local e = old[ids[i]]
        if e then old[ids[i]] = nil
        else e = { name = name, id = ids[i], media = media.load(DIRS.pt .. '\\' .. name, { maxSide = 128, budget = 128 * 128 * 60, maxFrames = 60, fps = 20, cutBg = cut[name] }) } end
        list[#list + 1] = e
    end
    for _, e in pairs(old) do media.free(e.media) end
    ptState.list, ptState.key = list, key
end

local function newParticle(w, h, fromTop)
    return { x = math.random() * w, y = fromTop and -math.random() * 30 or math.random() * h,
             sp = 0.5 + math.random(), drift = (math.random() - 0.5) * 12,
             sz = 0.6 + math.random() * 0.8, a = 0.4 + math.random() * 0.6, hue = math.random(),
             rot = math.random() * 6.283, rs = (math.random() - 0.5) * 2.4, img = math.random(1000), ph = math.random() * 10 }
end

local function drawParticles(dl, pos, size)
    local P = cfg.particles
    if not P.enabled then return end
    local n = math.floor(clamp(num(P.count, 0), 0, 300))
    while #particles < n do particles[#particles + 1] = newParticle(size.x, size.y, false) end
    while #particles > n do particles[#particles] = nil end
    local dt, time = imgui.GetIO().DeltaTime, imgui.GetTime()
    local r, g, b = hexToRGB(P.color)
    -- картинки, которые уже загрузились
    local imgs = {}
    local mode = num(P.mode, 0)
    local builtin = mode == 2 or mode == 3                 -- Arizona / Hearts (белые, без фона)
    if mode == 1 then
        for _, e in ipairs(ptState.list) do if #e.media.frames > 0 then imgs[#imgs + 1] = e.media end end
    elseif builtin then
        local m = media.builtin(mode == 2 and 'arizona' or 'hearts')
        if #m.frames > 0 then imgs[1] = m end
    end
    local spin = P.spin ~= false
    for i = 1, #particles do
        local p = particles[i]
        p.y = p.y + num(P.speed, 60) * p.sp * dt
        p.x = p.x + p.drift * dt
        p.rot = p.rot + p.rs * dt
        if p.y > size.y + 30 or p.x < -30 or p.x > size.x + 30 then
            p = newParticle(size.x, size.y, true)
            particles[i] = p
        end
        local cr, cg, cb = r, g, b
        if P.rainbow then cr, cg, cb = hsv((p.hue + time * 0.1) % 1, 0.65, 1) end
        local alpha = num(P.alpha, 0.6) * p.a
        if #imgs > 0 then
            local m = imgs[(p.img % #imgs) + 1]
            local tex = media.frame(m, time + p.ph)
            if tex then
                local tint = (P.tint or P.rainbow or builtin) and V4(cr, cg, cb, alpha) or V4(1, 1, 1, alpha)
                local s = num(P.size, 2) * 7 * p.sz
                local hw, hh = s, s * m.h / math.max(1, m.w)
                if hh > s then hw, hh = s * m.w / math.max(1, m.h), s end
                local cx, cy = pos.x + p.x, pos.y + p.y
                if spin then
                    -- встроенные значки не крутятся целиком, а плавно покачиваются
                    local rot = builtin and math.sin(time * 1.6 + p.ph) * 0.35 or p.rot
                    local ca, sa = math.cos(rot), math.sin(rot)
                    local function pt(x, y) return vec(cx + x * ca - y * sa, cy + x * sa + y * ca) end
                    dl:AddImageQuad(tex, pt(-hw, -hh), pt(hw, -hh), pt(hw, hh), pt(-hw, hh),
                        vec(0, 0), vec(1, 0), vec(1, 1), vec(0, 1), U32(tint))
                else
                    dl:AddImage(tex, vec(cx - hw, cy - hh), vec(cx + hw, cy + hh), vec(0, 0), vec(1, 1), U32(tint))
                end
            end
        else
            dl:AddCircleFilled(vec(pos.x + p.x, pos.y + p.y), num(P.size, 2) * p.sz,
                               U32(V4(cr, cg, cb, alpha)), 12)
        end
    end
end

-- Вкладки ----------------------------------------------------------------
-- Виджет бота: сцена с дорогой и грузовиком, статус, скорость, расстояние,
-- прицеп, прогресс поездки и кнопка запуска.
local function botWidget()
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    local h  = 150
    local time = imgui.GetTime()
    local T = bot.tele or {}
    local running = cfg.bot.enabled == true or hitch.active
    local moving = bot.active and (T.kmh or 0) > 1
    local rnd = 12

    -- карточка
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(mixV(CHILD, ACCENT, LIGHT and 0.06 or 0.08, 1)), rnd)
    dl:AddRect(p, vec(p.x + w, p.y + h), U32(V4(ACCENT.x, ACCENT.y, ACCENT.z, running and 0.55 or 0.25)), rnd)

    -- сцена: небо, холмы, дорога с разметкой (едет, когда едет бот)
    local sx0, sy0, sx1, sy1 = p.x + 8, p.y + 8, p.x + 8 + math.min(180, w * 0.38), p.y + h - 8
    anim.roadOff = ((anim.roadOff or 0) + (moving and imgui.GetIO().DeltaTime * (20 + math.min(T.kmh or 0, 120) * 1.2) or 0)) % 1000
    local off = anim.roadOff
    dl:AddRectFilled(vec(sx0, sy0), vec(sx1, sy1), U32(mixV(BGV, ACCENT, LIGHT and 0.10 or 0.14, 1)), 9)
    dl:PushClipRect(vec(sx0, sy0), vec(sx1, sy1), true)
    local roadY = sy1 - 26
    for i = 0, 6 do                                         -- дальние холмы
        local hx = sx0 + ((i * 70 - off * 0.25) % 420) - 60
        dl:AddCircleFilled(vec(hx, roadY + 18), 46, U32(mixV(BGV, ACCENT, LIGHT and 0.22 or 0.26, 1)), 32)
    end
    for i = 0, 8 do                                         -- столбики у дороги
        local px = sx0 + ((i * 48 - off * 0.6) % 432) - 24
        dl:AddRectFilled(vec(px, roadY - 14), vec(px + 2, roadY), U32(mixV(BGV, TEXT, 0.35, 1)))
        dl:AddRectFilled(vec(px - 1, roadY - 15), vec(px + 3, roadY - 12), U32(readable(YELLOW)), 1)
    end
    dl:AddRectFilled(vec(sx0, roadY), vec(sx1, sy1), U32(V4(0.20, 0.21, 0.25, 1)))
    dl:AddRectFilled(vec(sx0, roadY), vec(sx1, roadY + 2), U32(V4(0.45, 0.47, 0.52, 1)))
    for i = 0, 12 do                                        -- разметка
        local dx = sx0 + ((i * 30 - off) % 390) - 30
        dl:AddRectFilled(vec(dx, roadY + 12), vec(dx + 16, roadY + 14), U32(V4(0.95, 0.95, 0.95, 0.85)), 1)
    end
    local s = math.min(2.0, (sx1 - sx0 - 16) / 60)
    local sway = moving and math.sin(time * 14) * 0.5 or 0
    drawTruck(dl, sx0 + (sx1 - sx0 - 58 * s) / 2, roadY + 9 - 32.2 * s + sway, s, moving)
    dl:PopClipRect()

    -- правая часть: заголовок, статус, плитки, прогресс
    local x0, x1 = sx1 + 14, p.x + w - 12
    dl:PushClipRect(vec(x0, p.y), vec(x1, p.y + h), true)
    local stateTxt, stateCol
    if hitch.active then stateTxt, stateCol = 'СЦЕПКА', readable(YELLOW)
    elseif bot.active then stateTxt, stateCol = 'ЕДЕТ', readable(GREEN)
    elseif cfg.bot.enabled == true then stateTxt, stateCol = 'ЖДЁТ', readable(YELLOW)
    else stateTxt, stateCol = 'ВЫКЛ', DIM end
    local pulse = (bot.active or hitch.active) and (0.5 + 0.5 * math.sin(time * 5)) or 0
    local dc = vec(x0 + 5, p.y + 21)
    if pulse > 0 then dl:AddCircleFilled(dc, 5 + pulse * 4, U32(V4(stateCol.x, stateCol.y, stateCol.z, 0.25 * (1 - pulse))), 20) end
    dl:AddCircleFilled(dc, 5, U32(stateCol), 16)
    dl:AddText(vec(x0 + 16, p.y + 12), U32(TEXT), 'Дальнобойщик')
    local cw = imgui.CalcTextSize(stateTxt).x + 16
    dl:AddRectFilled(vec(x1 - cw, p.y + 10), vec(x1, p.y + 32), U32(V4(stateCol.x, stateCol.y, stateCol.z, 0.18)), 11)
    dl:AddText(vec(x1 - cw + 8, p.y + 13), U32(stateCol), stateTxt)
    dl:AddText(vec(x0, p.y + 38), U32(DIM), tostring(bot.status or ''))

    local tiles = {}
    tiles[1] = { 'Скорость', T.inCar and string.format('%d км/ч', math.floor((T.kmh or 0) + 0.5)) or '-', TEXT }
    tiles[2] = { 'До цели', (running and T.dist) and (T.dist >= 1000 and string.format('%.1f км', T.dist / 1000) or string.format('%d м', math.floor(T.dist))) or '-', TEXT }
    if T.hooked then tiles[3] = { 'Прицеп', 'прицеплен', readable(GREEN) }
    elseif hitch.active then tiles[3] = { 'Прицеп', 'цепляю...', readable(YELLOW) }
    elseif T.trailer then tiles[3] = { 'Прицеп', 'отцеплен', TEXT }
    else tiles[3] = { 'Прицеп', 'нет', DIM } end
    local gap = 8
    local tw = (x1 - x0 - gap * 2) / 3
    local ty = p.y + 62
    for i, t in ipairs(tiles) do
        local tx = x0 + (i - 1) * (tw + gap)
        dl:AddRectFilled(vec(tx, ty), vec(tx + tw, ty + 46), U32(V4(SURF.x, SURF.y, SURF.z, LIGHT and 0.55 or 0.65)), 8)
        dl:AddText(vec(tx + 6, ty + 5), U32(DIM), t[1])
        dl:AddText(vec(tx + 6, ty + 24), U32(t[3]), t[2])
    end
    -- прогресс поездки
    local py = p.y + 122
    local prog = 0
    if running and T.dist and bot.dist0 and bot.dist0 > 1 then prog = clamp(1 - T.dist / bot.dist0, 0, 1) end
    prog = approach('bw_prog', prog, 4)
    dl:AddRectFilled(vec(x0, py), vec(x1, py + 6), U32(TRACK), 3)
    if prog > 0.01 then dl:AddRectFilled(vec(x0, py), vec(x0 + (x1 - x0) * prog, py + 6), U32(ACCENT), 3) end
    dl:AddText(vec(x0, py + 9), U32(DIM), bot.arrived and 'Прибыл' or string.format('Поездка: %d%%', math.floor(prog * 100 + 0.5)))
    dl:PopClipRect()
    imgui.Dummy(vec(w, h))

    -- кнопка запуска
    local on = cfg.bot.enabled == true
    local clicked
    if on then clicked = grayButton('Остановить бота##bw_run', vec(-1, 34))
    else clicked = imgui.Button('Запустить бота##bw_run', vec(-1, 34)) end
    if clicked then
        cfg.bot.enabled = not on; ui.botOn[0] = cfg.bot.enabled; saveCfg()
    end
end

local function drawFarmTab()
    section('Бот дальнобойщик')
    botWidget()

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
    if not gps.ok and roadmap.state ~= 'ok' then hint('Маршрут по дорогам GTA недоступен в этой версии игры, используется обычный способ.') end

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

-- Настройки (шестерня) ---------------------------------------------------
local PRESETS = {
    { accent = '#3F99FF', bg = '#12141C' }, { accent = '#9B5CFF', bg = '#15121C' },
    { accent = '#FF4D6A', bg = '#1A1214' }, { accent = '#2ED47A', bg = '#111A15' },
    { accent = '#FFB020', bg = '#1A1610' }, { accent = '#21C7D9', bg = '#10181A' },
}
local PRESETS_LIGHT = {
    { accent = '#2F6BFF', bg = '#F4F6FA' }, { accent = '#7C4DFF', bg = '#F6F3FF' },
    { accent = '#E0405E', bg = '#FFF4F6' }, { accent = '#1E9E5A', bg = '#F1FAF4' },
    { accent = '#E08A00', bg = '#FFF8EC' }, { accent = '#0F9BB0', bg = '#EFF9FB' },
}

local function setTheme(accent, bg)
    cfg.theme.accent, cfg.theme.bg = accent, bg
    setF3(ui.accent, accent); setF3(ui.bg, bg)
    applyTheme(); saveCfg()
end

local function presetSwatches(id, list)
    local dl = imgui.GetWindowDrawList()
    local d = 30
    for i, pr in ipairs(list) do
        if i > 1 then imgui.SameLine() end
        local p = imgui.GetCursorScreenPos()
        if imgui.InvisibleButton('##preset' .. id .. i, vec(d, d)) then setTheme(pr.accent, pr.bg) end
        local hov = imgui.IsItemHovered()
        local ar, ag, ab = hexToRGB(pr.accent)
        local br, bgc, bb = hexToRGB(pr.bg)
        local c = vec(p.x + d / 2, p.y + d / 2)
        local rr = d / 2 - (hov and 1 or 3)
        dl:AddCircleFilled(c, rr, U32(V4(br, bgc, bb, 1)), 32)
        dl:AddCircle(c, rr, U32(V4(TEXT.x, TEXT.y, TEXT.z, 0.25)), 32, 1)
        dl:AddCircleFilled(c, rr * 0.55, U32(V4(ar, ag, ab, 1)), 24)
        if tostring(cfg.theme.accent):upper() == pr.accent and tostring(cfg.theme.bg):upper() == pr.bg then
            dl:AddCircle(c, d / 2 + 1, U32(ACCENT_TEXT), 32, 2)
        end
    end
end

local function resetTheme()
    cfg.theme.accent, cfg.theme.bg, cfg.theme.childAlpha, cfg.theme.rounding = '#3F99FF', '#12141C', 0.80, 12
    local P = cfg.particles
    P.enabled, P.count, P.speed, P.size, P.alpha, P.color, P.rainbow = true, 70, 60, 2.0, 0.60, '#FFFFFF', false
    P.mode, P.tint, P.spin = 0, false, true
    cfg.bgimg.fit, cfg.bgimg.dim, cfg.bgimg.speed = 0, 0.45, 1.0
    setF3(ui.accent, cfg.theme.accent); setF3(ui.bg, cfg.theme.bg); setF3(ui.pColor, P.color)
    ui.childAlpha[0], ui.rounding[0] = 0.80, 12
    ui.pOn[0], ui.pRainbow[0], ui.pCount[0], ui.pSpeed[0], ui.pSize[0], ui.pAlpha[0] = true, false, 70, 60, 2.0, 0.60
    ui.pMode[0], ui.pTint[0], ui.pSpin[0] = 0, false, true
    ui.bgFit[0], ui.bgDim[0], ui.bgSpeed[0] = 0, 0.45, 1.0
    applyTheme(); saveCfg()
end

-- Подобрать цвета темы под картинку фона
local function themeFromImage(m, light)
    if not (m and m.avg) then return end
    local v = m.vivid or m.avg
    local ar, ag, ab = v[1], v[2], v[3]
    local mx = math.max(ar, ag, ab, 0.01)
    ar, ag, ab = ar / mx, ag / mx, ab / mx              -- максимальная яркость акцента
    local a = m.avg
    local br, bgc, bb
    if light then br, bgc, bb = 0.94 + a[1] * 0.05, 0.94 + a[2] * 0.05, 0.94 + a[3] * 0.05
    else br, bgc, bb = 0.05 + a[1] * 0.08, 0.05 + a[2] * 0.08, 0.06 + a[3] * 0.08 end
    setTheme(rgbToHex(ar, ag, ab), rgbToHex(br, bgc, bb))
end

local scan = { bg = {}, pt = {}, t = -10 }
local function rescan(force)
    if force or os.clock() - scan.t > 2 then
        scan.t = os.clock()
        scan.bg, scan.pt = media.scanDir(DIRS.bg), media.scanDir(DIRS.pt)
    end
end

local function mediaStatus(m)
    if not m then return end
    if m.err then imgui.TextColored(readable(RED), 'Ошибка: ' .. tostring(m.err))
    elseif not m.done then imgui.TextColored(readable(YELLOW), string.format('Загрузка... кадров: %d', #m.frames))
    elseif #m.frames > 1 then imgui.TextColored(readable(GREEN), string.format('Анимация: %d кадров, %.1f с, %dx%d', #m.frames, m.total or 0, m.w, m.h))
    else imgui.TextColored(readable(GREEN), string.format('Картинка %dx%d', m.w, m.h)) end
end

local function removeBg()
    cfg.bgimg.enabled, cfg.bgimg.file, ui.bgOn[0] = false, '', false
    saveCfg(); bgReload()
end

local function ptToggle(name)
    local set = ptSelected()
    set[name] = not set[name] or nil
    local out = {}
    for _, g in ipairs(scan.pt) do if set[g.name] then out[#out + 1] = g.name end end
    cfg.particles.images = table.concat(out, '|'); saveCfg(); ptReload()
end

function ptState.cutToggle(name)
    local set = ptState.cutSet()
    set[name] = not set[name] or nil
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    cfg.particles.cutbg = table.concat(out, '|')
    if set[name] and not ptSelected()[name] then ptToggle(name) end
    saveCfg(); ptReload()
end

-- Подтверждение удаления файла (после пункта "Удалить из папки" в меню на ПКМ)
local ctxDel = nil
local function askDelete(kind, f) ctxDel = { kind = kind, name = f.name, disp = f.disp, dir = f.dir } end

local function doDelete(d)
    local path = ((d.kind == 'bg') and DIRS.bg or DIRS.pt) .. '\\' .. d.name
    if d.kind == 'bg' and tostring(cfg.bgimg.file) == d.name then removeBg() end
    if d.kind == 'pt' and ptSelected()[d.name] then ptToggle(d.name) end
    media.delete(path, d.dir, function(ok)
        if ok then msg('Удалено: ' .. d.disp) else msg('Не удалось удалить ' .. d.disp .. ' (файл открыт в другой программе?)') end
        rescan(true)
    end)
end

local function deleteConfirm(kind)
    local d = ctxDel
    if not d or d.kind ~= kind then return end
    imgui.TextColored(readable(RED), 'Удалить "' .. d.disp .. '" из папки насовсем?')
    local bw = (imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x) / 2
    imgui.PushStyleColor(imgui.Col.Button, readable(RED))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, mixV(readable(RED), TEXT, 0.15))
    imgui.PushStyleColor(imgui.Col.ButtonActive, mixV(readable(RED), BGV, 0.2))
    imgui.PushStyleColor(imgui.Col.Text, V4(1, 1, 1, 1))
    local yes = imgui.Button('Да, удалить##del_' .. kind, vec(bw, 30))
    imgui.PopStyleColor(4)
    imgui.SameLine()
    local no = grayButton('Отмена##del_' .. kind, vec(bw, 30))
    if yes then ctxDel = nil; doDelete(d) elseif no then ctxDel = nil end
end

-- Меню на правую кнопку мыши по последнему элементу (как в Windows)
local function contextMenu(id, title, items)
    if imgui.BeginPopupContextItem(id, 1) then
        imgui.TextDisabled(title)
        imgui.Separator()
        for _, it in ipairs(items) do
            if it and imgui.Selectable(it[1] .. id, false) then it[2]() end
        end
        imgui.EndPopup()
    end
end

local function folderButtons(id, dir)
    local hasBg = id == 'bg' and tostring(cfg.bgimg.file or '') ~= ''
    local n = hasBg and 3 or 2
    local bw = (imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x * (n - 1)) / n
    if imgui.Button('Открыть папку##' .. id, vec(bw, 30)) then media.openFolder(dir) end
    imgui.SameLine()
    if grayButton('Обновить список##' .. id, vec(bw, 30)) then rescan(true) end
    if hasBg then
        imgui.SameLine()
        if grayButton('Убрать фон##' .. id, vec(bw, 30)) then removeBg() end
    end
end

local function drawThemeSettings()
    section('Готовые темы')
    imgui.TextDisabled('Тёмные'); presetSwatches('d', PRESETS)
    imgui.TextDisabled('Светлые'); presetSwatches('l', PRESETS_LIGHT)
    section('Цвета')
    if colorRow('##accent', 'Основной цвет', ui.accent) then
        cfg.theme.accent = rgbToHex(ui.accent[0], ui.accent[1], ui.accent[2]); applyTheme(); saveCfg()
    end
    if colorRow('##bg', 'Цвет фона', ui.bg) then
        cfg.theme.bg = rgbToHex(ui.bg[0], ui.bg[1], ui.bg[2]); applyTheme(); saveCfg()
    end
    hint('Можно ставить любые цвета: текст и элементы сами становятся тёмными на светлом фоне и светлыми на тёмном, а слишком бледный основной цвет затемняется для надписей.')
    if sliderFloat('Прозрачность панелей:', '##childAlpha', ui.childAlpha, 0.2, 1.0, '%.2f') then
        cfg.theme.childAlpha = ui.childAlpha[0]; applyTheme(); saveCfg()
    end
    if sliderInt('Скругление:', '##rounding', ui.rounding, 0, 20, '%d px') then
        cfg.theme.rounding = ui.rounding[0]; applyTheme(); saveCfg()
    end
    imgui.Spacing()
    if grayButton('Сбросить оформление', vec(-1, 34)) then resetTheme() end
end

-- Гифка по ссылке или коду встраивания (Tenor, Giphy, прямая ссылка на файл).
-- Качаем через общий поток загрузок; у Tenor/страниц сначала страницу, из неё -
-- прямую ссылку на gif (og:image), потом сам файл в папку фонов или частиц.
local web = { busy = false }
function web.say(kind, text, col) web.kind, web.status, web.col = kind, text, col or DIM end
function web.parse(text)
    text = tostring(text or ''):gsub('\\u002F', '/'):gsub('&amp;', '&')
    local direct = text:match('(https?://[^%s"\'<>]-%.gif)[%s"\'<>?]') or text:match('(https?://[^%s"\'<>]-%.gif)$')
    if direct then return direct, nil end
    for _, ext in ipairs({ 'webp', 'png', 'jpe?g', 'mp4' }) do
        local u = text:match('(https?://[^%s"\'<>]-%.' .. ext .. ')[%s"\'<>?]') or text:match('(https?://[^%s"\'<>]-%.' .. ext .. ')$')
        if u and not u:find('tenor%.com/view') then return u, nil end
    end
    local id = text:match('data%-postid="(%d+)"') or text:match('tenor%.com/[^%s"\'<>]-%-(%d+)') or text:match('tenor%.com/embed/(%d+)')
    if id then return nil, 'https://tenor.com/view/gif-' .. id, 'tenor_' .. id end
    local gid = text:match('giphy%.com/gifs/[^%s"\'<>]-%-?(%w+)$') or text:match('giphy%.com/gifs/[^%s"\'<>]-%-(%w+)[%s"\'<>/?]')
        or text:match('giphy%.com/embed/(%w+)')
    if gid then return 'https://i.giphy.com/media/' .. gid .. '/giphy.gif', nil, 'giphy_' .. gid end
    local page = text:match('(https?://[^%s"\'<>]+)')
    if page then return nil, page end
end
function web.fileName(url, hint)
    local ext = (url:match('%.(%w+)$') or url:match('%.(%w+)%?') or 'gif'):lower()
    local base = hint or (url:match('/([^/%?]+)%.%w+$') or 'web')
    base = base:gsub('[^%w%-_]', '_'):sub(1, 40)
    return base .. '.' .. ext
end
function web.fetchFile(kind, url, hint)
    local dir = (kind == 'pt') and DIRS.pt or DIRS.bg
    local name = web.fileName(url, hint)
    web.say(kind, 'Скачиваю ' .. name .. '...', readable(YELLOW))
    download(url, DIRS.base .. '\\web_dl.tmp', nil, function(data)
        if not data or #data < 64 or data:sub(1, 1) == '<' then
            web.busy = false
            web.say(kind, 'Не удалось скачать файл.', readable(RED)) return
        end
        local f = io.open(dir .. '\\' .. name, 'wb')
        if not f then web.busy = false web.say(kind, 'Не удалось сохранить файл.', readable(RED)) return end
        f:write(data); f:close()
        web.busy, web.done = false, { kind = kind, name = name }
        web.say(kind, string.format('Готово: %s (%d КБ)', name, math.floor(#data / 1024)), readable(GREEN))
    end)
end
function web.start(text, kind)
    local url, page, hint = web.parse(text)
    if not url and not page then web.say(kind, 'Не нашёл ссылку. Вставьте код встраивания Tenor или ссылку на гифку.', readable(RED)) return end
    web.busy = true
    if url then web.fetchFile(kind, url, hint) return end
    web.say(kind, 'Ищу гифку на странице...', readable(YELLOW))
    download(page, DIRS.base .. '\\web_page.tmp', nil, function(html)
        html = tostring(html or ''):gsub('\\u002F', '/')
        local g = html:match('property="og:image" content="([^"]+%.gif)"') or html:match('content="([^"]+%.gif)" property="og:image"')
            or html:match('"contentUrl":"(https://[^"]+%.gif)"') or html:match('(https://media%d?%.tenor%.com/[^"\'%s]+%.gif)')
            or html:match('property="og:image" content="([^"]+)"')
        if not g then web.busy = false web.say(kind, 'На странице не нашлось гифки.', readable(RED)) return end
        web.fetchFile(kind, g, hint)
    end)
end
function web.draw(kind)
    imgui.Spacing()
    imgui.TextDisabled('Гифка по ссылке или коду встраивания (Tenor, Giphy, прямая ссылка):')
    imgui.PushItemWidth(-110)
    imgui.InputText('##web_' .. kind, ui.webUrl, ffi.sizeof(ui.webUrl))
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.Button((web.busy and 'Качаю...' or 'Добавить') .. '##webdl_' .. kind, vec(-1, 0)) and not web.busy then
        web.start(ffi.string(ui.webUrl), kind)
    end
    if web.kind == kind and web.status then
        imgui.PushTextWrapPos(0); imgui.TextColored(web.col, web.status); imgui.PopTextWrapPos()
    end
    -- скачалось - сразу ставим (в потоке меню, а не в потоке загрузки)
    local d = web.done
    if d and d.kind == kind then
        web.done = nil
        rescan(true)
        ui.webUrl[0] = 0
        if kind == 'bg' then
            cfg.bgimg.file, cfg.bgimg.enabled, ui.bgOn[0] = d.name, true, true
            saveCfg(); bgReload()
        else
            cfg.particles.mode, ui.pMode[0] = 1, 1
            if not ptSelected()[d.name] then ptToggle(d.name) else saveCfg(); ptReload() end
        end
    end
end

local function drawBgSettings()
    rescan()
    section('Фон меню')
    if toggle('##bg_on', 'Своя картинка / анимация / видео на фоне', ui.bgOn) then
        cfg.bgimg.enabled = ui.bgOn[0]; saveCfg(); bgReload()
    end
    if not media.ok then hint(media.err or '') end
    imgui.TextDisabled('Файлы из папки moonloader\\config\\lua_afk\\backgrounds:')
    imgui.BeginChild('##bg_files', vec(0, 130), true)
    if #scan.bg == 0 then hint('Папка пуста. Нажмите "Открыть папку" и положите туда картинку, GIF, видео или папку с кадрами.') end
    for i, f in ipairs(scan.bg) do
        local tag = f.dir and '[кадры] ' or (f.video and '[видео] ' or (f.ext == 'gif' and '[gif] ' or ''))
        if imgui.Selectable(tag .. f.disp .. '##bgf' .. i, tostring(cfg.bgimg.file) == f.name) then
            local m = bgState.media
            local same = bgState.file == f.name and m and not m.err and cfg.bgimg.enabled
            cfg.bgimg.file, cfg.bgimg.enabled, ui.bgOn[0] = f.name, true, true
            saveCfg()
            if not same then bgReload() end -- тот же файл ещё раз - не перезагружаем
        end
        local cur = tostring(cfg.bgimg.file) == f.name and cfg.bgimg.enabled
        contextMenu('##bgctx' .. i, f.disp, {
            not cur and { 'Поставить на фон', function()
                cfg.bgimg.file, cfg.bgimg.enabled, ui.bgOn[0] = f.name, true, true
                saveCfg(); bgReload()
            end } or false,
            cur and { 'Убрать фон', removeBg } or false,
            { 'Открыть папку', function() media.openFolder(DIRS.bg) end },
            { 'Удалить из папки', function() askDelete('bg', f) end },
        })
    end
    imgui.EndChild()
    hint('Правая кнопка мыши по файлу - меню: поставить, убрать фон, удалить.')
    deleteConfirm('bg')
    folderButtons('bg', DIRS.bg)
    web.draw('bg')
    mediaStatus(bgState.media)

    section('Подгонка')
    if segmented('bg_fit', ui.bgFit, { 'Заполнить', 'Вписать', 'Растянуть' }) then
        cfg.bgimg.fit = ui.bgFit[0]; saveCfg()
    end
    if sliderFloat('Затемнение фона:', '##bg_dim', ui.bgDim, 0, 0.95, '%.2f') then
        cfg.bgimg.dim = ui.bgDim[0]; saveCfg()
    end
    hint('Картинка всегда сохраняет пропорции и затемняется в цвет темы, поэтому текст читается на любом фоне. На светлой теме фон осветляется.')
    local m = bgState.media
    if m and m.avg then
        local bw = (imgui.GetContentRegionAvail().x - imgui.GetStyle().ItemSpacing.x) / 2
        if imgui.Button('Цвета под фон (тёмная)', vec(bw, 30)) then themeFromImage(m, false) end
        imgui.SameLine()
        if imgui.Button('Цвета под фон (светлая)', vec(bw, 30)) then themeFromImage(m, true) end
    end

    section('Анимация и видео')
    if sliderFloat('Скорость анимации:', '##bg_speed', ui.bgSpeed, 0.1, 3.0, '%.2fx') then
        cfg.bgimg.speed = ui.bgSpeed[0]; saveCfg()
    end
    if sliderInt('Кадров в секунду (видео и папка с кадрами):', '##bg_fps', ui.bgFps, 5, 60, '%d') then
        cfg.bgimg.fps = ui.bgFps[0]; saveCfg()
    end
    if imgui.IsItemDeactivatedAfterEdit() then bgReload() end
    imgui.Text('Качество анимации:')
    if segmented('bg_q', ui.bgQuality, { 'Низкое', 'Среднее', 'Высокое' }) then
        cfg.bgimg.quality = ui.bgQuality[0]; saveCfg(); bgReload()
    end
    if toggle('##bg_flip', 'Перевернуть видео (если оно вверх ногами)', ui.bgFlip) then
        cfg.bgimg.flip = ui.bgFlip[0]; saveCfg(); bgReload()
    end
    hint('Форматы: png, jpg, bmp, gif (анимация), tiff, ico, а также webp/heic/avif, если в Windows стоят их кодеки. Видео: mp4, avi, wmv, mov, mkv и др. - берутся первые несколько секунд (зависит от качества и FPS) и крутятся по кругу. Папка с кадрами 001.png, 002.png... тоже играет как анимация. Высокое качество ест больше памяти игры.')
end

local function drawParticleSettings()
    rescan()
    local P = cfg.particles
    section('Падающие частицы')
    if toggle('##p_on', 'Включить частицы', ui.pOn) then P.enabled = ui.pOn[0]; saveCfg() end
    imgui.Text('Вид частиц:')
    if segmented('p_mode', ui.pMode, { 'Точки', 'Свои картинки', 'Arizona', 'Hearts' }) then P.mode = ui.pMode[0]; saveCfg(); ptReload() end
    if ui.pMode[0] >= 2 then
        hint(ui.pMode[0] == 2 and 'Белый логотип Arizona без фона. Цвет можно поменять ниже.' or 'Белые сердечки без фона. Цвет можно поменять ниже.')
        if toggle('##p_spin2', 'Покачивание', ui.pSpin) then P.spin = ui.pSpin[0]; saveCfg() end
    end
    if ui.pMode[0] == 1 then
        imgui.TextDisabled('Отметьте картинки из moonloader\\config\\lua_afk\\particles:')
        imgui.BeginChild('##pt_files', vec(0, 120), true)
        local set = ptSelected()
        local cut = ptState.cutSet()
        local any = false
        for i, f in ipairs(scan.pt) do
            if not f.dir and not f.video then
                any = true
                if imgui.Selectable((set[f.name] and '[x] ' or '[  ] ') .. f.disp .. (cut[f.name] and '  (без фона)' or '') .. '##ptf' .. i, set[f.name] == true) then
                    ptToggle(f.name)
                end
                contextMenu('##ptctx' .. i, f.disp, {
                    { set[f.name] and 'Убрать из частиц' or 'Добавить в частицы', function() ptToggle(f.name) end },
                    { cut[f.name] and 'Вернуть фон' or 'Убрать фон', function() ptState.cutToggle(f.name) end },
                    { 'Открыть папку', function() media.openFolder(DIRS.pt) end },
                    { 'Удалить из папки', function() askDelete('pt', f) end },
                })
            end
        end
        if not any then hint('Папка пуста. Положите туда png/webp/gif (снежинки, сердечки, листья...).') end
        if any then hint('ПКМ по картинке - Убрать фон: если у картинки есть фон, он вырежется.') end
        imgui.EndChild()
        deleteConfirm('pt')
        folderButtons('pt', DIRS.pt)
        web.draw('pt')
        for _, e in ipairs(ptState.list) do
            if e.media.err then imgui.TextColored(readable(RED), u8(e.name) .. ': ' .. tostring(e.media.err)) end
        end
        if toggle('##p_spin', 'Вращение', ui.pSpin) then P.spin = ui.pSpin[0]; saveCfg() end
        if toggle('##p_tint', 'Красить картинки в цвет частиц', ui.pTint) then P.tint = ui.pTint[0]; saveCfg() end
    end
    if toggle('##p_rainbow', 'Радужные частицы', ui.pRainbow) then P.rainbow = ui.pRainbow[0]; saveCfg() end
    if not ui.pRainbow[0] and colorRow('##p_color', 'Цвет частиц', ui.pColor) then
        P.color = rgbToHex(ui.pColor[0], ui.pColor[1], ui.pColor[2]); saveCfg()
    end
    if sliderInt('Количество:', '##p_count', ui.pCount, 0, 300, '%d шт.') then P.count = ui.pCount[0]; saveCfg() end
    if sliderInt('Скорость:', '##p_speed', ui.pSpeed, 5, 400, '%d') then P.speed = ui.pSpeed[0]; saveCfg() end
    if sliderFloat('Размер:', '##p_size', ui.pSize, 0.5, 6.0, '%.1f') then P.size = ui.pSize[0]; saveCfg() end
    if sliderFloat('Яркость:', '##p_alpha', ui.pAlpha, 0.05, 1.0, '%.2f') then P.alpha = ui.pAlpha[0]; saveCfg() end
end

local function drawOtherSettings()
    section('Обновления')
    if toggle('##auto_upd', 'Автоматически проверять обновления', ui.autoUpd) then
        cfg.update.auto = ui.autoUpd[0]; saveCfg()
    end
    if imgui.Button('Проверить обновления', vec(-1, 34)) then checkUpdates(true) end
    section('Файлы')
    hint('Свои картинки, видео и частицы лежат в moonloader\\config\\lua_afk.')
    if grayButton('Открыть папку lua_afk', vec(-1, 30)) then media.openFolder(DIRS.base) end
end

local function drawSettingsTab()
    segmented('set_tabs', ui.setTab, { 'Тема', 'Фон', 'Частицы', 'Прочее' })
    local t = ui.setTab[0]
    if t == 0 then drawThemeSettings()
    elseif t == 1 then drawBgSettings()
    elseif t == 2 then drawParticleSettings()
    else drawOtherSettings() end
end

local function drawInfoTab()
    section('Скрипт')
    imgui.Text('Версия:'); imgui.SameLine(110); imgui.TextColored(readable(GREEN), SCRIPT_VERSION)
    imgui.Text('Автор:');  imgui.SameLine(110); imgui.TextDisabled('denismaslov769-lab')
    section('Команды')
    imgui.Text('/lafk');    imgui.SameLine(110); imgui.TextDisabled('открыть / закрыть меню')
    imgui.Text('/lafkupd'); imgui.SameLine(110); imgui.TextDisabled('проверить обновления')
    imgui.Text('/ltruck');  imgui.SameLine(110); imgui.TextDisabled('вкл / выкл бота дальнобойщика')
    imgui.Text('/pricep');  imgui.SameLine(110); imgui.TextDisabled('заспавнить прицеп (del - удалить)')
    imgui.Text('/lhitch');  imgui.SameLine(110); imgui.TextDisabled('бот цепляет прицеп / отмена')
    hint('Оформление, свой фон, частицы и обновления - в настройках (шестерня слева внизу).')
end

local TABS = {
    { name = 'Авто фарм',  icon = iconTruck, draw = drawFarmTab  },
    { name = 'Информация', icon = iconInfo,  draw = drawInfoTab  },
}
local SETTINGS_TAB = { name = 'Настройки', icon = iconGear, draw = drawSettingsTab }

-- Ошибка внутри вкладки ловится и показывается текстом: Begin/End всегда парные,
-- поэтому окно не ломается и игра не вылетает.
local function safe(where, fn)
    local ok, err = pcall(fn)
    if not ok then
        err = tostring(err)
        if menu.err ~= err then menu.err = err; log('[menu] ошибка (' .. where .. '): ' .. err) end
        imgui.TextColored(readable(RED), 'Ошибка: ' .. err)
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
        if not menu.mediaInit then
            -- свои файлы грузим при первом открытии меню
            menu.mediaInit = true
            pcall(bgReload); pcall(ptReload)
        end
        local okPump, ePump = pcall(media.pump, 0.008)
        if not okPump then log('[media] ' .. tostring(ePump)) end

        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
        imgui.SetNextWindowSize(vec(720, 500), imgui.Cond.Always)
        imgui.Begin('##lua_afk_menu', menu.window,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)

        step('окно')
        local hasBg = false
        safe('фон', function()
            hasBg = drawBackground(imgui.GetWindowDrawList(), imgui.GetWindowPos(), imgui.GetWindowSize())
        end)
        safe('частицы', function()
            drawParticles(imgui.GetWindowDrawList(), imgui.GetWindowPos(), imgui.GetWindowSize())
        end)
        -- на картинке панели становятся плотнее, чтобы текст не терялся
        local pushed = 0
        if hasBg then
            imgui.PushStyleColor(imgui.Col.ChildBg, V4(CHILD.x, CHILD.y, CHILD.z, math.max(0.62, num(cfg.theme.childAlpha, 0.8))))
            pushed = 1
        end

        step('панель')
        imgui.BeginChild('##sidebar', vec(190, 0), true)
        safe('меню слева', function()
            centerText('lua_afk', ACCENT_TEXT)
            centerText('v' .. SCRIPT_VERSION, DIM)
            imgui.Spacing(); imgui.Separator(); imgui.Spacing()
            for i, tab in ipairs(TABS) do
                if sidebarButton('##tab' .. i, tab.name, tab.icon, menu.tab == i) then menu.tab = i end
            end
            local pad = imgui.GetStyle().WindowPadding.y
            imgui.SetCursorPosY(imgui.GetWindowHeight() - 40 * 2 - 4 - pad)
            if sidebarButton('##settings', 'Настройки', iconGear, menu.tab == 'settings') then menu.tab = 'settings' end
            imgui.SetCursorPosY(imgui.GetWindowHeight() - 40 - pad)
            if sidebarButton('##close', 'Закрыть', iconClose, false) then menu.window[0] = false end
        end)
        imgui.EndChild()

        imgui.SameLine()

        imgui.BeginChild('##content', vec(0, 0), true)
        local tab = (menu.tab == 'settings') and SETTINGS_TAB or (TABS[menu.tab] or TABS[1])
        step('вкладка ' .. tostring(menu.tab))
        safe(tab.name, function()
            imgui.TextColored(ACCENT_TEXT, tab.name)
            tab.draw()
        end)
        imgui.EndChild()
        if pushed > 0 then imgui.PopStyleColor(pushed) end

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
                imgui.SameLine(); imgui.TextColored(readable(GREEN), tostring(upd.latest))
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
                imgui.TextColored(readable(RED), tostring(upd.error))
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
    lua_thread.create(botThread)
    lua_thread.create(roadmap.load)
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

