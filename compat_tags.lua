local namespace = shepherd_v4_compat
local mod_name = namespace.mod_name
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

-- Verify all compatibility tags exist (they are expected to be defined by Exile).
local function ensure_compat_tags_defined()
    if not (ms and ms.tag and ms.tag.check) then
        core.log("error", "[" .. mod_name .. "] mapchunk_shepherd tag API is unavailable")
        return false
    end

    local missing = {}
    for _, tag in ipairs(compat_tags) do
        if not ms.tag.check(tag) then
            table.insert(missing, tag)
        end
    end

    if #missing > 0 then
        core.log("error", string.format(
            "[%s] Missing required Exile tags: %s",
            mod_name, table.concat(missing, ", ")
        ))
        return false
    end

    core.log("action", "[" .. mod_name .. "] Verified required Exile tags for compatibility")
    return true
end

namespace.compat_tags = compat_tags
namespace.ensure_compat_tags_defined = ensure_compat_tags_defined
