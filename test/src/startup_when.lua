-- The `when` functions of the harness's startup fixtures, called through
-- `funcs` as the shell calls an application's: one says yes to one user only
-- (so the user id is seen to arrive), one always says no, one fails.
local function user(args: any): any
    return {show = type(args) == "table" and args.user_id == "u-startup"}
end

local function no(): any
    return {show = false}
end

local function fail(): any
    error("this when function fails on purpose")
end

return {user = user, no = no, fail = fail}
