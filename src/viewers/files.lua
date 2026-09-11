-- A file on a registry drive: how to name it in one string and how to read it.
--
-- A viewer is opened by the compositor with one string argument — the same
-- `args` any application window receives. Here that argument is assembled and
-- parsed, and this is the ONLY place where its form is known: the explorer
-- calls `encode`, the window calls `parse`, and neither of them knows that
-- there is JSON inside. Had the explorer parsed it its own way, the very
-- first file with a space in its name would have opened the wrong thing.
--
-- A drive is a registry entry (`fs.directory`, `fs.embed`), not a path on the
-- machine: the file is read by the `fs` module under the window's own
-- permissions, and a window with permission on a drive entry does not get
-- permission on a directory past it.

local fs = require("fs")
local json = require("json")

local files = {}

-- Caps. Notepad on a megabyte of text in a terminal is already useless, and
-- a picture over eight megabytes travels between processes in base64 on every
-- key press — that is not a size for a viewer but a size for a refusal with a
-- reason.
files.MAX_TEXT = 1 << 20
files.MAX_IMAGE = 8 << 20

-- encode(drive, path) -> argument string
function files.encode(drive: any, path: any): string
    return json.encode({drive = tostring(drive), path = tostring(path)})
end

-- name_of(path) -> file name without the directory
function files.name_of(path: any): string
    local text = tostring(path or "")
    return text:match("([^/]+)/*$") or text
end

-- ext(name) -> extension in lower case without the dot, or ""
--
-- The extension is what the explorer picks a program by, so case is removed
-- here, once: `Photo.PNG` and `photo.png` are one and the same kind.
function files.ext(name: any): string
    local text = files.name_of(name)
    -- A leading dot is a hidden file, not an extension: `.bashrc` has none.
    if text:sub(1, 1) == "." and not text:sub(2):find(".", 1, true) then return "" end
    local ext = text:match("%.([^%.]+)$")
    if not ext or ext == text then return "" end
    return ext:lower()
end

-- parse(args) -> {drive, path, name, ext} | nil, reason
function files.parse(args: any): (any, any)
    if type(args) ~= "string" or args == "" then
        return nil, "the window was not told which file to open"
    end
    local decoded: any = json.decode(args)
    if type(decoded) ~= "table" then
        return nil, "window argument not parsed: " .. args
    end
    local drive, path = decoded.drive, decoded.path
    if type(drive) ~= "string" or drive == "" or type(path) ~= "string" or path == "" then
        return nil, "the window argument has no drive or path"
    end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return {drive = drive, path = path, name = files.name_of(path), ext = files.ext(path)}, nil
end

-- read(drive, path, limit) -> bytes | nil, reason
--
-- The refusal names WHAT did not open: the drive or the file. "Not read"
-- without an address sends a person to check permissions where nobody
-- touched them.
function files.read(drive: any, path: any, limit: any): (any, any)
    local handle, err = fs.get(tostring(drive))
    if err or not handle then
        return nil, "drive " .. tostring(drive) .. " not opened: " .. tostring(err or "no such entry")
    end
    local data, read_err = handle:readfile(tostring(path))
    if read_err or type(data) ~= "string" then
        return nil, "file " .. tostring(path) .. " not read: " .. tostring(read_err)
    end
    local cap = math.tointeger(tonumber(limit) or 0) or 0
    if cap > 0 and #data > cap then
        return nil, string.format("file %s is too large: %d bytes against a limit of %d",
            tostring(path), #data, cap)
    end
    return data, nil
end

-- human_size(bytes) -> "12 KB"
function files.human_size(bytes: any): string
    local n = tonumber(bytes) or 0
    if n < 1024 then return string.format("%d bytes", n) end
    if n < 1024 * 1024 then return string.format("%d KB", n // 1024) end
    return string.format("%.1f MB", n / (1024 * 1024))
end

return files
