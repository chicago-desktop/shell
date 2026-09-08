-- Блокнот — просмотр текстовых файлов с диска реестра.
--
-- Окно в ячейках, как калькулятор: само открывает поверхность своего порта
-- и рисует кадры; рамку, заголовок и кнопки рисует тема. Файл приходит
-- аргументом открытия — строкой, которую собрал проводник через `files`, и
-- читается модулем `fs` под правами самого окна: доступ есть к записи
-- диска, а не к каталогу на машине.
--
-- Только чтение. Блокнот, который умеет писать, — это редактор, и у него
-- другие обязанности: сохранение, спросить перед закрытием, откат. Здесь
-- их нет, и окно этого не скрывает — в статусной строке так и написано.
--
-- Строки не переносятся, как в Windows 95 по умолчанию: длинная строка
-- уезжает вправо, и её прокручивают стрелками. Перенос делал бы из одной
-- строки файла три строки на экране, и номер строки в статусе врал бы.

local channel = require("channel")
local tty = require("tty")

local files = require("files")
local widgets = require("widgets")

local TAB = "    "
local LINE_CAP = 4000

local styles = widgets.styles

-- Разбить строку на символы UTF-8. Библиотеки `utf8` в Lua рантайма нет —
-- окно с `utf8.codes` умирало на первом кадре, и снаружи это выглядело как
-- «щёлкнул — ничего не открылось».
local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Файл → строки. Табуляция раскрывается пробелами: терминал рисует её сам и
-- по-своему, и колонка, посчитанная здесь, не совпала бы с экраном.
local function split_lines(text: string): {string}
    local lines: {string} = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", ""):gsub("\t", TAB)
        if #line > LINE_CAP then line = line:sub(1, LINE_CAP) end
        lines[#lines + 1] = line
    end
    if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
        lines[#lines] = nil
    end
    return lines
end

-- Отрезать `skip` ячеек слева, отдать не больше `room` ячеек. По символам,
-- а не по байтам: кириллица — два байта на ячейку, и срез по байтам делил
-- бы букву пополам.
local function slice(text: any, skip_cells: any, room_cells: any): string
    local line, skip, room = tostring(text or ""), whole(skip_cells), whole(room_cells)
    if room < 1 then return "" end
    local out, used, passed = {}, 0, 0
    for char in line:gmatch(UTF8_CHAR) do
        local w = widgets.cells(char)
        if passed < skip then
            passed = passed + w
        else
            if used + w > room then break end
            out[#out + 1] = char
            used = used + w
        end
    end
    return table.concat(out)
end

local function draw(out, canvas, width: any, height: any, doc: any)
    local w, h = whole(width), whole(height)
    canvas:clear(styles.field:render(" "))

    local text_rows = h - 1
    local blank = styles.field:render(string.rep(" ", w))
    for row = 1, text_rows do canvas:put(1, row, blank, w) end

    if doc.failure then
        canvas:put(2, 1, widgets.fit(styles.field, tostring(doc.failure), w - 2), w - 2)
    else
        for row = 1, text_rows do
            local line = doc.lines[doc.top + row]
            if not line then break end
            local shown = slice(line, doc.left, w - 1)
            if shown ~= "" then
                canvas:put(1, row, styles.field:render(shown), w - 1)
            end
        end
    end

    local position = doc.failure and "" or string.format("Стр %d из %d", math.min(doc.top + 1, math.max(1, #doc.lines)), #doc.lines)
    local column = doc.left > 0 and string.format("Кол +%d", doc.left) or ""
    widgets.statusbar(canvas, 1, h, w, {
        {text = doc.name .. " · " .. files.human_size(doc.size) .. " · только чтение"},
        {text = position, width = 16},
        {text = column, width = 10},
    })

    assert(out:present(canvas:rows(), {cursor = {x = 1, y = 1, visible = false}}))
end

local function main(argument)
    local events = assert(tty.events())
    assert(tty.start())

    local out = assert(tty.surface({hide_cursor = true, synchronized_output = true}))

    local width, height = tty.screen_size()
    width, height = whole(width), whole(height)
    if width < 10 then width = 60 end
    if height < 3 then height = 18 end

    local doc: any = {lines = {}, top = 0, left = 0, name = "", size = 0, failure = nil}

    local file, why = files.parse(argument)
    if not file then
        doc.failure = why
    else
        doc.name = file.name
        local text, read_err = files.read(file.drive, file.path, files.MAX_TEXT)
        if not text then
            doc.failure = read_err
        else
            doc.size = #text
            doc.lines = split_lines(text :: string)
        end
    end

    local canvas = tty.canvas(width, height)
    draw(out, canvas, width, height, doc)

    local function page(): integer return whole(math.max(1, height - 1)) end
    local function scroll_to(wanted: any)
        local max_top = math.max(0, #doc.lines - page())
        doc.top = math.max(0, math.min(max_top, whole(wanted)))
    end

    while true do
        local selected = channel.select({events:case_receive()})
        if not selected.ok then break end
        local event = selected.value

        if event.type == "close" then
            break
        elseif event.type == "resize" then
            local w, h = whole(event.width), whole(event.height)
            if w >= 10 then width = w end
            if h >= 3 then height = h end
            canvas = tty.canvas(width, height)
            scroll_to(doc.top)
            draw(out, canvas, width, height, doc)
        elseif event.type == "key" and event.action ~= "release" then
            local key = tostring(event.key or "")
            if key == "down" then scroll_to(doc.top + 1)
            elseif key == "up" then scroll_to(doc.top - 1)
            elseif key == "pgdown" or key == " " then scroll_to(doc.top + page())
            elseif key == "pgup" then scroll_to(doc.top - page())
            elseif key == "home" then scroll_to(0); doc.left = 0
            elseif key == "end" then scroll_to(#doc.lines)
            elseif key == "right" then doc.left = doc.left + 8
            elseif key == "left" then doc.left = math.max(0, doc.left - 8)
            end
            draw(out, canvas, width, height, doc)
        elseif event.type == "mouse" and event.action == "wheel" then
            if event.button == "wheel_down" then scroll_to(doc.top + 3)
            elseif event.button == "wheel_up" then scroll_to(doc.top - 3) end
            draw(out, canvas, width, height, doc)
        end
    end

    assert(out:close())
    assert(tty.stop())
end

return {main = main}
