-- A program that exists for the sake of one line in its declaration:
-- `meta.group`.
--
-- The catalog builds menu folders from the registry, and before this entry
-- there was not a single program with a group in the harness — that is, the
-- path "group → folder" was checked only on made-up tables. The defect that
-- kept the folder from being created lived exactly between the registry and
-- the theme.
--
-- The window draws nothing: it is needed as an ENTRY, not as a program.
local function main()
    return true, nil
end

return {main = main}
