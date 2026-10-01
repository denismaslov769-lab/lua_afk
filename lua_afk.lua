-- lua_afk.lua
-- Скрипт для SA-MP (MoonLoader): меню, авто спавн, бот дальнобойщик, автообновление
-- Требуется: MoonLoader, SAMPFUNCS, mimgui. Для чекпоинтов бота: SAMP.Lua (lib/samp/events)
-- @changelog: Бот: скорость без лимита (ползунок до упора), плавный газ и торможение по ситуации вместо резких остановок.

script_name('lua_afk')
script_author('denismaslov769-lab')
script_version('1.3.0')

local imgui    = require('mimgui')
local encoding = require('encoding')
local inicfg   = require('inicfg')
local ffi      = require('ffi')
local dlstatus = require('moonloader').download_status
local hasSampev, sampev = pcall(require, 'lib.samp.events')

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local SCRIPT_VERSION = '1.3.0'
local SCRIPT_URL = 'https://raw.githubusercontent.com/denismaslov769-lab/lua_afk/main/lua_afk.lua'
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
        speed    = 25,
        style    = 0,       -- 0 = объезжать машины, 1 = тормозить перед машинами
        radius   = 12,      -- м
        takeover = true,    -- W / S забирают управление
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

--==============================================================
-- Утилиты
--==============================================================
-- Текст в файле в UTF-8, чат игры в CP1251
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

--==============================================================
-- Загрузка файлов
-- Строго одна загрузка за раз. Файл читается не в колбэке загрузчика,
-- а в отдельном потоке после завершения - так MoonLoader не выбрасывает
-- исключений ("device or resource busy"), которые ломают игру.
-- JSON не используется вообще.
--==============================================================
local TMP_DIR = getWorkingDirectory() .. '\\config'
local net = { busy = false }

local function download(url, path, onProgress, onDone)
    if net.busy then return false end
    net.busy = true
    if not doesDirectoryExist(TMP_DIR) then createDirectory(TMP_DIR) end
    os.remove(path)
    local finished = false
    downloadUrlToFile(url, path, function(id, status, p1, p2)
        if status == dlstatus.STATUS_DOWNLOADINGDATA then
            if onProgress and p2 and p2 > 0 then onProgress(p1 / p2) end
        elseif status == dlstatus.STATUS_ENDDOWNLOADDATA then
            finished = true
        end
    end)
    lua_thread.create(function()
        local t = os.time()
        while not finished and os.time() - t < 30 do wait(50) end
        wait(300)
        local data = readFile(path)
        os.remove(path)
        net.busy = false
        if data == '' then data = nil end
        onDone(data)
    end)
    return true
end

--==============================================================
-- Автообновление
--==============================================================
local TMP_CHECK  = TMP_DIR .. '\\lua_afk_check.tmp'
local TMP_SCRIPT = TMP_DIR .. '\\lua_afk_update.tmp'

local upd = {
    window    = imgui.new.bool(false),
    state     = 'idle',   -- idle | prompt | downloading | installing | error
    latest    = nil,
    changelog = nil,
    progress  = 0.0,
    shown     = 0.0,
    newCode   = nil,
    error     = nil,
    dismissed = nil,
}

local function isScript(data)
    return data and data:find("script_version%('") and data:find('function main', 1, true)
end

-- manual   = ручная проверка (/lafkupd), пишет всё в чат
-- periodic = фоновая проверка, не показывает окно для уже отменённой версии
local function checkUpdates(manual, periodic)
    if not manual and not cfg.update.auto then return end
    if upd.state == 'prompt' or upd.state == 'downloading' or upd.state == 'installing' then return end
    if manual then msg('Проверка обновлений...') end

    local started = download(SCRIPT_URL .. '?t=' .. os.time(), TMP_CHECK, nil, function(data)
        if not isScript(data) then
            log('[update] не удалось получить скрипт с GitHub')
            if manual then msg('Не удалось связаться с GitHub. Попробуйте позже.') end
            return
        end
        local v = data:match("script_version%('([^']+)'%)")
        log('[update] на GitHub ' .. tostring(v) .. ', установлена ' .. SCRIPT_VERSION)
        if isNewer(v, SCRIPT_VERSION) then
            if periodic and upd.dismissed == v then return end
            upd.latest    = v
            upd.changelog = data:match('%-%- @changelog: ([^\r\n]+)')
            upd.state     = 'prompt'
            upd.window[0] = true
            msg('Доступно обновление ' .. v .. '!')
        elseif manual then
            msg('У вас последняя версия (' .. SCRIPT_VERSION .. ').')
        end
    end)
    if not started and manual then msg('Загрузка уже идёт, подождите пару секунд.') end
end

local function startDownload()
    upd.state, upd.progress, upd.shown, upd.error, upd.newCode = 'downloading', 0.0, 0.0, nil, nil
    local started = download(SCRIPT_URL .. '?t=' .. os.time(), TMP_SCRIPT,
        function(f) upd.progress = math.min(f, 0.99) end,
        function(data)
            if isScript(data) then
                upd.newCode, upd.progress, upd.state = data, 1.0, 'installing'
            else
                upd.state, upd.error = 'error', 'Не удалось скачать обновление.'
            end
        end)
    if not started then
        upd.state, upd.error = 'error', 'Идёт другая загрузка, нажмите Повторить.'
    end
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
    thisScript():reload()
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
            -- персонаж не был заспавнен 10+ секунд: это вход / перезаход на сервер
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
-- Тема mimgui
--==============================================================
local V4 = imgui.ImVec4
local function vec(x, y) return imgui.ImVec2(x, y) end
local U32 = imgui.ColorConvertFloat4ToU32

local WHITE = V4(1, 1, 1, 1)
local GRAY  = V4(0.60, 0.63, 0.70, 1.00)
local GREEN = V4(0.35, 0.85, 0.45, 1.00)
local RED   = V4(1.00, 0.40, 0.40, 1.00)
local ACCENT = V4(0.25, 0.60, 1.00, 1.00)

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
    local rnd = tonumber(cfg.theme.rounding) or 12

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
    style.WindowTitleAlign  = vec(0.5, 0.5)

    c[col.WindowBg]         = V4(br, bg, bb, 0.97)
    c[col.ChildBg]          = lift(0.03, tonumber(cfg.theme.childAlpha) or 0.8)
    c[col.PopupBg]          = lift(0.02, 0.98)
    c[col.Border]           = V4(ar, ag, ab, 0.40)
    c[col.Separator]        = V4(ar, ag, ab, 0.25)
    c[col.TitleBg]          = lift(0.03)
    c[col.TitleBgActive]    = lift(0.06)
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
    c[col.TextSelectedBg]   = V4(ar, ag, ab, 0.35)
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil

    -- Шрифт с кириллицей. Если не загрузится - стандартный, чтобы у меню всегда был шрифт.
    local dir = getFolderPath(0x14)
    local file
    for _, name in ipairs({ 'trebucbd.ttf', 'segoeui.ttf', 'arial.ttf', 'tahoma.ttf' }) do
        if doesFileExist(dir .. '\\' .. name) then file = dir .. '\\' .. name break end
    end
    local ranges = io.Fonts:GetGlyphRangesCyrillic()
    io.Fonts:Clear()
    local font = nil
    if file then font = io.Fonts:AddFontFromFileTTF(file, 16.0, nil, ranges) end
    if font == nil then io.Fonts:AddFontDefault() end

    applyTheme()
end)

--==============================================================
-- Виджеты (рисуются кодом, без icon-шрифтов - никаких "???")
--==============================================================
local anim = {}
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpV4(a, b, t) return V4(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t), lerp(a.w, b.w, t)) end
local function approach(id, target, speed)
    local v = anim[id] or target
    v = v + (target - v) * math.min(1, imgui.GetIO().DeltaTime * (speed or 12))
    anim[id] = v
    return v
end

local function centerText(text, color)
    local w = imgui.CalcTextSize(text).x
    imgui.SetCursorPosX((imgui.GetWindowWidth() - w) / 2)
    imgui.TextColored(color or WHITE, text)
end

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

local function grayButton(label, size)
    imgui.PushStyleColor(imgui.Col.Button,        V4(0.22, 0.24, 0.30, 1.00))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, V4(0.30, 0.32, 0.40, 1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  V4(0.18, 0.20, 0.25, 1.00))
    local pressed = imgui.Button(label, size)
    imgui.PopStyleColor(3)
    return pressed
end

-- Переключатель с анимацией
local function toggle(id, label, ptr)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local h  = imgui.GetFrameHeight()
    local w  = h * 1.9
    local clicked = imgui.InvisibleButton(id, vec(w, h))
    if clicked then ptr[0] = not ptr[0] end
    local hovered = imgui.IsItemHovered()
    local t = approach(id, ptr[0] and 1 or 0)
    local bg = lerpV4(V4(0.22, 0.24, 0.30, 1), ACCENT, t)
    if hovered then bg = lerpV4(bg, WHITE, 0.08) end
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(bg), h / 2)
    dl:AddCircleFilled(vec(p.x + h / 2 + t * (w - h), p.y + h / 2), h / 2 - 3, U32(WHITE), 24)
    imgui.SameLine()
    imgui.AlignTextToFramePadding()
    imgui.Text(label)
    return clicked
end

-- Сегментированный выбор
local function segmented(id, ptr, items)
    local sp = imgui.GetStyle().ItemSpacing.x
    local w  = (imgui.GetContentRegionAvail().x - sp * (#items - 1)) / #items
    local changed = false
    for i, name in ipairs(items) do
        if i > 1 then imgui.SameLine() end
        local active = ptr[0] == i - 1
        if not active then
            imgui.PushStyleColor(imgui.Col.Button,        V4(0.16, 0.18, 0.24, 1.00))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, V4(0.22, 0.25, 0.33, 1.00))
            imgui.PushStyleColor(imgui.Col.ButtonActive,  V4(0.18, 0.20, 0.27, 1.00))
        end
        if imgui.Button(name .. '##' .. id .. i, vec(w, 32)) then ptr[0] = i - 1; changed = true end
        if not active then imgui.PopStyleColor(3) end
    end
    return changed
end

--==============================================================
-- Иконки
--==============================================================
local function iconPerson(dl, c, col)
    dl:AddCircleFilled(vec(c.x, c.y - 4.5), 3.8, col, 20)
    dl:AddRectFilled(vec(c.x - 6.5, c.y + 1), vec(c.x + 6.5, c.y + 9), col, 4)
end

-- Фура: x, y - левый верхний угол, s - масштаб (примерно 58s x 26s)
local function drawTruck(dl, x, y, s, body, cab)
    local function R(a, b, c2, d, col, r)
        dl:AddRectFilled(vec(x + a * s, y + b * s), vec(x + c2 * s, y + d * s), col, (r or 0) * s)
    end
    local dark  = U32(V4(0.05, 0.06, 0.08, 1))
    local wheel = U32(V4(0.16, 0.17, 0.20, 1))
    local hub   = U32(V4(0.70, 0.72, 0.78, 1))
    R(0, 0, 38, 18, body, 2)                               -- прицеп
    R(2, 2, 36, 4, U32(V4(1, 1, 1, 0.12)), 1)              -- блик
    R(38, 14, 41, 19, dark)                                -- сцепка
    R(41, 3, 54, 19, cab, 2.5)                             -- кабина
    R(54, 10, 58, 19, cab, 1.5)                            -- капот
    R(47, 5, 53, 11, U32(V4(0.55, 0.80, 1.00, 0.85)), 1)   -- окно
    R(56.5, 12, 58, 14, U32(V4(1.00, 0.85, 0.35, 1)))      -- фара
    R(0, 18.5, 58, 21, dark, 1)                            -- рама
    for _, wx in ipairs({ 7, 15, 49 }) do
        dl:AddCircleFilled(vec(x + wx * s, y + 22 * s), 3.6 * s, wheel, 16)
        dl:AddCircleFilled(vec(x + wx * s, y + 22 * s), 1.4 * s, hub, 12)
    end
end

local function iconTruck(dl, c, col) drawTruck(dl, c.x - 9.3, c.y - 6, 0.32, col, col) end

local function iconPalette(dl, c, col)
    dl:AddCircle(c, 8, col, 24, 1.8)
    dl:AddCircleFilled(vec(c.x - 3.2, c.y - 2.5), 1.7, col, 12)
    dl:AddCircleFilled(vec(c.x + 3.2, c.y - 2.5), 1.7, col, 12)
    dl:AddCircleFilled(vec(c.x, c.y + 3.5), 1.7, col, 12)
end

local function iconInfo(dl, c, col)
    dl:AddCircle(c, 8, col, 24, 1.8)
    dl:AddCircleFilled(vec(c.x, c.y - 3.8), 1.4, col, 12)
    dl:AddRectFilled(vec(c.x - 1, c.y - 1), vec(c.x + 1, c.y + 4.5), col)
end

local function iconClose(dl, c, col)
    dl:AddLine(vec(c.x - 5, c.y - 5), vec(c.x + 5, c.y + 5), col, 2)
    dl:AddLine(vec(c.x + 5, c.y - 5), vec(c.x - 5, c.y + 5), col, 2)
end

-- Вкладка в боковой панели
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
    if active then
        dl:AddRectFilled(vec(p.x, p.y + 8), vec(p.x + 4, p.y + h - 8), U32(ACCENT), 2)
    end
    local col = U32(lerpV4(GRAY, WHITE, t))
    icon(dl, vec(p.x + 22, p.y + h / 2), col)
    dl:AddText(vec(p.x + 42, p.y + (h - imgui.GetTextLineHeight()) / 2), col, name)
    return clicked
end

--==============================================================
-- Падающие частицы
--==============================================================
local particles = {}

local function newParticle(w, h, fromTop)
    return {
        x = math.random() * w,
        y = fromTop and -math.random() * 20 or math.random() * h,
        sp = 0.5 + math.random(), sz = 0.6 + math.random() * 0.8,
        a = 0.4 + math.random() * 0.6, drift = (math.random() - 0.5) * 20, hue = math.random(),
    }
end

local function drawParticles(dl, pos, size)
    local P = cfg.particles
    if not P.enabled then return end
    local n = math.floor(tonumber(P.count) or 0)
    while #particles < n do particles[#particles + 1] = newParticle(size.x, size.y, false) end
    while #particles > n do particles[#particles] = nil end
    local dt, time = imgui.GetIO().DeltaTime, imgui.GetTime()
    local r, g, b = hexToRGB(P.color)
    for i = 1, #particles do
        local p = particles[i]
        p.y = p.y + P.speed * p.sp * dt
        p.x = p.x + p.drift * dt
        if p.y > size.y + 6 or p.x < -6 or p.x > size.x + 6 then
            p = newParticle(size.x, size.y, true)
            particles[i] = p
        end
        local cr, cg, cb = r, g, b
        if P.rainbow then cr, cg, cb = hsv((p.hue + time * 0.1) % 1, 0.65, 1) end
        dl:AddCircleFilled(vec(pos.x + p.x, pos.y + p.y), P.size * p.sz, U32(V4(cr, cg, cb, P.alpha * p.a)), 12)
    end
end

--==============================================================
-- Авто спавн
--==============================================================
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

local function autoSpawnThread()
    local lastSpawn, lastDialogId, lastDialogTime = 0, -1, 0
    while true do
        wait(200)
        if cfg.spawn.enabled then
            if tonumber(cfg.spawn.mode) == 0 then
                local connected = sampGetPlayerIdByCharHandle(PLAYER_PED)
                if connected and not sampIsLocalPlayerSpawned() and not sampIsDialogActive()
                   and os.clock() - lastSpawn > 3 then
                    wait(tonumber(cfg.spawn.delay) or 1000)
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
                        wait(tonumber(cfg.spawn.delay) or 1000)
                        if sampIsDialogActive() and sampGetCurrentDialogId() == id then
                            sampSetCurrentDialogListItem((tonumber(cfg.spawn.item) or 1) - 1)
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
-- Бот дальнобойщик (для личного сервера, на Arizona RP отключён)
--==============================================================
local bot = {
    status = 'Выключен', driving = false, cp = nil,
    wx = nil, wy = nil, nextPlan = 0,             -- текущая точка маршрута
    tx = nil, ty = nil,                           -- цель, к которой едем
    best = nil, bestTime = 0, gaveUp = false,     -- защита от кружения
    pauseUntil = 0, arrived = false,
    stuckSince = nil, reverseUntil = 0, reverseSteer = 0,
}

if hasSampev then
    function sampev.onSetCheckpoint(pos)             bot.cp = { pos.x, pos.y, pos.z } end
    function sampev.onDisableCheckpoint()            bot.cp = nil end
    function sampev.onSetRaceCheckpoint(t, pos)      bot.cp = { pos.x, pos.y, pos.z } end
    function sampev.onDisableRaceCheckpoint()        bot.cp = nil end
end

local function isArizona()
    local ok, name = pcall(sampGetCurrentServerName)
    if not ok or type(name) ~= 'string' then return false end
    local n = ruLower(u8(name))
    return n:find('arizona', 1, true) ~= nil or n:find('аризона', 1, true) ~= nil
end

local function botTarget()
    local src = tonumber(cfg.bot.source) or 0
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

--------------------------------------------------------------
-- Собственный автопилот. ИИ GTA не используется вообще, поэтому
-- светофоров для бота не существует. Скрипт сам жмёт газ / тормоз / руль.
--------------------------------------------------------------
local KEY_STEER, KEY_GAS, KEY_BRAKE, KEY_HANDBRAKE = 0, 16, 14, 6

-- gas / brake: true/false или сила нажатия 0..1 (педали аналоговые)
local function pedal(v)
    if v == true then return 255 elseif not v then return 0 end
    return math.floor(math.max(0, math.min(1, v)) * 255)
end

local function keys(steer, gas, brake, handbrake)
    setGameKeyState(KEY_STEER, math.floor(math.max(-128, math.min(128, steer * 128))))
    setGameKeyState(KEY_GAS, pedal(gas))
    setGameKeyState(KEY_BRAKE, pedal(brake))
    setGameKeyState(KEY_HANDBRAKE, pedal(handbrake))
end

local SPEED_NO_LIMIT = 61 -- ползунок скорости в крайнем правом положении

local function botStop()
    if bot.driving then
        keys(0, false, false, false)
        bot.driving, bot.wx, bot.wy, bot.vt = false, nil, nil, nil
    end
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

-- Прямая видимость между точками (здания и объекты), без учёта машин
local function clearLine(x1, y1, z1, x2, y2, z2)
    local hit = processLineOfSight(x1, y1, z1, x2, y2, z2, true, false, false, true, false, false, false, false)
    return not hit
end

-- Луч вперёд от бампера: расстояние до препятствия или nil. Подъёмы дороги не считаются.
local function ray(car, side, len)
    local minX, _, _, maxX, maxY = getModelDimensions(getCarModel(car))
    local half = ((maxX or 1.2) - 0.2) * side
    local front = (maxY or 3) + 0.3
    local x1, y1, z1 = getOffsetFromCarInWorldCoords(car, half, front, 0.3)
    local x2, y2, z2 = getOffsetFromCarInWorldCoords(car, half * 1.6, front + len, 0.3)
    local hit, cp = processLineOfSight(x1, y1, z1, x2, y2, z2, true, true, true, true, false, false, false, false)
    if not hit or not cp or not cp.pos then return nil end
    if cp.normal and cp.normal[3] and cp.normal[3] > 0.7 then return nil end
    return getDistanceBetweenCoords3d(x1, y1, z1, cp.pos[1], cp.pos[2], cp.pos[3])
end

-- Выбор следующей точки: дорожные узлы впереди (прямо и под углами),
-- до которых есть прямой проезд, ближе всего к цели
local ANGLES = { 0, 20, -20, 45, -45, 75, -75 }
local function planWaypoint(car, tx, ty, tz)
    local cx, cy, cz = getCarCoordinates(car)
    local fx, fy, rx, ry = carBasis(car)
    local R = math.max(12, math.min(30, 10 + getCarSpeed(car) * 0.8))
    local bestScore, bx, by
    for _, a in ipairs(ANGLES) do
        local ar = math.rad(a)
        local dx = fx * math.cos(ar) + rx * math.sin(ar)
        local dy = fy * math.cos(ar) + ry * math.sin(ar)
        local sx, sy = cx + dx * R, cy + dy * R
        local nx, ny, nz = getClosestCarNode(sx, sy, cz)
        if nx and (nx ~= 0 or ny ~= 0) and getDistanceBetweenCoords2d(nx, ny, sx, sy) < R * 0.6 then
            local _, ly = toLocal(car, nx, ny)
            if ly > 4 and clearLine(cx, cy, cz + 0.6, nx, ny, (nz or cz) + 0.6) then
                local score = getDistanceBetweenCoords2d(nx, ny, tx, ty) + math.abs(a) * 0.35
                if not bestScore or score < bestScore then bestScore, bx, by = score, nx, ny end
            end
        end
    end
    -- Цель рядом и к ней прямой проезд - едем прямо к ней
    local dist = getDistanceBetweenCoords2d(cx, cy, tx, ty)
    if dist < 45 and clearLine(cx, cy, cz + 0.6, tx, ty, tz + 0.6) then return tx, ty end
    return bx, by
end

local function botControl(car, tx, ty, tz, dist)
    local now = os.clock()
    local careful = tonumber(cfg.bot.style) == 1
    local vmax = tonumber(cfg.bot.speed) or 25
    local speed = getCarSpeed(car)

    -- Задний ход после застревания
    if now < bot.reverseUntil then
        keys(bot.reverseSteer, false, true, false)
        bot.vt = 0
        return
    end

    if now >= bot.nextPlan or not bot.wx then
        bot.nextPlan = now + 0.2
        local wx, wy = planWaypoint(car, tx, ty, tz)
        if wx then bot.wx, bot.wy = wx, wy end
    end
    if not bot.wx then
        -- Дороги рядом не нашли: аккуратно катимся вперёд
        keys(0, speed < 4, false, false)
        return
    end

    local lx, ly = toLocal(car, bot.wx, bot.wy)
    local ang = math.atan2(lx, ly)                       -- > 0 вправо
    local steer = math.max(-1, math.min(1, ang / 0.5))

    -- Желаемая скорость = минимум из нескольких безопасных скоростей.
    -- decel - комфортное замедление, aLat - допустимое боковое ускорение в повороте.
    local decel = careful and 5 or 7
    local aLat  = careful and 6 or 8
    local v = (vmax >= SPEED_NO_LIMIT) and 999 or vmax

    -- Поворот: скорость по радиусу дуги до точки маршрута (на прямой ограничения нет)
    local wd = math.max(5, math.sqrt(lx * lx + ly * ly))
    local s = math.abs(math.sin(math.max(-1.5, math.min(1.5, ang))))
    if s > 0.02 then v = math.min(v, math.max(6, math.sqrt(aLat * wd / (2 * s)))) end

    -- Цель: плавно подъезжаем и останавливаемся в радиусе прибытия
    local left = dist - (tonumber(cfg.bot.radius) or 12)
    v = math.min(v, math.sqrt(2 * decel * math.max(0, left)) + 2)

    -- Препятствия. Луч длиной с тормозной путь. Центр тормозит по-настоящему,
    -- боковые лучи только немного сбавляют и подруливают.
    local stopGap = careful and 5 or 3.5
    local len = math.min(60, 6 + speed * speed / (2 * decel) + speed * 0.3)
    local l, c, r = ray(car, -1, len), ray(car, 0, len), ray(car, 1, len)
    local danger = false
    if c then
        v = math.min(v, math.sqrt(2 * decel * math.max(0, c - stopGap)))
        danger = c < stopGap + 2
    end
    local side = math.min(l or 999, r or 999)
    if side < 999 then v = math.min(v, math.sqrt(2 * decel * math.max(0, side - 1.5)) + 6) end
    if l and not r then steer = steer + 0.5 elseif r and not l then steer = steer - 0.5 end
    steer = math.max(-1, math.min(1, steer))

    -- Сглаживание: желаемая скорость меняется плавно, кроме реальной опасности прямо по курсу
    local dt = math.min(0.2, now - (bot.lastCtl or now))
    bot.lastCtl = now
    bot.vt = bot.vt or speed
    if danger then
        bot.vt = v
    elseif v < bot.vt then
        bot.vt = bot.vt + (v - bot.vt) * math.min(1, dt * 4)
    else
        bot.vt = bot.vt + (v - bot.vt) * math.min(1, dt * 1.5)
    end

    -- Педали: газ пропорционально нехватке скорости, небольшое превышение - просто отпускаем газ,
    -- тормоз только при заметном превышении и тоже пропорционально
    local diff = bot.vt - speed
    local gas, brake = 0, 0
    if diff > 0.3 then
        gas = math.max(0.25, math.min(1, diff / 6))
    elseif diff < -3 then
        brake = math.max(0.15, math.min(1, (-diff - 3) / 8))
    end
    keys(steer, gas, brake, false)

    -- Застряли: жмём газ, но не едем 2.5 секунды - сдаём назад
    if gas > 0 and speed < 0.5 then
        bot.stuckSince = bot.stuckSince or now
        if now - bot.stuckSince > 2.5 then
            bot.reverseUntil, bot.reverseSteer, bot.stuckSince = now + 1.5, -steer, nil
        end
    else
        bot.stuckSince = nil
    end
end

local function botThread()
    while true do
        wait(bot.driving and 0 or 100)
        if not cfg.bot.enabled then
            botStop(); bot.status = 'Выключен'
        elseif isArizona() then
            botStop(); bot.status = 'Недоступно на Arizona RP'
        elseif not isCharInAnyCar(PLAYER_PED) then
            botStop(); bot.status = 'Сядьте в транспорт'
        else
            local car = storeCarCharIsInNoSave(PLAYER_PED)
            if getDriverOfCar(car) ~= PLAYER_PED then
                botStop(); bot.status = 'Сядьте за руль'
            else
                local x, y, z, name = botTarget()
                if not x then
                    botStop(); bot.status = 'Нет метки'; bot.arrived = false
                else
                    local px, py = getCharCoordinates(PLAYER_PED)
                    local dist = getDistanceBetweenCoords2d(px, py, x, y)
                    local typing = sampIsChatInputActive() or sampIsDialogActive() or isSampfuncsConsoleActive()
                    local manual = cfg.bot.takeover and not typing and (isKeyDown(0x57) or isKeyDown(0x53))

                    -- новая цель - сбрасываем прогресс
                    if not bot.tx or getDistanceBetweenCoords2d(bot.tx, bot.ty, x, y) > 10 then
                        bot.tx, bot.ty = x, y
                        bot.best, bot.bestTime, bot.gaveUp, bot.arrived = dist, os.clock(), false, false
                    end
                    if dist < bot.best - 5 then bot.best, bot.bestTime = dist, os.clock() end

                    if dist <= (tonumber(cfg.bot.radius) or 12) then
                        if getCarSpeed(car) > 1 then keys(0, false, true, false); bot.driving = true
                        else botStop() end
                        if not bot.arrived then msg('Бот: прибыли (' .. name .. ').') end
                        bot.arrived, bot.status = true, 'Прибыл'
                    elseif bot.gaveUp then
                        botStop(); bot.status = 'Ближе по дороге не подъехать'
                    elseif os.clock() - bot.bestTime > 45 then
                        botStop(); bot.gaveUp = true
                        msg('Бот: 45 секунд не получается приблизиться к метке, остановился.')
                    elseif manual then
                        botStop(); bot.pauseUntil = os.clock() + 3
                        bot.status = 'Управление у вас'
                    elseif os.clock() >= bot.pauseUntil then
                        bot.driving = true
                        botControl(car, x, y, z, dist)
                        bot.status = string.format('Едет: %s, %d м', name, math.floor(dist))
                    end
                end
            end
        end
    end
end

--==============================================================
-- Меню
--==============================================================
local menu = { window = imgui.new.bool(false), tab = 1 }

local function f3(hex) local r, g, b = hexToRGB(hex) return imgui.new.float[3](r, g, b) end
local function setF3(arr, hex) local r, g, b = hexToRGB(hex) arr[0], arr[1], arr[2] = r, g, b end

local ui = {
    spawnOn    = imgui.new.bool(cfg.spawn.enabled),
    spawnMode  = imgui.new.int(tonumber(cfg.spawn.mode) or 0),
    spawnDelay = imgui.new.int(tonumber(cfg.spawn.delay) or 1000),
    spawnItem  = imgui.new.int(tonumber(cfg.spawn.item) or 1),
    spawnKw    = imgui.new.char[64](tostring(cfg.spawn.keyword)),

    botOn      = imgui.new.bool(cfg.bot.enabled),
    botSource  = imgui.new.int(tonumber(cfg.bot.source) or 0),
    botSpeed   = imgui.new.int(tonumber(cfg.bot.speed) or 25),
    botStyle   = imgui.new.int(tonumber(cfg.bot.style) or 0),
    botRadius  = imgui.new.int(tonumber(cfg.bot.radius) or 12),
    botTake    = imgui.new.bool(cfg.bot.takeover),

    accent     = f3(cfg.theme.accent),
    bg         = f3(cfg.theme.bg),
    childAlpha = imgui.new.float(tonumber(cfg.theme.childAlpha) or 0.8),
    rounding   = imgui.new.int(tonumber(cfg.theme.rounding) or 12),
    pOn        = imgui.new.bool(cfg.particles.enabled),
    pRainbow   = imgui.new.bool(cfg.particles.rainbow),
    pColor     = f3(cfg.particles.color),
    pCount     = imgui.new.int(tonumber(cfg.particles.count) or 70),
    pSpeed     = imgui.new.int(tonumber(cfg.particles.speed) or 60),
    pSize      = imgui.new.float(tonumber(cfg.particles.size) or 2.0),
    pAlpha     = imgui.new.float(tonumber(cfg.particles.alpha) or 0.6),

    autoUpd    = imgui.new.bool(cfg.update.auto),
}

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

------------------------- Авто спавн ---------------------------
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

------------------------- Авто фарм ----------------------------
local function drawFarmTab()
    section('Бот дальнобойщик')

    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    local h  = 92
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(V4(ACCENT.x, ACCENT.y, ACCENT.z, 0.10)), 10)
    dl:AddLine(vec(p.x + 14, p.y + h - 16), vec(p.x + 150, p.y + h - 16), U32(V4(1, 1, 1, 0.10)), 2)
    local sway = bot.driving and math.sin(imgui.GetTime() * 12) * 0.6 or 0
    drawTruck(dl, p.x + 14, p.y + 14 + sway, 2.3, U32(V4(0.85, 0.87, 0.92, 1)), U32(ACCENT))
    dl:AddText(vec(p.x + 170, p.y + 22), U32(WHITE), 'Статус:')
    local scol = bot.driving and GREEN or (cfg.bot.enabled and V4(1.0, 0.8, 0.35, 1) or GRAY)
    dl:AddText(vec(p.x + 170, p.y + 44), U32(scol), bot.status)
    imgui.Dummy(vec(w, h))

    if toggle('##bot_on', 'Включить бота', ui.botOn) then
        cfg.bot.enabled = ui.botOn[0]; saveCfg()
        if not cfg.bot.enabled then botStop() end
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
    if sliderInt('Скорость:', '##bot_speed', ui.botSpeed, 5, SPEED_NO_LIMIT,
                 ui.botSpeed[0] >= SPEED_NO_LIMIT and 'Без лимита' or '%d') then
        cfg.bot.speed = ui.botSpeed[0]; saveCfg()
    end
    if sliderInt('Радиус прибытия:', '##bot_radius', ui.botRadius, 3, 40, '%d м') then
        cfg.bot.radius = ui.botRadius[0]; saveCfg()
    end
    if toggle('##bot_take', 'W / S забирают управление', ui.botTake) then
        cfg.bot.takeover = ui.botTake[0]; saveCfg()
    end
    hint('Собственный автопилот: едет по дорожным узлам игры, светофоров не видит, тормозит и объезжает препятствия по лучам. Аккуратный режим медленнее и раньше тормозит. Ползунок скорости до упора вправо - без лимита, бот сбавляет только в поворотах, у препятствий и у метки. Не работает на серверах Arizona RP.')
end

------------------------- Оформление ---------------------------
local PRESETS = {
    { name = 'Синий',      accent = '#3F99FF', bg = '#12141C' },
    { name = 'Фиолетовый', accent = '#9B5CFF', bg = '#15121E' },
    { name = 'Розовый',    accent = '#FF4FA3', bg = '#1A1218' },
    { name = 'Красный',    accent = '#FF4D4D', bg = '#1A1214' },
    { name = 'Оранжевый',  accent = '#FF9A3C', bg = '#1A1612' },
    { name = 'Зелёный',    accent = '#3CD27A', bg = '#111A15' },
    { name = 'Бирюзовый',  accent = '#2FD6D0', bg = '#101A1A' },
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
        local hovered = imgui.IsItemHovered()
        local r, g, b = hexToRGB(pr.accent)
        local c = vec(p.x + d / 2, p.y + d / 2)
        dl:AddCircleFilled(c, d / 2 - (hovered and 2 or 4), U32(V4(r, g, b, 1)), 32)
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

------------------------- Информация ---------------------------
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
end

local TABS = {
    { name = 'Авто спавн', icon = iconPerson,  draw = drawSpawnTab },
    { name = 'Авто фарм',  icon = iconTruck,   draw = drawFarmTab  },
    { name = 'Оформление', icon = iconPalette, draw = drawThemeTab },
    { name = 'Информация', icon = iconInfo,    draw = drawInfoTab  },
}

imgui.OnFrame(
    function() return menu.window[0] end,
    function()
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
        imgui.SetNextWindowSize(vec(700, 480), imgui.Cond.Always)
        imgui.Begin('##lua_afk_menu', menu.window,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)

        drawParticles(imgui.GetWindowDrawList(), imgui.GetWindowPos(), imgui.GetWindowSize())

        -- Боковая панель: вкладки столбиком
        imgui.BeginChild('##sidebar', vec(190, 0), true)
        centerText('lua_afk', ACCENT)
        centerText('v' .. SCRIPT_VERSION, GRAY)
        imgui.Spacing(); imgui.Separator(); imgui.Spacing()
        for i, tab in ipairs(TABS) do
            if sidebarButton('##tab' .. i, tab.name, tab.icon, menu.tab == i) then menu.tab = i end
        end
        imgui.SetCursorPosY(imgui.GetWindowHeight() - 40 - imgui.GetStyle().WindowPadding.y)
        if sidebarButton('##close', 'Закрыть', iconClose, false) then menu.window[0] = false end
        imgui.EndChild()

        imgui.SameLine()

        -- Содержимое вкладки
        imgui.BeginChild('##content', vec(0, 0), true)
        local tab = TABS[menu.tab]
        imgui.TextColored(ACCENT, tab.name)
        tab.draw()
        imgui.EndChild()

        imgui.End()
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
        imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.Always, vec(0.5, 0.5))
        imgui.Begin('lua_afk - обновление', nil, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
            + imgui.WindowFlags.NoMove + imgui.WindowFlags.AlwaysAutoResize)

        centerText('Доступно обновление!', GREEN)
        imgui.Separator()
        imgui.Text('Текущая версия:'); imgui.SameLine(150); imgui.TextColored(GRAY, SCRIPT_VERSION)
        imgui.Text('Новая версия:');   imgui.SameLine(150); imgui.TextColored(GREEN, upd.latest or '?')
        if upd.changelog and upd.changelog ~= '' then
            imgui.Spacing()
            imgui.TextDisabled('Что нового:')
            imgui.PushTextWrapPos(imgui.GetCursorPosX() + UPD_W)
            imgui.TextUnformatted(upd.changelog)
            imgui.PopTextWrapPos()
        end
        imgui.Spacing()

        local half = (UPD_W - imgui.GetStyle().ItemSpacing.x) / 2
        if upd.state == 'prompt' then
            if imgui.Button('Обновить', vec(half, 34)) then startDownload() end
            imgui.SameLine()
            if grayButton('Отмена', vec(half, 34)) then
                upd.window[0], upd.state, upd.dismissed = false, 'idle', upd.latest
                msg('Обновление отменено. Работаем на версии ' .. SCRIPT_VERSION .. '.')
            end
        elseif upd.state == 'downloading' or upd.state == 'installing' then
            local dt = imgui.GetIO().DeltaTime
            if upd.shown < upd.progress then
                upd.shown = math.min(upd.progress, upd.shown + math.max(dt * 0.8, (upd.progress - upd.shown) * dt * 4))
            end
            imgui.ProgressBar(upd.shown, vec(UPD_W, 26), string.format('%d%%', math.floor(upd.shown * 100)))
            centerText((upd.state == 'installing' and upd.shown >= 0.999) and 'Установка...' or 'Загрузка обновления...', GRAY)
        elseif upd.state == 'error' then
            centerText(upd.error or 'Ошибка обновления.', RED)
            if imgui.Button('Повторить', vec(half, 34)) then startDownload() end
            imgui.SameLine()
            if grayButton('Закрыть', vec(half, 34)) then upd.window[0], upd.state = false, 'idle' end
        end

        imgui.End()
    end
)

--==============================================================
-- Запуск
--==============================================================
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('lafk', function() menu.window[0] = not menu.window[0] end)
    sampRegisterChatCommand('lafkupd', function() checkUpdates(true) end)
    sampRegisterChatCommand('ltruck', function()
        cfg.bot.enabled = not cfg.bot.enabled; ui.botOn[0] = cfg.bot.enabled; saveCfg()
        if not cfg.bot.enabled then botStop() end
        msg(cfg.bot.enabled and 'Бот дальнобойщик включён.' or 'Бот дальнобойщик выключен.')
    end)
    msg('Загружен v' .. SCRIPT_VERSION .. '. Меню: /lafk')

    lua_thread.create(autoSpawnThread)
    lua_thread.create(botThread)
    lua_thread.create(updateScheduler)

    while true do
        wait(0)
        if upd.state == 'installing' and (upd.shown >= 0.999 or not upd.window[0]) then
            wait(500)
            if installUpdate() then return end
        end
    end
end

function onScriptTerminate(s, quit)
    if s ~= thisScript() then return end
    if not quit and bot.driving then pcall(keys, 0, false, false, false) end
end
