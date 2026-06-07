local M = {}
local uv = vim.loop

---Checks if a file is currently being modified in a loaded buffer.
---@param path string
---@return boolean
function M.is_buffer_busy(path)
    local bufnr = vim.fn.bufnr(path)
    if bufnr ~= -1 and vim.fn.bufloaded(bufnr) == 1 then
        if vim.api.nvim_buf_get_option(bufnr, "modified") then
            return true
        end
    end
    return false
end

---Patches a file asynchronously using libuv.
---@param path string The file to patch.
---@param content string The new content.
---@param sanity_rules table? { min_size_pct = 0.9, preserve_headers = true }
---@param cb function? Callback called with (success, err).
function M.patch_file_async(path, content, sanity_rules, cb)
    local rules = vim.tbl_extend("force", {
        min_size_pct = 0.9,
        preserve_headers = true
    }, sanity_rules or {})

    -- 1. Keystroke Protection
    if M.is_buffer_busy(path) then
        if cb then cb(false, "Buffer is modified in Neovim. Deferring patch.") end
        return
    end

    -- 2. Async Read Original for Sanity Check and Backup
    uv.fs_open(path, "r", 438, function(err, fd)
        if err or not fd then
            -- If file doesn't exist, just create it
            M.write_new_file(path, content, cb)
            return
        end

        uv.fs_fstat(fd, function(err2, stat)
            if err2 or not stat then
                uv.fs_close(fd)
                if cb then cb(false, "Failed to stat file") end
                return
            end

            local old_size = stat.size
            uv.fs_read(fd, old_size, 0, function(err3, old_content)
                uv.fs_close(fd)
                if err3 then
                    if cb then cb(false, "Failed to read original content") end
                    return
                end

                -- 3. Sanity Checks
                -- Size Check
                if #content < (old_size * rules.min_size_pct) then
                    if cb then cb(false, string.format("Sanity Check Failed: New content is too small (%.1f%% of original)", (#content/old_size)*100)) end
                    return
                end

                -- Header Preservation Check
                if rules.preserve_headers then
                    local _, old_headers = old_content:gsub("\n#", "")
                    local _, new_headers = content:gsub("\n#", "")
                    if new_headers < old_headers then
                        if cb then cb(false, "Sanity Check Failed: Headers were lost in the patch.") end
                        return
                    end
                end

                -- 4. Atomic Backup & Write
                local backup_path = path .. ".bak"
                
                local function rollback(err_msg)
                    -- Attempt to restore from .bak
                    uv.fs_open(backup_path, "r", 438, function(rerr, rfd)
                        if not rerr and rfd then
                            uv.fs_fstat(rfd, function(_, rstat)
                                uv.fs_read(rfd, rstat.size, 0, function(_, rcontent)
                                    uv.fs_close(rfd)
                                    uv.fs_open(path, "w", 438, function(_, wfd2)
                                        uv.fs_write(wfd2, rcontent, 0, function()
                                            uv.fs_close(wfd2)
                                            if cb then cb(false, "Write failed, restored from backup: " .. err_msg) end
                                        end)
                                    end)
                                end)
                            end)
                        else
                            if cb then cb(false, "Write failed and backup restore failed: " .. err_msg) end
                        end
                    end)
                end

                uv.fs_open(backup_path, "w", 438, function(err4, bfd)
                    if err4 or not bfd then
                        if cb then cb(false, "Failed to create backup: " .. tostring(err4)) end
                        return
                    end
                    uv.fs_write(bfd, old_content, 0, function(werr)
                        uv.fs_close(bfd)
                        if werr then
                            if cb then cb(false, "Failed to write backup: " .. tostring(werr)) end
                            return
                        end
                        
                        -- Write the new content
                        uv.fs_open(path, "w", 438, function(err5, wfd)
                            if err5 or not wfd then
                                rollback(tostring(err5))
                                return
                            end
                            uv.fs_write(wfd, content, 0, function(werr2)
                                uv.fs_close(wfd)
                                if werr2 then
                                    rollback(tostring(werr2))
                                else
                                    -- Success! Remove backup
                                    uv.fs_unlink(backup_path, function()
                                        if cb then cb(true) end
                                    end)
                                end
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end)
end

---Writes a new file asynchronously.
function M.write_new_file(path, content, cb)
    uv.fs_open(path, "w", 438, function(err, fd)
        if err or not fd then
            if cb then cb(false, "Failed to open " .. path) end
            return
        end
        uv.fs_write(fd, content, 0, function()
            uv.fs_close(fd)
            if cb then cb(true) end
        end)
    end)
end

---Applies a ripple (patch) to a file.
---@param path string
---@param ripple table { filepath = "...", patch_text = "...", target_header = "..." }
---@param cb function? Callback called with (success, err).
function M.apply_ripple_async(path, ripple, cb)
    uv.fs_open(path, "r", 438, function(err, fd)
        if err or not fd then
            if cb then cb(false, "Failed to open file for ripple: " .. path) end
            return
        end

        uv.fs_fstat(fd, function(err2, stat)
            if err2 or not stat then
                uv.fs_close(fd)
                if cb then cb(false, "Failed to stat file") end
                return
            end

            uv.fs_read(fd, stat.size, 0, function(err3, old_content)
                uv.fs_close(fd)
                if err3 then
                    if cb then cb(false, "Failed to read content for ripple") end
                    return
                end

                local header = ripple.target_header or "## Connections"
                local patch = ripple.patch_text or ""
                local new_content = old_content

                -- Header Fallback: if missing, append to bottom
                -- Using plain search since headers might have special chars, but usually just '## Connections'
                -- We look for the exact header at the start of a line
                local header_pattern = "\n" .. vim.pesc(header) .. "%s*\n"
                local header_pos = old_content:find(header_pattern)
                if not header_pos then
                    -- Check if it's the very first line
                    if old_content:find("^" .. vim.pesc(header) .. "%s*\n") then
                        header_pos = 1
                    end
                end

                if not header_pos then
                    -- Append header and patch to the end
                    new_content = new_content .. "\n\n" .. header .. "\n" .. patch .. "\n"
                else
                    -- Insert patch right after the header
                    -- We find the end of the header line
                    local _, end_idx = old_content:find("[^\n]*\n", header_pos)
                    if not end_idx then end_idx = #old_content end
                    
                    local before = new_content:sub(1, end_idx)
                    local after = new_content:sub(end_idx + 1)
                    new_content = before .. patch .. "\n" .. after
                end

                -- Pass to atomic safe writer
                M.patch_file_async(path, new_content, nil, cb)
            end)
        end)
    end)
end

return M
