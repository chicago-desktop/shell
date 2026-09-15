-- The whole shell, brought up in a test.
--
-- Its screen is real, only not a terminal but a viewport issued by the test.
-- For a day and a half it was believed here that the mechanics cannot be
-- checked without a real terminal — wrong, and here is the price of that
-- misconception: the `desktop.refresh` command, which the layout handlers
-- send AFTER every edit, was NEVER executed in the base. It landed in the
-- "no such window" branch, because it does not name a window, and silently
-- did nothing. From outside this looks like "the icon appears only after a
-- restart" — that is, like a layout defect, not like a command that did not
-- fire.
--
-- So what is checked here is not the shape of the registry but the chain
-- itself: the row is written — the shell is pushed — the shell re-read.
local test = require("test")
local channel = require("channel")
local control = require("control")
local process = require("process")
local repo = require("repo")
local time = require("time")
local tty = require("tty")

-- Bring up the shell and wait until it registers under its name.
-- We wait for the NAME, not for time: the name appears when the shell is
-- ready to accept commands, while a sleep at random gives now a false
-- failure, now a test that "sometimes passes".
local function boot_shell()
    local view = tty.viewport({width = 90, height = 26})
    test.not_nil(view, "the viewport was not created")
    local grant = view:grant()
    test.not_nil(grant, "the viewport grant was not issued")

    -- The entry is real, not a copy of the shell for the test: a copy would
    -- diverge from the original on the first edit, and what would be checked
    -- is not the shell that comes up on the stand. It takes the service name
    -- for itself — the same one `control` looks for.
    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("windows.shell:shell", "app:processes", "test")
    test.is_nil(err)
    test.not_nil(pid, "the shell did not start")

    local deadline = time.now():unix_nano() + 15000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(control.SERVICE_NAME) then
            return {pid = pid, view = view}
        end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.is_true(false, "the shell did not register under the name " .. control.SERVICE_NAME)
    return {pid = pid, view = view}
end

local function define_tests()
    test.describe("windows.shell shell alive", function()
        test.it("re-reads the layout on a handler's command", function()
            local shell: any = boot_shell()

            -- The first pass does not measure but creates the furniture: the
            -- shell puts out "My Computer" and the "Programs" folder on the
            -- first read, and counting before it would mean measuring two
            -- different desktops.
            local first, ferr = control.call("desktop.refresh", {})
            test.is_nil(ferr, "the shell must answer desktop.refresh")
            test.not_nil(first, "a command that does not run answers with silence")
            test.is_nil(first.failure, "the layout must be readable")

            local before = first.items
            test.not_nil(before, "the answer must say how many rows were read")

            -- Exactly what a person does with the PATCH handler: the row is
            -- written to the database, and without a push the shell will not
            -- learn about it until a restart.
            local item, cerr = repo.create({
                kind = repo.KIND_FOLDER, title = "Re-read probe",
            })
            test.is_nil(cerr)
            test.not_nil(item)

            local after, aerr = control.call("desktop.refresh", {})
            test.is_nil(aerr)
            test.eq(after.items, before + 1,
                "the re-read layout must carry the row just written")

            -- And the same through the handler's eyes: it must SAY that the
            -- push got through. While the command was silently not running,
            -- this read refreshed = false with the reason "no window nil" —
            -- that is, the handler sent the person looking for a typo in an
            -- identifier they had not sent.
            local reported = control.refresh()
            test.is_true(reported.refreshed,
                "the handler must report that the shell re-read: " ..
                tostring(reported.reason))

            repo.delete(item.id)
            process.terminate(tostring(shell.pid))
        end)

        test.it("does not pass off a stopped shell as a failure", function()
            -- The layout can be edited while the shell is stopped too, and
            -- calling that a failure is not allowed: the handler would return
            -- an error for a successful write.
            --
            -- The shell is stopped by THIS case itself, not by the previous
            -- one. A check that relies on the neighbor's cleanup goes red
            -- together with it and lies about the reason: had the previous
            -- one failed, this one would read "a stopped shell is passed off
            -- as a failure", which did not happen.
            local running = process.registry.lookup(control.SERVICE_NAME)
            if running then process.terminate(tostring(running)) end

            local deadline = time.now():unix_nano() + 10000000000
            while time.now():unix_nano() < deadline do
                if not process.registry.lookup(control.SERVICE_NAME) then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_nil(process.registry.lookup(control.SERVICE_NAME),
                "the shell must stop")

            local reported = control.refresh()
            test.is_false(reported.refreshed)
            test.is_true(reported.reason:find("is not running", 1, true) ~= nil,
                "the reason must tell a stopped shell from a failure")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
