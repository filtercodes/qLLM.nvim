local curl = require("plenary.curl")
local Utils = require("qllm.utils")
local Api = require("qllm.api")
local ContextEngine = require("qllm.context_engine")
local Logger = require("qllm.logger")

local KB = {}

-- State for background indexing
local is_indexing = false
local last_progress_time = 0
local index_stats = {
    total = 0,
    processed = 0,
    start_time = 0
}

---Helper to run SQL commands via the sqlite3 CLI.
---Supports loading the vector extension and running multiple statements in one session.
---@param sql string The SQL query or multiple statements.
---@param load_vec boolean? Whether to attempt loading the sqlite-vec extension.
---@return table results The output lines from the command.
function KB.run_sql(sql, load_vec)
    local kb_opts = vim.g.qllm_kb_opts
    local db_path = kb_opts.db_path
    local vec_path = kb_opts.sqlite_vec_path
    
    local function execute()
        local tmp = vim.fn.tempname()
        local f = io.open(tmp, "w")
        if f then
            if load_vec and vec_path ~= "" and vim.fn.filereadable(vec_path) == 1 then
                f:write(string.format(".load %s\n", vec_path))
            end
            f:write(sql)
            f:close()
            
            local cmd = string.format("sqlite3 %s < %s", db_path, tmp)
            local res = vim.fn.systemlist(cmd)
            os.remove(tmp)
            return res
        end
        return {}
    end

    -- RETRY LOGIC: SQLite can lock the database during background indexing.
    local retries = 3
    local delay = 100 -- ms
    for i = 1, retries do
        local results = execute()
        local output_str = table.concat(results, " ")
        if not output_str:lower():find("database is locked") then
            return results
        end
        if i < retries then
            vim.wait(delay)
        end
    end
    
    vim.notify("KB Error: SQLite database is locked after multiple retries.", vim.log.levels.ERROR)
    return {}
end

---Initializes the SQLite database with the hierarchical schema.
function KB.init_db()
    local kb_opts = vim.g.qllm_kb_opts
    if vim.fn.executable("sqlite3") ~= 1 then
        vim.notify("Knowledge Base Error: 'sqlite3' executable not found.", vim.log.levels.ERROR)
        return false
    end

    -- Relational Schema
    local schema = [[
        CREATE TABLE IF NOT EXISTS documents (
            id INTEGER PRIMARY KEY,
            filepath TEXT UNIQUE,
            hash TEXT,
            summary_text TEXT,
            schema_links TEXT,
            contradictions TEXT,
            last_updated INTEGER
        );
        CREATE TABLE IF NOT EXISTS chunk_content (
            id INTEGER PRIMARY KEY,
            document_id INTEGER,
            content TEXT,
            FOREIGN KEY(document_id) REFERENCES documents(id)
        );
    ]]
    
    KB.run_sql(schema)

    local vec_path = kb_opts.sqlite_vec_path
    if vec_path ~= "" and vim.fn.filereadable(vec_path) == 1 then
        local dim = kb_opts.dimension or 768

        -- VECTOR DIMENSION GUARD
        local existing_schema = KB.run_sql("SELECT sql FROM sqlite_master WHERE type='table' AND name='summaries_vec';", true)
        if #existing_schema > 0 then
            local current_dim_match = existing_schema[1]:match("FLOAT%[(%d+)%]")
            if current_dim_match and tonumber(current_dim_match) ~= dim then
                vim.notify(string.format("KB Error: Embedding dimension mismatch. DB has %s, Config has %d. Please delete %s and re-index.", current_dim_match, dim, kb_opts.db_path), vim.log.levels.ERROR)
                return false
            end
        end

        local vec_schema = string.format([[
            CREATE VIRTUAL TABLE IF NOT EXISTS summaries_vec USING vec0(
                id INTEGER PRIMARY KEY,
                embedding FLOAT[%d]
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_vec USING vec0(
                id INTEGER PRIMARY KEY,
                embedding FLOAT[%d]
            );
        ]], dim, dim)
        KB.run_sql(vec_schema, true)
    end
    
    return true
end

---Calls the LLM to act as a Librarian and summarize the document.
function KB.get_librarian_metadata(content, cb)
    local kb_opts = vim.g.qllm_kb_opts
    local kb_folder = kb_opts.wiki_folder
    local schema_path = kb_folder .. "/schema.md"
    local schema_content = ""
    if vim.fn.filereadable(schema_path) == 1 then
        schema_content = table.concat(vim.fn.readfile(schema_path), "\n")
    end

    local prompt = string.format([[
You are the Knowledge Base Librarian. Read the following document and the provided schema.
Output a JSON object with strictly these keys:
- summary: A dense, 3-sentence summary of the core concepts.
- schema_links: An array of strings listing concepts from the schema this document relates to.
- contradictions: Any notes on where this document differs from known schema rules.

SCHEMA:
%s

DOCUMENT:
%s
]], schema_content, content)

    local lib_provider = kb_opts.context_provider or kb_opts.project_provider or vim.g.qllm_api_provider
    local lib_model = kb_opts.context_model or kb_opts.project_model

    local Providers = require("qllm.providers")
    local CommandsList = require("qllm.commands_list")
    local cmd_opts = CommandsList.get_cmd_opts("chat", { provider = lib_provider })

    if not lib_model then
        lib_model = cmd_opts.model
    end

    local overrides = { provider = lib_provider, model = lib_model }
    local provider = Providers.get_provider(overrides)
    
    cmd_opts.extra_params = vim.tbl_extend("force", cmd_opts.extra_params or {}, { format = "json" })

    provider.make_call({
        model = lib_model,
        messages = {{role = "user", content = prompt}},
        stream = false,
        format = "json"
    }, prompt, function(lines)
        local response = table.concat(lines, "\n")
        local ok, json = pcall(vim.json.decode, response)
        if ok and json then
            cb(json)
        else
            cb(nil, "Librarian failed to return valid JSON")
        end
    end, -1)
end

---Generates an embedding for text.
function KB.generate_embedding(text, cb)
    local kb_opts = vim.g.qllm_kb_opts
    local kb_provider = kb_opts.provider or "ollama"
    local kb_model = kb_opts.model or "nomic-embed-text"
    
    local url = ""
    local body = {}
    local headers = { ["Content-Type"] = "application/json" }

    if kb_provider == "ollama" then
        url = (vim.g.qllm_ollama_url or "http://localhost:11434") .. "/api/embeddings"
        body = { model = kb_model, prompt = text }
    elseif kb_provider == "openai" then
        url = "https://api.openai.com/v1/embeddings"
        headers["Authorization"] = "Bearer " .. (vim.env.OPENAI_API_KEY or "")
        body = { model = kb_model, input = text }
    elseif kb_provider == "gemini" then
        url = string.format("https://generativelanguage.googleapis.com/v1beta/models/%s:embedContent", kb_model)
        headers["x-goog-api-key"] = vim.env.GEMINI_API_KEY or ""
        body = { model = "models/" .. kb_model, content = { parts = { { text = text } } } }
    else
        vim.notify("KB Error: Embeddings currently only supported via Ollama, OpenAI, Gemini.", vim.log.levels.ERROR)
        cb(nil, "Unsupported provider: " .. kb_provider)
        return
    end
    
    local function make_request(retries)
        curl.post(url, {
            headers = headers,
            body = vim.json.encode(body),
            callback = function(res)
                if res.status == 429 and retries > 0 then
                    vim.defer_fn(function() make_request(retries - 1) end, 2000)
                    return
                elseif res.status ~= 200 then
                    vim.schedule(function() cb(nil, "Embedding Error: " .. res.status .. " " .. tostring(res.body)) end)
                    return
                end

                local ok, json = pcall(vim.json.decode, res.body)
                if ok and json then
                    local embedding = nil
                    if kb_provider == "ollama" and json.embedding then
                        embedding = json.embedding
                    elseif kb_provider == "openai" and json.data and json.data[1] then
                        embedding = json.data[1].embedding
                    elseif kb_provider == "gemini" and json.embedding and json.embedding.values then
                        embedding = json.embedding.values
                    end

                    if embedding then
                        vim.schedule(function() cb(embedding) end)
                    else
                        vim.schedule(function() cb(nil, "Failed to parse embedding response structure") end)
                    end
                else
                    vim.schedule(function() cb(nil, "Failed to decode JSON embedding response") end)
                end
            end,
            on_error = function(err)
                if retries > 0 then
                    vim.defer_fn(function() make_request(retries - 1) end, 2000)
                else
                    vim.schedule(function() cb(nil, "Curl Error: " .. tostring(err)) end)
                end
            end
        })
    end
    make_request(3)
end

---Runs the Global Auditor to find anomalies and populates the Quickfix list.
function KB.wiki_lint()
    local kb_opts = vim.g.qllm_kb_opts
    if not KB.init_db() then return end
    local vec_path = kb_opts.sqlite_vec_path
    local has_vec = vec_path ~= "" and vim.fn.filereadable(vec_path) == 1

    local qf_items = {}
    vim.notify("Running Global Auditor...", vim.log.levels.INFO)

    -- 1. Anomaly: Orphan Detection
    -- Find files whose basename is not mentioned in any OTHER file's content
    local orphan_sql = [[
        SELECT d.filepath, d.id
        FROM documents d
    ]]
    local all_docs = KB.run_sql(orphan_sql)
    for _, row in ipairs(all_docs) do
        local parts = vim.split(row, "|")
        local filepath = parts[1]
        local id = parts[2]
        if filepath and id then
            local basename = vim.fn.fnamemodify(filepath, ":t")
            local escaped_basename = basename:gsub("'", "''")
            local mentions_sql = string.format([[
                SELECT COUNT(*) FROM chunk_content 
                WHERE document_id != %s 
                AND content LIKE '%%%s%%';
            ]], id, escaped_basename)

            local count_res = KB.run_sql(mentions_sql)
            if #count_res > 0 and tonumber(count_res[1]) == 0 then
                table.insert(qf_items, {
                    filename = filepath,
                    lnum = 1,
                    text = "[Orphan] No other document mentions this file."
                })
            end
        end
    end

    -- 2. Anomaly: Shadow Concepts
    if has_vec then
        local shadow_sql = [[
            SELECT d1.filepath, d2.filepath, d1.schema_links, d2.schema_links
            FROM documents d1
            JOIN summaries_vec s1 ON d1.id = s1.id
            JOIN summaries_vec s2 ON s1.id != s2.id
            JOIN documents d2 ON s2.id = d2.id
            WHERE vec_distance_cosine(s1.embedding, s2.embedding) < 0.15
            AND d1.id < d2.id;
        ]]
        local pairs = KB.run_sql(shadow_sql, true)
        for _, row in ipairs(pairs) do
            local parts = vim.split(row, "|")
            if #parts >= 4 then
                local file1 = parts[1]
                local file2 = parts[2]
                local links1 = parts[3]
                local links2 = parts[4]
                local ok1, parsed1 = pcall(vim.json.decode, links1)
                local ok2, parsed2 = pcall(vim.json.decode, links2)

                if ok1 and ok2 and type(parsed1) == "table" and type(parsed2) == "table" then
                    local shared = 0
                    for _, l1 in ipairs(parsed1) do
                        for _, l2 in ipairs(parsed2) do
                            if type(l1) == "string" and type(l2) == "string" and l1:lower() == l2:lower() then
                                shared = shared + 1
                            end
                        end
                    end

                    if shared == 0 then
                        table.insert(qf_items, {
                            filename = file1,
                            lnum = 1,
                            text = string.format("[Shadow Concept] Highly similar to %s but shares 0 schema links.", vim.fn.fnamemodify(file2, ":t"))
                        })
                    end
                end
            end
        end
    end

    if #qf_items > 0 then
        vim.fn.setqflist(qf_items, 'r')
        vim.cmd("copen")
        vim.notify(string.format("Found %d anomalies. Quickfix list updated.", #qf_items), vim.log.levels.WARN)
    else
        vim.fn.setqflist({}, 'r')
        vim.cmd("cclose")
        vim.notify("Knowledge Base is healthy! No anomalies found.", vim.log.levels.INFO)
    end
end

---Main indexing entry point.
function KB.wiki_index()
    local kb_opts = vim.g.qllm_kb_opts
    local now = os.time()
    
    -- SAFETY: If indexing has been "active" for more than 5 minutes without progress, 
    -- assume it crashed and allow reset.
    if is_indexing and (now - last_progress_time < 300) then
        vim.notify("Index already in progress.", vim.log.levels.WARN)
        return
    end

    if not KB.init_db() then return end

    local kb_folder = kb_opts.wiki_folder
    local files = vim.fn.globpath(kb_folder, "**/*.md", true, true)
    if #files == 0 then
        vim.notify("No Markdown files found in KB folder.", vim.log.levels.INFO)
        return
    end

    is_indexing = true
    last_progress_time = now
    index_stats.total = #files
    index_stats.processed = 0
    index_stats.start_time = vim.loop.now()

    vim.notify(string.format("Starting Knowledge Base wiki_index (%d files, Mode: %s)...", #files, kb_opts.style), vim.log.levels.INFO)

    KB.process_next_file(files, 1)
end

---Check if a file needs re-indexing.
function KB.needs_indexing(path)
    local current_hash = ContextEngine.get_file_hash(path)
    if not current_hash then return false end

    local results = KB.run_sql(string.format("SELECT hash FROM documents WHERE filepath = '%s';", path))
    return not (#results > 0 and results[1] == current_hash)
end

---Orchestrates the one-pass indexing for a file.
function KB.process_next_file(files, index)
    local kb_opts = vim.g.qllm_kb_opts
    if index > #files then
        is_indexing = false
        vim.notify(string.format("Index Complete! Processed %d files.", #files), vim.log.levels.INFO)
        return
    end

    -- Heartbeat for the lock safety
    last_progress_time = os.time()

    local path = files[index]
    if not KB.needs_indexing(path) then
        index_stats.processed = index
        KB.process_next_file(files, index + 1)
        return
    end

    local content_lines = vim.fn.readfile(path)
    local content = table.concat(content_lines, "\n")
    local hash = ContextEngine.get_file_hash(path)
    local style = kb_opts.style
    
    -- CHUNKING: Use the structure-aware chunker module
    local Chunker = require("qllm.chunker")
    local chunks = Chunker.chunk_file(path)

    -- ATOMIC CLEANUP: Reverse order to avoid orphans
    local cleanup_sql = string.format([[
        BEGIN TRANSACTION;
        DELETE FROM chunks_vec WHERE id IN (SELECT c.id FROM chunk_content c JOIN documents d ON c.document_id = d.id WHERE d.filepath = '%s');
        DELETE FROM summaries_vec WHERE id IN (SELECT id FROM documents WHERE filepath = '%s');
        DELETE FROM chunk_content WHERE document_id IN (SELECT id FROM documents WHERE filepath = '%s');
        DELETE FROM documents WHERE filepath = '%s';
        COMMIT;
    ]], path, path, path, path)
    KB.run_sql(cleanup_sql, true)

    local function finalize_file(metadata)
        -- 1. Insert Document and get ID (In same session)
        local summary = metadata and metadata.summary:gsub("'", "''") or ""
        local links = metadata and vim.json.encode(metadata.schema_links) or "[]"
        local contradictions = metadata and metadata.contradictions:gsub("'", "''") or ""
        
        local doc_sql = string.format([[
            INSERT INTO documents (filepath, hash, summary_text, schema_links, contradictions, last_updated)
            VALUES ('%s', '%s', '%s', '%s', '%s', %d);
            SELECT last_insert_rowid();
        ]], path, hash, summary, links, contradictions, os.time())
        
        local doc_id_res = KB.run_sql(doc_sql)
        local doc_id = tonumber(doc_id_res[1])

        -- 2. Parallel Embedding & Batch Storage
        local embeddings = {}
        local processed_count = 0
        local total_targets = #chunks + ( (style == "complex" and summary ~= "") and 1 or 0 )

        local function check_completion()
            processed_count = processed_count + 1
            if processed_count >= total_targets then
                -- All embeddings ready! Build one massive batch SQL string
                local batch_sqls = { "BEGIN TRANSACTION;" }
                
                -- Summary Vector
                if style == "complex" and embeddings["summary"] then
                    table.insert(batch_sqls, string.format(
                        "INSERT INTO summaries_vec (id, embedding) VALUES (%d, vec_f32('%s'));",
                        doc_id, vim.json.encode(embeddings["summary"])
                    ))
                end

                -- Chunks and Vectors
                for i, chunk_text in ipairs(chunks) do
                    local escaped_text = chunk_text:gsub("'", "''")
                    table.insert(batch_sqls, string.format(
                        "INSERT INTO chunk_content (document_id, content) VALUES (%d, '%s');",
                        doc_id, escaped_text
                    ))
                    if embeddings[i] then
                        table.insert(batch_sqls, string.format(
                            "INSERT INTO chunks_vec (id, embedding) VALUES (last_insert_rowid(), vec_f32('%s'));",
                            vim.json.encode(embeddings[i])
                        ))
                    end
                end
                
                table.insert(batch_sqls, "COMMIT;")
                KB.run_sql(table.concat(batch_sqls, "\n"), true)

                -- NEIGHBORHOOD WEAVING (Phase 4 Step 3)
                if style == "complex" and summary ~= "" then
                    local Orchestrator = require("qllm.wiki_orchestrator")
                    Orchestrator.weave_neighborhood(path, content, summary)
                end

                index_stats.processed = index
                vim.defer_fn(function() KB.process_next_file(files, index + 1) end, 10)
            end
        end

        -- Trigger async embeddings
        if style == "complex" and summary ~= "" then
            KB.generate_embedding(summary, function(emb)
                embeddings["summary"] = emb
                check_completion()
            end)
        end

        for i, chunk_text in ipairs(chunks) do
            KB.generate_embedding(chunk_text, function(emb)
                embeddings[i] = emb
                check_completion()
            end)
        end
    end

    if style == "complex" then
        KB.get_librarian_metadata(content, function(meta, err)
            if err then vim.notify("Librarian Error: " .. err, vim.log.levels.WARN) end
            finalize_file(meta)
        end)
    else
        finalize_file(nil)
    end
end

---Provider entry point for Search.
function KB.make_request(command, cmd_opts, command_args, text_selection, bufnr)
    return { query = command_args }, command_args
end

---Performs Hybrid Hierarchical Search.
function KB.make_call(payload, user_msg, cb, bufnr)
    local kb_opts = vim.g.qllm_kb_opts
    local query = payload.query

    -- TRACE: Log the outgoing request
    Logger.log_request("knowledge_base", "search", payload)

    local style = kb_opts.style
    local vec_path = kb_opts.sqlite_vec_path
    local has_vec = vec_path ~= "" and vim.fn.filereadable(vec_path) == 1

    KB.generate_embedding(query, function(query_vec, err)
        local results = {}
        
        if not err and query_vec and has_vec then
            local vec_json = vim.json.encode(query_vec)
            
            if style == "complex" then
                -- 1. Search Summaries (The Map) with Links
                -- We use vec_distance_cosine for maximum accuracy
                local summary_sql = string.format([[
                    SELECT summary_text || '@@@' || schema_links || '@@@' || filepath
                    FROM documents d
                    JOIN summaries_vec s ON d.id = s.id
                    WHERE vec_distance_cosine(s.embedding, vec_f32('%s')) < 1.0
                    ORDER BY vec_distance_cosine(s.embedding, vec_f32('%s'))
                    LIMIT 2;
                ]], vec_json, vec_json)
                local map_data = KB.run_sql(summary_sql, true)
                
                if #map_data > 0 then 
                    table.insert(results, "--- THE MAP (Conceptual Overview) ---")
                    for _, row in ipairs(map_data) do
                        local parts = vim.split(row, "@@@", { plain = true })
                        local summary = parts[1] or ""
                        local links = parts[2] or "[]"
                        local path = parts[3] or ""
                        
                        table.insert(results, "> " .. summary)
                        table.insert(results, "> Links: " .. links)
                        table.insert(results, "> SOURCE: " .. path)
                        table.insert(results, "")
                    end
                end
            end

            -- 2. Search Chunks (The Territory) with File Paths for 'gf'
            local chunk_sql = string.format([[
                SELECT d.filepath || '@@@' || c.content 
                FROM chunk_content c
                JOIN documents d ON c.document_id = d.id
                JOIN chunks_vec v ON c.id = v.id
                WHERE vec_distance_cosine(v.embedding, vec_f32('%s')) < 1.0
                ORDER BY vec_distance_cosine(v.embedding, vec_f32('%s'))
                LIMIT 5;
            ]], vec_json, vec_json)
            local territory_data = KB.run_sql(chunk_sql, true)
            
            if #territory_data > 0 then 
                table.insert(results, "\n--- THE TERRITORY (Specific Chunks) ---")
                for _, row in ipairs(territory_data) do
                    local parts = vim.split(row, "@@@", { plain = true })
                    local path = parts[1] or "Unknown"
                    local chunk = parts[2] or ""
                    
                    table.insert(results, string.format("SOURCE: %s\n%s", path, chunk))
                    table.insert(results, "---")
                end
            end
        else
            -- Keyword Fallback
            local kw_sql = string.format("SELECT content FROM chunk_content WHERE content LIKE '%%%s%%' LIMIT 5;", query:gsub("'", "''"))
            results = KB.run_sql(kw_sql)
        end

        local final_text = #results > 0 and table.concat(results, "\n") or "No relevant knowledge found."
        -- TRACE: Log the final response
        Logger.log_response("knowledge_base", "search", final_text)
        cb.on_chunk("[System: Knowledge Retrieval]\n\n" .. final_text, false)
        cb.on_complete(final_text)
    end)
end

---Saves content (selection or buffer) to a new markdown file in the KB folder.
---@param filename string The target filename.
---@param selection string? The selected text (optional).
function KB.wiki_save(filename, selection)
    local kb_folder = vim.g.qllm_kb_folder
    if vim.fn.isdirectory(kb_folder) == 0 then
        vim.fn.mkdir(kb_folder, "p")
    end

    -- Add .md extension if missing
    if not filename:match("%.md$") then
        filename = filename .. ".md"
    end

    local path = kb_folder .. "/" .. filename
    local content = selection
    
    if not content or content == "" then
        -- Use entire buffer if no selection
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        content = table.concat(lines, "\n")
    end

    local f = io.open(path, "w")
    if f then
        f:write(content)
        f:close()
        vim.notify("Saved to Wiki: " .. path, vim.log.levels.INFO)
        -- Trigger indexing for this specific file
        KB.process_next_file({ path }, 1)
    else
        vim.notify("Error: Could not write to " .. path, vim.log.levels.ERROR)
    end
end

return KB
