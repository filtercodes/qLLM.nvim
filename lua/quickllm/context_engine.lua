local M = {}

---Expands a list of file patterns (including wildcards) into absolute paths.
---@param patterns table A list of strings (e.g. {"*.lua", "src/*.js"})
---@return table A list of valid, readable file paths.
function M.resolve_patterns(patterns)
    local files = {}
    local seen = {}

    for _, pattern in ipairs(patterns) do
        -- Remove potential quotes from individual patterns if they were split naively
        local clean_pattern = pattern:gsub('^["\'`]', ''):gsub('["\'`]$', '')
        local expanded = vim.fn.glob(clean_pattern, true, true)
        for _, path in ipairs(expanded) do
            if vim.fn.filereadable(path) == 1 and not seen[path] then
                table.insert(files, path)
                seen[path] = true
            end
        end
    end
    return files
end

---Calculates a hash for a file to detect changes.
---@param path string
---@return string?
function M.get_file_hash(path)
    if vim.fn.filereadable(path) ~= 1 then return nil end
    local lines = vim.fn.readfile(path)
    local content = table.concat(lines, "\n")
    return vim.fn.sha256(content)
end

---Reads the content of multiple files and formats them into a single string.
---@param files table A list of absolute file paths.
---@return string The formatted content block.
function M.format_files_as_context(files)
    local context = ""
    for _, path in ipairs(files) do
        local lines = vim.fn.readfile(path)
        local content = table.concat(lines, "\n")
        context = context .. string.format("\nFILE: %s\n```%s\n%s\n```\n---\n", 
            path, 
            vim.filetype.match({ filename = path }) or "text", 
            content)
    end
    return context
end

---Parses the input string to find delimited blocks, search queries, and prompt.
---Handles escaped characters like \" or \`.
---@param input string The full command input (e.g. 'files "file 1.lua" <my query> prompt')
---@return table extracted List of strings from file delimiters.
---@return string? query Content from <query> brackets.
---@return string remaining Everything else.
function M.parse_input(input)
    local extracted = {}
    local remaining = input
    local query = nil

    -- 1. Extract Bracketed Query <...>
    -- This has precedence to avoid greediness with file delimiters
    local q_start = remaining:find("<")
    if q_start then
        local q_content = ""
        local i = q_start + 1
        while i <= #remaining do
            local char = remaining:sub(i, i)
            if char == "\\" then
                q_content = q_content .. (remaining:sub(i + 1, i + 1) or "")
                i = i + 2
            elseif char == ">" then
                query = q_content
                remaining = vim.trim(remaining:sub(1, q_start-1) .. " " .. remaining:sub(i + 1))
                break
            else
                q_content = q_content .. char
                i = i + 1
            end
        end
    end

    -- 2. Extract File Blocks
    local function extract_next_file(str)
        local delimiters = {
            { '"', '"' }, { "'", "'" }, { '`', '`' }, { '(', ')' }
        }
        
        for _, d in ipairs(delimiters) do
            local start_char = d[1]
            local end_char = d[2]
            
            local start_idx = str:find("^" .. vim.pesc(start_char))
            if not start_idx then
                start_idx = str:find("%s" .. vim.pesc(start_char))
                if start_idx then start_idx = start_idx + 1 end
            end

            if start_idx then
                local content = ""
                local i = start_idx + 1
                while i <= #str do
                    local char = str:sub(i, i)
                    if char == "\\" then
                        content = content .. (str:sub(i + 1, i + 1) or "")
                        i = i + 2
                    elseif char == end_char then
                        local full_match = str:sub(start_idx, i)
                        return content, full_match, i
                    else
                        content = content .. char
                        i = i + 1
                    end
                end
            end
        end
        return nil
    end

    while true do
        local content, full_match, end_pos = extract_next_file(remaining)
        if content then
            table.insert(extracted, content)
            remaining = vim.trim(remaining:sub(end_pos + 1))
        else
            break
        end
    end

    return extracted, query, remaining
end

---Performs a hybrid search (scan) across files and returns matching chunks.
---@param files table List of resolved file paths.
---@param query string The search query.
---@param context_lines number? Number of lines around the match to include.
---@return string The formatted search results.
function M.scan_search(files, query, context_lines)
    local results = ""
    -- Use global variable for context or default to 3
    local kb_opts = vim.g.quickllm_kb_opts
    local ctx = context_lines or kb_opts.scan_context or 3
    
    for _, path in ipairs(files) do
        local lines = vim.fn.readfile(path)
        local matches = {}

        for i, line in ipairs(lines) do
            -- Case-insensitive find
            if line:lower():find(query:lower(), 1, true) then
                table.insert(matches, i)
            end
        end

        if #matches > 0 then
            results = results .. string.format("\nFILE: %s (Matches for '%s')\n", vim.fn.fnamemodify(path, ":."), query)
            local last_end = -1

            for _, line_num in ipairs(matches) do
                local start_i = math.max(1, line_num - ctx)
                local end_i = math.min(#lines, line_num + ctx)

                if start_i <= last_end then
                    start_i = last_end + 1
                end

                if start_i <= end_i then
                    local chunk = {}
                    for k = start_i, end_i do
                        table.insert(chunk, lines[k])
                    end
                    results = results .. string.format("L%d-L%d:\n```\n%s\n```\n", start_i, end_i, table.concat(chunk, "\n"))
                    last_end = end_i
                end
            end
            results = results .. "---\n"
        end
    end
    return results
end

---Orchestrates context-based commands (files/scan/explain).
---@param command string The command name.
---@param fargs table The command arguments.
---@param current_bufnr number The current buffer.
---@param current_selection string? Optional current visual selection.
---@param overrides table? Optional overrides passed from the command runner.
---@return string? command The resolved command name.
---@return string command_args The prompt/arguments for the LLM.
---@return string text_selection The injected context.
---@return table overrides Table with history_user_message and ground_with_history.
function M.handle_context_command(command, fargs, current_bufnr, current_selection, overrides)
    local CommandsList = require("quickllm.commands_list")
    local ProjectContext = require("quickllm.project_context")
    local raw_input = table.concat(fargs, " ", 2)
    local extracted_blocks, query, remaining_prompt = M.parse_input(raw_input)
    
    local context_text = ""
    local resolved_files = {}
    overrides = overrides or {}
    overrides.ground_with_history = false
    local command_args = remaining_prompt
    local text_selection = current_selection or ""

    -- Project Context Injection
    local project_map = ProjectContext.get_active_context()
    local system_context = ""
    local kb_opts = vim.g.quickllm_kb_opts

    if project_map then
        system_context = "\n[SYSTEM PROJECT CONTEXT]\n" .. project_map .. "\n---\n"
        if kb_opts and kb_opts.auto_check_freshness then
            ProjectContext.check_freshness()
        end
    end

    if #extracted_blocks > 0 then
        resolved_files = M.resolve_patterns(extracted_blocks)
    elseif command == "scan" then
        resolved_files = { vim.api.nvim_buf_get_name(current_bufnr) }
    end

    if #resolved_files > 0 then
        if command == "files" then
            context_text = M.format_files_as_context(resolved_files)
            
            local history_prompt = ""
            if remaining_prompt == "" then
                command = "explain"
                command_args = "Explain the provided files."
                history_prompt = "FILES: Explain " .. table.concat(extracted_blocks, ", ")
            else
                local first_word = remaining_prompt:match("^(%S+)")
                if first_word and CommandsList.get_cmd_opts(first_word) then
                    command = first_word
                    command_args = vim.trim(remaining_prompt:sub(#first_word + 1))
                    history_prompt = "FILES " .. first_word:upper() .. ": " .. command_args .. " (" .. #resolved_files .. " files)"
                else
                    command = "chat"
                    command_args = remaining_prompt
                    history_prompt = "FILES CHAT: " .. command_args .. " (" .. #resolved_files .. " files)"
                end
            end
            overrides.history_user_message = history_prompt
            text_selection = system_context .. context_text
        elseif command == "scan" then
            -- 1. Determine the search query (prioritize <query> brackets)
            local search_query = query or remaining_prompt

            if search_query and search_query ~= "" then
                context_text = M.scan_search(resolved_files, search_query)

                -- 2. Determine prompt behavior
                if query and remaining_prompt ~= "" then
                    -- Both <query> and a prompt provided: Send to LLM
                    command = "chat"
                    command_args = remaining_prompt
                    text_selection = system_context .. context_text
                    overrides.history_user_message = "SCAN: '" .. search_query .. "' in " .. table.concat(extracted_blocks, ", ")
                else
                    -- No prompt provided: Just display results in a popup, bypass LLM.
                    local Ui = require("quickllm.ui")

                    local Utils = require("quickllm.utils")
                    local lines = Utils.parse_lines(context_text)
                    if #lines == 0 then table.insert(lines, "No matches found for: " .. search_query) end
                    
                    Ui.popup(lines, "markdown", current_bufnr)
                    return nil, "", "", {}
                end
            end
        end
    elseif command == "explain" then
        -- Standard 'explain' injection
        text_selection = system_context .. text_selection
    end

    return command, command_args, text_selection, overrides
end

return M
