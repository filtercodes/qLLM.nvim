local M = {}
local Window = require("qllm.window")
local Ui = require("qllm.ui")

-- Module-level cache to store decoded Lua tables for each popup buffer.
-- This bypasses the slow serialization/copying overhead of crossing the vim.b boundary.
local json_cache = {}

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

    local t4 = vim.loop.hrtime()

    -- Log render details (in milliseconds)
    local log_msg = string.format(
        "  [PERF_RENDER] get_vars=%.2fms, traverse=%.2fms, generate_lines=%.2fms, set_lines=%.2fms, total=%.2fms\n",
        (t1 - start_time) / 1e6,
        (t2 - t1) / 1e6,
        (t3 - t2) / 1e6,
        (t4 - t3) / 1e6,
        (t4 - start_time) / 1e6
    )
    local f = io.open("qllm_perf.log", "a")
    if f then
        f:write(log_msg)
        f:close()
    end
end

function M.handle_enter(bufnr)
    local line = vim.api.nvim_get_current_line()
    local path = vim.b[bufnr].json_path or {}

    -- Check if back navigation
    if line:find("◀ %[%.%.%]") then
        if #path > 0 then
            table.remove(path)
            vim.b[bufnr].json_path = path
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
        M.render(bufnr)
        -- Move cursor back to top/first item
        vim.api.nvim_win_set_cursor(0, {4, 0})
        return
    end
end

local function find_folding_index(path)
    for i, part in ipairs(path) do
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

    local fold_idx = find_folding_index(path)
    if not fold_idx then
        vim.notify("json_explore: No numeric folding index found in current path.", vim.log.levels.WARN, { title = "qLLM" })
        return
    end

    local count = vim.v.count > 0 and vim.v.count or 1
    local current_val = tonumber(path[fold_idx])
    local next_val = current_val + (direction == "forward" and count or -count)
    if next_val < 1 then
        vim.notify("json_explore: Cannot decrement index below 1", vim.log.levels.WARN, { title = "qLLM" })
        return
    end

    local old_val = path[fold_idx]
    if type(old_val) == "number" then
        path[fold_idx] = next_val
    else
        path[fold_idx] = tostring(next_val)
    end

    local t1 = vim.loop.hrtime()

    -- Verify if the new path actually exists in the data
    local data = json_cache[bufnr]
    local temp = data
    local exists = true
    for i = 1, #path do
        if type(temp) == "table" then
            temp = temp[path[i]]
        else
            exists = false
            break
        end
    end

    local t2 = vim.loop.hrtime()

    if not exists or temp == nil then
        vim.notify(string.format("json_explore: Index %d out of bounds or path doesn't exist.", next_val), vim.log.levels.WARN, { title = "qLLM" })
        path[fold_idx] = old_val
        return
    end

    vim.b[bufnr].json_path = path
    
    local t3 = vim.loop.hrtime()
    M.render(bufnr)
    local t4 = vim.loop.hrtime()

    -- Log duration details (in milliseconds)
    local log_msg = string.format(
        "[PERF] Navigate: path_setup=%.2fms, verify=%.2fms, path_save=%.2fms, render=%.2fms, total=%.2fms\n",
        (t1 - start_time) / 1e6,
        (t2 - t1) / 1e6,
        (t3 - t2) / 1e6,
        (t4 - t3) / 1e6,
        (t4 - start_time) / 1e6
    )
    local f = io.open("qllm_perf.log", "a")
    if f then
        f:write(log_msg)
        f:close()
    end
end

function M.start_explorer(filepath, initial_path)
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

    -- Create popup window using Nui
    local ui_elem, max_h, max_row, max_w, col = Window.create_popup(true)
    ui_elem:mount()
    local ui_bufnr = ui_elem.bufnr

    Ui.sync_window_size(ui_bufnr)

    -- Setup buffer-local state inside pure Lua cache
    json_cache[ui_bufnr] = decoded

    -- Setup deletion handler to purge pure Lua cache
    local event = require("nui.utils.autocmd").event
    ui_elem:on(event.BufDelete, function()
        json_cache[ui_bufnr] = nil
    end)

    vim.b[ui_bufnr].json_path = initial_path or {}
    vim.b[ui_bufnr].json_file = expanded
    vim.b[ui_bufnr].qllm_metadata = { command = "json_explore" }

    -- Map standard window mappings (like 'q' to quit, esc, etc.)
    Ui.window_mapping(ui_elem)

    -- Map Enter key in this buffer to handle navigation
    vim.keymap.set("n", "<CR>", function()
        M.handle_enter(ui_bufnr)
    end, { buffer = ui_bufnr, silent = true })

    -- Map Backspace to go back
    vim.keymap.set("n", "<BS>", function()
        local path = vim.b[ui_bufnr].json_path or {}
        if #path > 0 then
            table.remove(path)
            vim.b[ui_bufnr].json_path = path
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

    -- Set filetype to markdown for syntax highlighting
    vim.api.nvim_buf_set_option(ui_bufnr, "filetype", "markdown")

    -- Initial render
    M.render(ui_bufnr)
    vim.api.nvim_win_set_cursor(0, {4, 0})
end

return M
