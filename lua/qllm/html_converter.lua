local M = {}

---Decodes standard and numeric/hex HTML entities into plain text.
---@param text string The raw HTML text containing entities.
---@return string decoded Text with decoded entities.
function M.decode_entities(text)
    if not text or type(text) ~= "string" then
        return ""
    end

    local entity_map = {
        ["&quot;"] = '"',
        ["&apos;"] = "'",
        ["&#39;"]  = "'",
        ["&amp;"]  = "&",
        ["&lt;"]   = "<",
        ["&gt;"]   = ">",
        ["&nbsp;"] = " ",
        ["&copy;"] = "©",
        ["&reg;"]  = "®",
        ["&trade;"] = "™",
        ["&mdash;"] = "—",
        ["&ndash;"] = "–",
        ["&hellip;"] = "…",
    }

    -- 1. Replace named entity literals
    for ent, char in pairs(entity_map) do
        text = text:gsub(ent, char)
    end

    -- 2. Replace decimal numeric entities: &#123;
    text = text:gsub("&#(%d+);", function(dec)
        local n = tonumber(dec)
        if n and n > 0 and n < 65536 then
            return utf8.char(n)
        end
        return ""
    end)

    -- 3. Replace hexadecimal numeric entities: &#x1F600;
    text = text:gsub("&#x([0-9a-fA-F]+);", function(hex)
        local n = tonumber(hex, 16)
        if n and n > 0 and n < 65536 then
            return utf8.char(n)
        end
        return ""
    end)

    return text
end

---Heuristically checks if a string contains well-formed or common HTML tags.
---@param text string The string to inspect.
---@return boolean is_html True if tags are detected.
function M.is_html(text)
    if not text or type(text) ~= "string" then
        return false
    end
    -- Check for common structural/formatting tags
    if text:find("<%s*[pP][^>]*>") or
       text:find("<%s*[hH][1-6][^>]*>") or
       text:find("<%s*[uU][lL][^>]*>") or
       text:find("<%s*[oO][lL][^>]*>") or
       text:find("<%s*[lL][iI][^>]*>") or
       text:find("<%s*[pP][rR][eE][^>]*>") or
       text:find("<%s*[cC][oO][dD][eE][^>]*>") or
       text:find("<%s*[sS][tT][rR][oO][nN][gG][^>]*>") or
       text:find("<%s*[eE][mM][^>]*>") or
       text:find("<%s*[bB][rR]%s*/?>") then
        return true
    end
    return false
end

---Extracts language identifier from HTML tag attributes (pre or code tags).
---@param pre_attrs string Attributes of the <pre> tag.
---@param code_attrs string Attributes of the <code> tag.
---@return string lang Detected language identifier or empty string.
function M.extract_language(pre_attrs, code_attrs)
    local attrs = (pre_attrs or "") .. " " .. (code_attrs or "")
    if attrs == " " then return "" end

    -- Match class with language-xyz or lang-xyz
    local lang = attrs:match("class=[\"'][^\"']*language%-([%w_+-]+)")
    if lang then return string.lower(lang) end

    lang = attrs:match("class=[\"'][^\"']*lang%-([%w_+-]+)")
    if lang then return string.lower(lang) end

    -- Match hljs class: class="hljs python"
    lang = attrs:match("class=[\"'][^\"']*hljs%s+([%w_+-]+)")
    if lang then return string.lower(lang) end

    -- Match data-language or data-lang attribute
    lang = attrs:match("data%-language=[\"']([%w_+-]+)[\"']") or attrs:match("data%-lang=[\"']([%w_+-]+)[\"']")
    if lang then return string.lower(lang) end

    -- Match highlight-source-xyz
    lang = attrs:match("class=[\"'][^\"']*highlight%-source%-([%w_+-]+)")
    if lang then return string.lower(lang) end

    return ""
end

---Lightweight heuristic code language detector based on source content patterns.
---@param code string Raw unescaped code content.
---@return string lang Identified language name or empty string.
function M.detect_code_language(code)
    if not code or type(code) ~= "string" then return "" end

    -- Rust detection
    if code:find("use%s+std::") or
       code:find("pub%s+struct%s+") or
       code:find("pub%s+fn%s+") or
       code:find("impl%s+[%w_]+%s+for") or
       code:find("fn%s+main%s*%(") or
       code:find("let%s+mut%s+") or
       code:find("#%[derive%(") or
       code:find("println!%s*%(") then
        return "rust"
    end

    -- Python detection
    if code:find("def%s+[%w_]+%s*%(") or
       code:find("import%s+[%w_]+") or
       code:find("from%s+[%w_]+%s+import") or
       code:find("if%s+__name__%s*==%s*[\"']__main__[\"']") or
       code:find("elif%s+.*:") or
       code:find("class%s+[%w_]+%s*%(?.*%)?:%s*$") then
        return "python"
    end

    -- Lua detection
    if code:find("local%s+function%s+") or
       code:find("local%s+[%w_]+%s*=") or
       code:find("require%s*%(?[\"'][%w_%.]+[\"']%)?") or
       code:find("vim%.api%.") or
       code:find("vim%.fn%.") then
        return "lua"
    end

    -- Go detection
    if code:find("package%s+[%w_]+") or
       code:find("func%s+[%w_]+%s*%(") or
       code:find("fmt%.Print") or
       code:find("import%s*%(%s*[\"']") then
        return "go"
    end

    -- JavaScript / TypeScript detection
    if code:find("const%s+[%w_]+%s*=") or
       code:find("console%.log%s*%(") or
       code:find("import%s+.*from%s+[\"']") or
       code:find("export%s+default%s+") or
       code:find("export%s+const%s+") or
       code:find("interface%s+[%w_]+%s*{") or
       code:find("type%s+[%w_]+%s*=%s*{") then
        return "typescript"
    end

    -- C / C++ detection
    if code:find("#include%s*<[%w_%.]+>") or
       code:find("std::cout") or
       code:find("std::vector") or
       code:find("int%s+main%s*%(") then
        return "cpp"
    end

    -- SQL detection
    if code:find("^%s*SELECT%s+") or
       code:find("^%s*INSERT%s+INTO%s+") or
       code:find("^%s*CREATE%s+TABLE%s+") or
       code:find("^%s*UPDATE%s+[%w_]+%s+SET") then
        return "sql"
    end

    -- Bash / Shell detection
    if code:find("^#!/bin/") or
       code:find("^%s*curl%s+") or
       code:find("^%s*sudo%s+") or
       code:find("^%s*npm%s+install") or
       code:find("^%s*cargo%s+build") then
        return "bash"
    end

    -- JSON detection
    if code:find("^%s*{%s*\"[%w_]+\"%s*:") then
        return "json"
    end

    return ""
end

---Converts an HTML string into cleanly formatted Markdown.
---@param html string The input HTML string.
---@return string markdown Formatted markdown string.
function M.to_markdown(html)
    if not html or type(html) ~= "string" then
        return ""
    end

    local out = html

    -- Normalize newlines and carriage returns
    out = out:gsub("\r\n", "\n"):gsub("\r", "\n")

    -- 1. Code blocks with pre and code tags: <pre(attrs)><code(attrs)>...</code></pre> or <pre(attrs)>...</pre>
    out = out:gsub("<%s*[pP][rR][eE]([^>]*)>%s*<%s*[cC][oO][dD][eE]([^>]*)>(.-)<%s*/%s*[cC][oO][dD][eE]%s*>%s*<%s*/%s*[pP][rR][eE]%s*>", function(pre_attrs, code_attrs, code)
        local decoded_code = vim.trim(M.decode_entities(code))
        local lang = M.extract_language(pre_attrs, code_attrs)
        if lang == "" then
            lang = M.detect_code_language(decoded_code)
        end
        return "\n\n```" .. lang .. "\n" .. decoded_code .. "\n```\n\n"
    end)

    out = out:gsub("<%s*[pP][rR][eE]([^>]*)>(.-)<%s*/%s*[pP][rR][eE]%s*>", function(pre_attrs, code)
        local decoded_code = vim.trim(M.decode_entities(code))
        local lang = M.extract_language(pre_attrs, "")
        if lang == "" then
            lang = M.detect_code_language(decoded_code)
        end
        return "\n\n```" .. lang .. "\n" .. decoded_code .. "\n```\n\n"
    end)

    -- 2. Headers: <h1> through <h6>
    for level = 1, 6 do
        local prefix = string.rep("#", level) .. " "
        out = out:gsub("<%s*[hH]" .. level .. "[^>]*>(.-)<%s*/%s*[hH]" .. level .. "%s*>", function(content)
            return "\n\n" .. prefix .. vim.trim(content) .. "\n\n"
        end)
    end

    -- 3. Ordered list items: <ol><li>...</li></ol>
    out = out:gsub("<%s*[oO][lL][^>]*>(.-)<%s*/%s*[oO][lL]%s*>", function(list_content)
        local count = 1
        local parsed = list_content:gsub("<%s*[lL][iI][^>]*>(.-)<%s*/%s*[lL][iI]%s*>", function(item)
            local item_str = string.format("%d. %s", count, vim.trim(item))
            count = count + 1
            return "\n" .. item_str
        end)
        return "\n\n" .. vim.trim(parsed) .. "\n\n"
    end)

    -- 4. Unordered list items: <ul><li>...</li></ul>
    out = out:gsub("<%s*[uU][lL][^>]*>(.-)<%s*/%s*[uU][lL]%s*>", function(list_content)
        local parsed = list_content:gsub("<%s*[lL][iI][^>]*>(.-)<%s*/%s*[lL][iI]%s*>", function(item)
            return "\n- " .. vim.trim(item)
        end)
        return "\n\n" .. vim.trim(parsed) .. "\n\n"
    end)

    -- Residual <li> tags outside of ul/ol
    out = out:gsub("<%s*[lL][iI][^>]*>(.-)<%s*/%s*[lL][iI]%s*>", function(item)
        return "\n- " .. vim.trim(item) .. "\n"
    end)

    -- 5. Paragraphs: <p>...</p>
    out = out:gsub("<%s*[pP][^>]*>(.-)<%s*/%s*[pP]%s*>", function(p)
        return "\n\n" .. vim.trim(p) .. "\n\n"
    end)

    -- 6. Blockquotes: <blockquote>...</blockquote>
    out = out:gsub("<%s*[bB][lL][oO][cC][kK][qQ][uU][oO][tT][eE][^>]*>(.-)<%s*/%s*[bB][lL][oO][cC][kK][qQ][uU][oO][tT][eE]%s*>", function(bq)
        local lines = vim.split(vim.trim(bq), "\n")
        for i, l in ipairs(lines) do
            lines[i] = "> " .. l
        end
        return "\n\n" .. table.concat(lines, "\n") .. "\n\n"
    end)

    -- 7. Line breaks: <br>, <br/>, <hr>, <hr/>
    out = out:gsub("<%s*[bB][rR]%s*/?>", "\n")
    out = out:gsub("<%s*[hH][rR]%s*/?>", "\n\n---\n\n")

    -- 8. Inline formatting: strong, b, em, i, code, a
    out = out:gsub("<%s*[sS][tT][rR][oO][nN][gG][^>]*>(.-)<%s*/%s*[sS][tT][rR][oO][nN][gG]%s*>", "**%1**")
    out = out:gsub("<%s*[bB]%s*>(.-)<%s*/%s*[bB]%s*>", "**%1**")
    out = out:gsub("<%s*[eE][mM][^>]*>(.-)<%s*/%s*[eE][mM]%s*>", "*%1*")
    out = out:gsub("<%s*[iI]%s*>(.-)<%s*/%s*[iI]%s*>", "*%1*")
    out = out:gsub("<%s*[cC][oO][dD][eE][^>]*>(.-)<%s*/%s*[cC][oO][dD][eE]%s*>", "`%1`")

    -- Anchor links: <a href="url">text</a>
    out = out:gsub("<%s*[aA][^>]*href=[\"']([^\"']+)[\"'][^>]*>(.-)<%s*/%s*[aA]%s*>", "[%2](%1)")

    -- 9. Strip any remaining unsupported HTML tags
    out = out:gsub("<[^>]+>", "")

    -- 10. Decode HTML entities into literal characters
    out = M.decode_entities(out)

    -- Clean up excessive consecutive blank lines (more than 2 consecutive newlines)
    out = out:gsub("\n%s*\n%s*\n+", "\n\n")

    return vim.trim(out)
end

return M
