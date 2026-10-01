-- lua_afk.lua
-- Скрипт для Arizona Role Play (SA-MP, MoonLoader)
-- Требуется: MoonLoader, SAMPFUNCS, mimgui

script_name('lua_afk')
script_author('denismaslov769-lab')
script_version('0.4.0')
script_description('Скрипт для Arizona RP: меню, авто спавн, автообновление')

local imgui    = require('mimgui')
local encoding = require('encoding')
local dlstatus = require('moonloader').download_status
local inicfg   = require('inicfg')
local ffi      = require('ffi')

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ===================== Настройки =====================
local SCRIPT_VERSION = '0.4.0'
local REPO_RAW    = 'https://raw.githubusercontent.com/denismaslov769-lab/lua_afk/main/'
local VERSION_URL = REPO_RAW .. 'version.json'
local SCRIPT_URL  = REPO_RAW .. 'lua_afk.lua'

local TMP_DIR     = os.getenv('TEMP') or getWorkingDirectory()
local TMP_VERSION = TMP_DIR .. '\\lua_afk_version.json'
local TMP_SCRIPT  = TMP_DIR .. '\\lua_afk_update.lua'

local TAG = '{33AAFF}[lua_afk]{FFFFFF} '

-- ===================== Конфиг (moonloader/config/lua_afk.ini) =====================
local INI = 'lua_afk.ini'
local cfg = inicfg.load({
    spawn = {
        enabled = false,
        mode    = 0,        -- 0 = обычный спавн, 1 = выбор пункта в диалоге
        delay   = 1000,     -- задержка, мс
        item    = 1,        -- номер пункта в диалоге (с 1)
        keyword = 'спавн',  -- слово в заголовке диалога
    },
    theme = {
        accent     = '#3F99FF', -- основной цвет
        bg         = '#12141C', -- цвет фона окна
        childAlpha = 0.80,      -- прозрачность панелей
        rounding   = 12,        -- скругление
    },
    particles = {
        enabled = true,
        count   = 70,
        speed   = 60,           -- пикселей в секунду
        size    = 2.0,
        alpha   = 0.60,
        color   = '#FFFFFF',
        rainbow = false,
    },
}, INI)
local function saveCfg() inicfg.save(cfg, INI) end

-- ===================== Утилиты =====================
-- Текст в файле хранится в UTF-8, чат игры использует CP1251
local function msg(text)
    sampAddChatMessage(TAG .. u8:decode(text), -1)
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function parseVersion(v)
    local t = {}
    for n in tostring(v):gmatch('%d+') do t[#t + 1] = tonumber(n) end
    return t
end

-- true, если версия remote новее current
local function isNewer(remote, current)
    local a, b = parseVersion(remote), parseVersion(current)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- ===================== Автообновление =====================
local upd = {
    window    = imgui.new.bool(false),
    state     = 'idle',  -- idle | prompt | downloading | installing | error
    latest    = nil,
    changelog = nil,
    url       = SCRIPT_URL,
    progress  = 0.0,     -- реальный прогресс загрузки
    shown     = 0.0,     -- плавно анимированный прогресс для бара
    newCode   = nil,
    error     = nil,
}

local function checkUpdates(manual)
    os.remove(TMP_VERSION)
    downloadUrlToFile(VERSION_URL .. '?t=' .. os.time(), TMP_VERSION, function(id, status)
        if status ~= dlstatus.STATUS_ENDDOWNLOADDATA then return end
        local data = readFile(TMP_VERSION)
        os.remove(TMP_VERSION)
        local ok, info = pcall(decodeJson, data or '')
        if not ok or type(info) ~= 'table' or not info.version then
            if manual then msg('Не удалось проверить обновления.') end
            return
        end
        if isNewer(info.version, SCRIPT_VERSION) then
            upd.latest    = tostring(info.version)
            upd.changelog = info.changelog
            upd.url       = info.url or SCRIPT_URL
            upd.state     = 'prompt'
            upd.window[0] = true
        elseif manual then
            msg('У вас последняя версия: ' .. SCRIPT_VERSION)
        end
    end)
end

local function startDownload()
    upd.state, upd.progress, upd.shown, upd.error, upd.newCode = 'downloading', 0.0, 0.0, nil, nil
    os.remove(TMP_SCRIPT)
    downloadUrlToFile(upd.url .. '?t=' .. os.time(), TMP_SCRIPT, function(id, status, p1, p2)
        if status == dlstatus.STATUS_DOWNLOADINGDATA then
            if p2 and p2 > 0 then upd.progress = math.min(p1 / p2, 0.99) end
        elseif status == dlstatus.STATUS_ENDDOWNLOADDATA then
            local data = readFile(TMP_SCRIPT)
            os.remove(TMP_SCRIPT)
            if data and data:find('script_name%(') then
                upd.newCode  = data
                upd.progress = 1.0
                upd.state    = 'installing'
            else
                upd.state = 'error'
                upd.error = 'Не удалось скачать обновление.'
            end
        end
    end)
end

-- Записывает новую версию поверх текущего файла и перезапускает скрипт
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

-- ===================== Оформление mimgui =====================
local V4 = imgui.ImVec4
local COLOR_GREEN = V4(0.35, 0.85, 0.45, 1.00)
local COLOR_GRAY  = V4(0.60, 0.63, 0.70, 1.00)
local COLOR_RED   = V4(1.00, 0.40, 0.40, 1.00)
local WIDTH = 360
local ACCENT = V4(0.25, 0.60, 1.00, 1.00)

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

-- Применяет цвета и скругления из настроек (вызывается при каждом изменении)
local function applyTheme()
    local style = imgui.GetStyle()
    local c, col = style.Colors, imgui.Col
    local ar, ag, ab = hexToRGB(cfg.theme.accent)
    local br, bg, bb = hexToRGB(cfg.theme.bg)
    local function mix(r, g, b, k, a) -- k > 0 светлее, k < 0 темнее
        if k >= 0 then return V4(r + (1 - r) * k, g + (1 - g) * k, b + (1 - b) * k, a or 1) end
        return V4(r * (1 + k), g * (1 + k), b * (1 + k), a or 1)
    end
    local function lift(k, a) return V4(math.min(1, br + k), math.min(1, bg + k), math.min(1, bb + k), a or 1) end

    ACCENT = V4(ar, ag, ab, 1)
    local rnd = tonumber(cfg.theme.rounding) or 12

    style.WindowPadding     = imgui.ImVec2(18, 16)
    style.FramePadding      = imgui.ImVec2(10, 6)
    style.ItemSpacing       = imgui.ImVec2(10, 10)
    style.WindowRounding    = rnd
    style.ChildRounding     = rnd * 0.8
    style.FrameRounding     = rnd * 0.6
    style.GrabRounding      = rnd * 0.6
    style.PopupRounding     = rnd * 0.6
    style.ScrollbarRounding = rnd * 0.6
    style.GrabMinSize       = 14
    style.WindowBorderSize  = 1
    style.ChildBorderSize   = 1
    style.WindowTitleAlign  = imgui.ImVec2(0.5, 0.5)

    c[col.WindowBg]         = V4(br, bg, bb, 0.97)
    c[col.ChildBg]          = lift(0.03, tonumber(cfg.theme.childAlpha) or 0.8)
    c[col.PopupBg]          = lift(0.02, 0.98)
    c[col.Border]           = V4(ar, ag, ab, 0.40)
    c[col.Separator]        = V4(ar, ag, ab, 0.25)
    c[col.TitleBg]          = lift(0.03)
    c[col.TitleBgActive]    = lift(0.06)
    c[col.Text]             = V4(0.92, 0.94, 0.97, 1.00)
    c[col.TextDisabled]     = COLOR_GRAY
    c[col.FrameBg]          = lift(0.06)
    c[col.FrameBgHovered]   = lift(0.09)
    c[col.FrameBgActive]    = lift(0.12)
    c[col.Button]           = mix(ar, ag, ab, -0.15)
    c[col.ButtonHovered]    = mix(ar, ag, ab, 0.12)
    c[col.ButtonActive]     = mix(ar, ag, ab, -0.30)
    c[col.Header]           = V4(ar, ag, ab, 0.35)
    c[col.HeaderHovered]    = V4(ar, ag, ab, 0.50)
    c[col.HeaderActive]     = V4(ar, ag, ab, 0.65)
    c[col.PlotHistogram]    = ACCENT
    c[col.SliderGrab]       = ACCENT
    c[col.SliderGrabActive] = mix(ar, ag, ab, 0.25)
    c[col.CheckMark]        = ACCENT
    c[col.ScrollbarBg]      = lift(0.0)
    c[col.ScrollbarGrab]    = lift(0.12)
    c[col.TextSelectedBg]   = V4(ar, ag, ab, 0.35)
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil

    -- Шрифт с поддержкой кириллицы
    local fontsDir = getFolderPath(0x14)
    local font
    for _, name in ipairs({ 'trebucbd.ttf', 'segoeui.ttf', 'arial.ttf', 'tahoma.ttf' }) do
        if doesFileExist(fontsDir .. '\\' .. name) then font = fontsDir .. '\\' .. name break end
    end
    if font then
        io.Fonts:Clear()
        io.Fonts:AddFontFromFileTTF(font, 16.0, nil, io.Fonts:GetGlyphRangesCyrillic())
    end

    applyTheme()
end)

local function centerText(text, color)
    local w = imgui.CalcTextSize(text).x
    imgui.SetCursorPosX((imgui.GetWindowWidth() - w) / 2)
    if color then imgui.TextColored(color, text) else imgui.Text(text) end
end

local function grayButton(label, size)
    imgui.PushStyleColor(imgui.Col.Button,        V4(0.22, 0.24, 0.30, 1.00))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, V4(0.30, 0.32, 0.40, 1.00))
    imgui.PushStyleColor(imgui.Col.ButtonActive,  V4(0.18, 0.20, 0.25, 1.00))
    local pressed = imgui.Button(label, size)
    imgui.PopStyleColor(3)
    return pressed
end

imgui.OnFrame(
    function() return upd.window[0] end,
    function(player)
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        local flags = imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
                    + imgui.WindowFlags.NoMove + imgui.WindowFlags.AlwaysAutoResize
        imgui.Begin('lua_afk - обновление', nil, flags)

        centerText('Доступно обновление!', COLOR_GREEN)
        imgui.Separator()

        imgui.Text('Текущая версия:'); imgui.SameLine(150); imgui.TextColored(COLOR_GRAY, SCRIPT_VERSION)
        imgui.Text('Новая версия:');   imgui.SameLine(150); imgui.TextColored(COLOR_GREEN, upd.latest or '?')

        if upd.changelog and upd.changelog ~= '' then
            imgui.Spacing()
            imgui.TextDisabled('Что нового:')
            imgui.PushTextWrapPos(imgui.GetCursorPosX() + WIDTH)
            imgui.Text(tostring(upd.changelog))
            imgui.PopTextWrapPos()
        end
        imgui.Spacing()

        local half = (WIDTH - imgui.GetStyle().ItemSpacing.x) / 2

        if upd.state == 'prompt' then
            if imgui.Button('Обновить', imgui.ImVec2(half, 34)) then
                startDownload()
            end
            imgui.SameLine()
            if grayButton('Отмена', imgui.ImVec2(half, 34)) then
                upd.window[0], upd.state = false, 'idle'
                msg('Обновление отменено. Работаем на версии ' .. SCRIPT_VERSION .. '.')
            end

        elseif upd.state == 'downloading' or upd.state == 'installing' then
            -- Плавная анимация заполнения
            local dt = imgui.GetIO().DeltaTime
            if upd.shown < upd.progress then
                upd.shown = math.min(upd.progress, upd.shown + math.max(dt * 0.8, (upd.progress - upd.shown) * dt * 4))
            end
            imgui.ProgressBar(upd.shown, imgui.ImVec2(WIDTH, 26), string.format('%d%%', math.floor(upd.shown * 100)))
            local status = (upd.state == 'installing' and upd.shown >= 0.999) and 'Установка...' or 'Загрузка обновления...'
            centerText(status, COLOR_GRAY)

        elseif upd.state == 'error' then
            centerText(upd.error or 'Ошибка обновления.', COLOR_RED)
            if imgui.Button('Повторить', imgui.ImVec2(half, 34)) then
                startDownload()
            end
            imgui.SameLine()
            if grayButton('Закрыть', imgui.ImVec2(half, 34)) then
                upd.window[0], upd.state = false, 'idle'
            end
        end

        imgui.End()
    end
)


-- ===================== Виджеты (рисуются кодом, без icon-шрифтов => никаких "???") =====================
local U32 = imgui.ColorConvertFloat4ToU32
local function vec(x, y) return imgui.ImVec2(x, y) end
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpV4(a, b, t) return V4(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t), lerp(a.w, b.w, t)) end
local anim = {}

-- Переключатель (toggle switch) с анимацией
local function toggle(id, label, ptr)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local h  = imgui.GetFrameHeight()
    local w  = h * 1.9
    local clicked = imgui.InvisibleButton(id, vec(w, h))
    if clicked then ptr[0] = not ptr[0] end
    local target = ptr[0] and 1 or 0
    local t = anim[id] or target
    t = t + (target - t) * math.min(1, imgui.GetIO().DeltaTime * 12)
    anim[id] = t
    local bg = lerpV4(V4(0.22, 0.24, 0.30, 1), ACCENT, t)
    if imgui.IsItemHovered() then bg = lerpV4(bg, V4(1, 1, 1, 1), 0.08) end
    dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(bg), h / 2)
    dl:AddCircleFilled(vec(p.x + h / 2 + t * (w - h), p.y + h / 2), h / 2 - 3, U32(V4(1, 1, 1, 1)), 24)
    imgui.SameLine()
    imgui.AlignTextToFramePadding()
    imgui.Text(label)
    return clicked
end

-- Сегментированный выбор (вместо выпадающего списка)
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

-- Иконки
local function iconPerson(dl, c, col)
    dl:AddCircleFilled(vec(c.x, c.y - 4.5), 3.8, col, 20)                       -- голова
    dl:AddRectFilled(vec(c.x - 6.5, c.y + 1), vec(c.x + 6.5, c.y + 9), col, 4)  -- туловище
end

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

-- Кнопка-вкладка в боковой панели
local function sidebarButton(id, name, icon, active)
    local dl = imgui.GetWindowDrawList()
    local p  = imgui.GetCursorScreenPos()
    local w  = imgui.GetContentRegionAvail().x
    local h  = 40
    local clicked = imgui.InvisibleButton(id, vec(w, h))
    local hovered = imgui.IsItemHovered()

    local t = anim[id] or 0
    local target = active and 1 or (hovered and 0.45 or 0)
    t = t + (target - t) * math.min(1, imgui.GetIO().DeltaTime * 14)
    anim[id] = t

    if t > 0.01 then
        dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(V4(ACCENT.x, ACCENT.y, ACCENT.z, 0.18 * t)), 8)
    end
    if active then
        dl:AddRectFilled(vec(p.x, p.y + 8), vec(p.x + 4, p.y + h - 8), U32(ACCENT), 2)
    end
    local col = U32(lerpV4(COLOR_GRAY, V4(1, 1, 1, 1), t))
    icon(dl, vec(p.x + 22, p.y + h / 2), col)
    dl:AddText(vec(p.x + 42, p.y + (h - imgui.GetTextLineHeight()) / 2), col, name)
    return clicked
end

-- ===================== Меню =====================
local menu = {
    window = imgui.new.bool(false),
    tab    = 1,
}

local ui = {
    spawnEnabled = imgui.new.bool(cfg.spawn.enabled),
    spawnMode    = imgui.new.int(cfg.spawn.mode),
    spawnDelay   = imgui.new.int(cfg.spawn.delay),
    spawnItem    = imgui.new.int(cfg.spawn.item),
    spawnKeyword = imgui.new.char[64](tostring(cfg.spawn.keyword)),
}

local function drawSpawnTab()
    section('Основное')
    if toggle('##spawn_on', 'Включить авто спавн', ui.spawnEnabled) then
        cfg.spawn.enabled = ui.spawnEnabled[0]; saveCfg()
        msg(cfg.spawn.enabled and 'Авто спавн включён.' or 'Авто спавн выключен.')
    end

    section('Режим')
    if segmented('spawn_mode', ui.spawnMode, { 'Кнопка Spawn', 'Пункт в диалоге' }) then
        cfg.spawn.mode = ui.spawnMode[0]; saveCfg()
    end
    if ui.spawnMode[0] == 0 then
        hint('Скрипт сам нажмёт Spawn, когда персонаж ещё не появился на сервере и нет открытых диалогов.')
    else
        hint('Когда откроется диалог, в заголовке которого есть ключевое слово, скрипт выберет нужный пункт.')
        imgui.Text('Ключевое слово:')
        imgui.PushItemWidth(-1)
        if imgui.InputText('##spawn_kw', ui.spawnKeyword, ffi.sizeof(ui.spawnKeyword)) then
            cfg.spawn.keyword = ffi.string(ui.spawnKeyword); saveCfg()
        end
        imgui.Text('Номер пункта:')
        if imgui.SliderInt('##spawn_item', ui.spawnItem, 1, 10, 'Пункт %d') then
            cfg.spawn.item = ui.spawnItem[0]; saveCfg()
        end
        imgui.PopItemWidth()
    end

    section('Задержка')
    imgui.PushItemWidth(-1)
    if imgui.SliderInt('##spawn_delay', ui.spawnDelay, 0, 5000, '%d мс') then
        cfg.spawn.delay = ui.spawnDelay[0]; saveCfg()
    end
    imgui.PopItemWidth()
end

local function drawInfoTab()
    section('Скрипт')
    imgui.Text('Версия:');  imgui.SameLine(110); imgui.TextColored(COLOR_GREEN, SCRIPT_VERSION)
    imgui.Text('Автор:');   imgui.SameLine(110); imgui.TextColored(COLOR_GRAY, 'denismaslov769-lab')

    section('Обновления')
    if imgui.Button('Проверить обновления', vec(-1, 34)) then checkUpdates(true) end

    section('Команды')
    imgui.Text('/lafk');    imgui.SameLine(110); imgui.TextDisabled('открыть / закрыть меню')
    imgui.Text('/lafkupd'); imgui.SameLine(110); imgui.TextDisabled('проверить обновления')
end

-- ===================== Падающие частицы =====================
local particles = {}

local function newParticle(w, h, fromTop)
    return {
        x     = math.random() * w,
        y     = fromTop and -math.random() * 20 or math.random() * h,
        sp    = 0.5 + math.random(),          -- множитель скорости
        sz    = 0.6 + math.random() * 0.8,    -- множитель размера
        a     = 0.4 + math.random() * 0.6,    -- множитель прозрачности
        drift = (math.random() - 0.5) * 20,   -- снос в сторону
        hue   = math.random(),
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

-- ===================== Вкладка «Оформление» =====================
local function f3(hex) local r, g, b = hexToRGB(hex) return imgui.new.float[3](r, g, b) end

local tui = {
    accent     = f3(cfg.theme.accent),
    bg         = f3(cfg.theme.bg),
    childAlpha = imgui.new.float(tonumber(cfg.theme.childAlpha) or 0.8),
    rounding   = imgui.new.int(tonumber(cfg.theme.rounding) or 12),
    pOn        = imgui.new.bool(cfg.particles.enabled),
    pCount     = imgui.new.int(cfg.particles.count),
    pSpeed     = imgui.new.int(cfg.particles.speed),
    pSize      = imgui.new.float(cfg.particles.size),
    pAlpha     = imgui.new.float(cfg.particles.alpha),
    pColor     = f3(cfg.particles.color),
    pRainbow   = imgui.new.bool(cfg.particles.rainbow),
}

local PRESETS = {
    { name = 'Синий',      accent = '#3F99FF', bg = '#12141C' },
    { name = 'Фиолетовый', accent = '#9B5CFF', bg = '#15121E' },
    { name = 'Розовый',    accent = '#FF4FA3', bg = '#1A1218' },
    { name = 'Красный',    accent = '#FF4D4D', bg = '#1A1214' },
    { name = 'Оранжевый',  accent = '#FF9A3C', bg = '#1A1612' },
    { name = 'Зелёный',    accent = '#3CD27A', bg = '#111A15' },
    { name = 'Бирюзовый',  accent = '#2FD6D0', bg = '#101A1A' },
}

local function setColor3(arr, hex)
    local r, g, b = hexToRGB(hex)
    arr[0], arr[1], arr[2] = r, g, b
end

-- Ряд круглых образцов цвета (пресеты темы)
local function presetSwatches()
    local dl = imgui.GetWindowDrawList()
    local d = 30
    for i, pr in ipairs(PRESETS) do
        if i > 1 then imgui.SameLine() end
        local p = imgui.GetCursorScreenPos()
        if imgui.InvisibleButton('##preset' .. i, vec(d, d)) then
            cfg.theme.accent, cfg.theme.bg = pr.accent, pr.bg
            setColor3(tui.accent, pr.accent); setColor3(tui.bg, pr.bg)
            applyTheme(); saveCfg()
        end
        local hovered = imgui.IsItemHovered()
        local r, g, b = hexToRGB(pr.accent)
        local c = vec(p.x + d / 2, p.y + d / 2)
        dl:AddCircleFilled(c, d / 2 - (hovered and 2 or 4), U32(V4(r, g, b, 1)), 32)
        if cfg.theme.accent:upper() == pr.accent:upper() then
            dl:AddCircle(c, d / 2 - 0.5, U32(V4(1, 1, 1, 0.9)), 32, 2)
        end
        if hovered then imgui.SetTooltip(pr.name) end
    end
end

local function colorRow(id, label, arr)
    local changed = imgui.ColorEdit3(id, arr, imgui.ColorEditFlags.NoInputs)
    imgui.SameLine()
    imgui.Text(label)
    return changed
end

local function drawThemeTab()
    section('Готовые темы')
    presetSwatches()

    section('Цвета меню')
    if colorRow('##accent', 'Основной цвет', tui.accent) then
        cfg.theme.accent = rgbToHex(tui.accent[0], tui.accent[1], tui.accent[2]); applyTheme(); saveCfg()
    end
    if colorRow('##bg', 'Цвет фона', tui.bg) then
        cfg.theme.bg = rgbToHex(tui.bg[0], tui.bg[1], tui.bg[2]); applyTheme(); saveCfg()
    end
    imgui.PushItemWidth(-1)
    imgui.Text('Прозрачность панелей:')
    if imgui.SliderFloat('##childAlpha', tui.childAlpha, 0.2, 1.0, '%.2f') then
        cfg.theme.childAlpha = tui.childAlpha[0]; applyTheme(); saveCfg()
    end
    imgui.Text('Скругление:')
    if imgui.SliderInt('##rounding', tui.rounding, 0, 20, '%d px') then
        cfg.theme.rounding = tui.rounding[0]; applyTheme(); saveCfg()
    end
    imgui.PopItemWidth()

    section('Падающие частицы')
    if toggle('##p_on', 'Включить частицы', tui.pOn) then
        cfg.particles.enabled = tui.pOn[0]; saveCfg()
    end
    if toggle('##p_rainbow', 'Радужные частицы', tui.pRainbow) then
        cfg.particles.rainbow = tui.pRainbow[0]; saveCfg()
    end
    if not tui.pRainbow[0] then
        if colorRow('##p_color', 'Цвет частиц', tui.pColor) then
            cfg.particles.color = rgbToHex(tui.pColor[0], tui.pColor[1], tui.pColor[2]); saveCfg()
        end
    end
    imgui.PushItemWidth(-1)
    imgui.Text('Количество:')
    if imgui.SliderInt('##p_count', tui.pCount, 0, 300, '%d шт.') then
        cfg.particles.count = tui.pCount[0]; saveCfg()
    end
    imgui.Text('Скорость:')
    if imgui.SliderInt('##p_speed', tui.pSpeed, 5, 400, '%d') then
        cfg.particles.speed = tui.pSpeed[0]; saveCfg()
    end
    imgui.Text('Размер:')
    if imgui.SliderFloat('##p_size', tui.pSize, 0.5, 6.0, '%.1f') then
        cfg.particles.size = tui.pSize[0]; saveCfg()
    end
    imgui.Text('Яркость:')
    if imgui.SliderFloat('##p_alpha', tui.pAlpha, 0.05, 1.0, '%.2f') then
        cfg.particles.alpha = tui.pAlpha[0]; saveCfg()
    end
    imgui.PopItemWidth()

    imgui.Spacing()
    if grayButton('Сбросить оформление', vec(-1, 34)) then
        cfg.theme.accent, cfg.theme.bg, cfg.theme.childAlpha, cfg.theme.rounding = '#3F99FF', '#12141C', 0.80, 12
        cfg.particles.enabled, cfg.particles.count, cfg.particles.speed = true, 70, 60
        cfg.particles.size, cfg.particles.alpha, cfg.particles.color, cfg.particles.rainbow = 2.0, 0.60, '#FFFFFF', false
        setColor3(tui.accent, cfg.theme.accent); setColor3(tui.bg, cfg.theme.bg); setColor3(tui.pColor, cfg.particles.color)
        tui.childAlpha[0], tui.rounding[0] = cfg.theme.childAlpha, cfg.theme.rounding
        tui.pOn[0], tui.pCount[0], tui.pSpeed[0] = true, 70, 60
        tui.pSize[0], tui.pAlpha[0], tui.pRainbow[0] = 2.0, 0.60, false
        applyTheme(); saveCfg()
    end
end

local TABS = {
    { name = 'Авто спавн', icon = iconPerson, draw = drawSpawnTab },
    { name = 'Оформление', icon = iconPalette, draw = drawThemeTab },
    { name = 'Информация', icon = iconInfo,  draw = drawInfoTab  },
}

imgui.OnFrame(
    function() return menu.window[0] end,
    function(player)
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
        imgui.SetNextWindowSize(vec(700, 480), imgui.Cond.Always)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, vec(10, 10))
        imgui.Begin('##lua_afk_menu', menu.window,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
        imgui.PopStyleVar()

        -- Частицы рисуются на фоне окна, панели поверх них полупрозрачные
        drawParticles(imgui.GetWindowDrawList(), imgui.GetWindowPos(), imgui.GetWindowSize())

        -- Боковая панель: вкладки столбиком
        imgui.BeginChild('##sidebar', vec(190, 0), true)
        imgui.SetWindowFontScale(1.35)
        centerText('lua_afk', ACCENT)
        imgui.SetWindowFontScale(1.0)
        centerText('v' .. SCRIPT_VERSION, COLOR_GRAY)
        imgui.Spacing(); imgui.Separator(); imgui.Spacing()

        for i, tab in ipairs(TABS) do
            if sidebarButton('##tab' .. i, tab.name, tab.icon, menu.tab == i) then menu.tab = i end
        end

        -- Кнопка закрытия внизу панели
        imgui.SetCursorPosY(imgui.GetWindowHeight() - 40 - imgui.GetStyle().WindowPadding.y)
        if sidebarButton('##close', 'Закрыть', iconClose, false) then menu.window[0] = false end
        imgui.EndChild()

        imgui.SameLine()

        -- Содержимое вкладки
        imgui.BeginChild('##content', vec(0, 0), true)
        local tab = TABS[menu.tab]
        imgui.SetWindowFontScale(1.25)
        imgui.Text(tab.name)
        imgui.SetWindowFontScale(1.0)
        tab.draw()
        imgui.EndChild()

        imgui.End()
    end
)

-- ===================== Авто спавн =====================
local RU_UP = 'АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'
local RU_LO = 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя'
local RU_MAP = {}
do
    local up, lo = {}, {}
    for ch in RU_UP:gmatch('[\208\209][\128-\191]') do up[#up + 1] = ch end
    for ch in RU_LO:gmatch('[\208\209][\128-\191]') do lo[#lo + 1] = ch end
    for i = 1, #up do RU_MAP[up[i]] = lo[i] end
end
local function ruLower(s)
    local r = s:lower():gsub('[\208\209][\128-\191]', RU_MAP)
    return r
end

local function autoSpawnThread()
    local lastSpawn, lastDialogId, lastDialogTime = 0, -1, 0
    while true do
        wait(200)
        if cfg.spawn.enabled then
            if cfg.spawn.mode == 0 then
                -- Обычный спавн: персонаж подключён, но ещё не появился, диалогов нет
                local connected = sampGetPlayerIdByCharHandle(PLAYER_PED)
                if connected and not sampIsLocalPlayerSpawned() and not sampIsDialogActive()
                   and os.clock() - lastSpawn > 3 then
                    wait(cfg.spawn.delay)
                    if not sampIsLocalPlayerSpawned() and not sampIsDialogActive() then
                        sampSendRequestSpawn()
                        sampSpawnPlayer()
                        lastSpawn = os.clock()
                        msg('Авто спавн: персонаж заспавнен.')
                    end
                end
            elseif sampIsDialogActive() then
                -- Выбор пункта в диалоге спавна
                local id = sampGetCurrentDialogId()
                if id ~= lastDialogId or os.clock() - lastDialogTime > 3 then
                    local caption = u8(sampGetDialogCaption() or ''):gsub('{%x+}', '')
                    local kw = ruLower(tostring(cfg.spawn.keyword))
                    if kw ~= '' and ruLower(caption):find(kw, 1, true) then
                        lastDialogId, lastDialogTime = id, os.clock()
                        wait(cfg.spawn.delay)
                        if sampIsDialogActive() and sampGetCurrentDialogId() == id then
                            sampSetCurrentDialogListItem(cfg.spawn.item - 1)
                            sampCloseCurrentDialogWithButton(1)
                            msg('Авто спавн: выбран пункт ' .. cfg.spawn.item .. '.')
                        end
                    end
                end
            end
        end
    end
end

-- ===================== Команды =====================
-- /lafk - открыть/закрыть меню
local function cmdMenu()
    menu.window[0] = not menu.window[0]
end

-- ===================== Главный цикл =====================
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('lafk', cmdMenu)
    sampRegisterChatCommand('lafkupd', function() checkUpdates(true) end)
    msg('Загружен v' .. SCRIPT_VERSION .. '. Меню: /lafk')

    lua_thread.create(autoSpawnThread)

    -- Проверяем обновления после входа на сервер (когда персонаж заспавнился)
    lua_thread.create(function()
        while not sampIsLocalPlayerSpawned() do wait(500) end
        wait(1500)
        checkUpdates(false)
    end)

    while true do
        wait(0)

        if upd.state == 'installing' and upd.shown >= 0.999 then
            wait(500)
            if installUpdate() then return end
        end
    end
end
