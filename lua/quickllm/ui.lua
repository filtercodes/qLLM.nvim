local event = require("nui.utils.autocmd").event
local Window = require("quickllm.window")
local Renderer = require("quickllm.renderer")

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

    local recall_index = vim.b[ui_bufnr].quickllm_recall_index
    if not recall_index then return end

    local winid = vim.fn.bufwinid(ui_bufnr)
    if winid ~= -1 then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        local History = require("quickllm.history")
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
        local metadata = vim.b[target_bufnr] and vim.b[target_bufnr].quickllm_metadata
        if metadata then
            return metadata.command, metadata.model
        end
    end

    -- Fallback: If no active popup, check the buffer itself (for direct edits)
    local metadata = vim.b[bufnr] and vim.b[bufnr].quickllm_metadata
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

    local popup_type = vim.g.quickllm_popup_type
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
        vim.b[ui_bufnr].quickllm_metadata = vim.b[bufnr].quickllm_metadata
        vim.b[ui_bufnr].quickllm_recall_index = vim.b[bufnr].quickllm_recall_index
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
    if vim.g.quickllm_close_on_leave then
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

    -- Mappings
    ui_elem:map("n", vim.g.quickllm_ui_commands.quit, function()
        ui_elem:unmount()
    end, { noremap = true, silent = true })

    if vim.g.quickllm_quit_with_double_esc then
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

    vim.api.nvim_buf_set_option(ui_elem.bufnr, "filetype", filetype)

    ui_elem:map("n", vim.g.quickllm_ui_commands.use_as_output, function()
        local lines = vim.api.nvim_buf_get_lines(ui_elem.bufnr, 0, -1, false)
        vim.api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, lines)
        ui_elem:unmount()
    end)

    ui_elem:map("n", vim.g.quickllm_ui_commands.use_as_input, function()
        vim.api.nvim_feedkeys("ggVG:Chat ", "n", false)
    end, { noremap = false })

    for _, command in ipairs(vim.g.quickllm_ui_custom_commands) do
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
    if vim.g.quickllm_popup_type ~= "popup" then return end

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
