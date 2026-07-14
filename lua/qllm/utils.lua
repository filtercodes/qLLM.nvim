Utils = {}

function Utils.get_filetype()
    local bufnr = vim.api.nvim_get_current_buf()
    return vim.api.nvim_buf_get_option(bufnr, "filetype")
end

function Utils.get_visual_selection()
    local bufnr = vim.api.nvim_get_current_buf()

    local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
    local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")

    if start_pos[1] == end_pos[1] and start_pos[2] == end_pos[2] then
        return 0, 0, 0, 0
    end

    local start_row = start_pos[1] - 1
    local start_col = start_pos[2]

    local end_row = end_pos[1] - 1
    local end_col = end_pos[2] + 1

    if vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, true)[1] == nil then
        return 0, 0, 0, 0
    end

    local start_line_length = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, true)[1]:len()
    start_col = math.min(start_col, start_line_length)

    local end_line_length = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, true)[1]:len()
    end_col = math.min(end_col, end_line_length)

    return start_row, start_col, end_row, end_col
end

function Utils.get_selected_lines()
    local bufnr = vim.api.nvim_get_current_buf()
    local start_row, start_col, end_row, end_col = Utils.get_visual_selection()
    local lines = vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
    return table.concat(lines, "\n")
end

function Utils.insert_lines(lines)
    local bufnr = vim.api.nvim_get_current_buf()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(bufnr, line, line, false, lines)
    vim.api.nvim_win_set_cursor(0, { line + #lines, 0 })
end

function Utils.replace_lines(lines, bufnr, start_row, start_col, end_row, end_col)
    vim.api.nvim_buf_set_text(bufnr, start_row, start_col, end_row, end_col, lines)
end

local function get_code_block(text)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown")
    if not ok or not parser then return nil end

    local tree = parser:parse()[1]
    local root = tree:root()

    local current_ft = Utils.get_filetype()

    -- Find all fenced code blocks
    local query = vim.treesitter.query.parse("markdown", "(fenced_code_block) @block")

    local blocks = {}
    for _, node, _ in query:iter_captures(root, text, 0, -1) do
        local lang = ""
        local content = ""

        -- Manually check children for info_string and content
        for child in node:iter_children() do
            if child:type() == "info_string" then
                lang = vim.trim(vim.treesitter.get_node_text(child, text))
            elseif child:type() == "code_fence_content" then
                content = vim.treesitter.get_node_text(child, text)
            end
        end

        if content ~= "" then
            table.insert(blocks, { lang = lang, content = content })
        end
    end

    if #blocks == 0 then return nil end

    -- 1. First Pass: Find the largest block matching the current filetype
    local best_block = nil
    for _, block in ipairs(blocks) do
        if block.lang == current_ft then
            if not best_block or #block.content > #best_block.content then
                best_block = block
            end
        end
    end

    -- 2. Second Pass: If no filetype match, find the largest block overall
    if not best_block then
        for _, block in ipairs(blocks) do
            if not best_block or #block.content > #best_block.content then
                best_block = block
            end
        end
    end

    if best_block then
        return vim.split(vim.trim(best_block.content), "\n")
    end

    return nil
end

---Structural code extraction using Tree-sitter.
---Used when we want to extract just the code from a markdown response.
function Utils.trim_to_code_block(lines)
    local text = table.concat(lines, "\n")
    local code = get_code_block(text)
    if code then
        return code
    end

    return lines
end

---Removes leading and trailing backtick fences if they exist.
---Used for commands like 'edit' and 'complete' to prevent markdown artifacts in code.
function Utils.strip_broken_fences(lines)
    -- Broken Fence Protection:
    -- Check if the response starts/ends with a broken fence.
    if #lines > 1 then
        local first = lines[1]
        local last = lines[#lines]
        local has_broken_fence = false

        if first:match("^```") then
            table.remove(lines, 1)
            has_broken_fence = true
        end

        if #lines > 0 and last:match("^```") then
            table.remove(lines, #lines)
            has_broken_fence = true
        end

        if has_broken_fence then
            -- Re-trim whitespace after removing fences
            local cleaned_text = table.concat(lines, "\n")
            return vim.split(vim.trim(cleaned_text), "\n")
        end
    end

    return lines
end

function Utils.parse_lines(response_text)
    if vim.g.qllm_write_response_to_err_log then
        vim.api.nvim_err_write("Response: \n" .. response_text .. "\n")
    end

    return vim.fn.split(vim.trim(response_text), "\n")
end

function Utils.fix_indentation(bufnr, start_row, end_row, new_lines)
    local original_lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, true)
    local min_indentation = math.huge
    local original_identation = ""

    -- Find the minimum indentation of any line in original_lines
    for _, line in ipairs(original_lines) do
        local indentation = string.match(line, "^%s*")
        if #indentation < min_indentation then
            min_indentation = #indentation
            original_identation = indentation
        end
    end

    -- Change the existing lines in new_lines by adding the old identation
    for i, line in ipairs(new_lines) do
        new_lines[i] = original_identation .. line
    end
end

function Utils.get_accurate_tokens(content)
    content = content or ""

    -- Heuristic: 1 token is approximately 3.8 characters for standard code and prose.
    -- This provides a fast, zero-dependency local estimate.
    local char_count = #content
    local estimated_tokens = math.floor(char_count / 3.8)

    return true, estimated_tokens
end

function Utils.remove_trailing_whitespace(lines)
    for i, line in ipairs(lines) do
        lines[i] = line:gsub("%s+$", "")
    end
    return lines
end

---Removes <think> tags and their content from a string (handles multi-line and multiple blocks).
---@param text string
---@return string
function Utils.strip_thinking_tags(text)
    if not text then return "" end

    local result = ""
    local last_pos = 1

    while true do
        local start_idx = text:find("<think>", last_pos, true)
        if not start_idx then
            result = result .. text:sub(last_pos)
            break
        end

        result = result .. text:sub(last_pos, start_idx - 1)

        local end_idx = text:find("</think>", start_idx + 7, true)
        if not end_idx then
            -- Orphaned start tag: we skip the rest as it's likely a thinking block in progress
            break
        end

        last_pos = end_idx + 8
    end

    -- Cleanup remaining orphaned end tags (safety)
    result = result:gsub("</think>", "")

    -- Trim leading and trailing whitespace/newlines
    return result:match("^%s*(.-)%s*$") or ""
end


---Greedily attempts to decode a JSON object from a stream buffer.
---This is highly robust against formatting and internal braces (like code blocks).
---It finds the first '{', then iteratively tests '}' until decoding succeeds.
---@param buffer string The accumulated stream buffer.
---@param start_search_idx number The index to start looking for '{'
---@return boolean ok True if a complete JSON object was decoded.
---@return table|nil json The decoded JSON object.
---@return number next_idx The index where the decoded JSON ended, allowing the caller to advance the buffer.
function Utils.decode_json_stream(buffer, start_search_idx)
    local json_start_idx = string.find(buffer, "{", start_search_idx, true)
    if not json_start_idx then return false, nil, start_search_idx end

    local search_end_idx = json_start_idx
    while true do
        -- Find the next '}'
        local json_end_idx = string.find(buffer, "}", search_end_idx, true)
        if not json_end_idx then
            -- Reached end of buffer without successfully decoding -> wait for more chunks
            return false, nil, json_start_idx
        end

        local json_str = string.sub(buffer, json_start_idx, json_end_idx)
        local ok, json = pcall(vim.json.decode, json_str)

        if ok and json then
            -- Success! We found the exact boundary.
            return true, json, json_end_idx
        end

        -- Failed to decode (likely because this '}' was inside a string or code block).
        -- Move past this '}' and try the next one.
        search_end_idx = json_end_idx + 1
    end
end

---Path Command-Line Enter logic.
---Prevents execution of files/scan commands if a bracket [ is unclosed.
---Allows using Enter to select items from completion menu.
---@return string The key sequence to execute.
function Utils.handle_cmdline_enter()
    local cmdline = vim.fn.getcmdline()
    -- Strip optional Vim range prefix (e.g. '<,'> or % or 12,34) to get the command name
    local clean_cmdline = cmdline:gsub("^['<,>%%d%%%%%$.%+%-%s;]*", "")
    local cmd, sub = clean_cmdline:match("^(%S+)%s+(%S+)")

    local qllm_cmds = { Que=1, Gemini=1, Claude=1, Openai=1, Ollama=1, Groq=1 }
    local is_qllm = cmd and (qllm_cmds[cmd] or cmd:match("^Pre%d$"))

    if is_qllm and (sub == "files" or sub == "scan") then
        -- 1. If completion menu is open, Enter always selects (accepts current match).
        if vim.fn.wildmenumode() == 1 or vim.fn.pumvisible() == 1 then
            return "<C-y>"
        end

        -- 2. Only block if the first bracket is still unclosed.
        -- This ensures at least one complete file block exists before accidental trigger,
        -- but allows subsequent brackets in the user's prompt (e.g. code snippets).
        local first_open = cmdline:find("%[")
        local first_close = cmdline:find("%]")
        if first_open and not first_close then
            return "" -- Block execution
        end
    end
    return "<CR>"
end

---Handles the end of a stream, parsing raw JSON error payloads if no text was generated.
---@param partial_data string The raw response buffer accumulated so far.
---@param full_text string The accumulated text parsed from stream chunks.
---@param cb table The callbacks table (containing on_error).
---@param provider_name string The name of the provider for fallback warning messages.
---@return boolean handled True if an error was found and processed, indicating that the caller should bypass on_complete.
function Utils.handle_stream_end(partial_data, full_text, cb, provider_name)
    if full_text ~= "" then
        return false
    end

    local trimmed = vim.trim(partial_data)
    if trimmed ~= "" then
        local decode_ok, decoded = pcall(vim.fn.json_decode, trimmed)
        if decode_ok and decoded then
            -- Handle common JSON error formats from API providers (Gemini, OpenAI, Anthropic, Groq)
            if decoded.error then
                cb.on_error(decoded.error)
                return true
            elseif decoded.type == "error" and decoded.error then
                cb.on_error(decoded.error)
                return true
            end
        end

        -- If not standard JSON error structure, return the raw trimmed payload
        cb.on_error(trimmed)
        return true
    end

    return false
end

return Utils
