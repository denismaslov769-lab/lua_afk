-- lua_afk.lua
-- Скрипт для Arizona Role Play (SA-MP, MoonLoader)

script_name('lua_afk')
script_author('denismaslov769-lab')
script_version('0.1.0')
script_description('Базовый скрипт для Arizona RP')

local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local TAG = '{33AAFF}[lua_afk]{FFFFFF} '
local enabled = false

-- Сообщение в чат (текст в файле хранится в UTF-8, игра использует CP1251)
local function msg(text)
    sampAddChatMessage(TAG .. u8:decode(text), -1)
end

-- Команда /lafk — включить/выключить скрипт
local function cmdToggle()
    enabled = not enabled
    msg(enabled and 'Скрипт включён.' or 'Скрипт выключен.')
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand('lafk', cmdToggle)
    msg('Загружен. Команда: /lafk')

    while true do
        wait(0)
        if enabled then
            -- TODO: основная логика скрипта
        end
    end
end
