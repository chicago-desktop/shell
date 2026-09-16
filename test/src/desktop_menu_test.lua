local test = require("test")
local menu = require("menu")
local function define_tests()
    test.describe("Desktop menu contributions",function()
        test.it("sorts valid windows, skips malformed entries and keeps only supported fields",function()
            local function entry(id,order,data) return {id=id,meta={order=order},data=data} end
            local records = {
                entry("b",20,{text="Later",entry="test:window",quit=true}),
                entry("z",10,{text="Second",entry="test:window",args="hello"}),
                entry("a",10,{text="First",entry="test:window"}),
                entry("missing",0,{text="Missing",entry="test:absent"}),
                entry("bad",0,{text="Bad",entry="test:window",args={}}),
            }
            local items,why = menu.read(function(filter)
                test.eq(filter[".kind"],"registry.entry"); test.eq(filter["meta.type"],"chicago.desktop_menu")
                return records
            end,function(id) if id == "test:window" then return {meta={type="tui_desktop.window"}} end end)
            test.eq(#items,3);test.eq(items[1].id,"a");test.eq(items[2].id,"z");test.eq(items[3].id,"b")
            test.eq(items[2].args,"hello");test.is_nil(items[3].quit);test.not_nil(why)
        end)
        test.it("reports registry failures and reflects removed contributions",function()
            local items,why = menu.read(function() return nil,"denied" end)
            test.eq(#items,0);test.is_true(why:find("denied",1,true) ~= nil)
            local empty,reason = menu.read(function() return {} end)
            test.eq(#empty,0);test.is_nil(reason)
        end)
    end)
end
local run_cases = test.run_cases(define_tests)
return {run=function(options) return run_cases(options) end}
