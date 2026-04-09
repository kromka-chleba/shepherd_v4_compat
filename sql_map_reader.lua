-- Note: insecure environment must be requested in init.lua; retrieve it from the module table
local secenv = shepherd_v4_compat and shepherd_v4_compat.secenv
local sql

-- The `map.sqlite` table has different structures depending on Luanti version:
--
-- Pre-5.12.0 format:
-- CREATE TABLE `blocks` (`pos` INT NOT NULL PRIMARY KEY, `data` BLOB);
-- Position is encoded as: pos = (z << 24) + (y << 12) + x
--
-- 5.12.0+ format:
-- CREATE TABLE `blocks` (`x` INTEGER, `y` INTEGER, `z` INTEGER,
--                        `data` BLOB NOT NULL, PRIMARY KEY (`x`, `z`, `y`));
-- Position is stored as separate x, y, z columns
--
-- The code below automatically detects which schema is in use and retrieves data accordingly.
-- What is obtained are node content IDs (core.get_content_id(node_name)) mapped to node names.

-- load insecure environment

if secenv then
    print("[shepherd_v4_compat] insecure environment loaded.")
    local success, lib = pcall(secenv.require, "lsqlite3")
    if success then
        sql = lib
        assert(sql)
        assert(sql.open)
    else
        core.log("error", "[shepherd_v4_compat] Could not find sqlite3 (lsqlite3). Old map update will not function")
        core.log("error", "[shepherd_v4_compat] " .. tostring(lib))
        return nil
    end
else
    core.log("error", "[shepherd_v4_compat] Failed to load insecure" ..
                 " environment, please add this mod to the trusted mods list.")
    return nil
end


local wpath = core.get_worldpath()
local filespec = wpath..'/map.sqlite'
local db
if sql then
    db = sql.open(filespec)
end
assert(db)
local cid_name_cache = {}

-- Export functions for use by other files in this mod
local sql_map_reader = {}

-- Detect SQL table schema version
-- Returns: "new" for 5.12.0+ (x,y,z columns), "old" for pre-5.12.0 (pos column)
local function detect_schema()
    -- Query the table structure
    local has_pos = false
    local has_xyz = false
    
    for row in db:nrows("PRAGMA table_info(blocks)") do
        if row.name == "pos" then
            has_pos = true
        elseif row.name == "x" or row.name == "y" or row.name == "z" then
            has_xyz = true
        end
    end
    
    if has_xyz then
        return "new"
    elseif has_pos then
        return "old"
    else
        error("[shepherd_v4_compat] Unknown map.sqlite schema - neither pos nor x,y,z columns found")
    end
end

-- Decode position hash (for old schema only)
local function decode_pos_hash(hash)
        local value = tonumber(hash)
        if not value then
            return nil
        end

        -- Match Luanti's MapDatabase::getIntegerAsBlock using arithmetic.
        -- Do not use Lua bitops here: old-schema position values exceed 32-bit.
        value = value + 0x800800800
        local x = (value % 0x1000) - 0x800
        value = math.floor(value / 0x1000)
        local y = (value % 0x1000) - 0x800
        local z = (math.floor(value / 0x1000) % 0x1000) - 0x800

        return {
            x = x,
            y = y,
            z = z,
        }
end

-- Read map nodes for a mapblock position and return node data
function sql_map_reader.read_mapblock_nodes(block_pos)
    local minp = vector.new(block_pos.x * 16, block_pos.y * 16, block_pos.z * 16)
    local maxp = vector.new(minp.x + 15, minp.y + 15, minp.z + 15)

    local vm = core.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    if not emin or not emax then
        return {
            pos = block_pos,
            nodes = {},
            id_name_table = {}
        }
    end

    local voxel_data = vm:get_data()
    local nodes = {}
    local id_name_table = {}
    local cid_to_local_id = {}
    local next_local_id = 0

    for i = 1, #voxel_data do
        local cid = voxel_data[i]
        local node_name = cid_name_cache[cid]
        if not node_name then
            node_name = core.get_name_from_content_id(cid) or "unknown"
            cid_name_cache[cid] = node_name
        end
        nodes[#nodes + 1] = node_name

        local local_id = cid_to_local_id[cid]
        if local_id == nil then
            local_id = next_local_id
            next_local_id = next_local_id + 1
            cid_to_local_id[cid] = local_id
            id_name_table[local_id] = node_name
        end
    end

    return {
        pos = block_pos,
        nodes = nodes,
        id_name_table = id_name_table
    }
end

-- Iterate through mapblock positions stored in map.sqlite and call a callback for each
function sql_map_reader.iterate_block_positions(callback)
    if not db then
        core.log("error", "[shepherd_v4_compat] Database not available")
        return
    end

    local schema = detect_schema()
    core.log("action", string.format("[shepherd_v4_compat] Detected map.sqlite schema: %s (%s format)",
        schema, schema == "new" and "5.12.0+" or "pre-5.12.0"))

    if schema == "new" then
        -- New schema (5.12.0+): SELECT x,y,z FROM blocks
        for row in db:nrows("SELECT x,y,z FROM blocks") do
            local block_pos = { x = row.x, y = row.y, z = row.z }
            callback(block_pos)
        end
    else
        -- Old schema (pre-5.12.0): SELECT pos FROM blocks
        for row in db:nrows("SELECT pos FROM blocks") do
            local block_pos = decode_pos_hash(row.pos)
            if not block_pos then
                core.log("warning", string.format(
                    "[shepherd_v4_compat] Skipping block row with invalid pos value: %s",
                    tostring(row.pos)
                ))
                goto continue_old_block_row
            end
            callback(block_pos)
            ::continue_old_block_row::
        end
    end
end

-- Iterate through all blocks, read their nodes, and call a callback for each
function sql_map_reader.iterate_blocks(callback)
    local count = 0
    local start = os.clock()

    sql_map_reader.iterate_block_positions(function(block_pos)
        local block_data = sql_map_reader.read_mapblock_nodes(block_pos)
        callback(block_data)
        count = count + 1
    end)

    local elapsed = os.clock() - start
    core.log("action", string.format(
        "[shepherd_v4_compat] Processed %d mapblocks in %.2f seconds",
        count, elapsed
    ))
end

return sql_map_reader
