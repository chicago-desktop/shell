-- butschster.windows.antibug:scan — AntiBug's model (FR-009 §4, §4a, §6), pure.
--
-- A scan is a run of test entries and targets; an infected test is a failed
-- case. This file knows the entries (from a registry listing it is given),
-- the declared targets, the tree of group → suite → entry, which items a
-- selection means, and the state machine of one scan fed with the
-- `wippy.test` events (and the target process's, of the same shape), the
-- runner's answers and the window's timers. No registry, no `funcs`, no
-- clock: the window passes `now` in seconds, so a test drives every path
-- with plain tables.
--
-- One item at a time. A test entry is settled when the runner has answered
-- AND its `test:complete` arrived — the answer and the last message race —
-- or when the one-second grace after the answer ran out (`scan.GRACE`, as
-- the CLI runner waits). An entry that sent no case events is a plain
-- function test: an error or `false` is one failure, anything else one pass.
-- A target is settled by its process's `antibug:exit`; it has no timeout
-- (a module's suite runs for minutes) — Stop kills its child.
local scan = {}

-- The topic the window listens on and the runner hands to the test library.
scan.TOPIC = "antibug.test"
scan.GRACE = "1s"
scan.OTHER = "other"
scan.DEFAULT_TIMEOUT = "30s"
-- The tree's node for entries without `meta.group`.
scan.NO_GROUP = "(no group)"
-- The `Scan in:` values that are not a declared target.
scan.REGISTRY = "registry"
scan.ALL = "all"

scan.STATUS = {failed = "Failed", skipped = "Skipped", passed = "Passed"}

local function text_of(value: any): string
    return type(value) == "string" and value or ""
end

-- entries(found) -> the test entries of a registry listing, sorted by group,
-- suite, `meta.order`, id: `{id, group, suite, order, timeout, comment}`.
function scan.entries(found: any): any
    local out: any = {}
    for _, entry in ipairs(type(found) == "table" and found or {}) do
        local meta: any = type(entry.meta) == "table" and entry.meta or {}
        local kind = entry.kind
        if meta.type == "test" and (kind == nil or kind == "function.lua") then
            out[#out + 1] = {
                id = tostring(entry.id), group = text_of(meta.group),
                suite = text_of(meta.suite) ~= "" and text_of(meta.suite) or scan.OTHER,
                order = tonumber(meta.order) or 0,
                timeout = text_of(meta.timeout) ~= "" and text_of(meta.timeout) or scan.DEFAULT_TIMEOUT,
                comment = text_of(meta.comment),
            }
        end
    end
    table.sort(out, function(a: any, b: any): boolean
        if a.group ~= b.group then return a.group < b.group end
        if a.suite ~= b.suite then return a.suite < b.suite end
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return out
end

-- short(id) -> the entry's name without its namespace.
function scan.short(id: any): string
    local name = tostring(id or "")
    return name:match(":([^:]+)$") or name
end

-- new(entries, targets) — `targets` as `butschster.windows.antibug:targets`
-- lists them (`{id, title, kind, dir, problem?}`).
function scan.new(entries: any, targets: any?): any
    local state: any = {entries = entries or {}, targets = targets or {}, target = scan.REGISTRY,
        expanded = {}, selected = nil, include_other = true, only_failed = false, show_all = false,
        last = {}, totals = {}, run = nil, findings = {}, log = {},
        counts = {scanned = 0, infected = 0, skipped = 0, passed = 0}, phase = "idle", elapsed = 0}
    for _, entry in ipairs(state.entries) do state.expanded["g:" .. entry.group] = true end
    return state
end

-- refresh(state, entries, targets) — a re-read registry; the choices that
-- still name something are kept.
function scan.refresh(state: any, entries: any, targets: any?)
    state.entries = entries or {}
    if targets ~= nil then state.targets = targets end
    for _, entry in ipairs(state.entries) do
        if state.expanded["g:" .. entry.group] == nil then state.expanded["g:" .. entry.group] = true end
    end
end

local function group_label(group: string): string
    return group ~= "" and group or scan.NO_GROUP
end

-- options(state) -> the `Scan in:` choices: this computer's tests, every
-- declared target, and all of them when there is a target.
function scan.options(state: any): any
    local options: any = {{value = scan.REGISTRY, label = "This computer"}}
    for _, target in ipairs(state.targets) do
        options[#options + 1] = {value = "t:" .. target.id,
            label = target.title .. (target.problem and " (cannot run)" or "")}
    end
    if #state.targets > 0 then options[#options + 1] = {value = scan.ALL, label = "All targets"} end
    return options
end

-- registry_shown(state) — the registry's tests are part of the choice.
function scan.registry_shown(state: any): boolean
    return state.target == scan.REGISTRY or state.target == scan.ALL
end

-- in_scope(state, entry) — `Include suites without a group`: the entries
-- without a group are left out unless the box is checked.
local function in_scope(state: any, entry: any): boolean
    return entry.group ~= "" or state.include_other == true
end

local function under(selected: any, entry: any): boolean
    if selected == nil then return true end
    local id = tostring(selected)
    if id == "e:" .. entry.id then return true end
    if id == "s:" .. entry.group .. "/" .. entry.suite then return true end
    return id == "g:" .. entry.group
end

-- chosen(state) -> the registry entries a Scan Now runs: in scope, under the
-- tree's selection (an entry, a suite, a group, or nothing — everything), and
-- with `Only failed last time` only those whose last scan failed.
function scan.chosen(state: any): any
    local out: any = {}
    for _, entry in ipairs(state.entries) do
        if in_scope(state, entry) and under(state.selected, entry)
            and (not state.only_failed or state.last[entry.id] == "failed") then
            out[#out + 1] = entry
        end
    end
    return out
end

-- queue(state) -> the items a Scan Now runs, in order: the chosen registry
-- entries, then the chosen targets (`{id, target, title}`).
function scan.queue(state: any): any
    local selected = state.selected ~= nil and tostring(state.selected) or nil
    local picks_target = selected ~= nil and selected:sub(1, 2) == "t:"
    local out: any = {}
    if scan.registry_shown(state) and not picks_target then
        for _, entry in ipairs(scan.chosen(state)) do out[#out + 1] = entry end
    end
    if state.target ~= scan.REGISTRY then
        for _, target in ipairs(state.targets) do
            local id = "t:" .. target.id
            local wanted = state.target == id
                or (state.target == scan.ALL and (selected == nil or selected == id))
            if wanted and (not state.only_failed or state.last[target.id] == "failed") then
                out[#out + 1] = {id = target.id, target = target, title = target.title}
            end
        end
    end
    return out
end

local function mark_of(state: any, id: string): string
    if state.last[id] == "failed" then return "  — infected" end
    if state.last[id] == "passed" then return "  — clean" end
    return ""
end

-- tree(state) -> the `tree` rows: group → suite → entry, flattened, with the
-- counts on groups and suites and the last result on entries; a target is
-- one row of its own.
function scan.tree(state: any): any
    local rows: any = {}
    local targets_shown: any = {}
    for _, target in ipairs(state.targets) do
        if state.target == scan.ALL or state.target == "t:" .. target.id then targets_shown[#targets_shown + 1] = target end
    end
    if scan.registry_shown(state) then
        local groups: any, order: any = {}, {}
        for _, entry in ipairs(state.entries) do
            if in_scope(state, entry) then
                local group = groups[entry.group]
                if not group then
                    group = {suites = {}, order = {}, count = 0}
                    groups[entry.group] = group
                    order[#order + 1] = entry.group
                end
                local suite = group.suites[entry.suite]
                if not suite then
                    suite = {entries = {}}
                    group.suites[entry.suite] = suite
                    group.order[#group.order + 1] = entry.suite
                end
                suite.entries[#suite.entries + 1] = entry
                group.count = group.count + 1
            end
        end
        local function trail_with(trail: any, more: boolean): any
            local out: any = {}
            for index, value in ipairs(trail) do out[index] = value end
            out[#out + 1] = more
            return out
        end
        for gi, name in ipairs(order) do
            local group = groups[name]
            local gid = "g:" .. name
            local gopen = state.expanded[gid] == true
            rows[#rows + 1] = {id = gid, label = group_label(name) .. " (" .. group.count .. ")", depth = 0,
                has_children = true, expanded = gopen, trail = {}, kind = "folder"}
            if gopen then
                local gtrail = trail_with({}, gi < #order or #targets_shown > 0)
                for si, suite_name in ipairs(group.order) do
                    local suite = group.suites[suite_name]
                    local sid = "s:" .. name .. "/" .. suite_name
                    local sopen = state.expanded[sid] == true
                    rows[#rows + 1] = {id = sid, label = suite_name .. " (" .. #suite.entries .. ")", depth = 1,
                        has_children = true, expanded = sopen, trail = gtrail, kind = "folder"}
                    if sopen then
                        local strail = trail_with(gtrail, si < #group.order)
                        for _, entry in ipairs(suite.entries) do
                            rows[#rows + 1] = {id = "e:" .. entry.id, label = scan.short(entry.id) .. mark_of(state, entry.id),
                                depth = 2, has_children = false, expanded = false, trail = strail, kind = "entry"}
                        end
                    end
                end
            end
        end
    end
    for _, target in ipairs(targets_shown) do
        rows[#rows + 1] = {id = "t:" .. target.id,
            label = target.title .. " (" .. target.kind .. ")" .. (target.problem and ("  — " .. target.problem) or mark_of(state, target.id)),
            depth = 0, has_children = false, expanded = false, trail = {}, kind = "entry"}
    end
    return rows
end

function scan.toggle(state: any, id: any)
    local key = tostring(id or "")
    if key:sub(1, 2) == "g:" or key:sub(1, 2) == "s:" then state.expanded[key] = not (state.expanded[key] == true) end
end

-- ─── the scan ───────────────────────────────────────────────────────────

function scan.scanning(state: any): boolean
    return state.run ~= nil and state.run.ended == nil
end

-- clear(state) — New Scan: no findings, no log, no counts.
function scan.clear(state: any)
    state.findings, state.log = {}, {}
    state.counts = {scanned = 0, infected = 0, skipped = 0, passed = 0}
    state.elapsed = 0
    if not scan.scanning(state) then state.run, state.phase = nil, "idle" end
end

local function log(state: any, line: string)
    state.log[#state.log + 1] = line
end

local function first_line(text: any): string
    local whole = tostring(text or "")
    return whole:match("^[^\n]*") or whole
end

local function millis(seconds: any): string
    local value = tonumber(seconds) or 0
    return string.format("%d ms", math.tointeger(math.floor(value * 1000 + 0.5)) or 0)
end

local function seconds_text(seconds: any): string
    return string.format("%.1f s", (tonumber(seconds) or 0) + 0.0)
end

local function finding(state: any, status: string, name: string, err: any, duration: any)
    local current: any = state.run and state.run.current or {}
    state.findings[#state.findings + 1] = {status = status, name = name, error = err and tostring(err) or nil,
        duration = duration, entry = current.id, suite = current.suite}
end

local function fail(state: any, name: string, err: any, duration: any)
    local current: any = state.run and state.run.current
    if current then current.failed = true end
    state.counts.scanned, state.counts.infected = state.counts.scanned + 1, state.counts.infected + 1
    finding(state, "failed", name, err, duration)
    log(state, "FAIL " .. name .. ": " .. first_line(err))
end

-- start(state, now) -> the first item id to run, or nil when nothing is
-- chosen. A scan clears the last one's findings and log.
function scan.start(state: any, now: any): any
    if scan.scanning(state) then return nil end
    local queue = scan.queue(state)
    scan.clear(state)
    if #queue == 0 then
        state.phase = "idle"
        state.notice = state.only_failed and "Nothing failed last time." or "Nothing to scan."
        return nil
    end
    state.notice = nil
    state.run = {queue = queue, index = 0, total = #queue, started = tonumber(now) or 0, stop = false,
        current = nil, seq = 0}
    state.phase = "scanning"
    log(state, "AntiBug: scanning " .. #queue .. " item" .. (#queue == 1 and "" or "s"))
    return scan.next(state, now)
end

-- next(state, now) -> the next item id, or nil when the scan ended (all
-- done, or Stop asked for) — then `state.box` is the VirusScan box.
function scan.next(state: any, now: any): any
    local run: any = state.run
    if not run then return nil end
    run.current = nil
    if run.stop or run.index >= run.total then
        run.ended = tonumber(now) or 0
        state.elapsed = run.ended - run.started
        state.phase = run.stop and (run.index < run.total or run.killed) and "stopped" or "complete"
        log(state, "")
        log(state, "Scanned: " .. state.counts.scanned .. "  Infected: " .. state.counts.infected
            .. "  Skipped: " .. state.counts.skipped .. "  Time: " .. seconds_text(state.elapsed))
        state.box = scan.summary(state)
        return nil
    end
    run.index = run.index + 1
    run.seq = run.seq + 1
    local item: any = run.queue[run.index]
    run.current = {id = item.id, target = item.target, suite = item.target and item.title or item.suite,
        group = item.group, timeout = item.timeout, seq = run.seq, planned = 0, done = 0, cases = 0,
        entries = 0, known = nil, failed = false, answered = false, completed = false, case = nil,
        started = tonumber(now) or 0}
    if item.target then
        log(state, "")
        log(state, "» " .. item.title .. " (" .. tostring(item.target.kind) .. ", " .. tostring(item.target.dir) .. ")")
    else
        log(state, "» " .. item.id)
    end
    return item.id
end

-- current(state) -> the item now running, or nil.
function scan.current(state: any): any
    return state.run and state.run.current or nil
end

-- The failed finding of the current item a late `antibug:detail` belongs
-- to: the last one of that test still without its text.
local function awaiting_detail(state: any, test: string): any
    local current: any = scan.current(state)
    for index = #state.findings, 1, -1 do
        local found: any = state.findings[index]
        if found.entry == current.id and found.status == "failed" and (found.error == nil or found.error == "")
            and found.name:sub(-(#test + 1)) == "/" .. test then
            return found
        end
    end
    return nil
end

-- event(state, message) -> whether it changed anything. `message` is what
-- the test library (or the target process) sends: `{type, data}`,
-- `data.ref_id` naming the item. A message of another item (one that timed
-- out and still talks) is dropped.
function scan.event(state: any, message: any): boolean
    local current: any = scan.current(state)
    if not current or type(message) ~= "table" then return false end
    local data: any = type(message.data) == "table" and message.data or {}
    if data.ref_id ~= nil and tostring(data.ref_id) ~= current.id then return false end
    local kind = tostring(message.type or "")
    local name = tostring(data.suite or "") .. "/" .. tostring(data.test or "")
    if kind == "test:plan" then
        local planned = 0
        for _, suite in ipairs(type(data.suites) == "table" and data.suites or {}) do
            planned = planned + #(type(suite.tests) == "table" and suite.tests or {})
        end
        current.planned = planned
        log(state, "  plan: " .. planned .. " case" .. (planned == 1 and "" or "s"))
    elseif kind == "test:case:start" then
        current.case = name
    elseif kind == "test:case:pass" then
        -- The last case seen is the progress row's: the wippy runner's text
        -- has no case start, only results.
        current.done, current.cases, current.case = current.done + 1, current.cases + 1, name
        state.counts.scanned, state.counts.passed = state.counts.scanned + 1, state.counts.passed + 1
        finding(state, "passed", name, nil, data.duration)
        log(state, "PASS " .. name .. " " .. millis(data.duration))
    elseif kind == "test:case:fail" then
        current.done, current.cases, current.case = current.done + 1, current.cases + 1, name
        local err = data.error
        if err == "" then err = nil end
        fail(state, name, err, data.duration)
    elseif kind == "test:case:skip" then
        current.done, current.cases, current.case = current.done + 1, current.cases + 1, name
        state.counts.skipped = state.counts.skipped + 1
        finding(state, "skipped", name, nil, nil)
        log(state, "SKIP " .. name)
    elseif kind == "test:complete" then
        current.completed = true
    elseif kind == "test:error" then
        fail(state, scan.short(current.id), data.message or "test error", nil)
    elseif kind == "antibug:progress" then
        if tonumber(data.known) then current.known = tonumber(data.known) end
        if data.entry ~= nil then
            current.entries = current.entries + 1
            current.case = tostring(data.entry)
        end
    elseif kind == "antibug:detail" then
        local found = awaiting_detail(state, tostring(data.test or ""))
        if not found then return false end
        found.error = tostring(data.error or "")
        log(state, "  " .. found.name .. ": " .. first_line(found.error))
    elseif kind == "antibug:exit" then
        current.completed = true
        if data.stopped then
            current.stopped = true
            state.run.killed = true
            log(state, "  stopped")
        end
        local code = tonumber(data.code)
        if data.error ~= nil and not data.stopped then
            fail(state, tostring(current.suite), data.error, nil)
        elseif code ~= nil and code ~= 0 and not current.failed then
            fail(state, tostring(current.suite), "exited with code " .. code .. " and no failed test", nil)
        end
    else
        return false
    end
    return true
end

-- answered(state, answer) — the runner answered for the current item:
-- `{error?, returned?, child?}`. Returns whether the item is settled (a test
-- entry's `test:complete` already came, or a target that did not start);
-- otherwise a test entry gets the grace and a target waits for its exit.
function scan.answered(state: any, answer: any): boolean
    local current: any = scan.current(state)
    if not current then return false end
    current.answered = true
    current.answer = type(answer) == "table" and answer or {}
    if current.target then
        if current.answer.error ~= nil then current.completed = true end
        current.child = current.answer.child
    end
    return current.completed == true
end

-- settled(state) -> the current item has answered and completed.
function scan.settled(state: any): boolean
    local current: any = scan.current(state)
    return current ~= nil and current.answered == true and current.completed == true
end

-- finish(state, now) -> the next item id or nil: the current one is done —
-- its answer and its events are in. An item without case events (a plain
-- function test, a target that ran none) is judged by the answer.
function scan.finish(state: any, now: any): any
    local current: any = scan.current(state)
    if not current then return nil end
    if current.cases == 0 and not current.failed then
        local answer: any = current.answer or {}
        local name = current.target and current.suite or scan.short(current.id)
        if answer.error ~= nil then
            fail(state, name, answer.target and answer.error or (current.target and ("not started: " .. tostring(answer.error)) or answer.error), nil)
        elseif answer.returned == false then
            fail(state, name, "test returned false", nil)
        elseif not current.stopped then
            state.counts.scanned, state.counts.passed = state.counts.scanned + 1, state.counts.passed + 1
            finding(state, "passed", name, nil, (tonumber(now) or 0) - current.started)
            log(state, "PASS " .. name)
        end
    end
    if current.target and not current.stopped and current.cases > 0 then state.totals[current.id] = current.cases end
    state.last[current.id] = current.failed and "failed" or "passed"
    return scan.next(state, now)
end

-- timed_out(state, now) -> the next item id or nil: the current entry did
-- not answer within its `meta.timeout`. It cannot be killed; its later
-- messages are dropped by `event`.
function scan.timed_out(state: any, now: any): any
    local current: any = scan.current(state)
    if not current then return nil end
    fail(state, scan.short(current.id), "timeout after " .. tostring(current.timeout), nil)
    state.last[current.id] = "failed"
    return scan.next(state, now)
end

-- failed_to_start(state, err, now) -> the next item id or nil.
function scan.failed_to_start(state: any, err: any, now: any): any
    local current: any = scan.current(state)
    if not current then return nil end
    current.answered, current.completed = true, true
    current.answer = {error = "not started: " .. tostring(err), target = current.target ~= nil}
    return scan.finish(state, now)
end

-- stop(state) — Stop: a running test entry finishes, a target's child is
-- killed (the window asks its process), and no other item starts.
function scan.stop(state: any)
    if scan.scanning(state) then
        state.run.stop = true
        state.phase = "stopping"
    end
end

-- ─── what the window shows ──────────────────────────────────────────────

scan.COLUMNS = {
    {title = "Name", weight = 4},
    {title = "Infected by", weight = 5},
    {title = "Status", width = 8},
    {title = "Time", width = 8, align = "right"},
}

-- visible(state) -> the findings the table shows: failures and skips, and
-- passes only with `Show all results`.
function scan.visible(state: any): any
    local out: any = {}
    for index, found in ipairs(state.findings) do
        if found.status ~= "passed" or state.show_all then out[#out + 1] = {index = index, finding = found} end
    end
    return out
end

function scan.rows(state: any): any
    local rows: any = {}
    for _, item in ipairs(scan.visible(state)) do
        local found: any = item.finding
        rows[#rows + 1] = {id = "f" .. item.index, cells = {
            found.name, found.error and first_line(found.error) or "",
            scan.STATUS[found.status] or found.status, found.duration and millis(found.duration) or "",
        }}
    end
    return rows
end

-- finding_of(state, row_id) -> the finding a table row shows.
function scan.finding_of(state: any, row_id: any): any
    local index = tonumber(tostring(row_id or ""):match("^f(%d+)$"))
    return index and state.findings[index] or nil
end

function scan.log_text(state: any): string
    return table.concat(state.log, "\n")
end

-- wrap(text, width) -> lines of at most `width` characters, broken at spaces.
function scan.wrap(text: any, width: integer): any
    local lines: any = {}
    -- The source is built first and the loop variables are never assigned:
    -- a generic `for` over `(a .. b):gmatch(…)` failed in go-lua with a
    -- concat of nil on this line.
    local source = tostring(text or "") .. "\n"
    for paragraph in string.gmatch(source, "([^\n]*)\n") do
        local line = ""
        for word in string.gmatch(paragraph, "%S+") do
            local rest = word
            while #rest > width do
                if line ~= "" then lines[#lines + 1] = line; line = "" end
                lines[#lines + 1] = rest:sub(1, width)
                rest = rest:sub(width + 1)
            end
            if line == "" then line = rest
            elseif #line + 1 + #rest <= width then line = line .. " " .. rest
            else lines[#lines + 1] = line; line = rest end
        end
        lines[#lines + 1] = line
    end
    while #lines > 1 and lines[#lines] == "" do table.remove(lines :: {any}) end
    return lines
end

-- info(finding) -> the Virus Info sheet's lines: the error, wrapped, then
-- the suite, the entry and the time.
function scan.info(found: any): any
    local lines: any = {}
    for _, line in ipairs(scan.wrap(found.error or "No error: this test passed.", 52)) do lines[#lines + 1] = line end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Suite: " .. tostring(found.suite or "")
    lines[#lines + 1] = "Entry: " .. tostring(found.entry or "")
    lines[#lines + 1] = "Time: " .. (found.duration and millis(found.duration) or "—")
    return lines
end

-- summary(state) -> the box at the end of a scan: VirusScan's words.
function scan.summary(state: any): any
    local infected = state.counts.infected
    local lines: any = {state.phase == "stopped" and "Scan stopped." or "Scan complete."}
    if infected == 0 then lines[#lines + 1] = "No infected tests found."
    else lines[#lines + 1] = infected .. " infected test" .. (infected == 1 and "" or "s") .. " found." end
    return {title = "AntiBug", lines = lines, infected = infected}
end

scan.PHASE = {idle = "Idle", scanning = "Scanning…", stopping = "Stopping…", stopped = "Stopped", complete = "Complete"}

-- status(state, now) -> the status bar's two texts.
function scan.status(state: any, now: any): (string, string)
    local elapsed = state.elapsed
    if scan.scanning(state) then elapsed = (tonumber(now) or 0) - state.run.started end
    local counts: any = state.counts
    return "Scanned: " .. counts.scanned .. "   Infected: " .. counts.infected .. "   Skipped: " .. counts.skipped
        .. "   Time: " .. seconds_text(elapsed), scan.PHASE[state.phase] or state.phase
end

-- progress(state) -> value, ceiling, caption of the gauge row: cases of the
-- current entry once its plan came, entries of the scan before that; for a
-- target, cases against its previous scan's total, and on its first scan
-- the entries it announced ("first scan").
function scan.progress(state: any): (number, number, string)
    local run: any = state.run
    if not run then return 0, 1, "" end
    local current: any = run.current
    local index: number = tonumber(run.index) or 0
    local total: number = tonumber(run.total) or 0
    if current and current.target then
        local what = tostring(current.case or current.suite)
        local cases: number = tonumber(current.cases) or 0
        local before: number = tonumber(state.totals[current.id]) or 0
        if before > 0 then return math.min(cases, before), before, "Scanning: " .. what end
        local known: number = tonumber(current.known) or 0
        local entries: number = tonumber(current.entries) or 0
        if known > 0 then return math.min(entries, known), known, "first scan: " .. what end
        return 0, 1, "first scan: " .. what
    end
    if current and (tonumber(current.planned) or 0) > 0 then
        return tonumber(current.done) or 0, tonumber(current.planned) or 1,
            "Scanning: " .. tostring(current.case or scan.short(current.id))
    end
    if current then return index - 1, total, "Scanning: " .. scan.short(current.id) end
    return index, math.max(total, 1), ""
end

return scan
