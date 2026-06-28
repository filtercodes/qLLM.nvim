--/lua/qllm/history.lua
-- This module manages the chat history on a per-buffer basis.

local M = {}
local Utils = require("qllm.utils")

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
---@param extra table|nil: Optional structured metadata for heaviness resolution.
function M.add_message(bufnr, role, content, model, command, extra)
    -- Guard against invalid buffer IDs (like -1 used for global/background context)
    if not bufnr or bufnr <= 0 or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    if not history[bufnr] then
        history[bufnr] = {}
    end

    -- If metadata isn't explicitly provided
    -- try to retrieve it from the buffer-local source of truth.
    if not model or not command then
        local metadata = vim.b[bufnr] and vim.b[bufnr].qllm_metadata
        if metadata then
            model = model or metadata.model
            command = command or metadata.command
        end
    end

    -- Filter out <think> tags and their contents before saving to history
    if role == "assistant" and content then
        content = Utils.strip_thinking_tags(content)
    end

    -- Filter extra metadata based on active heaviness level at the time of message insertion
    if role == "user" and extra then
        local heaviness = vim.g.qllm_history_heaviness or "low"
        local filtered_extra = {}
        if heaviness == "high" then
            filtered_extra.files = extra.files
            filtered_extra.search_results = extra.search_results
            filtered_extra.selection = extra.selection
        elseif heaviness == "medium" then
            filtered_extra.search_results = extra.search_results
            filtered_extra.selection = extra.selection
        end
        extra = filtered_extra
    end

    local message = {
        role = role,
        content = content,
        timestamp = os.time(),
        model = model,
        command = command,
        extra = extra,
    }
    table.insert(history[bufnr], message)

    local opts = vim.g.qllm_history_opts or {}
    local max_messages = opts.max_messages or 50
    local max_tokens   = opts.max_tokens   or 8000

    -- Normalize legacy boolean values to the new string enum.
    -- true  -> "messages"  (old default behaviour)
    -- false -> "none"
    local summarize_mode = opts.summarize_history
    if summarize_mode == true  then summarize_mode = "messages" end
    if summarize_mode == false then summarize_mode = "none"     end
    summarize_mode = summarize_mode or "messages"

    local should_summarize = false

    if summarize_mode == "messages" then
        should_summarize = #history[bufnr] > max_messages

    elseif summarize_mode == "tokens" then
        -- Token counting is async/expensive; only run it when the buffer
        -- has grown past a cheap pre-check (avoids calling tiktoken on every keystroke).
        local pre_check = #history[bufnr] > 5
        if pre_check then
            local full_text = ""
            for _, msg in ipairs(history[bufnr]) do
                full_text = full_text .. (msg.content or "")
            end
            local ok, token_count = Utils.get_accurate_tokens(full_text)
            if ok and token_count and token_count > max_tokens then
                should_summarize = true
            end
        end

    -- "none" falls through: should_summarize stays false
    end

    if should_summarize then
        if not is_summarizing[bufnr] then
            M.summarize_history(bufnr)
        end
    elseif summarize_mode == "none" then
        -- Sliding window: keep the buffer trimmed to max_messages
        if #history[bufnr] > max_messages then
            table.remove(history[bufnr], 1)
        end
    end

    -- Safety cap regardless of mode: never let history grow to 2× the message limit.
    if #history[bufnr] > (max_messages * 2) then
        table.remove(history[bufnr], 1)
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

    local opts = vim.g.qllm_history_opts or {}
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
             -- vim.notify("qLLM chat history cleared due to inactivity.", vim.log.levels.INFO, { title = "qLLM" })
             return {}
         end
    end

    -- Return messages in API format
    local messages_to_send = {}
    for _, msg in ipairs(bufnr_history) do
        local content = msg.content
        if msg.role == "user" and msg.extra then
            if msg.extra.files and #msg.extra.files > 0 then
                -- Lazy require to avoid circular dependency
                local ContextEngine = require("qllm.context_engine")
                content = content .. "\n" .. ContextEngine.format_files_as_context(msg.extra.files)
            end
            if msg.extra.search_results and msg.extra.search_results ~= "" then
                content = content .. "\n" .. msg.extra.search_results
            end
            if msg.extra.selection and msg.extra.selection ~= "" then
                content = content .. "\n[USER SELECTION]\n" .. msg.extra.selection
            end
        end
        -- We only need role and content for the API
        table.insert(messages_to_send, { role = msg.role, content = content })
    end

    return messages_to_send
end

---Returns the total token count for a buffer's history, or nil if unavailable.
---Uses Utils.get_accurate_tokens; returns nil gracefully if tiktoken is not installed.
---@param bufnr number
---@return number|nil token_count, string|nil err
function M.get_history_token_count(bufnr)
    local msgs = M.get_messages(bufnr)
    if #msgs == 0 then
        return 0, nil
    end

    local full_text = ""
    for _, msg in ipairs(msgs) do
        full_text = full_text .. (msg.content or "")
    end

    local ok, result = Utils.get_accurate_tokens(full_text)
    if ok and result then
        return result, nil
    else
        -- result contains the error string when ok == false
        return nil, tostring(result or "tiktoken unavailable")
    end
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
                    local user_msg = buf_history[i-1]
                    local content = user_msg.content
                    if user_msg.extra then
                        if user_msg.extra.files and #user_msg.extra.files > 0 then
                            local ContextEngine = require("qllm.context_engine")
                            content = content .. "\n" .. ContextEngine.format_files_as_context(user_msg.extra.files)
                        end
                        if user_msg.extra.search_results and user_msg.extra.search_results ~= "" then
                            content = content .. "\n" .. user_msg.extra.search_results
                        end
                        if user_msg.extra.selection and user_msg.extra.selection ~= "" then
                            content = content .. "\n[USER SELECTION]\n" .. user_msg.extra.selection
                        end
                    end
                    question = content
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

---Returns a list of all buffers that have active history.
---@return table: list of { bufnr, message_count, last_command, last_model, last_timestamp }
function M.list_history_buffers()
    local result = {}
    for bufnr, msgs in pairs(history) do
        if msgs and #msgs > 0 then
            -- Find last assistant message for metadata
            local last_model, last_command, last_ts
            for i = #msgs, 1, -1 do
                if msgs[i].role == "assistant" then
                    last_model   = msgs[i].model
                    last_command = msgs[i].command
                    last_ts      = msgs[i].timestamp
                    break
                end
            end

            -- Get a human-readable buffer name
            local buf_name = vim.api.nvim_buf_is_valid(bufnr)
                and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
                or ("[invalid buf " .. bufnr .. "]")

            if buf_name == "" then
                buf_name = "[No Name]"
            end

            table.insert(result, {
                bufnr       = bufnr,
                buf_name    = buf_name,
                msg_count   = #msgs,
                last_model  = last_model or "unknown",
                last_command= last_command or "unknown",
                last_ts     = last_ts,
            })
        end
    end

    -- Sort by most recently active
    table.sort(result, function(a, b)
        return (a.last_ts or 0) > (b.last_ts or 0)
    end)

    return result
end

---Returns the raw in-memory history table for a given buffer.
---@param bufnr number
---@return table|nil
function M.get_raw_history(bufnr)
    return history[bufnr]
end

---Copies the history from one buffer (or raw history table) to another.
---Merges into destination if destination already has history.
---@param src_bufnr_or_history number|table
---@param dst_bufnr number
---@param opts table|nil  { merge: bool (default false = replace) }
---@return boolean, string  success, error_message
function M.copy_history(src_bufnr_or_history, dst_bufnr, opts)
    opts = opts or {}

    local src_history
    if type(src_bufnr_or_history) == "table" then
        src_history = src_bufnr_or_history
    else
        local src_bufnr = src_bufnr_or_history
        if src_bufnr == dst_bufnr then
            return false, "Source and destination buffers are the same."
        end
        src_history = history[src_bufnr]
    end

    if not src_history or #src_history == 0 then
        return false, "No history found to copy."
    end

    -- Deep copy so dst mutations don't affect src
    local copied = {}
    for _, msg in ipairs(src_history) do
        table.insert(copied, vim.deepcopy(msg))
    end

    if opts.merge and history[dst_bufnr] and #history[dst_bufnr] > 0 then
        -- Append src onto dst
        for _, msg in ipairs(copied) do
            table.insert(history[dst_bufnr], msg)
        end
    else
        -- Replace
        history[dst_bufnr] = copied
    end

    return true, nil
end

--- Resolves how many messages constitute the "summarizable" portion of history.
---@param max_messages number
---@return number
local function resolve_summary_cutoff(max_messages)
    local opts = vim.g.qllm_history_opts or {}
    local pct  = tonumber(opts.summarize_percent) or 50
    -- Clamp to [1, 100] so nonsense values don't break things
    pct = math.max(1, math.min(100, pct))
    return math.max(1, math.floor(max_messages * pct / 100))
end

---@param bufnr
---@param summary_text string
function M.apply_summary(bufnr, summary_text)
    local msgs = history[bufnr]
    local opts = vim.g.qllm_history_opts or {}
    local max_messages = opts.max_messages or 50
    local half = resolve_summary_cutoff(max_messages)

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
    
    local opts = vim.g.qllm_history_opts or {}
    local max_messages = opts.max_messages or 50
    local half = resolve_summary_cutoff(max_messages)

    -- Lazy require to avoid circular dependency
    local Providers = require("qllm.providers")
    local CommandsList = require("qllm.commands_list")
    
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
