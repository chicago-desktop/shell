local test = require("test")
local bitmap = require("bitmap")
local gfx = require("gfx")
local base64 = require("base64")
local app = require("app")
local ui = require("ui")
local function define_tests()
    test.describe("Inline SDK pictures",function()
        test.it("decodes PNG once and gives both plans the same dimensions",function()
            local source = gfx.raster(32,24);source:fill("#008080")
            local data = assert(base64.encode(assert(source:encode("png"))))
            local first = assert(bitmap.source(data))
            test.eq(bitmap.source(data),first)
            local tree = {kind="column",children={{kind="picture",id="image",png=data,fill=true,fit="contain"},
                {kind="button",id="close",text="Close",size=2}}}
            app.measure(tree)
            test.eq(tree.children[1].natural_w,32);test.eq(tree.children[1].natural_h,24)
            local plan=ui.plan(tree,20,10,ui.interaction(),{cell={w=10,h=20}})
            test.eq(plan.by_id.image.rect.h,8);test.eq(plan.by_id.close.rect.y,9)
        end)
        test.it("rejects malformed and oversized images without raising",function()
            for _,data in ipairs({"bad base64",assert(base64.encode("not png")),string.rep("a",1400001)}) do
                local raster,why = bitmap.source(data);test.is_nil(raster);test.not_nil(why)
            end
            local large = gfx.raster(1025,1)
            local raster,why = bitmap.source(assert(base64.encode(assert(large:encode("png")))))
            test.is_nil(raster);test.not_nil(why)
        end)
    end)
end
local run_cases=test.run_cases(define_tests)
return {run=function(options) return run_cases(options) end}
