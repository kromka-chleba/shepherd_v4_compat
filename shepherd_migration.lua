local shepherd_migration = {}

function shepherd_migration.setup(opts)
    local core = opts.core
    local mod_name = opts.mod_name
    local ms = opts.ms
    local storage = opts.storage
    local migration_defer_seconds = opts.migration_defer_seconds
    local debug_ctx = opts.debug_ctx
    local sql_map_reader = opts.sql_map_reader
    local process_mapblock = opts.process_mapblock
    local ensure_required_tags_defined = opts.ensure_required_tags_defined

    local migration_scheduled = false
    local migration_running = false
    local migration_complete = storage:get_string("migration_complete") == "true"
    local migration_armed_by_purge = false
    local pending_migration_purge_seq = nil
    local last_handled_migration_purge_seq = storage:get_int("last_handled_migration_purge_seq")

    local function should_skip_migration()
        if migration_complete or storage:get_string("migration_complete") == "true" then
            core.log("action", "[" .. mod_name .. "] Migration already done, skipping.")
            migration_complete = true
            return true
        end
        return false
    end

    local function ensure_shepherd_database_api()
        if not (ms.database
            and type(ms.database.purge_for_migration) == "function"
            and type(ms.database.register_on_purged) == "function"
            and type(ms.database.initialize) == "function"
            and type(ms.database.get_purge_state) == "function") then
            core.log("error", string.format(
                "[%s] Migration aborted: shepherd database API must provide callable purge_for_migration(), register_on_purged(), initialize(), and get_purge_state() methods",
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

    local function parse_purge_seq(raw_seq)
        local seq = tonumber(raw_seq)
        if not seq then
            return nil
        end
        seq = math.floor(seq)
        if seq <= 0 then
            return nil
        end
        return seq
    end

    local function can_consume_migration_purge_seq(purge_seq)
        if not purge_seq then
            return false
        end
        return purge_seq > last_handled_migration_purge_seq
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

            if block_count % 1000 == 0 then
                core.log("action", string.format(
                    "[" .. mod_name .. "] Processed %d mapblocks...",
                    block_count
                ))
            end

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
        if pending_migration_purge_seq and pending_migration_purge_seq > last_handled_migration_purge_seq then
            last_handled_migration_purge_seq = pending_migration_purge_seq
            storage:set_int("last_handled_migration_purge_seq", last_handled_migration_purge_seq)
        end
    end

    local function run_migration()
        local function finish_run(clear_purge_arm)
            migration_scheduled = false
            if clear_purge_arm then
                migration_armed_by_purge = false
                pending_migration_purge_seq = nil
            end
            migration_running = false
        end

        if migration_running then
            return
        end
        migration_running = true

        if should_skip_migration() then
            finish_run(true)
            return
        end
        if not ensure_required_tags_defined() then
            finish_run(false)
            return
        end
        if not ensure_shepherd_database_api() then
            finish_run(false)
            return
        end
        if not migration_armed_by_purge then
            core.log("action", "[" .. mod_name .. "] Migration not armed by purge event, skipping.")
            finish_run(false)
            return
        end

        if not initialize_shepherd_database() then
            finish_run(false)
            return
        end
        local block_count, label_write_failures, elapsed = migrate_mapblocks()
        finalize_migration(block_count, label_write_failures, elapsed)
        finish_run(true)
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
        local purge_seq = parse_purge_seq(event_data.purge_seq)
        if not can_consume_migration_purge_seq(purge_seq) then
            return
        end
        migration_armed_by_purge = true
        pending_migration_purge_seq = purge_seq
        schedule_migration("database_purged:migration")
    end

    local function reconcile_with_shepherd_purge_state()
        if migration_complete then
            return
        end
        local ok, purge_state = pcall(ms.database.get_purge_state)
        if not ok then
            core.log("warning", string.format(
                "[%s] Failed to query shepherd purge state: %s",
                mod_name, tostring(purge_state)
            ))
            return
        end
        if type(purge_state) ~= "table" then
            return
        end
        local seq = parse_purge_seq(purge_state.seq)
        if not can_consume_migration_purge_seq(seq) then
            return
        end
        if purge_state.reason ~= "migration" then
            return
        end

        local event_data = {
            event = "database_purged",
            reason = "migration",
            purge_seq = seq,
        }
        if type(purge_state.event) == "table" then
            for key, value in pairs(purge_state.event) do
                event_data[key] = value
            end
        end
        event_data.purge_seq = parse_purge_seq(event_data.purge_seq) or seq
        handle_database_purged(event_data)
    end

    local function request_manual_migration_purge(requester_name)
        if migration_running then
            return false, "Migration is already running; purge request denied."
        end

        if migration_complete or storage:get_string("migration_complete") == "true" then
            migration_complete = true
            return false, "Migration is already complete."
        end

        if not ensure_shepherd_database_api() then
            return false, "Shepherd database API is missing required methods (purge_for_migration, register_on_purged, initialize, or get_purge_state)."
        end

        local ok, err = pcall(ms.database.purge_for_migration)
        if not ok then
            return false, "Failed to request shepherd migration purge: " .. tostring(err)
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
        reconcile_with_shepherd_purge_state()
    end)

    core.register_chatcommand("shepherd_v4_migrate", {
        params = "",
        description = "Request shepherd purge for shepherd_v4_compat SQL migration",
        privs = { server = true },
        func = function(name)
            return request_manual_migration_purge(name)
        end,
    })
end

return shepherd_migration
