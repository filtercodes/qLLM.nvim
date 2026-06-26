local event = require("nui.utils.autocmd").event
local Window = require("qllm.window")
local Renderer = require("qllm.renderer")

local Ui = {}

-- "History Owner" buffer (e.g., { [popup_bufnr] = owner_bufnr }).
local ui_to_owner_map = {}

-- Track which popups are currently active
local active_popups = {}

---Helper to save the current cursor position of a UI popup back to history.
function Ui.save_cursor_pos_for_buf(ui_bufnr)
    local info = active_popups[ui_bufnr]
    if not info then return end

    if not vim.api.nvim_buf_is_valid(ui_bufnr) then return end

    local recall_index = vim.b[ui_bufnr].qllm_recall_index
    if not recall_index then return end

    local winid = vim.fn.bufwinid(ui_bufnr)
    if winid ~= -1 then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        local History = require("qllm.history")
        History.save_cursor_pos(info.owner, recall_index, cursor)
    end
end

---Looks up the owner buffer for a given UI buffer.
function Ui.get_owner_bufnr(bufnr)
    return ui_to_owner_map[bufnr]
end

---Checks if there is an active popup associated with the given buffer.
function Ui.has_active_popup(bufnr)
    if active_popups[bufnr] then return true end
    for _, info in pairs(active_popups) do
        if info.owner == bufnr then return true end
    end
    return false
end

---Retrieves metadata for the active popup or the buffer itself.
function Ui.get_active_status_info(bufnr)
    local target_bufnr = bufnr

    -- If the buffer is an owner, find its active popup
    if not active_popups[bufnr] then
        for p_buf, info in pairs(active_popups) do
            if info.owner == bufnr then
                target_bufnr = p_buf
                break
            end
        end
    end

    -- Return metadata if the target buffer is an active popup
    if active_popups[target_bufnr] then
        local metadata = vim.b[target_bufnr] and vim.b[target_bufnr].qllm_metadata
        if metadata then
            return metadata.command, metadata.model
        end
    end

    -- Fallback: If no active popup, check the buffer itself (for direct edits)
    local metadata = vim.b[bufnr] and vim.b[bufnr].qllm_metadata
    if metadata then
        return metadata.command, metadata.model
    end

    return nil, nil
end

---Closes the active popup associated with the given buffer.
function Ui.close_active_popup(bufnr)
    -- If the buffer is itself a popup
    if active_popups[bufnr] then
        local info = active_popups[bufnr]
        Ui.save_cursor_pos_for_buf(bufnr)
        active_popups[bufnr] = nil
        ui_to_owner_map[bufnr] = nil
        info.ui_elem:unmount()
        return
    end

    -- If the buffer is an owner, find and close its popup
    for p_bufnr, info in pairs(active_popups) do
        if info.owner == bufnr then
            Ui.save_cursor_pos_for_buf(p_bufnr)
            active_popups[p_bufnr] = nil
            ui_to_owner_map[p_bufnr] = nil
            info.ui_elem:unmount()
            break
        end
    end
end

---Wrapper for window size synchronization.
function Ui.sync_window_size(ui_bufnr)
    local info = active_popups[ui_bufnr]
    return Window.sync_size(ui_bufnr, info)
end

function Ui.create_window(filetype, bufnr, start_row, start_col, end_row, end_col)
    -- Close any existing popup for this owner before opening a new one
    Ui.close_active_popup(bufnr)

    local popup_type = vim.g.qllm_popup_type
    local ui_elem, max_h, max_row, max_w, col

    if popup_type == "horizontal" then
        ui_elem, max_h, max_row, max_w, col = Window.create_horizontal()
    elseif popup_type == "vertical" then
        ui_elem, max_h, max_row, max_w, col = Window.create_vertical()
    else
        ui_elem, max_h, max_row, max_w, col = Window.create_popup()
    end
    
    -- mount/open the component
    ui_elem:mount()

    local ui_bufnr = ui_elem.bufnr

    -- Metadata inheritance
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[ui_bufnr].qllm_metadata = vim.b[bufnr].qllm_metadata
        vim.b[ui_bufnr].qllm_recall_index = vim.b[bufnr].qllm_recall_index
    end

    -- State registration
    ui_to_owner_map[ui_bufnr] = bufnr
    active_popups[ui_bufnr] = {
        owner = bufnr,
        ui_elem = ui_elem,
        max_h = max_h,
        max_row = max_row,
        max_w = max_w,
        col = col,
        current_h = (popup_type == "popup" and 1 or max_h),
        current_w = max_w,
        last_chunk_was_thinking = false,
        following = true,
    }

    if popup_type == "popup" then
        Ui.sync_window_size(ui_bufnr)
    end

    -- Event: Handle BufLeave - buffer cleanup and unmounting
    if vim.g.qllm_close_on_leave then
        -- Default: Close when clicking away/switching buffers
        ui_elem:on(event.BufLeave, function()
            Ui.save_cursor_pos_for_buf(ui_bufnr)
            ui_to_owner_map[ui_bufnr] = nil
            active_popups[ui_bufnr] = nil
            ui_elem:unmount()
        end)
    else
        -- Persistent: Only clean up state when explicitly closed (via q, <esc>, etc.)
        ui_elem:on(event.BufDelete, function()
            Ui.save_cursor_pos_for_buf(ui_bufnr)
            ui_to_owner_map[ui_bufnr] = nil
            active_popups[ui_bufnr] = nil
        end)
    end

    vim.api.nvim_buf_set_option(ui_elem.bufnr, "filetype", filetype)

    -- Mappings
    ui_elm = Ui.window_mapping(ui_elem)

    return ui_elm
end

function Ui.window_mapping(ui_elem)
    ui_elem:map("n", "<CR>", function()
        local line = vim.api.nvim_get_current_line()
        local target_path = nil
        local target_line = 1

        -- 1. Try markdown file link: file:///path/to/file#L123
        local path_md, line_md = line:match("file:///(.-)#L(%d+)")
        if path_md then
            if path_md:sub(1, 1) ~= "/" then
                path_md = "/" .. path_md
            end
            target_path = path_md
            target_line = tonumber(line_md) or 1
        else
            -- Try markdown file link without line number: file:///path/to/file
            local path_md_no_line = line:match("file:///(%S+)")
            if path_md_no_line then
                if path_md_no_line:sub(1, 1) ~= "/" then
                    path_md_no_line = "/" .. path_md_no_line
                end
                target_path = path_md_no_line
                target_line = 1
            end
        end

        -- 2. Try reference and call tree patterns (only if this popup belongs to the "tree" command)
        local metadata = vim.b[ui_elem.bufnr].qllm_metadata
        local is_tree_cmd = metadata and metadata.command == "tree"

        if is_tree_cmd then
            -- Try reference format with line number: [Name] (path:L123)
            if not target_path then
                local func_name, path, line_num = line:match("%[%s*([%w_.:]+)%s*%]%s*%(%s*([^:%)]+):L(%d+)")
                if func_name and path and line_num then
                    local root = require("qllm.project_context").get_project_root()
                    target_path = root .. path
                    target_line = tonumber(line_num) or 1
                end
            end

            -- Try standard call tree format: [Name] (path)
            if not target_path then
                local func_name, path = line:match("%[%s*([%w_.:]+)%s*%]%s*%(%s*([^:%)]+)%s*%)")
                if func_name and path then
                    local root = require("qllm.project_context").get_project_root()
                    target_path = root .. path
                    target_line = 1

                    -- Look up function start line in call graph if available
                    local map_path = root .. "qLLM_map.json"
                    if vim.fn.filereadable(map_path) == 1 then
                        local json_content = table.concat(vim.fn.readfile(map_path), "\n")
                        local ok, map_data = pcall(vim.json.decode, json_content)
                        if ok and map_data then
                            for _, f in ipairs(map_data) do
                                if f.name == func_name and f.file == path then
                                    target_line = f.start_line or 1
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if target_path and vim.fn.filereadable(target_path) == 1 then
            ui_elem:unmount()
            vim.schedule(function()
                vim.cmd("edit " .. vim.fn.fnameescape(target_path))
                pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
            end)
        end
    end, { noremap = true, silent = true })

    ui_elem:map("n", vim.g.qllm_ui_commands.quit, function()
        ui_elem:unmount()
    end, { noremap = true, silent = true })

    if vim.g.qllm_quit_with_double_esc then
        local last_esc_time = 0
        ui_elem:map("n", "<esc>", function()
            local now = vim.loop.now()
            if now - last_esc_time < 500 then
                ui_elem:unmount()
            else
                last_esc_time = now
            end
        end, { noremap = true, silent = true })
    end

    ui_elem:map("n", vim.g.qllm_ui_commands.use_as_output, function()
        local lines = vim.api.nvim_buf_get_lines(ui_elem.bufnr, 0, -1, false)
        vim.api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, lines)
        ui_elem:unmount()
    end)

    ui_elem:map("n", vim.g.qllm_ui_commands.use_as_input, function()
        vim.api.nvim_feedkeys("ggVG:Chat ", "n", false)
    end, { noremap = false })

    for _, command in ipairs(vim.g.qllm_ui_custom_commands) do
        ui_elem:map(command[1], command[2], command[3], command[4])
    end

    return ui_elem
end

function Ui.start_spinner(bufnr, loading_message)
    local info = active_popups[bufnr]
    return Renderer.start_spinner(bufnr, loading_message, info)
end

function Ui.update_thinking_state(bufnr, is_thinking, show_thinking)
    local info = active_popups[bufnr]
    return Renderer.update_thinking_state(info, is_thinking, show_thinking)
end

function Ui.append_to_buf(bufnr, text_chunk, is_thinking)
    local info = active_popups[bufnr]
    return Renderer.append_to_buf(bufnr, text_chunk, is_thinking, info)
end

function Ui.popup(lines, filetype, bufnr, start_row, start_col, end_row, end_col, cursor_pos)
    local ui_elem = Ui.create_window(filetype, bufnr, start_row, start_col, end_row, end_col)
    vim.api.nvim_buf_set_lines(ui_elem.bufnr, 0, -1, false, lines)
    Ui.sync_window_size(ui_elem.bufnr)

    if cursor_pos then
        local winid = vim.fn.bufwinid(ui_elem.bufnr)
        if winid ~= -1 then
            pcall(vim.api.nvim_win_set_cursor, winid, cursor_pos)
        end
    end
end

---Recalculates and applies layout constraints to the currently active popup.
function Ui.refresh_active_popup()
    if vim.g.qllm_popup_type ~= "popup" then return end

    for bufnr, info in pairs(active_popups) do
        if info.ui_elem and vim.api.nvim_buf_is_valid(bufnr) then
            local max_h, max_row, max_w, col = Window.get_layout_constraints()

            info.max_h = max_h
            info.max_row = max_row
            info.max_w = max_w
            info.col = col

            Ui.sync_window_size(bufnr)
        end
    end
end

return Ui
