-- Спецификация запуска через штатное PTY-окно основы; прав на запуск нет.
-- Редактор строки у диалога больше не свой: его даёт `sdk:editor`.
local model = {}
model.PTY = "butschster.tui_desktop.desktop:window_pty"

function model.spec(text)
    local command = tostring(text or ""):match("^%s*(.-)%s*$")
    if command == "" then return nil, "Type the name of a program or command." end
    -- exec parses argv without expansion. Bash evaluates exactly the user's
    -- command, with its normal interactive setup; afterwards the prompt stays.
    local script = command .. "\nexec /bin/bash -i"
    local quoted = "'" .. script:gsub("'", "'\"'\"'") .. "'"
    return {entry = model.PTY, title = command, image = "program",
        command = "/bin/bash -ic " .. quoted, w = 80, h = 24}, nil
end

return model
