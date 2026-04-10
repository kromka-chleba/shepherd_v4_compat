if not shepherd_v4_compat then
    error("[shepherd_v4_compat] Shared module table is not initialized")
end
shepherd_v4_compat.migration_debug = {}
local migration_debug_module = shepherd_v4_compat.migration_debug

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

function migration_debug_module.new(opts)
    local core = opts.core
    local mod_name = opts.mod_name
    local ms = opts.ms
    local enabled = opts.enabled
    local log_limit = opts.log_limit

    local logged_labeled_blocks = 0
    local logged_unlabeled_blocks = 0

    local ctx = {
        is_enabled = enabled,
        stats = {
            labeled_blocks = 0,
            unlabeled_blocks = 0,
            label_hits = {},
        },
        format_label_hits = format_label_hits,
    }

    function ctx.log_labeled_block(pos, node_pos, labels_array, matched_nodes)
        if not enabled or logged_labeled_blocks >= log_limit then
            return
        end
        local mapchunk_hash = ms.mapchunk_hash(node_pos)
        core.log("action", string.format(
            "[%s][debug] label write #%d mapblock=(%d,%d,%d) node=(%d,%d,%d) mapchunk_hash=%s labels=[%s] matched_nodes=[%s]",
            mod_name,
            logged_labeled_blocks + 1,
            pos.x, pos.y, pos.z,
            node_pos.x, node_pos.y, node_pos.z,
            tostring(mapchunk_hash),
            table.concat(labels_array, ","),
            format_set(matched_nodes)
        ))
        logged_labeled_blocks = logged_labeled_blocks + 1
    end

    function ctx.log_unlabeled_block(pos, sampled_nodes, unknown_count)
        if not enabled or logged_unlabeled_blocks >= log_limit then
            return
        end
        core.log("action", string.format(
            "[%s][debug] no labels for mapblock=(%d,%d,%d) unknown_nodes=%d sampled_nodes=[%s]",
            mod_name,
            pos.x, pos.y, pos.z,
            unknown_count,
            table.concat(sampled_nodes, ",")
        ))
        logged_unlabeled_blocks = logged_unlabeled_blocks + 1
    end

    function ctx.record_unlabeled(pos, sampled_nodes, unknown_count)
        ctx.stats.unlabeled_blocks = ctx.stats.unlabeled_blocks + 1
        ctx.log_unlabeled_block(pos, sampled_nodes, unknown_count)
    end

    function ctx.record_labeled(pos, node_pos, labels_array, matched_nodes)
        ctx.stats.labeled_blocks = ctx.stats.labeled_blocks + 1
        for _, label in ipairs(labels_array) do
            ctx.stats.label_hits[label] = (ctx.stats.label_hits[label] or 0) + 1
        end
        ctx.log_labeled_block(pos, node_pos, labels_array, matched_nodes)
    end

    return ctx
end
