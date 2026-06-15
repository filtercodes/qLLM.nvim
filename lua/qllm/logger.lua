local M = {}

-- In-memory cache for the last request to enable combined debugging popups
local last_request = nil

---Gets the path to the log file.
function M.get_log_path()
    local path = vim.fn.stdpath("state")
    if not path or path == "" then
        path = vim.fn.stdpath("cache")
    end
    return path .. "/qllm.log"
end

---Writes a message to the log file with a timestamp.
local function write_to_file(message)
    local log_path = M.get_log_path()
    local f = io.open(log_path, "a")
    if f then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        f:write(string.format("[%s] %s\n", timestamp, message))
        f:close()
    end
end

---Logs the request payload sent to a provider.
---@param provider string The provider name.
---@param command string The command being executed.
---@param payload table|string The raw payload.
function M.log_request(provider, command, payload)
    local log_enabled = vim.g.qllm_log_enabled == true
    local debug_enabled = vim.g.qllm_debug == true

    if not log_enabled and not debug_enabled then return end

    local payload_str = payload
    if type(payload) == "table" then
        payload_str = vim.fn.json_encode(payload)
    end

    -- Store for the combined debug popup
    if debug_enabled then
        last_request = {
            provider = provider,
            command = command,
            payload = payload_str
        }
    end

    if log_enabled then
        write_to_file(string.format("[REQUEST] [%s] [%s]: %s", 
            string.upper(provider), 
            string.upper(command), 
            payload_str))
    end
end

---Logs the final response and triggers the debug popup if enabled.
---@param provider string The provider name.
---@param command string The command name.
---@param response string The full response text.
function M.log_response(provider, command, response)
    local log_enabled = vim.g.qllm_log_enabled == true
    local debug_enabled = vim.g.qllm_debug == true

    if not log_enabled and not debug_enabled then return end

    if log_enabled then
        write_to_file(string.format("[RESPONSE] [%s] [%s]: %s", 
            string.upper(provider), 
            string.upper(command), 
            response))
    end

    -- If qllm_debug is enabled, open a combined popup
    -- showing exactly what went out and what came back.
    if debug_enabled then
        vim.schedule(function()
            local Ui = require("qllm.ui")
            local lines = {
                "# DEBUG TRACE",
                "",
                "## REQUEST [" .. string.upper(provider) .. "] [" .. string.upper(command) .. "]",
                "```json",
            }
            
            -- Add request payload (handle table or string)
            local req_str = (last_request and last_request.payload) or "No request data cached."
            for _, line in ipairs(vim.split(req_str, "\n")) do
                table.insert(lines, line)
            end
            
            table.insert(lines, "```")
            table.insert(lines, "")
            table.insert(lines, "## RESPONSE")
            table.insert(lines, "```markdown")
            
            for _, line in ipairs(vim.split(response, "\n")) do
                table.insert(lines, line)
            end
            
            table.insert(lines, "```")
            
            -- Show the combined popup
            Ui.popup(lines, "markdown")
            
            -- One-shot reset
            vim.g.qllm_debug = false
            last_request = nil
        end)
    end
end

return M
