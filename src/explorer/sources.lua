-- Откуда «Мой компьютер» берёт объекты.
--
-- Отделено от сборки объектов нарочно: сборка — чистое правило и проверяется
-- без живой базы, а здесь только чтение. Правило, проверяемое только через
-- базу, проверяется один раз, а потом никогда.
--
-- Открытых окон здесь НЕТ, и это не пропуск. Список окон живёт у композитора,
-- и спросить его можно только сообщением с ответом в собственный inbox. Внутри
-- окна так делать нельзя: ждущий цикл забирает из inbox и ЧУЖИЕ сообщения
-- тоже, а выбросить сообщение, адресованное окну, — значит потерять команду
-- композитора без следа. Поэтому список окон приносит сам процесс окна: его
-- цикл владеет inbox и разбирает ответ наравне с остальным, а `model.windows`
-- превращает принесённое в объекты.

local catalog = require("catalog")
local model = require("model")
local repo = require("repo")

local sources = {}

-- list(path) -> (объекты, nil) | (nil, причина)
--
-- Отказ и пустая папка различаются ПЕРВЫМ значением: пустая папка — таблица,
-- нечитаемый источник — nil и причина. Одинаковые, они отправляют человека
-- искать пропажу там, где ничего не пропадало.
function sources.list(path)
    if path == "programs" then
        local found, err = catalog.list()
        if err or not found then return nil, err or "каталог не прочитан" end
        return model.programs(found.programs), nil
    end

    if path == "desktop" then
        local items, err = repo.list()
        if err then return nil, "раскладка не прочитана: " .. tostring(err) end
        -- Каталог нужен, чтобы отличить битый ярлык от исправного. Его отказ
        -- НЕ прячет стол: объекты отдаются, просто все без признака битости —
        -- обвинить исправную программу хуже, чем промолчать.
        local found = catalog.list()
        return model.desktop(items or {}, found and found.programs or nil), nil
    end

    return nil, "неизвестная папка: " .. tostring(path)
end

-- counts() -> (счётчики, nil)
--
-- Для корня. Источник, который не прочитался, остаётся БЕЗ числа, а не с
-- нулём: ноль сказал бы «пусто», то есть утверждение, которого мы не делали.
function sources.counts()
    local out: any = {}

    local found = catalog.list()
    if found then out.programs = #found.programs end

    local items = repo.list()
    if items then out.desktop = #items end

    return out, nil
end

return sources
