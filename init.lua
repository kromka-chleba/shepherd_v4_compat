local mod_name = core.get_current_modname()
local mod_path = core.get_modpath(mod_name)

shepherd_v4_compat = shepherd_v4_compat or {}
shepherd_v4_compat.mod_name = mod_name
shepherd_v4_compat.mod_path = mod_path
shepherd_v4_compat.secenv = core.request_insecure_environment()

dofile(mod_path .. "/compat_tags.lua")
dofile(mod_path .. "/compat_loader.lua")
