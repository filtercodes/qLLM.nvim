local Api = require("quickllm.api")
local Window = require("quickllm.window")

local Renderer = {}

function Renderer.start_spinner(bufnr, loading_message, info)
    local msg = loading_message or "Generating..."
    local frames = Api.progress_bar_dots
    local idx = 1
    local timer = vim.loop.new_timer()
    local start_time = vim.loop.now()
    local ns_id = vim.api.nvim_create_namespace("quickllm_spinner")
    
    -- Initial set
    if vim.api.nvim_buf_is_valid(bufnr) then
        local base_text = "  " .. frames[1] .. " " .. msg
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { base_text })
        Window.sync_size(bufnr, info)
    end

    timer:start(100, 100, vim.schedule_wrap(function()
        if not timer then return end

        if not vim.api.nvim_buf_is_valid(bufnr) then
            if timer then
                timer:stop()
                if not timer:is_closing() then timer:close() end
            end
            return
        end

        idx = (idx % #frames) + 1
        local elapsed_ms = vim.loop.now() - start_time
        local elapsed_sec = math.floor(elapsed_ms / 1000)

        local base_text = "  " .. frames[idx] .. " " .. msg
        local display_text = base_text
        if elapsed_sec >= 5 then
            display_text = base_text .. string.format(" (%ds)", elapsed_sec)
        end

        pcall(function()
            vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { display_text })
            if elapsed_sec >= 5 then
                vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", 0, #base_text, -1)
            end
        end)
    end))

    return function()
        if timer then
            timer:stop()
            if not timer:is_closing() then timer:close() end
            timer = nil
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_set_lines, bufnr, 0, 1, false, { "" })
            Window.sync_size(bufnr, info)
        end
    end
end

function Renderer.update_thinking_state(info, is_thinking, show_thinking)
    if not info then return "" end

    local separator = ""
    if info.last_chunk_was_thinking and not is_thinking then
        -- Only add separator if we are showing the thinking context
        if show_thinking ~= false then
            separator = "\n\n---\n\n"
        end
    end

    info.last_chunk_was_thinking = is_thinking
    return separator
end

function Renderer.append_to_buf(bufnr, text_chunk, is_thinking, info)
    if text_chunk == nil or #text_chunk == 0 then return end

    local winid = vim.fn.bufwinid(bufnr)

    -- Sticky Auto-Scroll Logic
    if winid ~= -1 and info then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        local line_count = vim.api.nvim_buf_line_count(bufnr)

        if info.current_h >= info.max_h then
            info.following = (cursor[1] == line_count)
        else
            info.following = (cursor[1] == 1)
        end
    end

    local current_line_count = vim.api.nvim_buf_line_count(bufnr)
    local last_line_len = 0
    if current_line_count > 0 then
        local last_line = vim.api.nvim_buf_get_lines(bufnr, current_line_count - 1, current_line_count, false)[1]
        last_line_len = #last_line
    end

    local start_line = current_line_count - 1
    local start_col = last_line_len

    vim.api.nvim_buf_set_text(bufnr, start_line, start_col, start_line, start_col, vim.split(text_chunk, '\n', { plain = true }))

    -- Thinking Highlight
    if is_thinking then
        local end_line = vim.api.nvim_buf_line_count(bufnr) - 1
        local ns_id = vim.api.nvim_create_namespace("quickllm_thinking")
        local final_lines = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)
        local final_col = #final_lines[1]

        if start_line == end_line then
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", start_line, start_col, final_col)
        else
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", start_line, start_col, -1)
            for i = start_line + 1, end_line - 1 do
                vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", i, 0, -1)
            end
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", end_line, 0, final_col)
        end
    end

    local visual_height, max_h = Window.sync_size(bufnr, info)

    -- DETERMINISTIC SCROLLING:
    -- Keep the cursor at the top (1, 0) while the window is blooming (visual_height < max_h). 
    -- Only jump the cursor to the bottom and begin active scrolling once
    -- the content exceeds the maximum allowed window size.
    if winid ~= -1 and info and info.following then
        if visual_height >= max_h then
            pcall(vim.api.nvim_win_set_cursor, winid, {vim.api.nvim_buf_line_count(bufnr), 0})
        else
            pcall(vim.api.nvim_win_set_cursor, winid, {1, 0})
        end
    end
end

return Renderer
