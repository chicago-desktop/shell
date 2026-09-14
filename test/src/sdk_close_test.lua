-- A close the window may refuse (C1, C3): the compositor's `close` is a
-- request, and a window keeps itself open only by calling `context.stay()`
-- while answering `{type = "close"}` — Notepad asks "save changes?" first.
-- What `update` returns does not count: `false` is "nothing changed", and a
-- window answering it to every action it does not handle must still close. The
-- rule is `app.refuses_close`; the loop is checked live, in this process, the
-- way sdk_test's A6 runs `app.run`.
local test = require("test")
local app = require("app")
local process = require("process")
local desktop = require("desktop")
local channel = require("channel")
local time = require("time")

-- A loop that ends at a close leaves the events sent after it in this
-- process's inbox, and the next test's `app.run` would read them as its own
-- (a key "after the close" reaching a window that never got one). Read them
-- off here, until the inbox is quiet.
local function drain()
    local events = desktop.inputs()
    if not events then return end
    while true do
        local picked = channel.select({events:case_receive(), time.after("50ms"):case_receive()})
        if picked.channel ~= events or not picked.ok then return end
    end
end

-- What the runner told the compositor: `desktop.close` is swapped for a
-- recorder while `app.run` runs (the test and `app` share the same
-- `window_api` table), and put back after.
local function recording(run: any): any
    local calls: any = {}
    local original = desktop.close
    desktop.close = function(id: any, opts: any): (any, any)
        calls[#calls + 1] = {id = id, refused = type(opts) == "table" and opts.refused == true}
        return true, nil
    end
    run()
    desktop.close = original
    drain()
    return calls
end

local function definition_with(update: any): any
    return {update = update}
end

local function staying(answer: any): any
    return definition_with(function(_: any, _: any, context: any): any
        context.stay()
        return answer
    end)
end

local function define_tests()
    test.describe("SDK close requests", function()
        test.it("the rule: only stay() keeps the window open; update's answer does not count", function()
            local context = app.context({width = 10, height = 4})
            test.is_false(app.refuses_close(definition_with(function(): any return false end), {}, context),
                "false without stay closes: it only means nothing changed")
            test.is_false(app.refuses_close(definition_with(function(): any return nil end), {}, context))
            test.is_false(app.refuses_close(definition_with(function(): any return true end), {}, context))
            test.is_false(app.refuses_close({}, {}, context), "a window without update closes")

            test.is_true(app.refuses_close(staying(false), {}, app.context({width = 10, height = 4})),
                "stay() refuses")
            test.is_true(app.refuses_close(staying(nil), {}, app.context({width = 10, height = 4})),
                "stay() refuses whatever update returns")
            test.is_true(app.refuses_close(staying(true), {}, app.context({width = 10, height = 4})))

            local seen: any = {}
            test.is_true(app.refuses_close(definition_with(function(_: any, action: any, context: any): any
                seen.action = action.type
                context.stay()
                return false
            end), {}, app.context({width = 10, height = 4})))
            test.eq(seen.action, "close", "update is asked with the close action")

            -- A stay() from an earlier answer does not refuse the next close.
            local earlier = app.context({width = 10, height = 4})
            test.is_true(app.refuses_close(staying(false), {}, earlier))
            test.is_false(app.refuses_close(definition_with(function(): any return false end), {}, earlier),
                "the next close asks afresh")
            local elsewhere = app.context({width = 10, height = 4})
            elsewhere.stay()
            test.is_false(app.refuses_close(definition_with(function(): any return false end), {}, elsewhere),
                "stay() outside the close answer means nothing")

            local closing = app.context({width = 10, height = 4})
            test.is_false(app.refuses_close(definition_with(function(_: any, _: any, context: any): any
                context.stay()
                context.close()
                return false
            end), {}, closing), "close() wins over stay()")

            local failed = app.context({width = 10, height = 4})
            failed.failure = "update: broken"
            test.is_false(app.refuses_close(staying(false), {}, failed), "the failure tree has no update to ask")
            local erring = app.context({width = 10, height = 4})
            test.is_false(app.refuses_close(definition_with(function(_: any, _: any, context: any): any
                context.stay()
                error("on purpose")
            end), {}, erring), "an update that fails closes")
        end)

        test.it("the loop keeps running after a refused close and ends on the one the window accepts", function()
            -- Observations live in a table, not in locals: an error under pcall
            -- tears the upvalue between a closure and its owner (go-lua).
            local seen: any = {closes = 0, keys = 0, views = 0, disposed = false}
            local definition = {
                init = function(args: any, context: any): any
                    -- The `window.input` listener is open before `init`: these
                    -- reach the loop in order.
                    process.send(process.pid(), "window.input", {event = {type = "close"}})
                    process.send(process.pid(), "window.input",
                        {event = {type = "key", key = "x", key_type = "runes", action = "press"}})
                    process.send(process.pid(), "window.input", {event = {type = "close"}})
                    return {}
                end,
                view = function(): any
                    seen.views = seen.views + 1
                    return {kind = "label", text = "document"}
                end,
                update = function(model: any, action: any, context: any): any
                    if action.type == "close" then
                        seen.closes = seen.closes + 1
                        if seen.closes == 1 then context.stay() end
                        -- Both answers are false: only stay() decides.
                        return false
                    end
                    if action.type == "key" then seen.keys = seen.keys + 1 end
                    return false
                end,
                dispose = function() seen.disposed = true end,
            }
            local calls = recording(function()
                app.run(definition, nil, "sdk-close-refused", nil, {width = 20, height = 4, cell_w = 8, cell_h = 18})
            end)
            test.eq(seen.closes, 2, "the refused close did not end the loop")
            test.eq(seen.keys, 1, "an event after the refusal reached the window")
            test.is_true(seen.views >= 2, "the refused close redraws: " .. seen.views)
            test.is_true(seen.disposed, "the accepted close disposes")
            -- The refusal is told, so the compositor does not call the window
            -- stuck; the accepted close ends with the plain one after dispose.
            test.eq(#calls, 2, "a refusal, then the close")
            test.eq(calls[1].id, "sdk-close-refused")
            test.is_true(calls[1].refused, "the refusal says refused")
            test.is_false(calls[2].refused, "the real close does not")
        end)

        test.it("a window answering false to everything closes at the first close", function()
            -- The folder window, the monitor widgets and Calculator end their
            -- update with `return false`: that is not a refusal.
            local seen: any = {closes = 0, keys = 0, disposed = false}
            local definition = {
                init = function(args: any, context: any): any
                    process.send(process.pid(), "window.input", {event = {type = "close"}})
                    process.send(process.pid(), "window.input",
                        {event = {type = "key", key = "x", key_type = "runes", action = "press"}})
                    return {}
                end,
                view = function(): any return {kind = "label", text = "folder"} end,
                update = function(model: any, action: any): any
                    if action.type == "close" then seen.closes = seen.closes + 1 end
                    if action.type == "key" then seen.keys = seen.keys + 1 end
                    return false
                end,
                dispose = function() seen.disposed = true end,
            }
            local calls = recording(function()
                app.run(definition, nil, "sdk-close-false", nil, {width = 20, height = 4, cell_w = 8, cell_h = 18})
            end)
            test.eq(seen.closes, 1)
            test.eq(seen.keys, 0, "nothing after the close reaches it")
            test.is_true(seen.disposed)
            test.eq(#calls, 1, "no refusal is told, only the close")
            test.is_false(calls[1].refused)
        end)

        test.it("a window that calls context.close() while answering a close ends at once", function()
            local seen: any = {closes = 0, keys = 0, disposed = false}
            local definition = {
                init = function(args: any, context: any): any
                    process.send(process.pid(), "window.input", {event = {type = "close"}})
                    process.send(process.pid(), "window.input",
                        {event = {type = "key", key = "x", key_type = "runes", action = "press"}})
                    return {}
                end,
                view = function(): any return {kind = "label", text = "document"} end,
                update = function(model: any, action: any, context: any): any
                    if action.type == "close" then
                        seen.closes = seen.closes + 1
                        context.stay()
                        context.close()
                        return false
                    end
                    if action.type == "key" then seen.keys = seen.keys + 1 end
                    return false
                end,
                dispose = function() seen.disposed = true end,
            }
            local calls = recording(function()
                app.run(definition, nil, "sdk-close-self", nil, {width = 20, height = 4, cell_w = 8, cell_h = 18})
            end)
            test.eq(seen.closes, 1)
            test.eq(seen.keys, 0, "nothing after the close reaches it")
            test.is_true(seen.disposed)
            test.eq(#calls, 1, "no refusal is told, only the close")
            test.is_false(calls[1].refused)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
