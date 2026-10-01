-- lua_afk.lua
-- Скрипт для Arizona Role Play (SA-MP, MoonLoader)
-- Требуется: MoonLoader, SAMPFUNCS, mimgui

script_name('lua_afk')
script_author('denismaslov769-lab')
script_version('0.2.0')
script_description('Скрипт для Arizona RP с автообновлением')

local imgui    = require('mimgui')
local encoding = require('encoding')
local dlstatus = require('moonloader').download_status

encoding.default = 'CP1251'
local u8 = encoding.UTF8

-- ===================== Настройки =====================
local SCRIPT_VERSION = '0.2.0'
local REPO_RAW    = 'https://raw.githubusercontent.com/denismaslov769-lab/lua_afk/main/'
local VERSION_URL = REPO_RAW .. 'version.json'
local SCRIPT_URL  = REPO_RAW .. 'lua_afk.lua'

local TMP_DIR     = os.getenv('TEMP') or getWorkingDirectory()
local TMP_VERSION = TMP_DIR .. '\\lua_afk_version.json'
local TMP_SCRIPT  = TMP_DIR .. '\\lua_afk_update.lua'

local TAG = '{33AAFF}[lua_afk]{FFFFFF} '
local enabled = false

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
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil

    -- Шрифт с поддержкой кириллицы
    local fontsDir = getFolderPath(0x14)
    local font = fontsDir .. '\\trebucbd.ttf'
    if not doesFileExist(font) then font = fontsDir .. '\\arial.ttf' end
    io.Fonts:Clear()
    io.Fonts:AddFontFromFileTTF(font, 16.0, nil, io.Fonts:GetGlyphRangesCyrillic())

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

-- ===================== Команды =====================
-- /lafk - включить/выключить скрипт
local function cmdToggle()
    enabled = not enabled
    msg(enabled and 'Скрипт включён.' or 'Скрипт выключен.')
end

-- ===================== Главный цикл =====================
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('lafk', cmdToggle)
    sampRegisterChatCommand('lafkupd', function() checkUpdates(true) end)
    msg('Загружен v' .. SCRIPT_VERSION .. '. Команды: /lafk, /lafkupd')

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

        if enabled then
            -- TODO: основная логика скрипта
        end
    end
end
