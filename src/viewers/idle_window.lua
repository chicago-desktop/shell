-- Тело записи окна-вида.
--
-- Окно с `window_content: pixels` композитор не запускает: рисует его тема,
-- данные приносит поставщик состояния. Запись при этом обязана быть
-- процессом — так её находит каталог, — и этот файл существует ради формы.
-- Если он всё же запущен, значит запись открыли не как вид; тогда он
-- просто ждёт, пока его погасят, и ничего не рисует.
local channel = require("channel")
local time = require("time")

local function main()
    while true do
        local picked = channel.select({time.after("30s"):case_receive()})
        if not picked.ok then break end
    end
end

return {main = main}
