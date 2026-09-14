-- AntiBug (FR-009 §3): does a `funcs` call run the callee under the actor and
-- policies its entry declares, or under the caller's? Measured with two
-- function entries of this harness that report who they ran as and what they
-- could do: `antibug_actor_probe` declares its own actor and a policy granting
-- `antibug.probe`; `antibug_actor_plain` is the same code without a `security`
-- block — the control that shows the measurement tells the cases apart.
-- The narrow caller is built here: an actor of its own and a scope whose only
-- grant is `funcs.call` on the two probes (`antibug_narrow_grant`).
local test = require("test")
local security = require("security")
local funcs = require("funcs")

local function describe_answer(label: string, answer: any, err: any): string
    if err then return label .. " error=" .. tostring(err) end
    if type(answer) ~= "table" then return label .. " answer=" .. tostring(answer) end
    return label .. " actor=" .. tostring(answer.actor) .. " probe=" .. tostring(answer.probe)
        .. " other=" .. tostring(answer.other)
end

local function define_tests()
    test.describe("AntiBug: a funcs call and the callee's declared actor", function()
        test.it("measured: the facts of one wide and two narrow calls, in one line", function()
            test.is_true(security.can("antibug.other", "target"), "the test holds the runner's wildcard")
            local grant, grant_err = security.policy("app:antibug_narrow_grant")
            test.is_nil(grant_err, tostring(grant_err))
            local narrow_actor = security.new_actor("antibug.test.narrow")
            local narrow_scope = security.new_scope({grant})
            local function narrow(): any
                return funcs.new():with_actor(narrow_actor):with_scope(narrow_scope)
            end

            local facts = {}
            local direct, direct_err = funcs.new():call("app:antibug_actor_probe")
            facts[#facts + 1] = describe_answer("wide->declared", direct, direct_err)
            local declared, declared_err = narrow():call("app:antibug_actor_probe")
            facts[#facts + 1] = describe_answer("narrow->declared", declared, declared_err)
            local plain, plain_err = narrow():call("app:antibug_actor_plain")
            facts[#facts + 1] = describe_answer("narrow->plain", plain, plain_err)

            test.eq(table.concat(facts, " | "), table.concat({
                "wide->declared actor=app:antibug_actor_probe probe=true other=true",
                "narrow->declared actor=app:antibug_actor_probe probe=true other=false",
                "narrow->plain actor=antibug.test.narrow probe=false other=false",
            }, " | "))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
