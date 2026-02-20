# Shepherd v4 Compatibility Module

This mod provides compatibility for worlds upgrading from older versions of Exile (v0.3 and early v0.4-beta) where the mapchunk_shepherd internal database format changed.

## Purpose

The mapchunk_shepherd mod assigns labels to **mapchunks** during mapgen based on:
- Biome information
- Decoration placement
- Node content

Note: In Minetest/Luanti terminology:
- **Node** = one voxel (1x1x1)
- **Mapblock** = 16x16x16 nodes (what the SQL database stores)
- **Mapchunk** = 5x5x5 mapblocks (80x80x80 nodes, what mapgen uses and what gets labeled)

The shepherd API accepts node positions and internally determines which mapchunk contains that position, then labels that mapchunk.

When the database format changed, this labeling information was lost for existing mapchunks. This mod re-assigns shepherd labels to existing mapchunks using one of two methods:

## Compatibility Methods

### 1. SQL-Based (Preferred)

This is the primary method and requires insecure environment access.

The mod follows this data flow:

1. **SQL Map Reader** (`sql_map_reader.lua`): Reads and decodes mapblock data from the `map.sqlite` database, including:
   - Node ID to name mappings
   - Individual node content for all 4096 nodes per mapblock
   - Mapblock position information (in mapblock coordinates)

2. **Position Conversion**: Converts mapblock positions to node positions by multiplying by 16
   - Mapblock position (x, y, z) → Node position (x×16, y×16, z×16)

3. **Label Assignment** (`shepherd_labels.lua`): 
   - Maps specific nodes to shepherd labels (e.g., `nodes_nature:salt_water_source` → `ocean` label)
   - Checks node groups (e.g., `group:wet_sediment` → `moisture_spread` label)
   - Detects seasonal soil patterns (e.g., nodes with `_spring` → `spring_soil` and `seasonal_plants` labels)
   - Calls `ms.labels_to_position()` with node positions
   - The shepherd API internally determines which mapchunk contains each node position and labels that mapchunk

4. **Migration Execution**: Runs automatically on mod load, processing all mapblocks in the database.

**Requirements:**
- Add `shepherd_v4_compat` to your trusted mods list in `minetest.conf`:
  ```
  secure.trusted_mods = shepherd_v4_compat
  ```

### 2. LBM-Based Fallback (Optional)

If insecure environment is not available, you can enable the LBM-based fallback mechanism:

1. Set the following in `minetest.conf` or via game settings:
   ```
   shepherd_v4_use_lbm_fallback = true
   ```

2. **How it works:**
   - Uses Loading Block Modifiers (LBMs) to detect specific nodes when mapblocks are loaded
   - Labels the containing mapchunk based on the nodes found
   - LBMs run once per mapblock (not at every load) for better performance
   - Processes nodes as the world is explored/loaded

**Trade-offs:**
- ✅ No insecure environment required
- ✅ Works on all Minetest/Luanti versions
- ❌ Only processes mapblocks as they are loaded (not all at once)
- ❌ Slower than SQL-based method for large worlds

The LBM fallback was migrated from `nodes_nature:shepherd_v3_compat.lua` with the following improvements:
- Changed `run_at_every_load = true` to `false` for better performance (LBMs run once per mapblock)
- Uses `bulk_action` for efficiency - processes all matching nodes in a mapblock with a single function call
- Only needs one position from `pos_list[1]` because `ms.labels_to_position()` labels the entire mapchunk
- Made inactive by default with a setting to enable

**Why bulk_action?** The shepherd API's `labels_to_position(pos, labels)` function takes a single position and labels the entire mapchunk (5x5x5 mapblocks = 80x80x80 nodes) that contains it. LBMs process mapblocks (16x16x16 nodes), and `bulk_action` provides all matching node positions within that mapblock in one call. Since the mapblock is part of a larger mapchunk, we only need to call `labels_to_position()` once with any position from `pos_list` (e.g., `pos_list[1]`) to label the entire containing mapchunk. Using `bulk_action` instead of `action` reduces overhead significantly by processing all matches in one call instead of invoking a callback for each individual node.

## Node to Label Mappings

The following mappings are implemented based on the `shepherd_v3_compat` patterns:

- **Ocean**: `nodes_nature:salt_water_source` → `ocean`
- **Freezing**: `nodes_nature:ice`, `nodes_nature:sea_ice` → `last_freezed`
- **Snow**: `nodes_nature:snow`, `nodes_nature:snow_block` → `last_snow`
- **Water**: `nodes_nature:freshwater_source` → `water_gravity`
- **Moisture**: `group:wet_sediment` → `moisture_spread`
- **Leaves**: `group:drops_leaves` → `leaves`
- **Leaf Markers**: `group:leaf_marker` → `leaves_dropped`
- **Spring Soil**: Nodes matching `*_spring*` pattern or `spreading` group → `spring_soil`, `seasonal_plants`
- **Winter Soil**: Nodes matching `*_winter*` pattern → `winter_soil`, `seasonal_plants`

## Compatibility

The SQL-based method automatically detects and supports both SQL table formats:

**Pre-5.12.0 format:**
```sql
CREATE TABLE `blocks` (`pos` INT NOT NULL PRIMARY KEY, `data` BLOB);
```
Position is encoded as a single integer hash.

**5.12.0+ format:**
```sql
CREATE TABLE `blocks` (
    `x` INTEGER, `y` INTEGER, `z` INTEGER,
    `data` BLOB NOT NULL,
    PRIMARY KEY (`x`, `z`, `y`)
);
```
Position is stored as separate x, y, z columns.

## Performance

**SQL-Based Migration:**
- Runs once on server start and processes all existing mapblocks
- Processing time depends on world size
- Progress is logged every 1000 mapblocks
- Total processing time is reported when complete

**LBM-Based Migration:**
- Runs incrementally as mapblocks are loaded during gameplay
- Lower initial load time but slower overall migration
- Only affects mapblocks that contain matching nodes

