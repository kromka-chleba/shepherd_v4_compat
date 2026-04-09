local namespace = shepherd_v4_compat
local mod_name = namespace.mod_name
local mod_path = namespace.mod_path

core.log("action", "[" .. mod_name .. "] Loading shepherd v4 compatibility...")

assert(mapchunk_shepherd, string.format(
    "[%s] mapchunk_shepherd mod must be loaded before this compatibility module",
    mod_name
))

local secenv = core.request_insecure_environment()
namespace.secenv = secenv
local sql_loaded = false

if secenv then
    local success, sql_lib = pcall(secenv.require, "lsqlite3")

    if success and sql_lib then
        sql_loaded = dofile(mod_path .. "/shepherd_labels.lua")

        if sql_loaded then
            core.log("action", "[" .. mod_name .. "] Loaded SQL-based compatibility successfully")
        else
            core.log("warning", "[" .. mod_name .. "] shepherd_labels.lua did not load successfully")
        end
    else
        core.log("error", "[" .. mod_name .. "] SQLite (lsqlite3) is not installed or not available")
        core.log("error", "[" .. mod_name .. "] SQL-based compatibility cannot function without SQLite")
        core.log("warning", "[" .. mod_name .. "] Set shepherd_v4_use_lbm_fallback=true to enable LBM fallback")
    end
else
    core.log("warning", "[" .. mod_name .. "] Insecure environment not available, SQL-based compatibility disabled")
    core.log("warning", "[" .. mod_name .. "] Add 'shepherd_v4_compat' to secure.trusted_mods in minetest.conf")
    core.log("warning", "[" .. mod_name .. "] Set shepherd_v4_use_lbm_fallback=true to enable LBM fallback")
end

dofile(mod_path .. "/shepherd_lbm_compat.lua")

core.log("action", "[" .. mod_name .. "] Loaded successfully")
