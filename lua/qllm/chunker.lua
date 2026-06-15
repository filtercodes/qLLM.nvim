local M = {}

---Determines if a given buffer or string should use Tree-sitter for chunking.
---@param lang string
---@return boolean
local function has_parser(lang)
    local ok, _ = pcall(vim.treesitter.get_parser, 0, lang)
    if not ok then
        -- Try to see if we can get a string parser
        ok, _ = pcall(vim.treesitter.get_string_parser, "", lang)
    end
    return ok
end

---Splits very large chunks into smaller pieces using a sliding window.
---@param chunks table List of strings
---@param max_chars number? Default 4000
---@return table
function M.apply_safety_limits(chunks, max_chars)
    local limit = max_chars or 4000
    local final_chunks = {}

    for _, chunk in ipairs(chunks) do
        if #chunk <= limit then
            table.insert(final_chunks, chunk)
        else
            -- Simple split for now, preserving some overlap if needed
            -- But keeping it simple: just hard split at limit
            local start = 1
            while start <= #chunk do
                table.insert(final_chunks, chunk:sub(start, start + limit))
                start = start + limit - 100 -- 100 char overlap
            end
        end
    end
    return final_chunks
end

---Chunking Tier 2: Semantic (Paragraph-based)
---Used as a fallback or for non-structured text files.
---@param content string
---@return table
function M.chunk_by_paragraphs(content)
    local chunks = {}
    -- Split by double newlines (standard paragraph separator)
    local raw_chunks = vim.split(content, "\n\n", { trimempty = true })
    
    local current_chunk = ""
    for _, block in ipairs(raw_chunks) do
        -- Group small paragraphs together to maintain context
        if #current_chunk + #block < 1500 then
            current_chunk = current_chunk .. block .. "\n\n"
        else
            if current_chunk ~= "" then
                table.insert(chunks, vim.trim(current_chunk))
            end
            current_chunk = block .. "\n\n"
        end
    end
    
    if current_chunk ~= "" then
        table.insert(chunks, vim.trim(current_chunk))
    end
    
    return chunks
end

---Chunking Tier 1: Structural (Tree-sitter)
---Optimized for Markdown to split by headers while protecting code blocks.
---@param content string
---@return table?
function M.chunk_markdown(content)
    local ok, parser = pcall(vim.treesitter.get_string_parser, content, "markdown")
    if not ok or not parser then
        return nil -- Fallback to paragraph chunking
    end

    local tree = parser:parse()[1]
    local root = tree:root()
    
    -- We want to find all top-level sections or headers.
    -- However, TS for Markdown can be tricky across different versions.
    -- A robust "Hybrid" approach:
    -- 1. Identify all lines that are inside code blocks.
    -- 2. Use that to safely split by '#' headers.

    local lines = vim.split(content, "\n")
    local in_code_block_lines = {}
    
    -- Query for fenced code blocks
    local query_ok, query = pcall(vim.treesitter.query.parse, "markdown", "(fenced_code_block) @code")
    if query_ok then
        for _, node in query:iter_captures(root, content, 0, -1) do
            local start_row, _, end_row, _ = node:range()
            for i = start_row + 1, end_row + 1 do
                in_code_block_lines[i] = true
            end
        end
    end

    local chunks = {}
    local current_chunk = ""
    
    for i, line in ipairs(lines) do
        -- It's a header IF it starts with # AND it's NOT inside a code block
        local is_header = line:match("^#") and not in_code_block_lines[i]
        
        if is_header and current_chunk ~= "" then
            table.insert(chunks, vim.trim(current_chunk))
            current_chunk = line .. "\n"
        else
            current_chunk = current_chunk .. line .. "\n"
        end
    end

    if current_chunk ~= "" then
        table.insert(chunks, vim.trim(current_chunk))
    end

    return chunks
end

---Entry point for the Unified Chunker.
---@param path string
---@return table chunks
function M.chunk_file(path)
    if vim.fn.filereadable(path) ~= 1 then return {} end
    
    local content = table.concat(vim.fn.readfile(path), "\n")
    local ext = vim.fn.fnamemodify(path, ":e")
    local chunks = nil

    if ext == "md" then
        chunks = M.chunk_markdown(content)
    end

    -- Fallback to Paragraphs if TS failed or it's just a text file
    if not chunks or #chunks == 0 then
        chunks = M.chunk_by_paragraphs(content)
    end

    -- Finally, apply safety limits to handle massive blocks
    return M.apply_safety_limits(chunks)
end

return M
