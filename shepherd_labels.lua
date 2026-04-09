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
local migration_debug = dofile(core.get_modpath(mod_name) .. "/migration_debug.lua")
if not migration_debug then
    core.log("error", "[" .. mod_name .. "] Failed to load migration_debug.lua")
    return false
end

mapchunk_shepherd = mapchunk_shepherd  -- Ensure global is loaded before accessing
assert(mapchunk_shepherd, "mapchunk_shepherd mod must be loaded before shepherd_v4_compat")
local ms = mapchunk_shepherd

local storage = core.get_mod_storage()
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
local migration_scheduled = false
local migration_running = false
local migration_complete = storage:get_string("migration_complete") == "true"
local migration_armed_by_purge = false

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

local function should_skip_migration()
    if migration_complete or storage:get_string("migration_complete") == "true" then
        core.log("action", "[" .. mod_name .. "] Migration already done, skipping.")
        migration_complete = true
        return true
    end
    return false
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

local function ensure_shepherd_database_api()
    if not (ms.database
        and type(ms.database.purge_for_migration) == "function"
        and type(ms.database.register_on_purged) == "function"
        and type(ms.database.initialize) == "function") then
        core.log("error", string.format(
            "[%s] Migration aborted: shepherd database API must provide callable purge_for_migration(), register_on_purged(), and initialize() methods",
            mod_name
        ))
        return false
    end
    return true
end

local function initialize_shepherd_database()
    local init_ok, init_err = pcall(ms.database.initialize)
    if not init_ok then
        core.log("error", string.format(
            "[%s] Migration aborted: initialize() failed after purge: %s",
            mod_name, tostring(init_err)
        ))
        return false
    end

    return true
end

local function is_migration_purge_event(event_data)
    return type(event_data) == "table"
        and event_data.event == "database_purged"
        and event_data.reason == "migration"
end

local function migrate_mapblocks()
    core.log("action", "[" .. mod_name .. "] Starting mapblock label migration...")
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

    return block_count, label_write_failures, os.clock() - start_time
end

local function finalize_migration(block_count, label_write_failures, elapsed)
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
    if debug_ctx.is_enabled then
        core.log("action", string.format(
            "[%s][debug] migration label stats: labeled_blocks=%d unlabeled_blocks=%d label_hits={%s}",
            mod_name,
            debug_ctx.stats.labeled_blocks,
            debug_ctx.stats.unlabeled_blocks,
            debug_ctx.format_label_hits(debug_ctx.stats.label_hits)
        ))
    end
    core.chat_send_all(completion_msg)
    storage:set_string("migration_complete", "true")
    migration_complete = true
end

-- Run the migration
local function run_migration()
    if migration_running then
        return
    end
    migration_running = true

    if should_skip_migration() then
        migration_armed_by_purge = false
        migration_scheduled = false
        migration_running = false
        return
    end
    if not ensure_required_tags_defined() then
        migration_scheduled = false
        migration_running = false
        return
    end
    if not ensure_shepherd_database_api() then
        migration_scheduled = false
        migration_running = false
        return
    end
    if not migration_armed_by_purge then
        core.log("action", "[" .. mod_name .. "] Migration not armed by purge event, skipping.")
        migration_scheduled = false
        migration_running = false
        return
    end

    if not initialize_shepherd_database() then
        migration_scheduled = false
        migration_running = false
        return
    end
    local block_count, label_write_failures, elapsed = migrate_mapblocks()
    finalize_migration(block_count, label_write_failures, elapsed)
    migration_armed_by_purge = false
    migration_scheduled = false
    migration_running = false
end

local function schedule_migration(trigger)
    if migration_complete then
        return
    end
    if migration_scheduled then
        return
    end
    migration_scheduled = true

    core.log("action", string.format(
        "[%s] Scheduling migration in %d second(s) (trigger: %s)",
        mod_name, migration_defer_seconds, tostring(trigger)
    ))

    core.after(migration_defer_seconds, run_migration)
end

local function handle_database_purged(event_data)
    if not is_migration_purge_event(event_data) then
        return
    end
    if migration_complete then
        return
    end
    migration_armed_by_purge = true
    schedule_migration("database_purged:migration")
end

local function request_manual_migration_purge(requester_name)
    if migration_running then
        return false, "Migration is already running; cannot request another purge."
    end

    if migration_complete or storage:get_string("migration_complete") == "true" then
        migration_complete = true
        return false, "Migration is already complete."
    end

    if not ensure_shepherd_database_api() then
        return false, "Shepherd database API is missing required methods (purge_for_migration, register_on_purged, or initialize)."
    end

    local ok, err_or_event = pcall(ms.database.purge_for_migration)
    if not ok then
        return false, "Failed to request shepherd migration purge: " .. tostring(err_or_event)
    end

    core.log("action", string.format(
        "[%s] Manual migration purge requested by %s",
        mod_name,
        requester_name or "<unknown>"
    ))
    return true, "Migration purge requested; migration will run after purge callback."
end

core.register_on_mods_loaded(function()
    if not ensure_shepherd_database_api() then
        return
    end

    ms.database.register_on_purged(handle_database_purged)
end)

core.register_chatcommand("shepherd_v4_migrate", {
    params = "",
    description = "Request shepherd purge for shepherd_v4_compat SQL migration",
    privs = { server = true },
    func = function(name)
        return request_manual_migration_purge(name)
    end,
})

-- Return true to indicate successful loading
return true
