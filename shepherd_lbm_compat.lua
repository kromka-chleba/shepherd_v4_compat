-- LBM-based compatibility fallback for shepherd v4
-- This file provides a fallback mechanism when insecure environment is not available
-- LBMs are inactive by default and must be enabled via game settings

local mod_name = core.get_current_modname()

-- Check if LBMs should be enabled (they are disabled by default)
local enable_lbms = core.settings:get_bool("shepherd_v4_use_lbm_fallback", false)

if not enable_lbms then
    core.log("action", "[" .. mod_name ..
        "] LBM fallback is disabled (set shepherd_v4_use_lbm_fallback=true to enable)")
    return
end

core.log("action", "[" .. mod_name .. "] Loading LBM fallback compatibility...")

assert(mapchunk_shepherd, "mapchunk_shepherd mod must be loaded before shepherd_v4_compat")
local ms = mapchunk_shepherd

-- Helper function to safely get node names from nodes_nature
local function get_nodes_nature_soil_names(func_name)
    if nodes_nature and nodes_nature[func_name] then
        local names = nodes_nature[func_name]()
        if names and #names > 0 then
            return names
        end
    end
    core.log("warning", "[" .. mod_name .. "] nodes_nature." .. func_name ..
        " not available or returned no nodes")
    return nil
end

-- Spring soil compatibility
local spring_labels = {
    "spring_soil",
    "seasonal_plants",
}

local spring_soil_names = get_nodes_nature_soil_names("get_seasonal_soil_names")
if spring_soil_names then
    core.register_lbm({
        name = "shepherd_v4_compat:spring_soil_lbm",
        label = "Spring soil finder for mapchunk shepherd",
        nodenames = spring_soil_names,
        run_at_every_load = false,
        bulk_action = function(pos_list, dtime_s)
            -- All positions in pos_list are from the same mapblock (16x16x16)
            -- We only need one position to label the containing mapchunk (80x80x80)
            -- since labels_to_position() labels entire mapchunks
            if pos_list and #pos_list > 0 then
                ms.labels_to_position(pos_list[1], spring_labels)
            end
        end,
    })
end

-- Winter soil compatibility
local winter_labels = {
    "winter_soil",
    "seasonal_plants",
}

local winter_soil_names = get_nodes_nature_soil_names("get_winter_soil_names")
if winter_soil_names then
    core.register_lbm({
        name = "shepherd_v4_compat:winter_soil_lbm",
        label = "Winter soil finder for mapchunk shepherd",
        nodenames = winter_soil_names,
        run_at_every_load = false,
        bulk_action = function(pos_list, dtime_s)
            -- All positions in pos_list are from the same mapblock (16x16x16)
            -- We only need one position to label the containing mapchunk (80x80x80)
            -- since labels_to_position() labels entire mapchunks
            if pos_list and #pos_list > 0 then
                ms.labels_to_position(pos_list[1], winter_labels)
            end
        end,
    })
end

-- Leaf marker compatibility
core.register_lbm({
    name = "shepherd_v4_compat:leaf_marker_lbm",
    label = "Leaf marker finder for mapchunk shepherd",
    nodenames = {"group:leaf_marker"},
    run_at_every_load = false,
    bulk_action = function(pos_list, dtime_s)
        if pos_list and #pos_list > 0 then
            ms.labels_to_position(pos_list[1], {"leaves_dropped"})
        end
    end,
})

-- Leaf compatibility
core.register_lbm({
    name = "shepherd_v4_compat:leaf_lbm",
    label = "Leaf finder for mapchunk shepherd",
    nodenames = {"group:drops_leaves"},
    run_at_every_load = false,
    bulk_action = function(pos_list, dtime_s)
        if pos_list and #pos_list > 0 then
            ms.labels_to_position(pos_list[1], {"leaves"})
        end
    end,
})

-- Wet soil compatibility
core.register_lbm({
    name = "shepherd_v4_compat:moisture_lbm",
    label = "Wet soil finder for mapchunk shepherd",
    nodenames = {"group:wet_sediment"},
    run_at_every_load = false,
    bulk_action = function(pos_list, dtime_s)
        if pos_list and #pos_list > 0 then
            ms.labels_to_position(pos_list[1], "moisture_spread")
        end
    end,
})

-- Freshwater source compatibility
core.register_lbm({
    name = "shepherd_v4_compat:freshwater_lbm",
    label = "Freshwater finder for mapchunk shepherd",
    nodenames = {"nodes_nature:freshwater_source"},
    run_at_every_load = false,
    bulk_action = function(pos_list, dtime_s)
        if pos_list and #pos_list > 0 then
            ms.labels_to_position(pos_list[1], "water_gravity")
        end
    end,
})

-- Freezing compatibility
core.register_lbm({
    name = "shepherd_v4_compat:ice_lbm",
    label = "Ice finder for mapchunk shepherd",
    nodenames = {"nodes_nature:ice", "nodes_nature:sea_ice"},
    run_at_every_load = false,
    bulk_action = function(pos_list, dtime_s)
        if pos_list and #pos_list > 0 then
            ms.labels_to_position(pos_list[1], {"last_freezed"})
        end
    end,
})

-- Snow compatibility
core.register_lbm({
    name = "shepherd_v4_compat:snow_lbm",
    label = "Snow finder for mapchunk shepherd",
    nodenames = {"nodes_nature:snow", "nodes_nature:snow_block"},
    run_at_every_load = false,
    bulk_action = function(pos_list, dtime_s)
        if pos_list and #pos_list > 0 then
            ms.labels_to_position(pos_list[1], {"last_snow"})
        end
    end,
})

-- Ocean compatibility
core.register_lbm({
    name = "shepherd_v4_compat:ocean_lbm",
    label = "Ocean finder for mapchunk shepherd",
    nodenames = {"nodes_nature:salt_water_source"},
    run_at_every_load = false,
    bulk_action = function(pos_list, dtime_s)
        if pos_list and #pos_list > 0 then
            ms.labels_to_position(pos_list[1], {"ocean"})
        end
    end,
})

core.log("action", "[" .. mod_name .. "] LBM fallback compatibility loaded successfully")
