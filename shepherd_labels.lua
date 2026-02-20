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
    -- The 'spreading' group is assigned to spring/summer seasonal soils
    -- (winter soils and roots explicitly have spreading=nil or 0)
    ["spreading"] = {"seasonal_plants"},
}

-- Seasonal soil mappings require checking specific node patterns
-- Spring soils typically have "spring" or nodes with spreading group
-- Winter soils are derived from spring soils and have "winter" in name
local seasonal_soil_patterns = {
    spring = {
        patterns = {"_spring_", "_spring$", "^spring_"},
        labels = {"spring_soil", "seasonal_plants"},
    },
    winter = {
        patterns = {"_winter_", "_winter$", "^winter_"},
        labels = {"winter_soil", "seasonal_plants"},
    },
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
    
    -- Seasonal soil pattern matching
    for season, info in pairs(seasonal_soil_patterns) do
        for _, pattern in ipairs(info.patterns) do
            if string.find(node_name, pattern) then
                for _, label in ipairs(info.labels) do
                    table.insert(labels, label)
                end
                break
            end
        end
    end
    
    return labels
end

-- Process a single mapblock and assign labels
-- Converts mapblock position to node position, then labels the containing mapchunk
local function process_mapblock(block_data)
    local pos = block_data.pos
    local nodes = block_data.nodes
    
    -- Convert mapblock position to node position (multiply by 16)
    -- The shepherd API accepts node positions and labels the containing mapchunk
    local node_pos = {
        x = pos.x * 16,
        y = pos.y * 16,
        z = pos.z * 16
    }
    
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
    
    if #labels_array > 0 then
        ms.labels_to_position(node_pos, labels_array)
    end
end

-- Run the migration
local function run_migration()
    core.log("action", "[" .. mod_name .. "] Starting mapblock label migration...")
    
    -- Send initial message to all connected players
    core.chat_send_all("[" .. mod_name .. "] Starting world migration. This may take a while for large worlds...")
    
    local start_time = os.clock()
    local block_count = 0
    local last_chat_time = start_time
    
    sql_map_reader.iterate_blocks(function(block_data)
        process_mapblock(block_data)
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
    core.chat_send_all(completion_msg)
end

-- Execute migration on mod load
core.after(0, run_migration)

-- Return true to indicate successful loading
return true
