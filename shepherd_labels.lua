-- Assign shepherd labels to mapchunks based on node content from map.sqlite
-- This provides v4 compatibility by re-labeling mapchunks after database format changes
-- Note: SQL stores mapblocks, we convert to node positions, shepherd labels mapchunks

local mod_name = "shepherd_v4_compat"

-- This file requires insecure environment and will only run if available
-- Note: insecure environment must be requested in init.lua; retrieve it from the module table
local secenv = shepherd_v4_compat and shepherd_v4_compat.secenv
if not secenv then
    core.log("warning", "[" .. mod_name .. "] shepherd_labels.lua requires insecure environment")
    return false
end

local sql_map_reader = dofile(core.get_modpath(mod_name) .. "/sql_map_reader.lua")
if not sql_map_reader then
    core.log("error", "[" .. mod_name .. "] Failed to load sql_map_reader.lua")
    return false
end

mapchunk_shepherd = mapchunk_shepherd  -- Ensure global is loaded before accessing
assert(mapchunk_shepherd, "mapchunk_shepherd mod must be loaded before shepherd_v4_compat")
local ms = mapchunk_shepherd

local storage = core.get_mod_storage()
local debug_labels = core.settings:get_bool("shepherd_v4_debug_labels", false)
local debug_label_log_limit_raw = core.settings:get("shepherd_v4_debug_log_limit")
local debug_label_log_limit = tonumber(debug_label_log_limit_raw) or 30
if debug_label_log_limit_raw and tonumber(debug_label_log_limit_raw) == nil then
    core.log("warning", string.format(
        "[%s] Invalid shepherd_v4_debug_log_limit='%s'; using default 30",
        mod_name, tostring(debug_label_log_limit_raw)
    ))
end
if debug_label_log_limit < 0 then
    debug_label_log_limit = 0
end
local max_sampled_nodes_per_block = 8
local debug_logged_labeled_blocks = 0
local debug_logged_unlabeled_blocks = 0
local debug_stats = {
    labeled_blocks = 0,
    unlabeled_blocks = 0,
    label_hits = {},
}

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

local function sorted_keys(t)
    local keys = {}
    for key, _ in pairs(t) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

local function format_set(set_like)
    return table.concat(sorted_keys(set_like), ",")
end

local function format_label_hits(label_hits)
    local parts = {}
    local labels = sorted_keys(label_hits)
    for _, label in ipairs(labels) do
        table.insert(parts, label .. "=" .. tostring(label_hits[label]))
    end
    return table.concat(parts, ", ")
end

local function debug_log_labeled_block(pos, node_pos, labels_array, matched_nodes)
    if not debug_labels or debug_logged_labeled_blocks >= debug_label_log_limit then
        return
    end
    local mapchunk_hash = ms.mapchunk_hash(node_pos)
    core.log("action", string.format(
        "[%s][debug] label write #%d mapblock=(%d,%d,%d) node=(%d,%d,%d) mapchunk_hash=%s labels=[%s] matched_nodes=[%s]",
        mod_name,
        debug_logged_labeled_blocks + 1,
        pos.x, pos.y, pos.z,
        node_pos.x, node_pos.y, node_pos.z,
        tostring(mapchunk_hash),
        table.concat(labels_array, ","),
        format_set(matched_nodes)
    ))
    debug_logged_labeled_blocks = debug_logged_labeled_blocks + 1
end

local function debug_log_unlabeled_block(pos, sampled_nodes, unknown_count)
    if not debug_labels or debug_logged_unlabeled_blocks >= debug_label_log_limit then
        return
    end
    core.log("action", string.format(
        "[%s][debug] no labels for mapblock=(%d,%d,%d) unknown_nodes=%d sampled_nodes=[%s]",
        mod_name,
        pos.x, pos.y, pos.z,
        unknown_count,
        table.concat(sampled_nodes, ",")
    ))
    debug_logged_unlabeled_blocks = debug_logged_unlabeled_blocks + 1
end

local function process_mapblock(block_data)
    local pos = block_data.pos
    local nodes = block_data.nodes
    
    -- Convert mapblock position to node position (multiply by 16)
    -- The shepherd API accepts node positions and labels the containing mapchunk
    local node_pos = vector.new(pos.x * 16, pos.y * 16, pos.z * 16)
    
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

    if #labels_array == 0 then
        debug_stats.unlabeled_blocks = debug_stats.unlabeled_blocks + 1
        debug_log_unlabeled_block(pos, sampled_nodes, unknown_count)
        return true
    end

    table.sort(labels_array)
    debug_stats.labeled_blocks = debug_stats.labeled_blocks + 1
    for _, label in ipairs(labels_array) do
        debug_stats.label_hits[label] = (debug_stats.label_hits[label] or 0) + 1
    end
    debug_log_labeled_block(pos, node_pos, labels_array, matched_nodes)

    local ok, err = pcall(ms.labels_to_position, node_pos, labels_array)
    if not ok then
        core.log("error", string.format(
            "[%s] labels_to_position() failed at mapblock (%d,%d,%d): %s",
            mod_name, pos.x, pos.y, pos.z, tostring(err)
        ))
    end
    return ok
end

-- Run the migration
local function run_migration()
    if storage:get_string("migration_complete") == "true" then
        core.log("action", "[" .. mod_name .. "] Migration already done, skipping.")
        return
    end

    if shepherd_v4_compat and shepherd_v4_compat.ensure_compat_tags_defined then
        if not shepherd_v4_compat.ensure_compat_tags_defined() then
            core.log("error", "[" .. mod_name .. "] Migration aborted: required Exile tags are not defined")
            return
        end
    end

    if not (ms.database
        and type(ms.database.purge) == "function"
        and type(ms.database.initialize) == "function") then
        core.log("error", string.format(
            "[%s] Migration aborted: shepherd database API must provide callable purge() and initialize() methods",
            mod_name
        ))
        return
    end
    core.log("action", "[" .. mod_name .. "] Purging shepherd database before migration relabeling...")
    ms.database.purge()
    ms.database.initialize()

    core.log("action", "[" .. mod_name .. "] Starting mapblock label migration...")
    
    -- Send initial message to all connected players
    core.chat_send_all("[" .. mod_name .. "] Starting world migration. This may take a while for large worlds...")
    
    local start_time = os.clock()
    local block_count = 0
    local label_write_failures = 0
    local last_chat_time = start_time
    
    sql_map_reader.iterate_blocks(function(block_data)
        if not process_mapblock(block_data) then
            label_write_failures = label_write_failures + 1
        end
        block_count = block_count + 1
        
        -- Log progress every 1000 blocks
        if block_count % 1000 == 0 then
            core.log("action", string.format(
                "[" .. mod_name .. "] Processed %d mapblocks...",
                block_count
            ))
        end
        
        -- Send chat message to players every 10 seconds to show progress
        -- Check time only every 100 blocks to reduce os.clock() overhead
        if block_count % 100 == 0 then
            local current_time = os.clock()
            if current_time - last_chat_time >= 10 then
                core.chat_send_all(string.format(
                    "[" .. mod_name .. "] Migration in progress: %d mapblocks processed...",
                    block_count
                ))
                last_chat_time = current_time
            end
        end
    end)
    
    local elapsed = os.clock() - start_time
    local completion_msg = string.format(
        "[" .. mod_name .. "] Migration complete: %d mapblocks in %.2f seconds",
        block_count, elapsed
    )
    core.log("action", completion_msg)
    if label_write_failures > 0 then
        core.log("error", string.format(
            "[%s] Migration finished with %d mapblocks that failed to save labels",
            mod_name, label_write_failures
        ))
    end
    if debug_labels then
        core.log("action", string.format(
            "[%s][debug] migration label stats: labeled_blocks=%d unlabeled_blocks=%d label_hits={%s}",
            mod_name,
            debug_stats.labeled_blocks,
            debug_stats.unlabeled_blocks,
            format_label_hits(debug_stats.label_hits)
        ))
    end
    core.chat_send_all(completion_msg)
    storage:set_string("migration_complete", "true")
end

-- Execute migration on mod load
core.after(0, run_migration)

-- Return true to indicate successful loading
return true
