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
local label_setter_mode = nil
local label_setter_mode_logged = false

local function can_use_label_store_fallback()
    return ms.label_store and type(ms.label_store.new) == "function"
        and type(ms.mapchunk_hash) == "function"
end

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
}

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
    
    -- Direct node name mapping
    if node_to_labels[node_name] then
        for _, label in ipairs(node_to_labels[node_name]) do
            table.insert(labels, label)
        end
    end
    
    -- Group-based mappings
    for group, group_labels in pairs(group_to_labels) do
        if node_has_group(node_name, group) then
            for _, label in ipairs(group_labels) do
                table.insert(labels, label)
            end
        end
    end
    
    return labels
end

-- Process a single mapblock and assign labels
-- Converts mapblock position to node position, then labels the containing mapchunk
local function set_labels_with_fallback(pos, labels)
    if #labels == 0 then
        return true
    end

    if not label_setter_mode then
        if type(ms.labels_to_position) == "function" then
            label_setter_mode = "shepherd_api"
        elseif can_use_label_store_fallback() then
            label_setter_mode = "label_store_fallback"
        else
            label_setter_mode = "unavailable"
        end
    end

    if not label_setter_mode_logged then
        core.log("action", "[" .. mod_name .. "] Label setter mode: " .. label_setter_mode)
        label_setter_mode_logged = true
    end

    if label_setter_mode == "shepherd_api" then
        local ok, err = pcall(ms.labels_to_position, pos, labels)
        if ok then
            return true
        end
        core.log("error", "[" .. mod_name .. "] labels_to_position() failed: " .. tostring(err))
        if can_use_label_store_fallback() then
            core.log("warning", "[" .. mod_name .. "] Falling back to direct label_store writes")
            label_setter_mode = "label_store_fallback"
        else
            label_setter_mode = "unavailable"
        end
    end

    if label_setter_mode == "label_store_fallback" then
        -- Fallback writes labels directly via label_store for the mapchunk hash.
        -- This bypasses labels_to_position() when that API fails unexpectedly.
        local ok, err = pcall(function()
            local hash = ms.mapchunk_hash(pos)
            local ls = ms.label_store.new(hash)
            ls:add_labels(labels)
            ls:save_to_disk()
        end)
        if ok then
            return true
        end
        core.log("error", "[" .. mod_name .. "] label_store fallback failed: " .. tostring(err))
        label_setter_mode = "unavailable"
    end

    return false
end

local function process_mapblock(block_data)
    local pos = block_data.pos
    local nodes = block_data.nodes
    
    -- Convert mapblock position to node position (multiply by 16)
    -- The shepherd API accepts node positions and labels the containing mapchunk
    local node_pos = vector.new(pos.x * 16, pos.y * 16, pos.z * 16)
    
    -- Track which labels should be added to the mapchunk containing this mapblock
    local labels_to_add = {}
    
    -- Scan all nodes in the mapblock
    for _, node_name in ipairs(nodes) do
        if node_name ~= "ignore" and node_name ~= "unknown" then
            local node_labels = get_labels_for_node(node_name)
            for _, label in ipairs(node_labels) do
                labels_to_add[label] = true
            end
        end
    end
    
    -- Convert to array and assign labels if any were found
    local labels_array = {}
    for label, _ in pairs(labels_to_add) do
        table.insert(labels_array, label)
    end
    
    return set_labels_with_fallback(node_pos, labels_array)
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
        core.log("error",
            "[" .. mod_name .. "] Migration aborted: shepherd database API must provide callable purge() and initialize() methods")
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
            "[" .. mod_name .. "] Migration finished with %d mapblocks that failed to save labels",
            label_write_failures
        ))
    end
    core.chat_send_all(completion_msg)
    storage:set_string("migration_complete", "true")
end

-- Execute migration on mod load
core.after(0, run_migration)

-- Return true to indicate successful loading
return true
