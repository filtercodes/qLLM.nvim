--/lua/quickllm/history.lua
-- This module manages the chat history on a per-buffer basis.

local M = {}
local Utils = require("quickllm.utils")

-- In-memory store for chat history, keyed by buffer number.
-- Each history is a list of messages.
-- e.g., history[bufnr] = { { role = "user", content = "...", timestamp = 123 }, ... }
local history = {}

-- Lock to track if summarization is in progress for a buffer
local is_summarizing = {}

---Adds a message to the history for a given buffer.
---Triggers summarization if history exceeds limit.
---@param bufnr number: The buffer number.
---@param role string: "user" or "assistant".
---@param content string: The message content.
---@param model string|nil: Optional explicit model.
---@param command string|nil: Optional explicit command.
function M.add_message(bufnr, role, content, model, command)
    if not history[bufnr] then
        history[bufnr] = {}
    end

    -- If metadata isn't explicitly provided
    -- try to retrieve it from the buffer-local source of truth.
    if not model or not command then
        local metadata = vim.b[bufnr] and vim.b[bufnr].quickllm_metadata
        if metadata then
            model = model or metadata.model
            command = command or metadata.command
        end
    end

    -- Filter out <think> tags and their contents before saving to history
    if role == "assistant" and content then
        content = Utils.strip_thinking_tags(content)
    end

    local message = {
        role = role,
        content = content,
        timestamp = os.time(),
        model = model,
        command = command,
    }
    table.insert(history[bufnr], message)

    local opts = vim.g.quickllm_history_opts or {}
    local max_messages = opts.max_messages or 50
    local summarize_enabled = opts.summarize_history ~= false

    -- Check if we need to manage history size
    if #history[bufnr] > max_messages then
        if summarize_enabled then
            if not is_summarizing[bufnr] then
                M.summarize_history(bufnr)
            end
        else
            -- Sliding window: remove oldest message to make room
            table.remove(history[bufnr], 1)
        end

        -- Safety cap: If summarization is slow/failing, don't let history grow indefinitely.
        -- Keep a buffer of roughly 2x the max before hard deleting oldest.
        if #history[bufnr] > (max_messages * 2) then
            table.remove(history[bufnr], 1)
        end
    end
end

---Retrieves the message history for a buffer, handling granular timeouts.
---@param bufnr number: The buffer number.
---@return table: A list of messages ready to be sent to the API.
function M.get_messages(bufnr)
    local bufnr_history = history[bufnr]

    if not bufnr_history or #bufnr_history == 0 then
        return {}
    end

    local opts = vim.g.quickllm_history_opts or {}
    local time_based_expiry = opts.time_based_expiry or false

    local current_time = os.time()
    local timeout = opts.timeout or 900
    
    local valid_history = {}
    local expired_count = 0

    if time_based_expiry then
        -- Granular expiry: Keep only messages within the timeout window
        for _, msg in ipairs(bufnr_history) do
            if (current_time - msg.timestamp) <= timeout then
                table.insert(valid_history, msg)
            else
                expired_count = expired_count + 1
            end
        end
        
        -- Update the internal history with filtered list
        history[bufnr] = valid_history
        bufnr_history = valid_history -- update local ref for return loop below

        if expired_count > 0 and #valid_history == 0 then
             -- vim.notify("QuickLLM chat history cleared due to inactivity.", vim.log.levels.INFO, { title = "QuickLLM" })
             return {}
        end
    end

    -- Return messages in API format
    local messages_to_send = {}
    for _, msg in ipairs(bufnr_history) do
        -- We only need role and content for the API
        table.insert(messages_to_send, { role = msg.role, content = msg.content })
    end

    return messages_to_send
end

---Clears the history for a given buffer.
---@param bufnr number: The buffer number to clear.
function M.clear_history(bufnr)
    if history[bufnr] then
        history[bufnr] = nil
    end
    is_summarizing[bufnr] = false
end

---Retrieves a previous assistant response from the buffer's history.
---@param bufnr number: The buffer number.
---@param offset number|nil: 1-based index from the end (default 1).
---@return string|nil, string|nil, string|nil, table|nil, string|nil: content, model, command, cursor_pos, question
function M.get_last_response(bufnr, offset)
    local buf_history = history[bufnr]
    if not buf_history or #buf_history == 0 then
        return nil, nil, nil, nil, nil
    end
    
    local target = offset or 1
    local count = 0
    
    -- Iterate backwards to find the nth assistant message
    for i = #buf_history, 1, -1 do
        if buf_history[i].role == "assistant" then
            count = count + 1
            if count == target then
                local msg = buf_history[i]
                local question = nil
                -- The question is the message immediately preceding the answer
                if i > 1 and buf_history[i-1].role == "user" then
                    question = buf_history[i-1].content
                end
                return msg.content, msg.model, msg.command, msg.cursor_pos, question
            end
        end
    end
    return nil, nil, nil, nil, nil
end

---Updates the cursor position for a specific assistant response in history.
---@param bufnr number
---@param offset number
---@param cursor_pos table {row, col}
function M.save_cursor_pos(bufnr, offset, cursor_pos)
    local buf_history = history[bufnr]
    if not buf_history then return end

    local count = 0
    for i = #buf_history, 1, -1 do
        if buf_history[i].role == "assistant" then
            count = count + 1
            if count == offset then
                buf_history[i].cursor_pos = cursor_pos
                return
            end
        end
    end
end

---Removes the last exchange (assistant response + user prompt) from the history.
---@param bufnr number: The buffer number.
---@return boolean: True if something was removed, False otherwise.
function M.undo_last_exchange(bufnr)
    local buf_history = history[bufnr]
    if not buf_history or #buf_history == 0 then
        return false
    end
    
    local popped_something = false
    -- Remove the last message if it's an assistant response
    if #buf_history > 0 and buf_history[#buf_history].role == "assistant" then
        table.remove(buf_history)
        popped_something = true
    end
    -- Also remove the corresponding user prompt that triggered it
    if #buf_history > 0 and buf_history[#buf_history].role == "user" then
        table.remove(buf_history)
        popped_something = true
    end
    
    return popped_something
end

---Applies the summary to the history.
---@param bufnr
---@param summary_text string
function M.apply_summary(bufnr, summary_text)
    local msgs = history[bufnr]
    local opts = vim.g.quickllm_history_opts or {}
    local max_messages = opts.max_messages or 50
    local half = math.floor(max_messages / 2)

    if not msgs or #msgs < half then return end
    
    -- Use metadata from the message at the cutoff point
    local marker_msg = msgs[half]
    
    local summary_msg = {
        role = "system", -- System role implies context/instruction
        content = "Summary of previous conversation:\n" .. summary_text,
        timestamp = marker_msg.timestamp,
        is_summary = true,
        model = marker_msg.model,
        command = marker_msg.command
    }
    
    -- Remove the first half of messages
    for _ = 1, half do
        table.remove(msgs, 1)
    end
    
    -- Insert summary at the beginning
    table.insert(msgs, 1, summary_msg)
end

---Initiates background summarization of the first half of the message buffer.
---@param bufnr number
function M.summarize_history(bufnr)
    is_summarizing[bufnr] = true
    
    local opts = vim.g.quickllm_history_opts or {}
    local max_messages = opts.max_messages or 50
    local half = math.floor(max_messages / 2)

    -- Lazy require to avoid circular dependency
    local Providers = require("quickllm.providers")
    local CommandsList = require("quickllm.commands_list")
    
    local msgs = history[bufnr]
    if not msgs or #msgs < half then
        is_summarizing[bufnr] = false
        return
    end
    
    -- Prepare text to summarize
    local text_block = ""
    for i = 1, half do
        local msg = msgs[i]
        text_block = text_block .. string.upper(msg.role) .. ": " .. msg.content .. "\n\n"
    end
    
    local prompt = "Summarize the following conversation flow to retain key context. Keep it concise."
    local full_request_text = prompt .. "\n\nConversation:\n" .. text_block
    
    -- Use a dummy buffer ID (-1) to prevent `make_request` from fetching existing history
    -- and `make_call` (via handle_response) from polluting the real history.
    local dummy_bufnr = -1
    
    -- Resolve provider and opts with potential summarization overrides
    local overrides = {
        provider = opts.summarize_provider,
        model = opts.summarize_model
    }
    local provider = Providers.get_provider(overrides)
    local cmd_opts = CommandsList.get_cmd_opts("chat", overrides)
    
    if not opts then
         -- Should not happen if chat command exists, but safe guard
        is_summarizing[bufnr] = false
        return
    end
    
    -- Construct request
    local request, user_msg = provider.make_request("chat", cmd_opts, full_request_text, "", dummy_bufnr)
    
    local callback = function(lines)
        if lines and #lines > 0 then
            local summary = table.concat(lines, "\n")
            -- Schedule update on main loop
            vim.schedule(function()
                M.apply_summary(bufnr, summary)
                -- Cleanup dummy history if any was created
                M.clear_history(dummy_bufnr)
            end)
        end
        is_summarizing[bufnr] = false
    end
    
    -- Execute
    provider.make_call(request, user_msg, callback, dummy_bufnr)
end

return M
