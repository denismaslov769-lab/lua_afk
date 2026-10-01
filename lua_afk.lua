-- lua_afk.lua
-- Скрипт для Arizona Role Play (SA-MP, MoonLoader)
-- Требуется: MoonLoader, SAMPFUNCS, mimgui

script_name('lua_afk')
script_author('denismaslov769-lab')
script_version('0.3.0')
script_description('Скрипт для Arizona RP: меню, авто спавн, автообновление')

local imgui    = require('mimgui')
local encoding = require('encoding')
local dlstatus = require('moonloader').download_status
local inicfg   = require('inicfg')
local ffi      = require('ffi')

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ===================== Настройки =====================
local SCRIPT_VERSION = '0.3.0'
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

local function applyStyle()
    local style = imgui.GetStyle()
    local c, col = style.Colors, imgui.Col

    style.WindowPadding    = imgui.ImVec2(18, 16)
    style.FramePadding     = imgui.ImVec2(10, 6)
    style.ItemSpacing      = imgui.ImVec2(10, 10)
    style.WindowRounding   = 12
    style.FrameRounding    = 8
    style.WindowBorderSize = 1
    style.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)

    c[col.WindowBg]         = V4(0.07, 0.08, 0.11, 0.97)
    c[col.Border]           = V4(0.20, 0.55, 1.00, 0.40)
    c[col.TitleBg]          = V4(0.10, 0.12, 0.17, 1.00)
    c[col.TitleBgActive]    = V4(0.12, 0.16, 0.25, 1.00)
    c[col.Text]             = V4(0.92, 0.94, 0.97, 1.00)
    c[col.TextDisabled]     = COLOR_GRAY
    c[col.Separator]        = V4(0.20, 0.55, 1.00, 0.25)
    c[col.FrameBg]          = V4(0.13, 0.15, 0.20, 1.00)
    c[col.PlotHistogram]    = V4(0.20, 0.60, 1.00, 1.00) -- заливка прогресс-бара
    c[col.Button]           = V4(0.20, 0.47, 0.95, 1.00)
    c[col.ButtonHovered]    = V4(0.28, 0.56, 1.00, 1.00)
    c[col.ButtonActive]     = V4(0.15, 0.38, 0.85, 1.00)

    style.ChildRounding    = 10
    style.GrabRounding     = 8
    style.GrabMinSize      = 14
    style.ChildBorderSize  = 1
    style.ScrollbarRounding = 8
    c[col.ChildBg]          = V4(0.10, 0.11, 0.15, 1.00)
    c[col.PopupBg]          = V4(0.09, 0.10, 0.14, 0.98)
    c[col.FrameBgHovered]   = V4(0.17, 0.19, 0.26, 1.00)
    c[col.FrameBgActive]    = V4(0.20, 0.23, 0.32, 1.00)
    c[col.SliderGrab]       = V4(0.25, 0.60, 1.00, 1.00)
    c[col.SliderGrabActive] = V4(0.40, 0.70, 1.00, 1.00)
    c[col.CheckMark]        = V4(0.30, 0.65, 1.00, 1.00)
    c[col.ScrollbarBg]      = V4(0.08, 0.09, 0.12, 1.00)
    c[col.ScrollbarGrab]    = V4(0.20, 0.23, 0.30, 1.00)
    c[col.TextSelectedBg]   = V4(0.20, 0.55, 1.00, 0.35)
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

    applyStyle()
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
local ACCENT = V4(0.25, 0.60, 1.00, 1.00)
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
local function iconSpawn(dl, c, col)
    dl:AddCircleFilled(vec(c.x, c.y - 3), 6.5, col, 24)
    dl:AddTriangleFilled(vec(c.x - 5.6, c.y), vec(c.x + 5.6, c.y), vec(c.x, c.y + 8), col)
    dl:AddCircleFilled(vec(c.x, c.y - 3), 2.6, U32(V4(0.10, 0.11, 0.15, 1)), 16)
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

local TABS = {
    { name = 'Авто спавн', icon = iconSpawn, draw = drawSpawnTab },
    { name = 'Информация', icon = iconInfo,  draw = drawInfoTab  },
}

imgui.OnFrame(
    function() return menu.window[0] end,
    function(player)
        local sw, sh = getScreenResolution()
        imgui.SetNextWindowPos(vec(sw / 2, sh / 2), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
        imgui.SetNextWindowSize(vec(660, 430), imgui.Cond.Always)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, vec(10, 10))
        imgui.Begin('##lua_afk_menu', menu.window,
            imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
        imgui.PopStyleVar()

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
