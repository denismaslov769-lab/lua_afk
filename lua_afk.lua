-- lua_afk.lua
-- Скрипт для Arizona Role Play (SA-MP, MoonLoader)
-- Требуется: MoonLoader, SAMPFUNCS, mimgui

script_name('lua_afk')
script_author('denismaslov769-lab')
script_version('0.6.3')
script_description('Скрипт для Arizona RP: меню, авто спавн, автообновление')

local imgui    = require('mimgui')
local encoding = require('encoding')
local dlstatus = require('moonloader').download_status
local inicfg   = require('inicfg')
local ffi      = require('ffi')
local hasSampev, sampev = pcall(require, 'lib.samp.events')

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ===================== Настройки =====================
local SCRIPT_VERSION = '0.6.3'
local REPO_RAW    = 'https://raw.githubusercontent.com/denismaslov769-lab/lua_afk/main/'
local VERSION_URL = REPO_RAW .. 'version.json'
local SCRIPT_URL  = REPO_RAW .. 'lua_afk.lua'
-- Через API узнаём точный последний коммит, чтобы не получать устаревший файл из кэша GitHub
local API_COMMIT  = 'https://api.github.com/repos/denismaslov769-lab/lua_afk/commits/main'
local RAW_BY_SHA  = 'https://raw.githubusercontent.com/denismaslov769-lab/lua_afk/'
local ATOM_URL    = 'https://github.com/denismaslov769-lab/lua_afk/commits/main.atom'

local TMP_DIR     = getWorkingDirectory() .. '\\config'
local TMP_VERSION = TMP_DIR .. '\\lua_afk_version.json'
local TMP_SCRIPT  = TMP_DIR .. '\\lua_afk_update.lua'
local TMP_COMMIT  = TMP_DIR .. '\\lua_afk_commit.json'

local TAG = '{33AAFF}[lua_afk]{FFFFFF} '
local SAFE = false -- простой режим меню (/lafk safe): без частиц и нарисованных виджетов

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
    bot = {
        enabled  = false,
        source   = 0,     -- 0 = авто, 1 = только чекпоинт, 2 = только метка на карте
        speed    = 25,
        style    = 0,     -- 0 = объезжать машины, 1 = тормозить перед машинами (светофоры игнорируются всегда)
        radius   = 12,    -- радиус прибытия, м
        takeover = true,  -- W/S забирают управление
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

local function ulog(text, manual)
    print('[update] ' .. u8:decode(text))      -- пишется в moonloader.log
    if manual then msg(text) end
end

-- Скачивает url во временный файл и отдаёт содержимое в cb (nil при ошибке)
-- Загрузки идут строго по одной: следующая начинается только после того,
-- как предыдущая полностью завершилась (иначе MoonLoader: "device or resource busy")
local function fetch(url, path, cb)
    lua_thread.create(function()
        os.remove(path)
        local done, result, started = false, nil, false
        for attempt = 1, 10 do
            started = pcall(downloadUrlToFile, url, path, function(id, status)
                if status == dlstatus.STATUS_ENDDOWNLOADDATA then
                    result = readFile(path)
                    os.remove(path)
                    done = true
                end
            end)
            if started then break end
            wait(500) -- загрузчик занят, ждём и пробуем снова
        end
        if started then
            local t = os.time()
            while not done and os.time() - t < 20 do wait(50) end
            wait(200) -- даём загрузчику освободиться
        end
        cb(result ~= '' and result or nil)
    end)
end

-- Пробует адреса по очереди, пока один не ответит
local function fetchFirst(urls, path, cb, n)
    n = n or 1
    if not urls[n] then cb(nil, nil) return end
    fetch(urls[n] .. '?t=' .. os.time(), path, function(data)
        if data then cb(data, urls[n]) else fetchFirst(urls, path, cb, n + 1) end
    end)
end

-- manual   - ручная проверка (/lafkupd): подробные сообщения
-- periodic - фоновая проверка: не показывать окно повторно, если эту версию уже отменили
local function checkUpdates(manual, periodic)
    if upd.state ~= 'idle' and upd.state ~= 'error' then return end
    if not doesDirectoryExist(TMP_DIR) then createDirectory(TMP_DIR) end
    ulog('Проверка обновлений...', manual)

    fetch(API_COMMIT .. '?t=' .. os.time(), TMP_COMMIT, function(cdata)
        local sha
        if cdata then sha = cdata:match('"sha"%s*:%s*"(%x+)"') end
        if not sha then
            -- API не ответил: берём последний коммит из ленты github.com (она не кэшируется как raw)
            ulog('GitHub API не ответил, пробую ленту коммитов.', manual)
            local atom
            local doneAtom = false
            fetch(ATOM_URL .. '?t=' .. os.time(), TMP_COMMIT, function(d) atom = d; doneAtom = true end)
            while not doneAtom do wait(50) end
            if atom then sha = atom:match('Commit/(%x+)') end
        end
        local urls = {}
        if sha then
            urls[#urls + 1] = RAW_BY_SHA .. sha .. '/'
            urls[#urls + 1] = 'https://cdn.jsdelivr.net/gh/denismaslov769-lab/lua_afk@' .. sha .. '/'
        else
            ulog('Не удалось узнать последний коммит, версия может быть устаревшей.', manual)
        end
        urls[#urls + 1] = REPO_RAW

        local vurls = {}
        for k, u in ipairs(urls) do vurls[k] = u .. 'version.json' end
        fetchFirst(vurls, TMP_VERSION, function(data, from)
            if not data then
                ulog('Ошибка: не удалось скачать version.json ни с одного адреса.', true)
                return
            end
            local ok2, info = pcall(decodeJson, data)
            if not ok2 or type(info) ~= 'table' or not info.version then
                ulog('Ошибка: не удалось прочитать version.json.', true)
                return
            end
            local base = from:gsub('version%.json$', '')
            ulog('На GitHub версия ' .. tostring(info.version) .. ', у вас ' .. SCRIPT_VERSION .. '.', manual)
            if isNewer(info.version, SCRIPT_VERSION) then
                local v = tostring(info.version)
                if periodic and upd.dismissed == v then return end
                upd.latest    = v
                upd.changelog = info.changelog
                upd.url       = base .. 'lua_afk.lua'
                upd.state     = 'prompt'
                upd.window[0] = true
                msg('Доступно обновление ' .. v .. '!')
            elseif manual then
                msg('У вас последняя версия.')
            end
        end)
    end)
end

-- Новый вход на сервер (в т.ч. реконнект) - проверить обновления заново
if hasSampev then
    function sampev.onInitGame() upd.joined = true end
end

local function startDownload()
    upd.state, upd.progress, upd.shown, upd.error, upd.newCode = 'downloading', 0.0, 0.0, nil, nil
    os.remove(TMP_SCRIPT)
    local started = pcall(downloadUrlToFile, upd.url .. '?t=' .. os.time(), TMP_SCRIPT, function(id, status, p1, p2)
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
                ulog('Ошибка: файл скрипта не скачался или повреждён.', true)
            end
        end
    end)
    if not started then
        upd.state = 'error'
        upd.error = 'Загрузчик занят, нажмите Повторить.'
    end
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
    local ranges = io.Fonts:GetGlyphRangesCyrillic()
    io.Fonts:Clear()
    local loaded = nil
    if font then loaded = io.Fonts:AddFontFromFileTTF(font, 16.0, nil, ranges) end
    if loaded == nil then
        print('[menu] font not loaded, using default')
        io.Fonts:AddFontDefault()
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
                upd.window[0], upd.state, upd.dismissed = false, 'idle', upd.latest
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
    if SAFE then
        local c = imgui.Checkbox(label .. id, ptr)
        return c
    end
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

-- Фура: x, y - левый верхний угол, s - масштаб (размер примерно 58s x 26s)
local function drawTruck(dl, x, y, s, body, cab, alpha)
    alpha = alpha or 1
    local function R(a, b, c, d, col, r)
        dl:AddRectFilled(vec(x + a * s, y + b * s), vec(x + c * s, y + d * s), col, (r or 0) * s)
    end
    local dark   = U32(V4(0.05, 0.06, 0.08, alpha))
    local wheel  = U32(V4(0.16, 0.17, 0.20, alpha))
    local hub    = U32(V4(0.70, 0.72, 0.78, alpha))
    local glass  = U32(V4(0.55, 0.80, 1.00, 0.85 * alpha))
    local light  = U32(V4(1.00, 0.85, 0.35, alpha))

    R(0, 0, 38, 18, body, 2)            -- прицеп
    R(2, 2, 36, 4, U32(V4(1, 1, 1, 0.12 * alpha)), 1) -- блик на прицепе
    R(38, 14, 41, 19, dark)             -- сцепка
    R(41, 3, 54, 19, cab, 2.5)          -- кабина
    R(54, 10, 58, 19, cab, 1.5)         -- капот
    R(47, 5, 53, 11, glass, 1)          -- окно
    R(56.5, 12, 58, 14, light)          -- фара
    R(0, 18.5, 58, 21, dark, 1)         -- рама
    for _, wx in ipairs({ 7, 15, 49 }) do
        dl:AddCircleFilled(vec(x + wx * s, y + 22 * s), 3.6 * s, wheel, 16)
        dl:AddCircleFilled(vec(x + wx * s, y + 22 * s), 1.4 * s, hub, 12)
    end
end

local function iconTruck(dl, c, col)
    drawTruck(dl, c.x - 9.3, c.y - 6, 0.32, col, col)
end

local function iconClose(dl, c, col)
    dl:AddLine(vec(c.x - 5, c.y - 5), vec(c.x + 5, c.y + 5), col, 2)
    dl:AddLine(vec(c.x + 5, c.y - 5), vec(c.x - 5, c.y + 5), col, 2)
end

-- Кнопка-вкладка в боковой панели
local function sidebarButton(id, name, icon, active)
    if SAFE then
        return imgui.Button((active and '> ' or '') .. name .. id, vec(-1, 36))
    end
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
    trace  = true,   -- пишет шаги первого кадра в moonloader.log (для поиска крашей)
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

-- ===================== Бот дальнобойщик =====================
local bot = { status = 'Выключен', driving = false, cp = nil, tx = nil, ty = nil,
              lastTask = 0, stuckSince = nil, pauseUntil = 0, arrived = false }

-- Чекпоинты сервера (красные метки) - нужна библиотека SAMP.Lua (lib/samp/events)
if hasSampev then
    function sampev.onSetCheckpoint(pos, radius)      bot.cp = { pos.x, pos.y, pos.z } end
    function sampev.onDisableCheckpoint()             bot.cp = nil end
    function sampev.onSetRaceCheckpoint(t, pos, nxt, size) bot.cp = { pos.x, pos.y, pos.z } end
    function sampev.onDisableRaceCheckpoint()         bot.cp = nil end
end

local function isArizona()
    local ok, name = pcall(sampGetCurrentServerName)
    if not ok or type(name) ~= 'string' then return false end
    local n = u8(name):lower()
    return n:find('arizona', 1, true) ~= nil or n:find('аризона', 1, true) ~= nil or n:find('Аризона', 1, true) ~= nil
end

local function botTarget()
    local src = tonumber(cfg.bot.source) or 0
    if src ~= 2 and bot.cp then return bot.cp[1], bot.cp[2], bot.cp[3], 'чекпоинт' end
    if src ~= 1 then
        local ok, x, y, z = getTargetBlipCoordinates()
        if ok then
            if not z or z == 0 then z = getGroundZFor3dCoord(x, y, 1000.0) end
            return x, y, z, 'метка на карте'
        end
    end
end

local function botStop()
    if bot.driving then
        clearCharTasks(PLAYER_PED)
        bot.driving = false
    end
end

-- Стили вождения GTA SA: 2 = объезжать машины, 4 = тормозить перед машинами.
-- Оба НЕ останавливаются на светофорах (стили 0/1/5/6 - останавливаются).
local function botStyle() return (tonumber(cfg.bot.style) or 0) == 1 and 4 or 2 end

-- Задача водителя сбрасывает стиль на свой, поэтому стиль и скорость
-- принудительно выставляются заново каждые 100 мс, пока бот едет
local function botEnforce(car)
    setCarDrivingStyle(car, botStyle())
    setCarCruiseSpeed(car, tonumber(cfg.bot.speed) or 25)
end

-- Свободна ли дорога прямо перед машиной (лучом от переднего бампера)
local function roadAheadClear(car, len)
    local _, _, _, _, maxY = getModelDimensions(getCarModel(car))
    local x1, y1, z1 = getOffsetFromCarInWorldCoords(car, 0, (maxY or 3) + 0.6, 0.4)
    local x2, y2, z2 = getOffsetFromCarInWorldCoords(car, 0, (maxY or 3) + 0.6 + len, 0.4)
    local hit = processLineOfSight(x1, y1, z1, x2, y2, z2, true, true, true, true, false, false, false, false)
    return not hit
end

-- Защита от светофоров: если машина почти встала, а впереди пусто,
-- ее принудительно толкают вперед. Так бот не стоит на красном ни при каком маршруте.
local function lightBreaker(car)
    if getCarSpeed(car) < 4.0 and roadAheadClear(car, 12) then
        setCarForwardSpeed(car, math.min(tonumber(cfg.bot.speed) or 25, 12))
        return true
    end
    return false
end

local function botDrive(car, x, y, z)
    -- Встроенный ИИ водителя GTA: едет по дорогам (path nodes), объезжает транспорт.
    local speed = tonumber(cfg.bot.speed) or 25
    taskCarDriveToCoord(PLAYER_PED, car, x, y, z, speed, 0, 0, botStyle())
    botEnforce(car)
    bot.driving, bot.lastTask, bot.tx, bot.ty = true, os.clock(), x, y
end

local function botThread()
    while true do
        wait(100)
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

                    if dist <= (tonumber(cfg.bot.radius) or 12) then
                        botStop()
                        if not bot.arrived then msg('Бот: прибыли (' .. name .. ').') end
                        bot.arrived, bot.status = true, 'Прибыл'
                    elseif manual then
                        botStop(); bot.pauseUntil = os.clock() + 3
                        bot.status = 'Управление у вас'
                    elseif os.clock() >= bot.pauseUntil then
                        bot.arrived = false
                        local moved = not bot.tx or getDistanceBetweenCoords2d(bot.tx, bot.ty, x, y) > 3
                        -- Застревание: почти не едем дольше 3 секунд - перестраиваем маршрут
                        if getCarSpeed(car) < 1.0 then
                            bot.stuckSince = bot.stuckSince or os.clock()
                        else
                            bot.stuckSince = nil
                        end
                        local stuck = bot.stuckSince and os.clock() - bot.stuckSince > 3
                        if not bot.driving or moved or stuck then
                            botDrive(car, x, y, z)
                            bot.stuckSince = nil
                        else
                            botEnforce(car)
                            if os.clock() - bot.lastTask > 1.0 and lightBreaker(car) then
                                bot.stuckSince = nil
                            end
                        end
                        bot.status = string.format('Едет: %s, %d м', name, math.floor(dist))
                    end
                end
            end
        end
    end
end

local bui = {
    enabled  = imgui.new.bool(cfg.bot.enabled),
    source   = imgui.new.int(tonumber(cfg.bot.source) or 0),
    speed    = imgui.new.int(tonumber(cfg.bot.speed) or 25),
    style    = imgui.new.int(tonumber(cfg.bot.style) or 0),
    radius   = imgui.new.int(tonumber(cfg.bot.radius) or 12),
    takeover = imgui.new.bool(cfg.bot.takeover),
}

local function drawFarmTab()
    section('Бот дальнобойщик')

    if SAFE then
        imgui.Text('Статус: ' .. bot.status)
    else
        -- Карточка с нарисованной фурой и статусом
        local dl = imgui.GetWindowDrawList()
        local p  = imgui.GetCursorScreenPos()
        local w  = imgui.GetContentRegionAvail().x
        local h  = 92
        dl:AddRectFilled(p, vec(p.x + w, p.y + h), U32(V4(ACCENT.x, ACCENT.y, ACCENT.z, 0.10)), 10)
        dl:AddLine(vec(p.x + 14, p.y + h - 16), vec(p.x + 150, p.y + h - 16), U32(V4(1, 1, 1, 0.10)), 2) -- дорога
        local sway = cfg.bot.enabled and bot.driving and math.sin(imgui.GetTime() * 12) * 0.6 or 0
        drawTruck(dl, p.x + 14, p.y + 14 + sway, 2.3, U32(V4(0.85, 0.87, 0.92, 1)), U32(ACCENT))
        local tx = p.x + 170
        dl:AddText(vec(tx, p.y + 22), U32(V4(1, 1, 1, 1)), 'Статус:')
        local scol = bot.driving and COLOR_GREEN or (cfg.bot.enabled and V4(1.0, 0.8, 0.35, 1) or COLOR_GRAY)
        dl:AddText(vec(tx, p.y + 44), U32(scol), bot.status)
        imgui.Dummy(vec(w, h))
    end

    if toggle('##bot_on', 'Включить бота', bui.enabled) then
        cfg.bot.enabled = bui.enabled[0]; saveCfg()
        if not cfg.bot.enabled then botStop() end
    end

    section('Куда ехать')
    if segmented('bot_src', bui.source, { 'Авто', 'Чекпоинт', 'Метка на карте' }) then
        cfg.bot.source = bui.source[0]; saveCfg(); bot.tx = nil
    end
    if not hasSampev then
        hint('Для красных чекпоинтов сервера установите библиотеку SAMP.Lua (lib/samp/events). Метка на карте работает и без неё.')
    end

    section('Вождение')
    if segmented('bot_style', bui.style, { 'Объезжать машины', 'Тормозить перед машинами' }) then
        cfg.bot.style = bui.style[0]; saveCfg(); bot.tx = nil
    end
    imgui.PushItemWidth(-1)
    imgui.Text('Скорость:')
    if imgui.SliderInt('##bot_speed', bui.speed, 5, 60, '%d') then
        cfg.bot.speed = bui.speed[0]; saveCfg(); bot.tx = nil
    end
    imgui.Text('Радиус прибытия:')
    if imgui.SliderInt('##bot_radius', bui.radius, 3, 40, '%d м') then
        cfg.bot.radius = bui.radius[0]; saveCfg()
    end
    imgui.PopItemWidth()
    if toggle('##bot_take', 'W / S забирают управление', bui.takeover) then
        cfg.bot.takeover = bui.takeover[0]; saveCfg()
    end
    hint('Бот едет по дорогам встроенным ИИ водителя GTA и светофоры не учитывает. Не работает на серверах Arizona RP.')
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
    imgui.Text('/ltruck');  imgui.SameLine(110); imgui.TextDisabled('вкл / выкл бота дальнобойщика')
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
    if SAFE then return end
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
    if SAFE then
        for i, pr in ipairs(PRESETS) do
            if i > 1 and (i - 1) % 4 ~= 0 then imgui.SameLine() end
            if imgui.Button(pr.name .. '##preset' .. i, vec(110, 28)) then
                cfg.theme.accent, cfg.theme.bg = pr.accent, pr.bg
                setColor3(tui.accent, pr.accent); setColor3(tui.bg, pr.bg)
                applyTheme(); saveCfg()
            end
        end
        return
    end
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
    { name = 'Авто фарм',  icon = iconTruck,  draw = drawFarmTab  },
    { name = 'Оформление', icon = iconPalette, draw = drawThemeTab },
    { name = 'Информация', icon = iconInfo,  draw = drawInfoTab  },
}

imgui.OnFrame(
    function() return menu.window[0] end,
    function(player)
        menu.frames = (menu.frames or 0) + 1
        local function T(s) if menu.trace then print('[menu] ' .. s) end end
        T('frame start')
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
        imgui.SetNextWindowSize(vec(700, 480), imgui.Cond.Always)
        imgui.Begin('##lua_afk_menu', menu.window,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
        T('begin ok')

        -- Частицы рисуются на фоне окна, панели поверх них полупрозрачные
        drawParticles(imgui.GetWindowDrawList(), imgui.GetWindowPos(), imgui.GetWindowSize())
        T('particles ok')

        -- Боковая панель: вкладки столбиком
        imgui.BeginChild('##sidebar', vec(190, 0), true)
        T('sidebar begin')
        centerText('lua_afk', ACCENT)
        centerText('v' .. SCRIPT_VERSION, COLOR_GRAY)
        imgui.Spacing(); imgui.Separator(); imgui.Spacing()

        for i, tab in ipairs(TABS) do
            if sidebarButton('##tab' .. i, tab.name, tab.icon, menu.tab == i) then menu.tab = i end
            T('tab button ' .. i)
        end

        -- Кнопка закрытия внизу панели
        imgui.SetCursorPosY(imgui.GetWindowHeight() - 40 - imgui.GetStyle().WindowPadding.y)
        if sidebarButton('##close', 'Закрыть', iconClose, false) then menu.window[0] = false end
        imgui.EndChild()

        imgui.SameLine()

        -- Содержимое вкладки
        imgui.BeginChild('##content', vec(0, 0), true)
        T('content begin')
        local tab = TABS[menu.tab]
        imgui.TextColored(ACCENT, tab.name)
        tab.draw()
        T('tab drawn')
        imgui.EndChild()

        imgui.End()
        T('frame end')
        menu.trace = false
        if menu.frames <= 600 and menu.frames % 30 == 0 then print('[menu] frame ' .. menu.frames .. ' ok') end
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
local function cmdMenu(arg)
    SAFE = tostring(arg or ''):lower():find('safe', 1, true) ~= nil
    if SAFE then msg('Меню в простом режиме.') end
    menu.trace, menu.frames = true, 0
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
    lua_thread.create(botThread)
    sampRegisterChatCommand('ltruck', function()
        cfg.bot.enabled = not cfg.bot.enabled; bui.enabled[0] = cfg.bot.enabled; saveCfg()
        if not cfg.bot.enabled then botStop() end
        msg(cfg.bot.enabled and 'Бот дальнобойщик включён.' or 'Бот дальнобойщик выключен.')
    end)

    -- Проверяем обновления после входа на сервер (когда персонаж заспавнился)
    -- Автопроверка: при запуске, при каждом входе на сервер и каждые 5 минут
    lua_thread.create(function()
        local t = os.time()
        while not sampIsLocalPlayerSpawned() and os.time() - t < 20 do wait(500) end
        wait(1500)
        checkUpdates(false)
        upd.joined = false
        local last = os.time()
        while true do
            wait(1000)
            if upd.joined then
                upd.joined = false
                wait(5000)
                last = os.time()
                checkUpdates(false)
            elseif os.time() - last >= 300 then
                last = os.time()
                checkUpdates(false, true)
            end
        end
    end)

    while true do
        wait(0)

        if upd.state == 'installing' and (upd.shown >= 0.999 or not upd.window[0]) then
            wait(500)
            if installUpdate() then return end
        end
    end
end

function onScriptTerminate(s, quit)
    if s == thisScript() and not quit and bot and bot.driving then clearCharTasks(PLAYER_PED) end
end
