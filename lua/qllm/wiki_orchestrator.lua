local M = {}

---Cleans LLM response to ensure valid JSON decoding using Tree-sitter.
---Locates and extracts the content of a fenced code block labeled 'json'.
---@param response string
---@return string
function M.clean_json_response(response)
    local ok, parser = pcall(vim.treesitter.get_string_parser, response, "markdown")
    if not ok or not parser then return vim.trim(response) end

    local tree = parser:parse()[1]
    local root = tree:root()
    
    -- Find fenced code block with info string 'json'
    local query = vim.treesitter.query.parse("markdown", [[
        (fenced_code_block 
            (info_string) @lang (#eq? @lang "json")
            (code_fence_content) @content)
    ]])
    
    for id, node, _ in query:iter_captures(root, response, 0, -1) do
        local name = query.captures[id]
        if name == "content" then
            return vim.trim(vim.treesitter.get_node_text(node, response))
        end
    end
    
    -- Fallback: If no JSON block found, try any first code block
    local query_any = vim.treesitter.query.parse("markdown", "(fenced_code_block (code_fence_content) @content)")
    for id, node, _ in query_any:iter_captures(root, response, 0, -1) do
        local name = query_any.captures[id]
        if name == "content" then
            return vim.trim(vim.treesitter.get_node_text(node, response))
        end
    end

    -- Last resort: Just trim the original response
    return vim.trim(response)
end

---Determines the best Knowledge Propagation strategy based on provider capabilities.
---@param provider_name string
---@return string strategy "god_prompt" | "lazy"
function M.get_update_strategy(provider_name)
    local capabilities = vim.g.qllm_provider_capabilities or {}
    local name = provider_name:lower()

    -- 1. Check explicit map in config
    if capabilities[name] and capabilities[name].strategy then
        return capabilities[name].strategy
    end

    -- Default for unknown providers
    return "lazy"
end

---Decodes a JSON response with stripping logic.
---@param response string
---@return table? decoded
---@return string? error
function M.safe_json_decode(response)
    local clean = M.clean_json_response(response)
    local ok, decoded = pcall(vim.json.decode, clean)
    if ok then
        return decoded
    end
    return nil, "JSON Decode Failed: " .. tostring(decoded)
end

---Autonomous neighborhood weaving. Finds top 5 semantic neighbors and applies surgical updates.
---@param source_path string The path of the newly updated file.
---@param source_content string The raw content of the new file.
---@param source_summary string The LLM-generated summary.
function M.weave_neighborhood(source_path, source_content, source_summary)
    local KB = require("qllm.providers.knowledge_base")
    local SafeWriter = require("qllm.wiki_safe_writer")
    local kb_opts = vim.g.qllm_kb_opts
    
    local lib_provider = kb_opts.context_provider or kb_opts.project_provider or vim.g.qllm_api_provider
    local lib_model = kb_opts.context_model or kb_opts.project_model
    local strategy = M.get_update_strategy(lib_provider)
    
    -- Weave only if we have vector search enabled
    local vec_path = kb_opts.sqlite_vec_path
    if vec_path == "" or vim.fn.filereadable(vec_path) ~= 1 then return end

    KB.generate_embedding(source_summary, function(emb, err)
        if err or not emb then return end
        
        -- Find top 5 neighbors (similarity > 0.85 -> distance < 0.15)
        local vec_json = vim.json.encode(emb)
        local sql = string.format([[
            SELECT d.filepath, d.summary_text, c.content
            FROM documents d
            JOIN summaries_vec s ON d.id = s.id
            LEFT JOIN chunk_content c ON d.id = c.document_id
            WHERE vec_distance_cosine(s.embedding, vec_f32('%s')) < 0.15
            AND d.filepath != '%s'
            ORDER BY vec_distance_cosine(s.embedding, vec_f32('%s'))
            LIMIT 5;
        ]], vec_json, source_path:gsub("'", "''"), vec_json)
        
        local results = KB.run_sql(sql, true)
        if #results == 0 then return end
        
        -- Collect distinct neighbors
        local neighbors = {}
        local seen_paths = {}
        for _, row in ipairs(results) do
            local parts = vim.split(row, "|")
            local path = parts[1]
            local summary = parts[2] or ""
            local chunk = parts[3] or ""
            
            if path and not seen_paths[path] then
                table.insert(neighbors, { filepath = path, summary = summary, content = chunk })
                seen_paths[path] = true
            end
        end
        
        if #neighbors == 0 then return end

        local Providers = require("qllm.providers")
        local CommandsList = require("qllm.commands_list")
        
        local cmd_opts = CommandsList.get_cmd_opts("chat", { provider = lib_provider })
        if not lib_model then
            lib_model = cmd_opts.model
        end

        local overrides = { provider = lib_provider, model = lib_model }
        local provider = Providers.get_provider(overrides)
        cmd_opts.extra_params = vim.tbl_extend("force", cmd_opts.extra_params or {}, { format = "json" })

        local prompt = ""
        if strategy == "god_prompt" then
            -- Process all neighbors in one pass
            local neighbors_ctx = ""
            for _, n in ipairs(neighbors) do
                neighbors_ctx = neighbors_ctx .. string.format("\nFILE: %s\nSUMMARY: %s\n---\n", n.filepath, n.summary)
            end
            
            prompt = string.format([=[
You are the Active Librarian. A new document has been added to the knowledge base.
Your job is to identify how this new document affects its semantic neighbors.
For each neighbor, generate a surgical update (a "ripple").

NEW DOCUMENT:
%s
%s

NEIGHBORS:
%s

OUTPUT REQUIREMENT:
You MUST output a strictly formatted JSON array containing the ripples:
```json
{
  "ripples": [
    {
      "filepath": "/path/to/neighbor.md",
      "patch_text": "- **[Date]**: Connection found in [[%s]]: ...",
      "target_header": "## Connections"
    }
  ]
}
```
]=], vim.fn.fnamemodify(source_path, ":t"), source_summary, neighbors_ctx, vim.fn.fnamemodify(source_path, ":t"))
            
            provider.make_call({
                model = lib_model,
                messages = {{role = "user", content = prompt}},
                stream = false,
                format = "json"
            }, prompt, function(lines)
                local response = table.concat(lines, "\n")
                local decoded, jerr = M.safe_json_decode(response)
                if decoded and decoded.ripples then
                    for _, ripple in ipairs(decoded.ripples) do
                        SafeWriter.apply_ripple_async(ripple.filepath, ripple, function(success)
                            if success then
                                vim.schedule(function()
                                    vim.notify(string.format("[qLLM] Librarian integrated update into %s", vim.fn.fnamemodify(ripple.filepath, ":t")), vim.log.levels.INFO)
                                end)
                            end
                        end)
                    end
                end
            end, -1)
        else
            -- Lazy strategy: Just do the top 1
            local n = neighbors[1]
            prompt = string.format([[
You are the Active Librarian. A new document has been added. Generate a surgical update for this neighbor.
NEW DOCUMENT: %s
SUMMARY: %s

NEIGHBOR: %s
SUMMARY: %s

Output strictly JSON:
```json
{
  "ripples": [
    {
      "filepath": "%s",
      "patch_text": "- **[Date]**: Connection found...",
      "target_header": "## Connections"
    }
  ]
}
```
]], vim.fn.fnamemodify(source_path, ":t"), source_summary, vim.fn.fnamemodify(n.filepath, ":t"), n.summary, n.filepath)
            
            provider.make_call({
                model = lib_model,
                messages = {{role = "user", content = prompt}},
                stream = false,
                format = "json"
            }, prompt, function(lines)
                local response = table.concat(lines, "\n")
                local decoded, jerr = M.safe_json_decode(response)
                if decoded and decoded.ripples then
                    for _, ripple in ipairs(decoded.ripples) do
                        SafeWriter.apply_ripple_async(ripple.filepath, ripple, function(success)
                            if success then
                                vim.schedule(function()
                                    vim.notify(string.format("[qLLM] Librarian integrated update into %s", vim.fn.fnamemodify(ripple.filepath, ":t")), vim.log.levels.INFO)
                                end)
                            end
                        end)
                    end
                end
            end, -1)
        end
    end)
end

return M
