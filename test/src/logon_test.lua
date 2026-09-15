-- Logon screen: password mask, Enter order, refusal and retry, cancel, snapshot.
--
-- The dialog is run on a FAKE screen: events are its own channel, filled in
-- advance, the frame is an in-memory canvas. The password check is a stub
-- that records what it was given: that way it is visible that after a
-- refusal the password field is empty, while the name stayed.
local test = require("test")
local channel = require("channel")
local tty = require("tty")
local fs = require("fs")
local gfx = require("gfx")
local screen_lib = require("screen")
local chrome_pixels = require("chrome_pixels")
local ui = require("ui")
local cells = require("cells")
local provider = require("provider")
local errors = require("errors")

local function runes(word: any): any
    local out = {}
    for rune in tostring(word):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = {type = "key", key_type = "runes", key = rune}
    end
    return out
end

local function fake_screen(events: any, pixels: boolean): any
    local screen: any = {
        events = events, pixels = pixels, width = 100, height = 30,
        canvas = tty.canvas(100, 30), frames = 0, painted = nil,
    }
    function screen.cell() return 10, 20 end
    function screen.resize() return screen.width, screen.height end
    function screen.present(painted: any)
        screen.frames = screen.frames + 1
        screen.painted = painted
        return true
    end
    return screen
end

local function feed(events: any, list: any)
    for _, event in ipairs(list) do assert(events:send(event)) end
end

-- Accepts both a canvas and a ready list of rows (`cells.rows` returns the latter).
local function joined(canvas: any): string
    local rows: any = type(canvas) == "table" and canvas or canvas:rows()
    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = tostring(row) end
    return table.concat(out, "\n")
end

local function define_tests()
    test.describe("Welcome to Chicago", function()
        test.it("masks the password with asterisks, keeping the real value in the tree", function()
            local tree = screen_lib.tree({user = "pb", password = "secret", busy = false})
            local interaction = ui.interaction()
            local plan = ui.plan(tree, 52, 7, interaction)
            local shown = joined(cells.rows(plan, interaction, 52, 7))
            test.is_true(shown:find("******", 1, true) ~= nil, "no asterisks")
            test.is_nil(shown:find("secret", 1, true))
            test.is_true(shown:find("pb", 1, true) ~= nil, "user name not shown")
            test.eq(plan.by_id["password"].node.text, "secret")
        end)

        test.it("Enter in the name leads to the password; a refusal clears the password, the second attempt logs on", function()
            local events = channel.new(64)
            feed(events, runes("pb"))
            feed(events, {{type = "key", key = "enter"}})
            feed(events, runes("wrong"))
            feed(events, {{type = "key", key = "enter"}})
            feed(events, runes("right"))
            feed(events, {{type = "key", key = "enter"}})
            local screen = fake_screen(events, false)
            local attempts = {}
            local identity, why = screen_lib.run(screen, function(login, password)
                attempts[#attempts + 1] = {login = login, password = password}
                if password == "right" then return {actor = "A", scope = "S", context = {user_id = "u1"}}, nil end
                return nil, "Wrong password"
            end)
            test.is_nil(why)
            test.not_nil(identity)
            test.eq(identity.context.user_id, "u1")
            test.eq(#attempts, 2)
            test.eq(attempts[1].login, "pb")
            test.eq(attempts[1].password, "wrong")
            test.eq(attempts[2].login, "pb")
            -- The password after a refusal is empty: "wrongright" would mean the field was not cleared.
            test.eq(attempts[2].password, "right")
            test.is_true(screen.frames >= 6, "fewer frames than key presses")
        end)

        test.it("does not call the check with an empty name and shows a hint", function()
            local events = channel.new(8)
            feed(events, {{type = "key", key = "enter"}, {type = "key", key = "esc"}})
            local screen = fake_screen(events, false)
            local called = false
            local identity, why = screen_lib.run(screen, function() called = true; return nil, "x" end)
            test.is_nil(identity)
            test.eq(why, "logon cancelled")
            test.is_true(not called, "check called with an empty name")
            test.is_true(joined(screen.canvas):find("Type a user name.", 1, true) ~= nil)
        end)

        test.it("Esc and 'Cancel' refuse without a check; a closed terminal names the reason", function()
            local events = channel.new(8)
            feed(events, {{type = "key", key = "esc"}})
            local _, why = screen_lib.run(fake_screen(events, false), function() error("must not be called") end)
            test.eq(why, "logon cancelled")

            events = channel.new(8)
            -- Tab: name → password → OK → Cancel, then Enter.
            feed(events, {{type = "key", key = "tab"}, {type = "key", key = "tab"}, {type = "key", key = "tab"},
                {type = "key", key = "enter"}})
            _, why = screen_lib.run(fake_screen(events, false), function() error("must not be called") end)
            test.eq(why, "logon cancelled")

            events = channel.new(8)
            events:close()
            _, why = screen_lib.run(fake_screen(events, false), function() error("must not be called") end)
            test.eq(why, "the terminal closed before logon")
        end)

        test.it("draws the dialog in cells as a theme window: title, fields, buttons", function()
            local events = channel.new(8)
            events:close()
            local screen = fake_screen(events, false)
            screen_lib.run(screen, function() return nil, "x" end)
            local shown = joined(screen.canvas)
            for _, expected in ipairs({screen_lib.TITLE, "User name:", "Password:", "OK", "Cancel"}) do
                test.is_true(shown:find(expected, 1, true) ~= nil, "missing: " .. expected)
            end
        end)

        test.it("draws the dialog in pixels through the theme's paint and produces a snapshot", function()
            local font_files = assert(fs.get("app:system_fonts"))
            local face = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
            local bold = assert(gfx.font(assert(font_files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
            chrome_pixels.use_fonts(face, bold, bold)
            chrome_pixels.use_cell_size(10, 20)

            local events = channel.new(16)
            feed(events, runes("pb"))
            feed(events, {{type = "key", key = "enter"}})
            feed(events, runes("secret"))
            events:close()
            local screen = fake_screen(events, true)
            local _, why = screen_lib.run(screen, function() return nil, "x" end)
            test.eq(why, "the terminal closed before logon")
            local painted: any = screen.painted
            test.not_nil(painted)
            test.is_true(#painted.placements > 0, "no placements")

            local ids = {}
            local shot = assert(gfx.raster(100 * 10, 30 * 20))
            shot:fill("#008080")
            for _, item in ipairs(painted.placements) do
                ids[item.id] = true
                shot:blit(item.raster, (item.x - 1) * 10 + 1, (item.y - 1) * 20 + 1)
            end
            test.is_true(ids["win:logon:head"] == true, "no window title")
            test.is_true(ids["win:logon:sdk:row:1"] == true, "no SDK client (a placement per client row)")
            test.is_nil(ids["bars"], "taskbar drawn on the logon screen")
            assert(assert(fs.get("app:shots")):writefile("logon.png", assert(shot:encode("png"))))
        end)
    end)

    -- The logged-on user's name, read again on `desktop.refresh` through the
    -- application's function (CHICAGO_USER_FUNC). The call is a
    -- stand-in that records what it was asked.
    test.describe("The logged-on user's name, read again", function()
        test.it("takes the name only from a success, and tells a permission denial apart", function()
            local asked: any = {}
            local function answering(answer: any, err: any): any
                return function(name: any, args: any): (any, any)
                    asked[#asked + 1] = tostring(name) .. ":" .. tostring(args.user_id)
                    return answer, err
                end
            end
            test.eq(provider.USER_FUNC_ENV, "CHICAGO_USER_FUNC")
            local name, why, denied = provider.display_name("app.desktop:user_name", "u1",
                answering({success = true, user_id = "u1", name = "Pavel B."}, nil))
            test.eq(name, "Pavel B.")
            test.is_nil(why)
            test.eq(denied, false)
            test.eq(asked[1], "app.desktop:user_name:u1", "the function is asked about the logged-on user")

            name, why, denied = provider.display_name("app.desktop:user_name", "u1",
                answering({success = false, error = "user not found"}, nil))
            test.is_nil(name, "a refusal keeps the old name")
            test.eq(why, "the user name function refused: user not found")
            test.eq(denied, false)

            name, why, denied = provider.display_name("app.desktop:user_name", "u1",
                answering(nil, errors.new({message = "funcs.call is not allowed", kind = errors.PERMISSION_DENIED})))
            test.is_nil(name)
            test.eq(denied, true, "a permission denial is named as one")
            test.is_true(tostring(why):find("no permission to call app.desktop:user_name", 1, true) ~= nil, tostring(why))

            name, why = provider.display_name("app.desktop:user_name", "u1", answering(nil, "timeout"))
            test.is_nil(name)
            test.eq(why, "the user name function did not answer: timeout")
            test.is_nil(provider.display_name("app.desktop:user_name", "u1", answering({success = true, name = ""}, nil)),
                "an empty name is no name")
            test.is_nil(provider.display_name("app.desktop:user_name", nil, answering({success = true, name = "x"}, nil)),
                "nobody logged on, nothing to ask")
            test.eq(#asked, 5, "the last call is not made without a user")
        end)
    end)

    test.describe("A desktop nobody vouched for", function()
        test.it("is refused only when the host asked nothing and the shell cannot ask either", function()
            local config = {func = "app:logon", store = "app:tokens"}
            test.is_nil(provider.unvouched_refusal(nil, nil, nil), "the machine's own terminal")
            test.is_nil(provider.unvouched_refusal("key", nil, nil), "a key vouched for the connection")
            test.is_nil(provider.unvouched_refusal("none", config, nil), "the logon asks who came")

            local unset = provider.unvouched_refusal("none", nil, nil)
            test.not_nil(unset)
            test.is_true(string.find(tostring(unset), "not configured", 1, true) ~= nil, tostring(unset))

            local denied = provider.unvouched_refusal("none", nil, "no permission to read X (env.get)")
            test.is_true(string.find(tostring(denied), "no permission to read X", 1, true) ~= nil,
                "a permission denial is named, not called 'not configured'")
        end)
    end)

    test.describe("Logging on by an SSH key", function()
        test.it("asks the logon function with the key alone and passes its refusal on", function()
            local asked: any = {}
            local function call(name: any, args: any): (any, any)
                asked[#asked + 1] = {name = name, args = args}
                return {success = false, error = "This SSH key is not registered to any account."}, nil
            end
            local identity, why = provider.authenticate_key({func = "app:logon", store = "app:tokens"},
                "ssh-ed25519 AAAA", call)
            test.is_nil(identity)
            test.eq(why, "This SSH key is not registered to any account.")
            test.eq(#asked, 1)
            test.eq(asked[1].name, "app:logon")
            test.eq(asked[1].args.ssh_key, "ssh-ed25519 AAAA")
            test.is_nil(asked[1].args.password, "no password travels with a key")
        end)

        test.it("does not ask without a key, and names a function that did not answer", function()
            local count: any = {n = 0}
            local function call(): (any, any)
                count.n = count.n + 1
                return nil, "boom"
            end
            test.is_nil((provider.authenticate_key({func = "f", store = "s"}, "", call)))
            test.eq(count.n, 0)
            local _, why = provider.authenticate_key({func = "f", store = "s"}, "ssh-ed25519 AAAA", call)
            test.is_true(string.find(tostring(why), "did not answer", 1, true) ~= nil, tostring(why))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
