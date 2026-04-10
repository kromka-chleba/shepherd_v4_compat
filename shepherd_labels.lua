-- Assign shepherd labels to mapchunks based on node content from map.sqlite
-- This provides v4 compatibility by re-labeling mapchunks after database format changes
-- Note: SQL stores mapblocks, we convert to node positions, shepherd labels mapchunks

if not shepherd_v4_compat then
    error("[shepherd_v4_compat] Shared module table is not initialized")
end

local mod_name = shepherd_v4_compat.mod_name
if not mod_name then
    error("[shepherd_v4_compat] Module name is not initialized")
end
local mod_path = shepherd_v4_compat.mod_path
if not mod_path then
    error("[" .. mod_name .. "] Module path is not initialized")
end

-- This file requires insecure environment and will only run if available
-- Note: insecure environment must be requested in init.lua; retrieve it from the module table
local secenv = shepherd_v4_compat and shepherd_v4_compat.secenv
if not secenv then
    core.log("warning", "[" .. mod_name .. "] shepherd_labels.lua requires insecure environment")
    return false
end

dofile(mod_path .. "/sql_map_reader.lua")
dofile(mod_path .. "/migration_debug.lua")
dofile(mod_path .. "/shepherd_migration.lua")

local sql_map_reader = shepherd_v4_compat.sql_map_reader
local migration_debug = shepherd_v4_compat.migration_debug
local shepherd_migration = shepherd_v4_compat.shepherd_migration

if not sql_map_reader then
    error("[" .. mod_name .. "] Module sql_map_reader.lua did not register in shepherd_v4_compat table")
end
if not migration_debug then
    error("[" .. mod_name .. "] Module migration_debug.lua did not register in shepherd_v4_compat table")
end
if not shepherd_migration then
    error("[" .. mod_name .. "] Module shepherd_migration.lua did not register in shepherd_v4_compat table")
end

assert(mapchunk_shepherd, "mapchunk_shepherd mod must be loaded before shepherd_v4_compat")
local ms = mapchunk_shepherd

local debug_labels = core.settings:get_bool("shepherd_v4_debug_labels", false)
local debug_label_log_limit_raw = core.settings:get("shepherd_v4_debug_log_limit")
local debug_label_log_limit = tonumber(debug_label_log_limit_raw) or 30
local migration_defer_seconds_raw = core.settings:get("shepherd_v4_migration_defer_seconds")
local migration_defer_seconds = tonumber(migration_defer_seconds_raw) or 3
if debug_label_log_limit_raw and tonumber(debug_label_log_limit_raw) == nil then
    core.log("warning", string.format(
        "[%s] Invalid shepherd_v4_debug_log_limit='%s'; using default 30",
        mod_name, tostring(debug_label_log_limit_raw)
    ))
end
if migration_defer_seconds_raw and tonumber(migration_defer_seconds_raw) == nil then
    core.log("warning", string.format(
        "[%s] Invalid shepherd_v4_migration_defer_seconds='%s'; using default 3",
        mod_name, tostring(migration_defer_seconds_raw)
    ))
end
if debug_label_log_limit < 0 then
    debug_label_log_limit = 0
end
if migration_defer_seconds < 0 then
    migration_defer_seconds = 0
end
local max_sampled_nodes_per_block = 8
local debug_ctx = migration_debug.new({
    core = core,
    mod_name = mod_name,
    ms = ms,
    enabled = debug_labels,
    log_limit = debug_label_log_limit,
})

-- Node to label mappings based on shepherd_v3_compat patterns
-- Multiple labels can be assigned to a position
local node_to_labels = {
    -- Ocean biome nodes
    ["nodes_nature:salt_water_source"] = {"ocean"},
    
    -- Ice/freezing nodes
    ["nodes_nature:ice"] = {"last_freezed"},
    ["nodes_nature:sea_ice"] = {"last_freezed"},
    
    -- Snow nodes
    ["nodes_nature:snow"] = {"last_snow"},
    ["nodes_nature:snow_block"] = {"last_snow"},
    
    -- Freshwater nodes
    ["nodes_nature:freshwater_source"] = {"water_gravity"},
}

-- Group-based label assignments
-- We need to check node groups for these
local group_to_labels = {
    ["wet_sediment"] = {"moisture_spread"},
    ["drops_leaves"] = {"leaves"},
    ["leaf_marker"] = {"leaves_dropped"},
    -- The 'spreading' group marks spring/seasonal soils (nodes_nature soil nodes
    -- with grass on top, e.g. woodland_soil, grassland_soil). Winter soils and
    -- bare sediments do not have this group.
    ["spreading"] = {"seasonal_plants", "spring_soil"},
    -- In Exile's seasonal workers, winter soil mapchunks carry winter_soil
    -- and seasonal_plants labels.
    ["winter_soil"] = {"seasonal_plants", "winter_soil"},
}

local seasonal_soil_name_set = {}
local winter_soil_name_set = {}

local function register_soil_name_set(target_set, names)
    if type(names) ~= "table" then
        return
    end
    for _, name in ipairs(names) do
        if type(name) == "string" and name ~= "" then
            target_set[name] = true
        end
    end
end

if nodes_nature then
    if type(nodes_nature.get_seasonal_soil_names) == "function" then
        register_soil_name_set(seasonal_soil_name_set, nodes_nature.get_seasonal_soil_names())
    end
    if type(nodes_nature.get_winter_soil_names) == "function" then
        register_soil_name_set(winter_soil_name_set, nodes_nature.get_winter_soil_names())
    end
end

-- Check if a node belongs to a group
local function node_has_group(node_name, group)
    local node_def = core.registered_nodes[node_name]
    if node_def and node_def.groups and node_def.groups[group] then
        return true
    end
    return false
end

-- Get labels for a specific node
local function get_labels_for_node(node_name)
    local labels = {}
    local seen = {}

    local function add_label(label)
        if not seen[label] then
            table.insert(labels, label)
            seen[label] = true
        end
    end
    
    -- Direct node name mapping
    if node_to_labels[node_name] then
        for _, label in ipairs(node_to_labels[node_name]) do
            add_label(label)
        end
    end
    
    -- Group-based mappings
    for group, group_labels in pairs(group_to_labels) do
        if node_has_group(node_name, group) then
            for _, label in ipairs(group_labels) do
                add_label(label)
            end
        end
    end

    if seasonal_soil_name_set[node_name] then
        add_label("seasonal_plants")
        add_label("spring_soil")
    end
    if winter_soil_name_set[node_name] then
        add_label("seasonal_plants")
        add_label("winter_soil")
    end
    
    return labels
end

local collect_labels_for_mapblock_nodes

local function process_mapblock(block_data)
    local pos = block_data.pos
    local nodes = block_data.nodes

    -- Convert mapblock position to node position (multiply by 16)
    -- The shepherd API accepts node positions and labels the containing mapchunk
    local node_pos = vector.new(pos.x * 16, pos.y * 16, pos.z * 16)

    local labels_array, matched_nodes, sampled_nodes, unknown_count = collect_labels_for_mapblock_nodes(nodes)
    if #labels_array == 0 then
        debug_ctx.record_unlabeled(pos, sampled_nodes, unknown_count)
        return true
    end

    debug_ctx.record_labeled(pos, node_pos, labels_array, matched_nodes)

    local ok, err = pcall(ms.labels_to_position, node_pos, labels_array)
    if not ok then
        core.log("error", string.format(
            "[%s] labels_to_position() failed at mapblock (%d,%d,%d): %s",
            mod_name, pos.x, pos.y, pos.z, tostring(err)
        ))
    end
    return ok
end

collect_labels_for_mapblock_nodes = function(nodes)
    -- Track which labels should be added to the mapchunk containing this mapblock
    local labels_to_add = {}
    local matched_nodes = {}
    local sampled_nodes = {}
    local sampled_nodes_set = {}
    local unknown_count = 0
    
    -- Scan all nodes in the mapblock
    for _, node_name in ipairs(nodes) do
        if node_name == "unknown" then
            unknown_count = unknown_count + 1
end
        if node_name ~= "ignore" and node_name ~= "unknown" then
            if #sampled_nodes < max_sampled_nodes_per_block and not sampled_nodes_set[node_name] then
                table.insert(sampled_nodes, node_name)
                sampled_nodes_set[node_name] = true
            end
            local node_labels = get_labels_for_node(node_name)
            for _, label in ipairs(node_labels) do
                labels_to_add[label] = true
                matched_nodes[node_name] = true
            end
        end
    end
    
    -- Convert to array and assign labels if any were found
    local labels_array = {}
    for label, _ in pairs(labels_to_add) do
        table.insert(labels_array, label)
    end
    table.sort(labels_array)
    return labels_array, matched_nodes, sampled_nodes, unknown_count
end

local function ensure_required_tags_defined()
    if shepherd_v4_compat and shepherd_v4_compat.ensure_compat_tags_defined then
        if not shepherd_v4_compat.ensure_compat_tags_defined() then
            core.log("error", "[" .. mod_name .. "] Migration aborted: required Exile tags are not defined")
            return false
        end
    end
    return true
end

shepherd_migration.setup({
    core = core,
    mod_name = mod_name,
    ms = ms,
    storage = core.get_mod_storage(),
    migration_defer_seconds = migration_defer_seconds,
    debug_ctx = debug_ctx,
    sql_map_reader = sql_map_reader,
    process_mapblock = process_mapblock,
    ensure_required_tags_defined = ensure_required_tags_defined,
})

-- Return true to indicate successful loading
return true
