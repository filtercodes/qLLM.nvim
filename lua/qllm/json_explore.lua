local M = {}
local Window = require("qllm.window")
local Ui = require("qllm.ui")

-- Module-level cache to store decoded Lua tables for each popup buffer.
-- This bypasses the slow serialization/copying overhead of crossing the vim.b boundary.
local json_cache = {}

-- Module-level cache to persist state for files across popup lifetimes (within the session)
M.saved_paths = {}

local find_folding_index -- Forward declaration

local function get_perf_log_path()
    local path = vim.fn.stdpath("state")
    if not path or path == "" then
        path = vim.fn.stdpath("cache")
    end
    return path .. "/qllm_perf.log"
end

local function save_undo_state(bufnr)
    local path = vim.b[bufnr].json_path or {}
    local fold = vim.b[bufnr].json_active_fold_idx
    local path_copy = {}
    for i, v in ipairs(path) do
        path_copy[i] = v
    end
    vim.b[bufnr].json_last_path = path_copy
    vim.b[bufnr].json_last_fold_idx = fold
end

function M.render(bufnr)
    local start_time = vim.loop.hrtime()
    -- Fetch the JSON data from the fast, pure Lua memory cache
    local data = json_cache[bufnr]
    local path = vim.b[bufnr].json_path or {}
    local filepath = vim.b[bufnr].json_file or ""

    local t1 = vim.loop.hrtime()

    -- Navigate to the target node
    local node = data
    for _, key in ipairs(path) do
        if type(node) == "table" then
            node = node[key]
        else
            node = nil
            break
        end
    end

    local t2 = vim.loop.hrtime()

    local lines = {}
    table.insert(lines, "# JSON Explorer: " .. vim.fn.fnamemodify(filepath, ":t"))
    
    if #path > 0 then
        table.insert(lines, "Path: `root." .. table.concat(path, ".") .. "`")
        table.insert(lines, "")
        table.insert(lines, "◀ [..] (back to parent)")
    else
        table.insert(lines, "Path: `root`")
        table.insert(lines, "")
    end

    if type(node) == "table" then
        -- Check if it's an array or a dictionary
        local is_array = true
        local max_idx = 0
        local keys = {}
        for k in pairs(node) do
            if type(k) == "number" then
                if k > max_idx then max_idx = k end
            else
                is_array = false
            end
            table.insert(keys, k)
        end

        if is_array and #keys > 0 then
            -- Render array items
            for i = 1, max_idx do
                local val = node[i]
                if type(val) == "table" then
                    table.insert(lines, string.format("▶ [%d]", i))
                else
                    table.insert(lines, string.format("  [%d] = %s", i, vim.inspect(val)))
                end
            end
        else
            -- Render object keys sorted alphabetically
            table.sort(keys, function(a, b)
                return tostring(a) < tostring(b)
            end)
            for _, k in ipairs(keys) do
                local val = node[k]
                if type(val) == "table" then
                    table.insert(lines, string.format("▶ [%s]", tostring(k)))
                else
                    table.insert(lines, string.format("  [%s] = %s", tostring(k), vim.inspect(val)))
                end
            end
        end
    else
        table.insert(lines, "Value:")
        table.insert(lines, "  " .. vim.inspect(node))
    end

    local t3 = vim.loop.hrtime()

    -- Universal approach: If enabled, scan all generated lines and split any containing '\n' into actual newlines
    if vim.g.qllm_json_newline then
        local expanded_lines = {}
        for _, line in ipairs(lines) do
            local clean_line = line:gsub("\\n", "\n"):gsub("\\r", "")
            for sub_line in string.gmatch(clean_line .. "\n", "(.-)\n") do
                table.insert(expanded_lines, sub_line)
            end
        end
        lines = expanded_lines
    end

    -- Make buffer modifiable to update lines, then set unmodifiable
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)

    -- Validate and potentially clear json_active_fold_idx if it exceeds current path length
    local active_fold = vim.b[bufnr].json_active_fold_idx
    if active_fold and active_fold > #path then
        vim.b[bufnr].json_active_fold_idx = nil
    end

    -- Clear and set active folding highlight on Path line (line 2 of buffer, index 1)
    local ns_id = vim.api.nvim_create_namespace("qllm_json_fold_hl")
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    
    local fold_idx = find_folding_index(path, bufnr)
    if fold_idx and #path > 0 then
        local prefix = "Path: `root."
        local current_pos = #prefix
        for i = 1, fold_idx - 1 do
            current_pos = current_pos + #tostring(path[i]) + 1
        end
        local start_col = current_pos
        local end_col = current_pos + #tostring(path[fold_idx])
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "IncSearch", 1, start_col, end_col)
    end

    local t4 = vim.loop.hrtime()

    -- Log render details (in milliseconds)
    if vim.g.qllm_log_enabled == true then
        local log_msg = string.format(
            "  [PERF_RENDER] get_vars=%.2fms, traverse=%.2fms, generate_lines=%.2fms, set_lines=%.2fms, total=%.2fms\n",
            (t1 - start_time) / 1e6,
            (t2 - t1) / 1e6,
            (t3 - t2) / 1e6,
            (t4 - t3) / 1e6,
            (t4 - start_time) / 1e6
        )
        local f = io.open(get_perf_log_path(), "a")
        if f then
            f:write(log_msg)
            f:close()
        end
    end
end

function M.handle_enter(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row = cursor[1]
    local col = cursor[2]
    local filepath = vim.b[bufnr].json_file or ""

    -- Save undo state before changing path or active fold
    save_undo_state(bufnr)

    -- Reset virtual paging index on any navigation or fold change
    vim.b[bufnr].json_virtual_index = nil

    -- If cursor is on the Path line (line 2)
    if row == 2 then
        local path = vim.b[bufnr].json_path or {}
        local prefix = "Path: `root."
        local prefix_len = #prefix

        if #path == 0 or col < prefix_len then
            vim.b[bufnr].json_active_fold_idx = nil
            if filepath ~= "" then
                M.saved_paths[filepath] = {
                    path = path,
                    active_fold_idx = nil
                }
            end
            vim.notify("json_explore: Reset to default folding point.", vim.log.levels.INFO, { title = "qLLM" })
            M.render(bufnr)
            return
        end

        local current_pos = prefix_len
        local selected_idx = nil
        for idx, segment in ipairs(path) do
            local segment_str = tostring(segment)
            local start_col = current_pos
            local end_col = current_pos + #segment_str - 1

            if col >= start_col and col <= end_col then
                selected_idx = idx
                break
            end
            current_pos = current_pos + #segment_str + 1
        end

        if selected_idx then
            local part = path[selected_idx]
            if type(part) == "number" or (type(part) == "string" and tonumber(part) ~= nil) then
                vim.b[bufnr].json_active_fold_idx = selected_idx
                if filepath ~= "" then
                    M.saved_paths[filepath] = {
                        path = path,
                        active_fold_idx = selected_idx
                    }
                end
                vim.notify(string.format("json_explore: Active folding index set to segment %d (%s)", selected_idx, tostring(part)), vim.log.levels.INFO, { title = "qLLM" })
                M.render(bufnr)
            else
                vim.notify("json_explore: Selected segment is not a number. Folding requires a numeric index.", vim.log.levels.WARN, { title = "qLLM" })
            end
        end
        return
    end

    local line = vim.api.nvim_get_current_line()
    local path = vim.b[bufnr].json_path or {}

    -- Check if back navigation
    if line:find("◀ %[%.%.%]") then
        if #path > 0 then
            table.remove(path)
            vim.b[bufnr].json_path = path
            if filepath ~= "" then
                M.saved_paths[filepath] = {
                    path = path,
                    active_fold_idx = vim.b[bufnr].json_active_fold_idx
                }
            end
            M.render(bufnr)
            -- Move cursor back to top
            vim.api.nvim_win_set_cursor(0, {4, 0})
        end
        return
    end

    -- Check if drilling into an object/array
    local key = line:match("▶ %[(.-)%]")
    if key then
        -- Convert numeric key if it represents an array index
        local num = tonumber(key)
        if num then
            table.insert(path, num)
        else
            table.insert(path, key)
        end
        vim.b[bufnr].json_path = path
        if filepath ~= "" then
            M.saved_paths[filepath] = {
                path = path,
                active_fold_idx = vim.b[bufnr].json_active_fold_idx
            }
        end
        M.render(bufnr)
        -- Move cursor back to top/first item
        vim.api.nvim_win_set_cursor(0, {4, 0})
        return
    end
end

function find_folding_index(path, bufnr)
    if bufnr then
        local active = vim.b[bufnr].json_active_fold_idx
        if active and active <= #path then
            local part = path[active]
            if type(part) == "number" or (type(part) == "string" and tonumber(part) ~= nil) then
                return active
            end
        end
    end

    local start_idx = 1
    if bufnr then
        start_idx = (vim.b[bufnr].json_initial_path_len or 0) + 1
    end
    for i = start_idx, #path do
        local part = path[i]
        if type(part) == "number" or (type(part) == "string" and tonumber(part) ~= nil) then
            return i
        end
    end
    return nil
end

function M.navigate(bufnr, direction)
    local start_time = vim.loop.hrtime()
    local path = vim.b[bufnr].json_path or {}
    if #path == 0 then
        vim.notify("json_explore: Cannot navigate on root path.", vim.log.levels.WARN, { title = "qLLM" })
        return
    end

    local fold_idx = find_folding_index(path, bufnr)
    if not fold_idx then
        vim.notify("json_explore: No numeric folding index found in current path.", vim.log.levels.WARN, { title = "qLLM" })
        return
    end

    local count = vim.v.count > 0 and vim.v.count or 1
    local current_val = tonumber(path[fold_idx])

    -- Retrieve tracking virtual index, falling back to current active path index
    local virtual_index = vim.b[bufnr].json_virtual_index or current_val
    local next_virtual = virtual_index + (direction == "forward" and count or -count)
    if next_virtual < 1 then
        vim.notify("json_explore: Cannot decrement index below 1", vim.log.levels.WARN, { title = "qLLM" })
        return
    end

    -- Save new virtual index tracking state
    vim.b[bufnr].json_virtual_index = next_virtual

    -- Build target path to test if it exists
    local target_path = {}
    for i = 1, #path do
        target_path[i] = path[i]
    end

    local old_val = path[fold_idx]
    if type(old_val) == "number" then
        target_path[fold_idx] = next_virtual
    else
        target_path[fold_idx] = tostring(next_virtual)
    end

    local t1 = vim.loop.hrtime()

    -- Verify if the target path actually exists in the data
    local data = json_cache[bufnr]
    local temp = data
    local exists = true
    for i = 1, #target_path do
        if type(temp) == "table" then
            temp = temp[target_path[i]]
        else
            exists = false
            break
        end
    end

    local t2 = vim.loop.hrtime()

    if not exists or temp == nil then
        -- Notify warning but do not modify the active path or redraw the UI
        vim.notify(string.format("json_explore: Index %d out of bounds or path doesn't exist.", next_virtual), vim.log.levels.WARN, { title = "qLLM" })
        return
    end

    -- Target path exists: Save undo state, then update active path and json_path state
    save_undo_state(bufnr)
    path[fold_idx] = target_path[fold_idx]
    vim.b[bufnr].json_path = path

    -- Clear command-line area of previous out-of-bounds warning messages
    vim.cmd("echo ''")
    
    -- Save to persistent state
    local filepath = vim.b[bufnr].json_file or ""
    if filepath ~= "" then
        M.saved_paths[filepath] = {
            path = path,
            active_fold_idx = vim.b[bufnr].json_active_fold_idx
        }
    end

    local t3 = vim.loop.hrtime()
    M.render(bufnr)
    local t4 = vim.loop.hrtime()

    -- Log duration details (in milliseconds)
    if vim.g.qllm_log_enabled == true then
        local log_msg = string.format(
            "[PERF] Navigate: path_setup=%.2fms, verify=%.2fms, path_save=%.2fms, render=%.2fms, total=%.2fms\n",
            (t1 - start_time) / 1e6,
            (t2 - t1) / 1e6,
            (t3 - t2) / 1e6,
            (t4 - t3) / 1e6,
            (t4 - start_time) / 1e6
        )
        local f = io.open(get_perf_log_path(), "a")
        if f then
            f:write(log_msg)
            f:close()
        end
    end
end

function M.undo_navigation(bufnr)
    local last_path = vim.b[bufnr].json_last_path
    local last_fold = vim.b[bufnr].json_last_fold_idx

    if not last_path then
        vim.notify("json_explore: No undo history available.", vim.log.levels.WARN, { title = "qLLM" })
        return
    end

    local current_path = vim.b[bufnr].json_path or {}
    local current_fold = vim.b[bufnr].json_active_fold_idx

    local current_path_copy = {}
    for i, v in ipairs(current_path) do
        current_path_copy[i] = v
    end

    -- Swap current and last
    vim.b[bufnr].json_path = last_path
    vim.b[bufnr].json_active_fold_idx = last_fold
    vim.b[bufnr].json_last_path = current_path_copy
    vim.b[bufnr].json_last_fold_idx = current_fold

    -- Reset virtual index when undoing
    vim.b[bufnr].json_virtual_index = nil

    local filepath = vim.b[bufnr].json_file or ""
    if filepath ~= "" then
        M.saved_paths[filepath] = {
            path = last_path,
            active_fold_idx = last_fold
        }
    end

    vim.cmd("echo ''")
    M.render(bufnr)
end

function M.start_explorer(filepath, initial_path, bufnr)
    local expanded = vim.fn.expand(filepath)
    if vim.fn.filereadable(expanded) ~= 1 then
        vim.notify("json_explore: File not found or unreadable: " .. filepath, vim.log.levels.ERROR, { title = "qLLM" })
        return
    end

    local file_content = table.concat(vim.fn.readfile(expanded), "\n")
    local ok, decoded = pcall(vim.fn.json_decode, file_content)
    if not ok or not decoded then
        vim.notify("json_explore: Failed to parse JSON file: " .. filepath, vim.log.levels.ERROR, { title = "qLLM" })
        return
    end

    -- Create popup window using centralized Ui.create_window to register ownership
    local ui_elem = Ui.create_window("markdown", bufnr, nil, nil, nil, nil, true)
    local ui_bufnr = ui_elem.bufnr

    -- Setup buffer-local state inside pure Lua cache
    json_cache[ui_bufnr] = decoded

    -- Setup deletion handler to purge pure Lua cache
    local event = require("nui.utils.autocmd").event
    ui_elem:on(event.BufDelete, function()
        json_cache[ui_bufnr] = nil
    end)

    -- Check persistent cache first
    local saved = M.saved_paths[expanded]
    local use_path = initial_path or {}
    local use_fold_idx = nil
    -- Only use saved path if the user didn't specify a custom initial path via args
    if saved and (#use_path == 0) then
        use_path = saved.path
        use_fold_idx = saved.active_fold_idx
    end

    vim.b[ui_bufnr].json_path = use_path
    vim.b[ui_bufnr].json_initial_path_len = #(initial_path or {})
    vim.b[ui_bufnr].json_file = expanded
    vim.b[ui_bufnr].json_active_fold_idx = use_fold_idx
    vim.b[ui_bufnr].qllm_metadata = { command = "json_explore" }

    -- Map Enter key in this buffer to handle navigation
    vim.keymap.set("n", "<CR>", function()
        M.handle_enter(ui_bufnr)
    end, { buffer = ui_bufnr, silent = true })

    -- Map Backspace to go back
    vim.keymap.set("n", "<BS>", function()
        local path = vim.b[ui_bufnr].json_path or {}
        if #path > 0 then
            save_undo_state(ui_bufnr)
            table.remove(path)
            vim.b[ui_bufnr].json_path = path
            vim.b[ui_bufnr].json_virtual_index = nil
            if expanded ~= "" then
                M.saved_paths[expanded] = {
                    path = path,
                    active_fold_idx = vim.b[ui_bufnr].json_active_fold_idx
                }
            end
            M.render(ui_bufnr)
            vim.api.nvim_win_set_cursor(0, {4, 0})
        end
    end, { buffer = ui_bufnr, silent = true })

    -- Map f to go forward, d to go backward in numeric folding points
    vim.keymap.set("n", "f", function()
        M.navigate(ui_bufnr, "forward")
    end, { buffer = ui_bufnr, silent = true })

    vim.keymap.set("n", "d", function()
        M.navigate(ui_bufnr, "backward")
    end, { buffer = ui_bufnr, silent = true })

    -- Map u to undo
    vim.keymap.set("n", "u", function()
        M.undo_navigation(ui_bufnr)
    end, { buffer = ui_bufnr, silent = true })

    -- Set filetype to markdown for syntax highlighting
    vim.api.nvim_buf_set_option(ui_bufnr, "filetype", "markdown")

    -- Initial render
    M.render(ui_bufnr)
    vim.api.nvim_win_set_cursor(0, {4, 0})
end

return M
