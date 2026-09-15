-- windows.shell.antibug:targets — scan targets beyond the registry
-- (FR-009 §4a), pure.
--
-- A target is a registry entry of the application with `meta.type:
-- windows.antibug_target`: a module working copy run through the wippy test
-- runner (`kind: wippy`) or a Go module run through `go test -json` (`kind:
-- go`). This file knows the declarations, the command of each kind, and the
-- two parsers that turn the child's output into the events the scan model
-- already reads — `test:case:pass|fail|skip` — plus three of its own:
--   antibug:progress  {known?, entry?}   the runner's "N tests in M suites",
--                                         and the entry now running
--   antibug:detail    {test, error}      a failure's text, which the wippy
--                                         runner prints only at the end
--   antibug:exit      {code?, stopped?, error?}  sent by the target process
--
-- The child's environment is the declaration's `meta.env`: exec.native does
-- not inherit the OS environment, and a `${env:…}` placeholder in a module's
-- entry fails the whole boot where the variable is not in the environment
-- registry (measured in this harness). `go` needs PATH and a HOME or its
-- cache directories; the wippy runner needs HOME and PATH, and so do the
-- harnesses it boots.
--
-- Output arrives in chunks that split lines anywhere: a parser keeps the
-- partial line until its newline comes (`feed`), and `flush` ends it.
local json = require("json")

local targets = {}

targets.TYPE = "windows.antibug_target"
targets.DEFAULT_WIPPY = "wippy"
targets.DEFAULT_HOST = "wippy.terminal:host"
-- Every child runs at the lowest priority. A module's suite or a Go build
-- takes every core, and the shell the person is using must stay responsive:
-- on the live shell (2026-09-14) a scan of the runtime wrote 19385 build-cache
-- files in ten minutes while OK and × went unanswered.
targets.NICE = "nice -n 19 "
-- How many output lines of a failed Go test become its `Infected by`.
targets.TAIL = 12

local function text_of(value: any): string
    return type(value) == "string" and value or ""
end

local function env_of(value: any): any
    local out: any = {}
    if type(value) ~= "table" then return out end
    for key, item in pairs(value) do out[tostring(key)] = tostring(item) end
    return out
end

-- entries(found) -> the declared targets, sorted by order and title:
-- `{id, title, kind, dir, wippy, host, env, order, problem?}`. A declaration
-- that cannot run says why in `problem` and is still listed — hidden, it
-- would read as "the target is not declared".
function targets.entries(found: any): any
    local out: any = {}
    for _, entry in ipairs(type(found) == "table" and found or {}) do
        local meta: any = type(entry.meta) == "table" and entry.meta or {}
        if meta.type == targets.TYPE then
            local target: any = {id = tostring(entry.id), title = text_of(meta.title) ~= "" and text_of(meta.title) or tostring(entry.id),
                kind = text_of(meta.kind), dir = text_of(meta.dir), wippy = text_of(meta.wippy),
                host = text_of(meta.host), env = env_of(meta.env), order = tonumber(meta.order) or 0}
            target.problem = targets.problem(target)
            out[#out + 1] = target
        end
    end
    table.sort(out, function(a: any, b: any): boolean
        if a.order ~= b.order then return a.order < b.order end
        return a.title < b.title
    end)
    return out
end

local function unsafe(value: string): boolean
    return value:find("[\"\n\r%z]") ~= nil
end

-- problem(target) -> why the target cannot run, or nil.
function targets.problem(target: any): any
    if target.kind ~= "wippy" and target.kind ~= "go" then
        return "unknown kind '" .. tostring(target.kind) .. "' (wippy or go)"
    end
    if text_of(target.dir) == "" then return "no directory" end
    if unsafe(text_of(target.dir)) or unsafe(text_of(target.wippy)) or unsafe(text_of(target.host)) then
        return "a quote or a line break in the declaration"
    end
    for key, value in pairs(type(target.env) == "table" and target.env or {}) do
        if not tostring(key):match("^[%a_][%w_]*$") then return "a bad environment name '" .. tostring(key) .. "'" end
        if tostring(value):find("[\n\r%z]") then return "a line break in the environment variable " .. tostring(key) end
    end
    return nil
end

-- command(target) -> {cmd, work_dir, env?}, or nil and the reason. No shell:
-- the exec module splits the string itself, honouring quotes.
function targets.command(target: any): (any, any)
    local why = targets.problem(target)
    if why then return nil, why end
    local env: any = nil
    for key, value in pairs(type(target.env) == "table" and target.env or {}) do
        env = env or {}
        env[key] = value
    end
    if target.kind == "go" then
        return {cmd = targets.NICE .. "go test -json ./...", count = targets.NICE .. "go list ./...",
            work_dir = target.dir, env = env}, nil
    end
    local binary = text_of(target.wippy) ~= "" and target.wippy or targets.DEFAULT_WIPPY
    local host = text_of(target.host) ~= "" and target.host or targets.DEFAULT_HOST
    return {cmd = targets.NICE .. "\"" .. binary .. "\" test --host \"" .. host .. "\"",
        work_dir = target.dir .. "/test", env = env}, nil
end

-- plain(text) -> the text without ANSI escapes.
function targets.plain(text: any): string
    local out = tostring(text or ""):gsub("\27%[[%d;?]*[%a]", "")
    return out
end

-- seconds(text) -> the runner's duration text in seconds: "<1ms", "12ms", "1.2s".
function targets.seconds(text: any): number
    local value = tostring(text or "")
    if value:sub(1, 1) == "<" then return 0 end
    local ms = value:match("^([%d%.]+)ms$")
    if ms then return (tonumber(ms) or 0) / 1000 end
    local s = value:match("^([%d%.]+)s$")
    return tonumber(s) or 0
end

local function event(list: any, kind: string, data: any)
    list[#list + 1] = {type = kind, data = data}
end

-- ─── the wippy test runner's text ───────────────────────────────────────
--
-- The runner (wippy/test display.lua) writes a progress line that later
-- segments overwrite with "\r": "  ⠋ <suite> (i/n) <entry>  <bar> <pct>";
-- a case "    o <name> <duration>", "    x <name>", "    - <name> (skipped)";
-- a suite "  o|x <suite> (<count>) …"; then "  Failures" with blocks of
-- "    <describe> > <test>" and the error lines, a blank line between; and
-- "  PASSED|FAILED" with "  N passed  M failed  …" or "  N tests  …".

local function wippy_segment(parser: any, raw: string, out: any)
    local line = targets.plain(raw):gsub("%s+$", "")
    if parser.failures then
        if line == "" then
            if parser.key then
                event(out, "antibug:detail", {test = parser.key:match(".* > (.+)$") or parser.key,
                    error = table.concat(parser.error_lines, "\n")})
                parser.key, parser.error_lines = nil, {}
            end
            return
        end
        if line:match("^  PASSED") or line:match("^  FAILED") then
            parser.failures = false
        elseif parser.key == nil then
            parser.key = line:gsub("^%s+", "")
            return
        else
            parser.error_lines[#parser.error_lines + 1] = line:gsub("^%s+", "")
            return
        end
    end
    if line == "" then return end
    local known = line:match("^%s*(%d+) tests in %d+ suites?$")
    if known then
        event(out, "antibug:progress", {known = tonumber(known)})
        return
    end
    local suite, index, count, entry = line:match("^  %S+ (%S+) %((%d+)/(%d+)%) (%S+)")
    if suite then
        if entry ~= parser.entry then
            parser.entry = entry
            event(out, "antibug:progress", {entry = entry, suite = suite, index = tonumber(index), count = tonumber(count)})
        end
        return
    end
    local passed, took = line:match("^    o (.-) (<?[%d%.]+m?s)$")
    if passed then
        event(out, "test:case:pass", {suite = parser.entry or "", test = passed, duration = targets.seconds(took)})
        return
    end
    local skipped = line:match("^    %- (.-) %(skipped%)$")
    if skipped then
        event(out, "test:case:skip", {suite = parser.entry or "", test = skipped})
        return
    end
    local failed = line:match("^    x (.+)$")
    if failed then
        event(out, "test:case:fail", {suite = parser.entry or "", test = failed, error = ""})
        return
    end
    if line:match("^  Failures$") then
        parser.failures, parser.key, parser.error_lines = true, nil, {}
        return
    end
    -- The runner's own refusals ("Error: …") are the reason of a bad exit.
    if line:match("^Error:") then parser.errors[#parser.errors + 1] = line end
end

-- ─── go test -json ──────────────────────────────────────────────────────

local function short_package(name: string): string
    local tail = name:match("([^/]+/[^/]+)$")
    return tail or name
end

local function keep(list: any, line: string, limit: integer)
    list[#list + 1] = line
    while #list > limit do table.remove(list :: {any}, 1) end
end

local function go_line(parser: any, raw: string, out: any)
    local line = raw:gsub("%s+$", "")
    if line == "" then return end
    local ok, record = pcall(json.decode, line)
    if not ok or type(record) ~= "table" then
        keep(parser.stray, line, targets.TAIL)
        return
    end
    local action = text_of(record.Action)
    local package = text_of(record.Package)
    local test = text_of(record.Test)
    if action == "build-output" then
        local path = text_of(record.ImportPath)
        parser.build[path] = parser.build[path] or {}
        keep(parser.build[path], text_of(record.Output):gsub("\n$", ""), targets.TAIL)
        return
    end
    if action == "start" and package ~= "" then
        event(out, "antibug:progress", {entry = short_package(package)})
        return
    end
    local key = package .. "\0" .. test
    if action == "output" then
        local text = text_of(record.Output):gsub("\n$", "")
        if test == "" then
            parser.package_output[package] = parser.package_output[package] or {}
            keep(parser.package_output[package], text, targets.TAIL)
        elseif not text:match("^=== ") and not text:match("^%s*%-%-%- ") then
            parser.output[key] = parser.output[key] or {}
            keep(parser.output[key], text, targets.TAIL)
        end
        return
    end
    if test ~= "" then
        local suite = short_package(package)
        if action == "run" then
            event(out, "test:case:start", {suite = suite, test = test})
        elseif action == "pass" then
            event(out, "test:case:pass", {suite = suite, test = test, duration = tonumber(record.Elapsed) or 0})
        elseif action == "skip" then
            event(out, "test:case:skip", {suite = suite, test = test})
        elseif action == "fail" then
            parser.failed_in[package] = true
            local lines: any = parser.output[key] or {}
            event(out, "test:case:fail", {suite = suite, test = test, duration = tonumber(record.Elapsed) or 0,
                error = #lines > 0 and table.concat(lines, "\n") or "failed (a subtest failed)"})
        end
        return
    end
    -- A package's own result. A build that failed is one finding; a package
    -- that failed with no failed test (a panic, a timeout) is one too.
    if action == "fail" then
        local built = text_of(record.FailedBuild)
        if built ~= "" then
            local lines: any = parser.build[built] or {}
            event(out, "test:case:fail", {suite = short_package(package), test = "[build failed]",
                error = #lines > 0 and table.concat(lines, "\n") or "build failed"})
        elseif not parser.failed_in[package] then
            local lines: any = parser.package_output[package] or {}
            event(out, "test:case:fail", {suite = short_package(package), test = "[package failed]",
                error = #lines > 0 and table.concat(lines, "\n") or "package failed"})
        end
    end
end

-- parser(kind) -> a parser for the output of a target of that kind.
function targets.parser(kind: any): any
    return {kind = kind == "go" and "go" or "wippy", buffer = "", entry = nil, failures = false,
        key = nil, error_lines = {}, errors = {}, stray = {}, build = {}, output = {},
        package_output = {}, failed_in = {}}
end

local function line_of(parser: any, line: string, out: any)
    if parser.kind == "go" then
        go_line(parser, line, out)
        return
    end
    -- One physical line may carry several overwritten segments.
    for segment in string.gmatch(line .. "\r", "([^\r]*)\r") do wippy_segment(parser, segment, out) end
end

-- feed(parser, chunk) -> the events of the complete lines in the chunk.
function targets.feed(parser: any, chunk: any): any
    local out: any = {}
    local data = parser.buffer .. tostring(chunk or "")
    local start = 1
    while true do
        local stop = data:find("\n", start, true)
        if not stop then break end
        line_of(parser, data:sub(start, stop - 1), out)
        start = stop + 1
    end
    parser.buffer = data:sub(start)
    return out
end

-- flush(parser) -> the events of the last, unterminated line and of a
-- failure block that ended without a blank line.
function targets.flush(parser: any): any
    local out: any = {}
    if parser.buffer ~= "" then
        line_of(parser, tostring(parser.buffer), out)
        parser.buffer = ""
    end
    if parser.kind == "wippy" and parser.failures then wippy_segment(parser, "", out) end
    return out
end

-- reason(parser) -> the last lines worth showing when the child ended badly
-- with no case to blame: the runner's own errors, or stray output.
function targets.reason(parser: any): any
    if #parser.errors > 0 then return table.concat(parser.errors, "\n") end
    if #parser.stray > 0 then return table.concat(parser.stray, "\n") end
    return nil
end

-- stray(parser, chunk) — stderr: kept for the reason, never parsed as cases.
function targets.stray(parser: any, chunk: any)
    for line in string.gmatch(tostring(chunk or ""), "[^\n]+") do
        keep(parser.stray, targets.plain(line), targets.TAIL)
    end
end

return targets
