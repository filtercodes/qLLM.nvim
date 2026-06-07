local M = {}
local Api = require("quickllm.api")

---Gets the project root directory (closest directory with .git or current working dir).
---@return string
function M.get_project_root()
    local git_dir = vim.fn.finddir(".git", ".;")
    if git_dir ~= "" then
        return vim.fn.fnamemodify(git_dir, ":h:p") .. "/"
    end
    return vim.fn.getcwd() .. "/"
end

---Generates a lightweight skeleton hash and file count.
---@param root string
---@return string hash
---@return number count
function M.generate_project_skeleton(root)
    -- Scan files up to 3 levels deep, ignoring .git
    local files = vim.fn.globpath(root, "**", true, true)
    local structure = {}
    local count = 0
    for _, file in ipairs(files) do
        if not file:find("%.git/") then
            local stats = vim.loop.fs_stat(file)
            if stats then
                -- Skeleton: Names and timestamps
                table.insert(structure, string.format("%s:%d", file, stats.mtime.sec))
                count = count + 1
            end
        end
    end
    table.sort(structure)
    return vim.fn.sha256(table.concat(structure, "\n")), count
end

---Orchestrates the project initialization (:Chat init).
---@param callback function? Optional callback for when init is complete.
function M.init_project(callback)
    local kb_opts = vim.g.quickllm_kb_opts
    local now = os.time()
    if is_indexing and (now - last_progress_time < 300) then
        vim.notify("Project initialization already in progress.", vim.log.levels.WARN)
        return
    end

    local root = M.get_project_root()
    -- ... (rest of function)
    is_indexing = true
    last_progress_time = now
    local readme_path = root .. "README.md"
    local readme_content = ""
    if vim.fn.filereadable(readme_path) == 1 then
        readme_content = table.concat(vim.fn.readfile(readme_path), "\n")
    end

    -- Get directory listing
    local files = vim.fn.globpath(root, "*", true, true)
    local relative_files = {}
    for _, file in ipairs(files) do
        table.insert(relative_files, vim.fn.fnamemodify(file, ":."))
    end
    local dir_listing = table.concat(relative_files, "\n")

    local prompt = string.format([[
You are the Project Librarian. Analyze the following project structure and README.
Generate a high-level architectural map for this project.
Include:
1. Architecture Summary: What is this project?
2. Core Hubs: Key files/directories and their functional roles.

PROJECT STRUCTURE:
%s

README CONTENT:
%s

IMPORTANT: Output your response in Markdown format. Start with a metadata block in HTML comments:
<!-- METADATA: {"hash": "PENDING", "count": 0} -->
]], dir_listing, readme_content)

    local provider_name = kb_opts.project_provider or "ollama"
    local model_name = kb_opts.project_model or "qwen3:8b"

    local Providers = require("quickllm.providers")
    local CommandsList = require("quickllm.commands_list")
    local provider = Providers.get_provider({ provider = provider_name })

    vim.notify("Initializing Project Context... Calling Librarian.", vim.log.levels.INFO)
    Api.run_started_hook()

    provider.make_call({
        model = model_name,
        messages = {{role = "user", content = prompt}},
        stream = false
    }, prompt, function(lines)
        local response = table.concat(lines, "\n")
        local hash, count = M.generate_project_skeleton(root)
        
        -- Replace pending metadata with actual values
        local metadata_str = string.format('{"hash": "%s", "count": %d}', hash, count)
        local final_content = response:gsub('{"hash": "PENDING", "count": 0}', metadata_str)
        
        local output_path = root .. "quickLLM.md"
        local f = io.open(output_path, "w")
        if f then
            f:write(final_content)
            f:close()
            vim.notify("Project Context initialized: " .. output_path, vim.log.levels.INFO)
        else
            vim.notify("Error: Could not write to " .. output_path, vim.log.levels.ERROR)
        end
        Api.run_finished_hook()
        is_indexing = false
        if callback then callback() end
    end, -1)
end

---Returns the content of quickLLM.md if it exists.
function M.get_active_context()
    local root = M.get_project_root()
    local path = root .. "quickLLM.md"
    if vim.fn.filereadable(path) == 1 then
        return table.concat(vim.fn.readfile(path), "\n")
    end
    return nil
end

---Analyzes freshness and returns a status and recommendation.
---@return string status "missing" | "fresh" | "stale" | "significant_change"
function M.get_freshness_status()
    local context = M.get_active_context()
    if not context then return "missing" end

    local metadata_json = context:match("<!%-%- METADATA: (.-) %-%->")
    if not metadata_json then return "stale" end

    local ok, decoded = pcall(vim.json.decode, metadata_json)
    if not ok or not decoded.hash then return "stale" end

    local root = M.get_project_root()
    local current_hash, current_count = M.generate_project_skeleton(root)

    if current_hash == decoded.hash then
        return "fresh"
    end

    -- Check for "significant" change (e.g. 10+ files difference or count change)
    local diff = math.abs(current_count - (decoded.count or 0))
    if diff >= 10 then
        return "significant_change"
    end

    return "stale"
end

---Ensures project context is fresh, running init if needed based on auto_init setting.
---@param callback function The function to call once context is ready/checked.
function M.ensure_fresh_context(callback)
    local kb_opts = vim.g.quickllm_kb_opts
    local auto_init = kb_opts.auto_init ~= false
    local auto_check = kb_opts.auto_check_freshness ~= false

    if not auto_check then
        callback()
        return
    end

    local status = M.get_freshness_status()

    if status == "missing" then
        -- Truly Optional: If the map doesn't exist, we don't nag.
        -- We only start managing it once the user has manually run :Chat init.
        callback()
    elseif status == "significant_change" then
        if auto_init then
            vim.notify("[QuickLLM] Syncing project map (significant changes detected)...", vim.log.levels.INFO)
            M.init_project(callback)
        else
            vim.notify("[QuickLLM] Project map is stale. Run :Chat init to update.", vim.log.levels.WARN)
            callback()
        end
    else
        -- status is "fresh" or "stale" (minor change)
        callback()
    end
end

return M
