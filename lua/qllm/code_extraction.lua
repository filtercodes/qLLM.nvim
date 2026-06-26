local M = {}

local function match_pattern(path, pat)
    local rel_path = vim.fn.fnamemodify(path, ":.")
    local filename = vim.fn.fnamemodify(path, ":t")
    
    -- Strip leading slash
    local clean_pat = pat:gsub("^/", "")
    
    -- 1. Extension match (e.g. *.o)
    if clean_pat:match("^%*%.") then
        local ext = clean_pat:sub(3)
        return vim.fn.fnamemodify(path, ":e"):lower() == ext:lower()
    end
    
    -- 2. Directory match (e.g. build/)
    if clean_pat:sub(-1) == "/" then
        local dir = clean_pat:sub(1, -2)
        return rel_path:find("/" .. dir .. "/") or rel_path:find("^" .. dir .. "/")
    end
    
    -- 3. Standard filename match
    if clean_pat == filename then
        return true
    end
    
    -- 4. Simple substring/glob translation
    local lua_pat = clean_pat
        :gsub("%%", "%%%%")
        :gsub("%.", "%%.")
        :gsub("%+", "%%+")
        :gsub("%-", "%%-")
        :gsub("%^", "%%^")
        :gsub("%$", "%%$")
        :gsub("%(", "%%(")
        :gsub("%)", "%%)")
        :gsub("%[", "%%[")
        :gsub("%]", "%%]")
        :gsub("%*", ".*")
        :gsub("%?", ".")
    
    if pat:sub(1, 1) == "/" then
        lua_pat = "^" .. lua_pat
    end
    
    return rel_path:find(lua_pat) ~= nil
end

local function is_binary_file(path)
    local f = io.open(path, "rb")
    if not f then return true end -- Treat unreadable as binary/ignored
    local bytes = f:read(1024)
    f:close()
    if not bytes then return false end
    return bytes:find("%z") ~= nil
end

function M.should_ignore(path, root, ignore_patterns)
    local rel_path = vim.fn.fnamemodify(path, ":.")
    
    -- Exclude standard project context files from the map
    if rel_path == "qLLM.md" or rel_path == "qLLM_map.json" then
        return true
    end

    -- Check default ignores first
    local defaults = {
        "node_modules", "%.git", "venv", "%.venv", "env", "build", "dist",
        "bin", "obj", "target", "__pycache__", "%.pytest_cache", "%.cache", "out"
    }
    for _, d in ipairs(defaults) do
        if rel_path:find("/" .. d .. "/") or rel_path:find("^" .. d .. "/") then
            return true
        end
    end

    -- Ignore binary files based on content signature (null byte check)
    if is_binary_file(path) then
        return true
    end

    -- Check custom patterns loaded from .gitignore
    for _, pat in ipairs(ignore_patterns) do
        if match_pattern(path, pat) then
            return true
        end
    end
    return false
end

---Parses the .gitignore file and returns list of patterns
---@param root string
---@return table ignore_patterns
function M.get_gitignore_patterns(root)
    local path = root .. ".gitignore"
    if vim.fn.filereadable(path) ~= 1 then
        return {}
    end
    local lines = vim.fn.readfile(path)
    local patterns = {}
    for _, line in ipairs(lines) do
        line = vim.trim(line)
        if line ~= "" and not line:match("^#") then
            table.insert(patterns, line)
        end
    end
    return patterns
end

---Parses a file using Treesitter and extracts function information.
---@param path string
---@param root string
---@param detected_filetype string? Optional pre-detected Neovim filetype.
---@return table functions List of extracted function metadata.
function M.extract_functions_from_file(path, root, detected_filetype)
    local rel_path = vim.fn.fnamemodify(path, ":.")
    local content_lines = vim.fn.readfile(path)
    local content = table.concat(content_lines, "\n")
    local filetype = detected_filetype or vim.filetype.match({ filename = path }) or "text"

    local ok, parser = pcall(vim.treesitter.get_string_parser, content, filetype)
    if not ok or not parser then
        -- Fallback to regex-based parser when Treesitter is not available
        local functions = {}
        local ext = vim.fn.fnamemodify(path, ":e"):lower()

        -- Unified fallback configuration based on regex matching and scope extraction
        local lang_configs = {
            python = {
                name_pattern = "def%s+([%w_]+)",
                parse_body = function(start_line, lines)
                    local base_indent = #lines[start_line]:match("^%s*")
                    local end_line = start_line
                    for k = start_line + 1, #lines do
                        local l = lines[k]
                        if l:match("^%s*$") == nil then
                            local indent = #l:match("^%s*")
                            if indent <= base_indent then
                                break
                            end
                            end_line = k
                        end
                    end
                    return end_line
                end
            },
            lua = {
                name_pattern = "function%s+([%w_.:]+)",
                parse_body = function(start_line, lines)
                    local end_line = nil
                    local count = 1
                    for k = start_line + 1, #lines do
                        local l = lines[k]
                        local clean_line = l:gsub("%-%-.*", "")
                        for word in clean_line:gmatch("[%w_]+") do
                            if word == "function" or word == "do" or word == "then" then
                                count = count + 1
                            elseif word == "end" then
                                count = count - 1
                            end
                        end
                        if count <= 0 then
                            end_line = k
                            break
                        end
                    end
                    return end_line
                end
            },
            braces = {
                -- Fallback configuration for brace-delimited languages (C, C++, Rust, Go, JS, TS, Java, C#)
                parse_name = function(line, file_ext, ft)
                    if file_ext == "rs" or ft == "rust" then
                        return line:match("fn%s+([%w_]+)")
                    elseif file_ext == "go" or ft == "go" then
                        return line:match("func%s+([%w_]+)") or line:match("func%s*%([^)]*%)%s*([%w_]+)")
                    else
                        return line:match("[%w_:]+%s+([%w_:]+)%s*%(")
                    end
                end,
                parse_body = function(start_line, lines)
                    local end_line = nil
                    local brace_count = 0
                    local found_start = false
                    for k = start_line, #lines do
                        local l = lines[k]
                        local clean_line = l:gsub("//.*", ""):gsub("/%*.-%*/", ""):gsub('"[^"]*"', ""):gsub("'[^']*'", "")
                        if not found_start then
                            if clean_line:find("{") then
                                found_start = true
                                brace_count = 1
                                for char in clean_line:gmatch(".") do
                                    if char == "}" then
                                        brace_count = brace_count - 1
                                    end
                                end
                                if brace_count == 0 then
                                    end_line = k
                                    break
                                end
                            end
                        else
                            for char in clean_line:gmatch(".") do
                                if char == "{" then
                                    brace_count = brace_count + 1
                                elseif char == "}" then
                                    brace_count = brace_count - 1
                                end
                            end
                            if brace_count <= 0 then
                                end_line = k
                                break
                            end
                        end
                    end
                    return end_line
                end
            }
        }

        -- Determine language config
        local cfg = nil
        if ext == "py" or filetype == "python" then
            cfg = lang_configs.python
        elseif ext == "lua" or filetype == "lua" then
            cfg = lang_configs.lua
        elseif ext == "rs" or filetype == "rust" or ext == "go" or filetype == "go"
            or ext == "cpp" or ext == "c" or ext == "h" or ext == "hpp" or ext == "js"
            or ext == "ts" or ext == "java" or ext == "cs" or filetype == "cpp"
            or filetype == "c" or filetype == "javascript" or filetype == "typescript"
            or filetype == "tsx" or filetype == "java" or filetype == "cs" then
            cfg = lang_configs.braces
        end

        if cfg then
            local idx = 1
            while idx <= #content_lines do
                local line = content_lines[idx]
                local name = nil
                if cfg.name_pattern then
                    name = line:match(cfg.name_pattern)
                elseif cfg.parse_name then
                    name = cfg.parse_name(line, ext, filetype)
                end

                if name then
                    name = name:match("^([%w_.:]+)") or name
                    local keywords = { ["fn"]=true, ["func"]=true, ["function"]=true, ["if"]=true, ["while"]=true, ["for"]=true, ["return"]=true }
                    if keywords[name] then name = nil end
                end

                if name and name ~= "" then
                    local end_line = cfg.parse_body(idx, content_lines)
                    if end_line then
                        local body_lines = {}
                        for k = idx, end_line do
                            table.insert(body_lines, content_lines[k] or "")
                        end
                        table.insert(functions, {
                            name = name,
                            file = rel_path,
                            start_line = idx,
                            end_line = end_line,
                            length = end_line - idx + 1,
                            body = table.concat(body_lines, "\n")
                        })
                        idx = end_line
                    end
                end
                idx = idx + 1
            end
        end

        return functions
    end

    local functions = {}

    parser:parse()
    -- Parse all parsed sub-trees (including injected languages like inline scripts inside HTML)
    parser:for_each_tree(function(tree, lang_tree)
        local root_node = tree:root()
        if not root_node then return end

        local function is_function_definition_node(node_type)
            local t = node_type:lower()
            if t:find("call") or t:find("argument") or t:find("parameter") or t:find("comment") or t:find("string") or t:find("expression") then
                return false
            end
            if t == "function" or t == "method" or t == "fn" then
                return false
            end
            return t:find("function")
                or t:find("method")
                or t == "func_literal"
                or t == "function_item"
                or t == "local_function"
        end

        local function get_function_name(node)
            -- Try to find child identifier/name
            for child in node:iter_children() do
                local ctype = child:type()
                if ctype == "identifier" or ctype == "name" or ctype == "field_expression" or ctype == "declarator" then
                    local text = vim.trim(vim.treesitter.get_node_text(child, content) or "")
                    if text ~= "" and not text:find("^function") then
                        text = text:match("^([%w_.:]+)") or text
                        return text
                    end
                end
            end
            return nil
        end

        local function traverse(node)
            local ntype = node:type()
            if is_function_definition_node(ntype) then
                local start_row, _, end_row, _ = node:range()
                local start_line = start_row + 1
                local end_line = end_row + 1
                local length = end_line - start_line + 1

                local name = get_function_name(node)
                if not name then
                    -- First line regex fallback
                    local first_line = content_lines[start_line] or ""
                    first_line = first_line:gsub("^%s*", "")
                    name = first_line:match("function%s+([%w_.:]+)")
                        or first_line:match("def%s+([%w_]+)")
                        or first_line:match("func%s+([%w_]+)")
                        or first_line:match("fn%s+([%w_]+)")
                        or first_line:match("[%w_:]+%s+([%w_:]+)%s*%(")
                end

                -- Clean name if matched
                if name then
                    name = name:match("^([%w_.:]+)") or name
                    local keywords = {
                        ["function"] = true,
                        ["local"] = true,
                        ["def"] = true,
                        ["func"] = true,
                        ["fn"] = true,
                        ["local_function"] = true,
                        ["method"] = true
                    }
                    if keywords[name] then
                        name = nil
                    end
                end

                if name and name ~= "" then
                    -- Get body text
                    local body_lines = {}
                    for idx = start_line, end_line do
                        table.insert(body_lines, content_lines[idx] or "")
                    end
                    table.insert(functions, {
                        name = name,
                        file = rel_path,
                        start_line = start_line,
                        end_line = end_line,
                        length = length,
                        body = table.concat(body_lines, "\n")
                    })
                end
            end

            for child in node:iter_children() do
                traverse(child)
            end
        end

        traverse(root_node)
    end)

    return functions
end

---Builds the project AST call graph and saves it as qLLM_map.json.
---@param root string
function M.build_and_save_call_graph(root)
    local source_files = {}
    local tokei_executable = vim.fn.executable("tokei") == 1

    if tokei_executable then
        -- Run tokei on the root directory to find all code files and detect their languages.
        local cmd = string.format("tokei -f -o json %s", vim.fn.shellescape(root))
        local raw_json = vim.fn.system(cmd)
        local ok, decoded = pcall(vim.json.decode, raw_json)

        if ok and decoded then
            -- Parse each language key except "Total"
            for lang_name, lang_data in pairs(decoded) do
                if lang_name ~= "Total" and type(lang_data) == "table" and lang_data.reports then
                    for _, report in ipairs(lang_data.reports) do
                        if report.name and report.stats and (report.stats.code or 0) > 0 then
                            -- Tokei returns paths relative to root or execution dir. Resolve it properly.
                            local path = report.name
                            if path:sub(1, 2) == "./" then
                                path = path:sub(3)
                            end
                            local abs_path = path
                            if not (path:sub(1, 1) == "/" or path:match("^%a:")) then
                                abs_path = root .. path
                            end
                            abs_path = vim.fn.fnamemodify(abs_path, ":p")

                            if vim.fn.filereadable(abs_path) == 1 then
                                -- Dynamically match filetype using Neovim's built-in filetype database.
                                -- If Neovim doesn't recognize it, fall back to lowercase of tokei's language name.
                                local filetype = vim.filetype.match({ filename = abs_path }) or string.lower(lang_name)
                                table.insert(source_files, {
                                    path = abs_path,
                                    filetype = filetype
                                })
                            end
                        end
                    end
                end
            end
        else
            tokei_executable = false -- Fall back to native scanner if decode failed
        end
    end

    if not tokei_executable then
        -- Fallback to native Lua globbing and gitignore parsing
        local gitignore_patterns = M.get_gitignore_patterns(root)
        local all_files = vim.fn.globpath(root, "**", true, true)
        for _, file in ipairs(all_files) do
            if vim.fn.filereadable(file) == 1 and not M.should_ignore(file, root, gitignore_patterns) then
                table.insert(source_files, {
                    path = file,
                    filetype = nil -- Will match dynamically
                })
            end
        end
    end

    -- Extract functions
    local functions = {}
    local function_name_to_info = {}

    for _, file_info in ipairs(source_files) do
        local file_funcs = M.extract_functions_from_file(file_info.path, root, file_info.filetype)
        for _, f in ipairs(file_funcs) do
            table.insert(functions, f)
            if not function_name_to_info[f.name] then
                function_name_to_info[f.name] = {}
            end
            table.insert(function_name_to_info[f.name], f)
        end
    end

    -- Weave caller and callee connections
    for _, f in ipairs(functions) do
        f.calls = {}
        f.callers = {}
    end

    for _, f in ipairs(functions) do
        for name, defs in pairs(function_name_to_info) do
            -- Avoid recursion or matching itself
            local is_self = false
            for _, def in ipairs(defs) do
                if def.file == f.file and def.name == f.name and def.start_line == f.start_line then
                    is_self = true
                end
            end

            if not is_self then
                local base_name = name:match("[.:]([%w_]+)$") or name
                local pattern = "%f[%w_]" .. vim.pesc(base_name) .. "%f[^%w_]"
                if f.body:find(pattern) then
                    for _, def in ipairs(defs) do
                        -- Add to f.calls (unique entries)
                        local already_calls = false
                        for _, c in ipairs(f.calls) do
                            if c.name == def.name and c.file == def.file then
                                already_calls = true
                                break
                            end
                        end
                        if not already_calls then
                            table.insert(f.calls, { name = def.name, file = def.file })
                        end

                        -- Add to def.callers (unique entries)
                        local already_caller = false
                        for _, c in ipairs(def.callers) do
                            if c.name == f.name and c.file == f.file then
                                already_caller = true
                                break
                            end
                        end
                        if not already_caller then
                            table.insert(def.callers, { name = f.name, file = f.file })
                        end
                    end
                end
            end
        end
    end

    -- Prepare serializable representation without bodies
    local serializable = {}
    for _, f in ipairs(functions) do
        table.insert(serializable, {
            name = f.name,
            file = f.file,
            start_line = f.start_line,
            end_line = f.end_line,
            length = f.length,
            calls = f.calls,
            callers = f.callers
        })
    end

    local json_path = root .. "qLLM_map.json"
    local f_json = io.open(json_path, "w")
    if f_json then
        f_json:write(vim.json.encode(serializable))
        f_json:close()
        vim.notify("Project call graph saved to " .. json_path, vim.log.levels.INFO)
    else
        vim.notify("Error: Could not write call graph to " .. json_path, vim.log.levels.ERROR)
    end
end

---Queries the call tree or variable reference tree structure for a given query.
---@param query string The function or variable name to query.
---@param root string The project root path.
---@return table|nil output_lines The list of formatted Markdown lines, or nil if an error occurs.
---@return string|nil error_msg An error message if something fails.
function M.query_call_tree(query, root)
    local map_path = root .. "qLLM_map.json"
    if vim.fn.filereadable(map_path) ~= 1 then
        return nil, "Project call graph not initialized. Please run :Chat init first."
    end

    local json_content = table.concat(vim.fn.readfile(map_path), "\n")
    local ok, map_data = pcall(vim.json.decode, json_content)
    if not ok or not map_data then
        return nil, "Error reading call graph metadata."
    end

    local functions_by_name = {}
    local functions_by_signature = {}
    for _, f in ipairs(map_data) do
        if not functions_by_name[f.name] then
            functions_by_name[f.name] = {}
        end
        table.insert(functions_by_name[f.name], f)
        functions_by_signature[f.name .. "@" .. f.file] = f
    end

    local output_lines = {}

    local function traverse_downward(func_sig, path_visited, global_visited, lines, prefix)
        local f = functions_by_signature[func_sig]
        if not f or not f.calls then return end
        for i, call in ipairs(f.calls) do
            local is_last = (i == #f.calls)
            local branch = is_last and "└─ " or "├─ "
            local call_sig = call.name .. "@" .. call.file
            if path_visited[call_sig] then
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s) (cycle)", call.name, call.file))
            elseif global_visited[call_sig] then
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s) (already shown)", call.name, call.file))
            else
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s)", call.name, call.file))
                path_visited[call_sig] = true
                global_visited[call_sig] = true
                traverse_downward(call_sig, path_visited, global_visited, lines, prefix .. (is_last and "   " or "│  "))
                path_visited[call_sig] = nil
            end
        end
    end

    local function traverse_upward(func_sig, path_visited, global_visited, lines, prefix)
        local f = functions_by_signature[func_sig]
        if not f or not f.callers then return end
        for i, caller in ipairs(f.callers) do
            local is_last = (i == #f.callers)
            local branch = is_last and "└─ " or "├─ "
            local caller_sig = caller.name .. "@" .. caller.file
            if path_visited[caller_sig] then
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s) (cycle)", caller.name, caller.file))
            elseif global_visited[caller_sig] then
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s) (already shown)", caller.name, caller.file))
            else
                table.insert(lines, prefix .. branch .. string.format("[%s] (%s)", caller.name, caller.file))
                path_visited[caller_sig] = true
                global_visited[caller_sig] = true
                traverse_upward(caller_sig, path_visited, global_visited, lines, prefix .. (is_last and "   " or "│  "))
                path_visited[caller_sig] = nil
            end
        end
    end

    local matched_funcs = functions_by_name[query]
    local matched_name = nil
    local alt_matches = {}

    if matched_funcs then
        matched_name = query
    else
        -- Try suffix match first
        for name, funcs in pairs(functions_by_name) do
            if name:match("[.:]" .. query .. "$") then
                matched_funcs = funcs
                matched_name = name
                break
            end
        end

        -- Try fuzzy matching if still not matched
        if not matched_funcs then
            local function_names = {}
            for name, _ in pairs(functions_by_name) do
                table.insert(function_names, name)
            end
            local fuzzy = vim.fn.matchfuzzy(function_names, query)
            if #fuzzy > 0 then
                matched_name = fuzzy[1]
                matched_funcs = functions_by_name[matched_name]
                for idx = 2, math.min(#fuzzy, 5) do
                    table.insert(alt_matches, fuzzy[idx])
                end
            end
        end
    end

    if matched_funcs then
        if matched_name == query then
            table.insert(output_lines, string.format("# Call Tree for '%s'", query))
        else
            table.insert(output_lines, string.format("# Call Tree for '%s' (fuzzy matched to '%s')", query, matched_name))
        end
        if #alt_matches > 0 then
            table.insert(output_lines, string.format("*(alternative matches: %s)*", table.concat(alt_matches, ", ")))
        end
        table.insert(output_lines, "")
        for _, f in ipairs(matched_funcs) do
            table.insert(output_lines, string.format("### Defined in: [%s](file://%s#L%d)", f.file, root .. f.file, f.start_line))
            table.insert(output_lines, string.format("- **Range**: Lines %d-%d (length: %d lines)", f.start_line, f.end_line, f.length))
            table.insert(output_lines, "")

            -- Upward / Callers
            table.insert(output_lines, "▲ CALLERS (Upward callers):")
            local path_visited = {}
            local global_visited_up = {}
            local sig = f.name .. "@" .. f.file
            path_visited[sig] = true
            global_visited_up[sig] = true
            local caller_lines = {}
            traverse_upward(sig, path_visited, global_visited_up, caller_lines, "  ")
            if #caller_lines == 0 then
                table.insert(output_lines, "  └─ None")
            else
                for _, line in ipairs(caller_lines) do
                    table.insert(output_lines, line)
                end
            end
            table.insert(output_lines, "")

            -- Downward / Callees
            table.insert(output_lines, "▼ CALLEES (Downward calls):")
            path_visited = {}
            local global_visited_down = {}
            path_visited[sig] = true
            global_visited_down[sig] = true
            local callee_lines = {}
            traverse_downward(sig, path_visited, global_visited_down, callee_lines, "  ")
            if #callee_lines == 0 then
                table.insert(output_lines, "  └─ None")
            else
                for _, line in ipairs(callee_lines) do
                    table.insert(output_lines, line)
                end
            end
            table.insert(output_lines, "")
            table.insert(output_lines, string.rep("─", 50))
            table.insert(output_lines, "")
        end
    else
        -- Scan file bodies for references representing variable/symbol usage
        local file_cache = {}
        local function get_file_lines(filepath)
            if not file_cache[filepath] then
                local abs_path = root .. filepath
                if vim.fn.filereadable(abs_path) == 1 then
                    file_cache[filepath] = vim.fn.readfile(abs_path)
                else
                    file_cache[filepath] = {}
                end
            end
            return file_cache[filepath]
        end

        local references = {}
        local pattern = "%f[%w_]" .. vim.pesc(query) .. "%f[^%w_]"
        for _, f in ipairs(map_data) do
            local file_lines = get_file_lines(f.file)
            local body_lines = {}
            for idx = f.start_line, math.min(f.end_line, #file_lines) do
                table.insert(body_lines, file_lines[idx] or "")
            end
            local body_text = table.concat(body_lines, "\n")
            if body_text:find(pattern) then
                table.insert(references, f)
            end
        end

        table.insert(output_lines, string.format("# Reference Tree for Symbol '%s'", query))
        table.insert(output_lines, "")
        table.insert(output_lines, "The symbol was not found as a function definition. Showing referencing functions:")
        table.insert(output_lines, "")

        if #references == 0 then
            table.insert(output_lines, "  └─ No references found in project functions.")
        else
            for i, ref in ipairs(references) do
                local is_last = (i == #references)
                local branch = is_last and "└─ " or "├─ "
                table.insert(output_lines, string.format("  %s[%s] (%s:L%d-L%d, length: %d lines)", branch, ref.name, ref.file, ref.start_line, ref.end_line, ref.length))
            end
        end
    end

    return output_lines
end

return M
