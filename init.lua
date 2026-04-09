-- Shepherd v4 Compatibility Module
-- Re-assigns shepherd labels to mapchunks based on node content from map.sqlite
-- Note: SQL stores mapblocks → convert to node positions → shepherd labels mapchunks

local mod_name = core.get_current_modname()
local mod_path = core.get_modpath(mod_name)

core.log("action", "[" .. mod_name .. "] Loading shepherd v4 compatibility...")

assert(mapchunk_shepherd,
    "[" .. mod_name .. "] mapchunk_shepherd mod must be loaded before " .. mod_name)
local ms = mapchunk_shepherd

-- Tags used by this compatibility module for mapchunk labels.
local compat_tags = {
    "ocean",
    "last_freezed",
    "last_snow",
    "water_gravity",
    "moisture_spread",
    "leaves",
    "leaves_dropped",
    "spring_soil",
    "seasonal_plants",
    "winter_soil",
}

-- Register all compatibility tags before any label writes happen.
local function ensure_compat_tags_registered()
    if not (ms.tag and ms.tag.check and ms.tag.register) then
        core.log("error", "[" .. mod_name .. "] mapchunk_shepherd tag API is unavailable")
        return false
    end

    local registered = 0
    for _, tag in ipairs(compat_tags) do
        if not ms.tag.check(tag) then
            ms.tag.register(tag)
            registered = registered + 1
        end
    end

    core.log("action", string.format(
        "[%s] Verified compatibility tag registrations (%d newly registered)",
        mod_name, registered
    ))
    return true
end

shepherd_v4_compat = shepherd_v4_compat or {}
shepherd_v4_compat.ensure_compat_tags_registered = ensure_compat_tags_registered
shepherd_v4_compat.compat_tags = compat_tags

if not ensure_compat_tags_registered() then
    core.log("error", "[" .. mod_name .. "] Failed to register compatibility tags")
end

-- Try to use insecure environment for SQL-based compatibility first
-- Note: core.request_insecure_environment() MUST be called only from init.lua
local secenv = core.request_insecure_environment()
shepherd_v4_compat.secenv = secenv  -- Store for use by submodules (dofile'd files)
local sql_loaded = false

if secenv then
    -- Try to load SQLite library to check if it's available
    local success, sql_lib = pcall(secenv.require, "lsqlite3")
    
    if success and sql_lib then
        -- SQLite is available, load the label assignment system which uses SQL
        sql_loaded = dofile(mod_path .. "/shepherd_labels.lua")
        
        if sql_loaded then
            core.log("action", "[" .. mod_name .. "] Loaded SQL-based compatibility successfully")
        else
            core.log("warning", "[" .. mod_name .. "] shepherd_labels.lua did not load successfully")
        end
    else
        -- SQLite is not available
        core.log("error", "[" .. mod_name .. "] SQLite (lsqlite3) is not installed or not available")
        core.log("error", "[" .. mod_name .. "] SQL-based compatibility cannot function without SQLite")
        core.log("warning", "[" .. mod_name .. "] Set shepherd_v4_use_lbm_fallback=true to enable LBM fallback")
    end
else
    core.log("warning", "[" .. mod_name .. "] Insecure environment not available, SQL-based compatibility disabled")
    core.log("warning", "[" .. mod_name .. "] Add 'shepherd_v4_compat' to secure.trusted_mods in minetest.conf")
    core.log("warning", "[" .. mod_name .. "] Set shepherd_v4_use_lbm_fallback=true to enable LBM fallback")
end

-- Load LBM-based fallback (only activates if setting is enabled)
dofile(mod_path .. "/shepherd_lbm_compat.lua")

core.log("action", "[" .. mod_name .. "] Loaded successfully")
