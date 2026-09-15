-- The desktop layout: desktop shortcuts and folders.
--
-- A shortcut stores a REFERENCE to a registry entry, not program code: the
-- program got updated — the shortcut leads to the new version. A reference
-- to a vanished entry stays a row in the table and is marked broken on read;
-- it must not be removed silently — a vanished icon reads as "I deleted it by
-- accident", and a broken one as "the program is gone".
--
-- Every row belongs to a person (`user_id`, migration 04). Several people use
-- one runtime at once — a terminal.ssh host gives every connection its own
-- desktop — and an icon one of them moves must not move on the others'
-- screens. `repo.of(user)` is the layout of one person; the module's own
-- functions are the SHARED layout (`user_id = ''`), the one a desktop without
-- logon shows. A person's first use inherits the shared layout once — shortcuts,
-- the marks of what was offered, the settings — so the desktop someone had
-- before logon existed does not vanish at their first logon.

local sql = require("sql")
local registry = require("registry")
local time = require("time")
local uuid = require("uuid")

local ITEMS = "butschster_windows_desktop_items"
local SETTINGS = "butschster_windows_settings"
local SEEDED = "butschster_windows_desktop_seeded"

local repo = {}

repo.KIND_SHORTCUT = "shortcut"
repo.KIND_FOLDER = "folder"

-- The layout of nobody in particular: a desktop without logon.
repo.SHARED = ""

-- The mark, among the offered ones, that a person inherited the shared
-- layout. It lives with the marks because they are never deleted: a person
-- who removed every inherited icon must not get them back.
repo.INHERITED = "butschster.windows:inherited-shared-layout"

-- The database is named ONCE: by the module's `target_db` requirement, which
-- writes `meta.target_db` into every migration (src/_index.yaml). A migration
-- cannot read the environment, so the second name that lived here
-- (BUTSCHSTER_WINDOWS_DB_ID) could only diverge from it: the tables created in
-- one database, the layout written to another. The repository reads the name
-- back from the migration that creates its first table.
--
-- No default: an unreadable entry is the reason on every call, not "the
-- application did not override anything".
repo.MIGRATION = "butschster.windows.migrations:01_create_desktop_items"

local function target_db(): (any, any)
    local entry, err = registry.get(repo.MIGRATION)
    if not entry then
        return nil, "the layout database is named by " .. repo.MIGRATION
            .. " (meta.target_db), and the entry is unreadable: " .. tostring(err)
    end
    local record: any = entry
    local meta: any = type(record.meta) == "table" and record.meta
        or (type(record.data) == "table" and type(record.data.meta) == "table" and record.data.meta) or {}
    local id: any = meta.target_db
    if type(id) ~= "string" or id == "" then return nil, repo.MIGRATION .. " has no meta.target_db" end
    return id, nil
end
-- Read on first use, not at load: while a library is being loaded the
-- process has no registry in its context yet ("registry not found in
-- context"). Only a name that was read is kept, in a table rather than an
-- upvalue: an error under pcall in go-lua tears upvalues apart (sdk_test).
local target: any = {}
-- The people whose inheritance is settled in this process, so the check is
-- one query per person, not one per read.
local inherited: any = {}

-- database() -> id | nil, why — the database every query here goes to.
function repo.database(): (any, any)
    if target.id == nil then
        local id, why = target_db()
        if id == nil then return nil, why end
        target.id = id
    end
    return target.id, nil
end

-- The connection is returned on EVERY path, including an error inside the
-- work: a lost connection gives no sign of itself until the pool runs out.
local function with_db(work)
    local id, why = repo.database()
    if id == nil then return nil, why end
    local db, err = sql.get(tostring(id))
    if err or not db then return nil, err or ("database unavailable: " .. tostring(id)) end
    local ok, result, work_err = pcall(work, db)
    db:release()
    if not ok then return nil, tostring(result) end
    return result, work_err
end

-- The same inside a transaction: all or nothing. Work that returned a reason
-- or crashed is rolled back; the connection is returned on every path.
local function with_tx(work)
    local id, why = repo.database()
    if id == nil then return nil, why end
    local db, err = sql.get(tostring(id))
    if err or not db then return nil, err or ("database unavailable: " .. tostring(id)) end
    local tx, berr = db:begin()
    if berr or not tx then
        db:release()
        return nil, "begin: " .. tostring(berr)
    end
    local ok, result, work_err = pcall(work, tx)
    if not ok or work_err ~= nil then
        tx:rollback()
        db:release()
        if not ok then return nil, tostring(result) end
        return nil, work_err
    end
    local committed, cerr = tx:commit()
    db:release()
    if not committed then return nil, "commit: " .. tostring(cerr) end
    return result, nil
end

local function now_stamp()
    return time.now():utc():format(time.RFC3339)
end

-- Coordinates are integers: a grid cell, not a fraction of the screen.
-- tonumber gives a number, while the column is INTEGER, and a fractional
-- value would reach the database silently.
--
-- Empty here is a VALUE, not an absence of data: "nobody named a place".
-- Therefore there can be no zero instead of nil here on any path: zero is a
-- place, and it would glue the icon to the top-left corner instead of handing
-- it to the compositor for layout.
--
-- Infinity and NaN are not a place either: `math.floor(inf)` does not become
-- an integer, and the former `or 0` glued such an icon to the corner, against
-- the rule above.
local function cell(value: any)
    if value == nil then return nil end
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
    return math.tointeger(number) or math.tointeger(math.floor(number))
end

local function to_item(row: any)
    local record = row :: any
    return {
        id = record.id,
        kind = record.kind,
        -- An empty string and NULL arrive from different dialects meaning the
        -- same thing — "no entry" — so they are normalized to nil here, not in
        -- every reader.
        entry = (type(record.entry) == "string" and record.entry ~= "") and record.entry or nil,
        parent_id = (type(record.parent_id) == "string" and record.parent_id ~= "") and record.parent_id or nil,
        title = record.title,
        x = cell(record.x),
        y = cell(record.y),
        created_at = record.created_at,
        updated_at = record.updated_at,
    }
end

-- One row insert for either a connection or a transaction — `create`,
-- `offer` and the inheritance call it, so that writers of the same row do not
-- diverge.
local function insert_item(conn: any, user: string, item: any): (any, any)
    local id, uerr = uuid.v7()
    if not id then return nil, "id: " .. tostring(uerr) end
    local stamp = now_stamp()
    local _, err = conn:execute(
        "INSERT INTO " .. ITEMS ..
        " (id, user_id, kind, entry, parent_id, title, x, y, created_at, updated_at)" ..
        " VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
        {
            id, user, item.kind, item.entry, item.parent_id, item.title,
            cell(item.x), cell(item.y), stamp, stamp,
        })
    if err then return nil, err end
    return {
        id = id,
        kind = item.kind,
        entry = item.entry,
        parent_id = item.parent_id,
        title = item.title,
        x = cell(item.x),
        y = cell(item.y),
        created_at = stamp,
        updated_at = stamp,
    }, nil
end

-- One mark insert: `ON CONFLICT DO NOTHING`, not "check, then insert".
-- Between the check and the insert a second writer managed to insert its own,
-- and the first one failed on the primary key. How many rows landed is told
-- by `rows_affected`: one — marked just now, zero — it was already there.
local function claim(conn: any, user: string, entry: any): (any, any)
    local result, err = conn:execute(
        "INSERT INTO " .. SEEDED .. " (user_id, entry, seeded_at) VALUES ($1, $2, $3)"
            .. " ON CONFLICT (user_id, entry) DO NOTHING",
        { user, entry, now_stamp() })
    if err then return nil, err end
    return type(result) == "table" and (tonumber(result.rows_affected) or 0) > 0, nil
end

-- inherit(user) -> true | nil, reason
--
-- A person's first use copies the shared layout: shortcuts and folders (the
-- folder ids are new, so the contents follow them), the marks of what was
-- offered, the settings. Once: the claim of repo.INHERITED decides, inside
-- the same transaction as the copy, and a second desktop of the same person
-- starting at the same moment gets "already inherited", not a second copy.
local function inherit(user: string): (any, any)
    if user == repo.SHARED or inherited[user] then return true, nil end
    local done, err = with_tx(function(tx)
        local claimed, cerr = claim(tx, user, repo.INHERITED)
        if cerr then return nil, cerr end
        if not claimed then return true end

        local rows, rerr = tx:query("SELECT * FROM " .. ITEMS .. " WHERE user_id = $1"
            .. " ORDER BY (parent_id IS NOT NULL), created_at, id", { repo.SHARED })
        if rerr then return nil, rerr end
        local renamed: any = {}
        for _, row in ipairs(rows or {}) do
            local item: any = to_item(row)
            local copy: any = {kind = item.kind, entry = item.entry, title = item.title, x = item.x, y = item.y}
            if item.parent_id then copy.parent_id = renamed[item.parent_id] end
            local made, ierr = insert_item(tx, user, copy)
            if ierr then return nil, ierr end
            renamed[item.id] = made.id
        end

        -- CAST, not a bare $1: PostgreSQL cannot tell the type of a parameter
        -- in a select list, and SQLite does not know `::text`.
        local _, serr = tx:execute("INSERT INTO " .. SEEDED .. " (user_id, entry, seeded_at)"
            .. " SELECT CAST($1 AS TEXT), entry, seeded_at FROM " .. SEEDED .. " WHERE user_id = $2"
            .. " ON CONFLICT (user_id, entry) DO NOTHING", { user, repo.SHARED })
        if serr then return nil, serr end
        local _, verr = tx:execute("INSERT INTO " .. SETTINGS .. " (user_id, key, value, updated_at)"
            .. " SELECT CAST($1 AS TEXT), key, value, updated_at FROM " .. SETTINGS .. " WHERE user_id = $2"
            .. " ON CONFLICT (user_id, key) DO NOTHING", { user, repo.SHARED })
        if verr then return nil, verr end
        return true
    end)
    if not done then return nil, "inheriting the shared layout: " .. tostring(err) end
    inherited[user] = true
    return true, nil
end

-- person() -> the logged-on person's id in a window's process, or SHARED.
--
-- A desktop with logon writes `user_id` into the context of every window it
-- spawns; a window of a desktop without logon has none, and shows the shared
-- layout, as that desktop does.
function repo.person(): string
    local ok, ctx = pcall(require, "ctx")
    if not ok or type(ctx) ~= "table" then return repo.SHARED end
    local value = ctx.get("user_id")
    if type(value) == "string" and value ~= "" then return value end
    return repo.SHARED
end

-- forget(user) — drop this process's note that the person's inheritance is
-- settled; the next use asks the database again, as a second desktop process
-- of the same person does. The database's mark is what keeps it to once.
function repo.forget(user: any)
    if type(user) == "string" then inherited[user] = nil end
end

-- of(user) -> the layout of one person. `nil` and "" are the shared layout.
function repo.of(user: any): any
    local who: string = (type(user) == "string" and user ~= "") and user or repo.SHARED
    local store: any = {user = who}

    -- The whole desktop at once, including folder contents: the shell draws
    -- both the desktop and the folder windows from one read, and separate
    -- queries for each folder would mean a frame assembled from different
    -- moments in time.
    --
    -- The order is set explicitly and down to the last field. `(x IS NULL)`
    -- comes first because dialects sort empty coordinates differently (SQLite
    -- puts NULL at the start, PostgreSQL in ascending order at the end), and
    -- the icon layout would depend on which database the stand runs on.
    -- `created_at, id` at the tail because the order of icons WITHOUT
    -- coordinates decides which cells the compositor puts them into: sorting
    -- by name would reshuffle them when a program is renamed.
    function store.list()
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_db(function(db)
            local rows, err = db:query(
                "SELECT * FROM " .. ITEMS .. " WHERE user_id = $1" ..
                " ORDER BY (x IS NULL), y, x, created_at, id", { who })
            if err then return nil, err end
            local out = {}
            for _, row in ipairs(rows or {}) do out[#out + 1] = to_item(row) end
            return out
        end)
    end

    function store.get(id)
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_db(function(db)
            local rows, err = db:query("SELECT * FROM " .. ITEMS .. " WHERE id = $1 AND user_id = $2", { id, who })
            if err then return nil, err end
            local row = rows and rows[1]
            if not row then return nil, nil end
            return to_item(row)
        end)
    end

    -- create(item) -> (item, nil) | (nil, reason)
    --
    -- The identifier is minted here and does not come from outside: a
    -- shortcut is a state object, and letting the caller name its id means
    -- letting it overwrite someone else's shortcut by getting the name wrong.
    --
    -- Without `x`/`y` the row is written WITHOUT coordinates, and that is not
    -- an omission but a statement: the compositor will choose the place when
    -- it learns the screen width. Were we to put zero here, the icon would
    -- become "placed in the top-left corner", and it could no longer be
    -- relaid.
    function store.create(item)
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_db(function(db) return insert_item(db, who, item) end)
    end

    -- update(id, patch) -> (item, nil) | (false, nil) | (nil, reason)
    --
    -- `false` means "no such row" and differs from a database failure:
    -- otherwise a typo in the identifier looks like a successful move.
    -- Someone else's row is "no such row" too.
    --
    -- Only the named fields in patch are interpreted. `parent_id = false` is a
    -- request to take the item out of a folder onto the desktop: nil here
    -- would mean "leave alone", and there would be no way to take the icon
    -- out.
    --
    -- A named place makes the icon PLACED: from this moment on the compositor
    -- does not relay it, even if the screen got narrower and the icon went
    -- past the edge. That is by design — a place named by a person is
    -- inviolable.
    function store.update(id, patch: any)
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_db(function(db)
            local rows, err = db:query("SELECT * FROM " .. ITEMS .. " WHERE id = $1 AND user_id = $2", { id, who })
            if err then return nil, err end
            local row = rows and rows[1]
            if not row then return false, nil end

            local current = to_item(row)
            local title = patch.title ~= nil and patch.title or current.title
            local x = patch.x ~= nil and cell(patch.x) or current.x
            local y = patch.y ~= nil and cell(patch.y) or current.y
            local parent_id = current.parent_id
            if patch.parent_id == false then
                parent_id = nil
            elseif patch.parent_id ~= nil then
                parent_id = patch.parent_id
            end

            local stamp = now_stamp()
            local _, uerr = db:execute(
                "UPDATE " .. ITEMS ..
                " SET title = $1, x = $2, y = $3, parent_id = $4, updated_at = $5 WHERE id = $6 AND user_id = $7",
                { title, x, y, parent_id, stamp, id, who })
            if uerr then return nil, uerr end

            current.title = title
            current.x = x
            current.y = y
            current.parent_id = parent_id
            current.updated_at = stamp
            return current
        end)
    end

    -- delete(id) -> (result, nil) | (nil, reason)
    --
    -- The result says whether the row EXISTED: `existed = false` is not a
    -- failure, but not a successful deletion either, otherwise a typo in the
    -- identifier looks like success.
    --
    -- The contents of a deleted folder are not deleted with it but returned to
    -- the desktop. A cascade here would mean that a removed folder carries
    -- away the icons the user had been putting into it — and there is nothing
    -- to restore them from.
    --
    -- In a transaction: moving the children out and removing the folder are
    -- one action. A failure between them would leave the children on the
    -- desktop with the folder still alive, or the folder without its children.
    function store.delete(id)
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_tx(function(db)
            local rows, err = db:query("SELECT * FROM " .. ITEMS .. " WHERE id = $1 AND user_id = $2", { id, who })
            if err then return nil, err end
            local row = rows and rows[1]
            if not row then return { existed = false, promoted = 0 } end

            local item = to_item(row)
            local promoted = 0
            if item.kind == repo.KIND_FOLDER then
                local children, cerr = db:query(
                    "SELECT id FROM " .. ITEMS .. " WHERE parent_id = $1 AND user_id = $2", { id, who })
                if cerr then return nil, cerr end
                promoted = #(children or {})
                if promoted > 0 then
                    local _, perr = db:execute(
                        "UPDATE " .. ITEMS .. " SET parent_id = NULL, updated_at = $1 WHERE parent_id = $2 AND user_id = $3",
                        { now_stamp(), id, who })
                    if perr then return nil, perr end
                end
            end

            local _, derr = db:execute("DELETE FROM " .. ITEMS .. " WHERE id = $1 AND user_id = $2", { id, who })
            if derr then return nil, derr end
            return { existed = true, promoted = promoted, item = item }
        end)
    end

    -- ─── Settings ────────────────────────────────────────────────────────
    --
    -- Key — value, as a string. A missing row is nil without an error: "never
    -- configured" and "database unavailable" are told apart by the second
    -- value.
    function store.setting(key: any)
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_db(function(db)
            -- `$n` placeholders, as in the whole file: `?` is accepted only by
            -- SQLite, and the runtime's `sql` module does no placeholder
            -- rewriting, so on postgres these queries would not run at all.
            local rows, err = db:query("SELECT value FROM " .. SETTINGS
                .. " WHERE user_id = $1 AND key = $2 LIMIT 1", {who, tostring(key)})
            if err then return nil, tostring(err) end
            local first: any = type(rows) == "table" and rows[1] or nil
            if type(first) == "table" and type(first.value) == "string" then return first.value, nil end
            return nil, nil
        end)
    end

    function store.set_setting(key: any, value: any)
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_db(function(db)
            local stamp = now_stamp()
            local _, err = db:execute("INSERT INTO " .. SETTINGS .. " (user_id, key, value, updated_at)"
                .. " VALUES ($1, $2, $3, $4)"
                .. " ON CONFLICT(user_id, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
                {who, tostring(key), tostring(value), stamp})
            if err then return nil, tostring(err) end
            return true, nil
        end)
    end

    -- ─── The mark "we have already offered this program" ─────────────────
    --
    -- Lives separately from the layout and is never deleted. Only thanks to
    -- this does deleting an icon work: the shortcut left, the mark stayed,
    -- and a program with `desktop: true` is not put onto the desktop again on
    -- the next startup.
    function store.seeded()
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_db(function(db)
            local rows, err = db:query("SELECT entry FROM " .. SEEDED .. " WHERE user_id = $1", { who })
            if err then return nil, err end
            local out = {}
            for _, row in ipairs(rows or {}) do
                local record = row :: any
                if type(record.entry) == "string" then out[record.entry] = true end
            end
            return out
        end)
    end

    -- Mark a program as offered. A repeated call is not a failure: the mark
    -- is a statement about the past, and the second time it is just as true
    -- (`false`).
    function store.mark_seeded(entry)
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_db(function(db) return claim(db, who, entry) end)
    end

    -- offer(key, item) -> (shortcut, nil) | (false, nil) | (nil, reason)
    --
    -- Offer an icon once: the mark and the shortcut are in one transaction,
    -- and the mark is set FIRST. Whoever inserted the mark creates the
    -- shortcut; the second writer (two startups in a row, the workshop while
    -- the shell is running) gets `false` — "already offered" — not a primary
    -- key error and an extra icon. A failure to write the shortcut rolls back
    -- the mark as well: an icon will not stay "offered but not offered".
    function store.offer(key: any, item: any)
        local _, ierr = inherit(who)
        if ierr then return nil, ierr end
        return with_tx(function(tx)
            local claimed, cerr = claim(tx, who, key)
            if cerr then return nil, cerr end
            if not claimed then return false, nil end
            return insert_item(tx, who, item)
        end)
    end

    return store
end

-- The shared layout, under the names every caller used before layouts
-- belonged to people.
local shared: any = repo.of(repo.SHARED)
repo.list = shared.list
repo.get = shared.get
repo.create = shared.create
repo.update = shared.update
repo.delete = shared.delete
repo.setting = shared.setting
repo.set_setting = shared.set_setting
repo.seeded = shared.seeded
repo.mark_seeded = shared.mark_seeded
repo.offer = shared.offer

return repo
