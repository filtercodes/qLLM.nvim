local Utils = require("qllm.utils")

local Render = {}

local function get_language()
    local filetype = Utils.get_filetype()
    if filetype == "cpp" then
        return "C++"
    else
        return filetype
    end
end

local function normalize_value(val)
    if val == nil then
        return ""
    elseif type(val) == "table" then
        return table.concat(val, "\n")
    else
        return tostring(val)
    end
end

function Render.render(cmd, template, command_args, text_selection, cmd_opts)
    if not template then return "" end

    local language = get_language()
    local language_instructions = ""
    
    if cmd_opts.language_instructions ~= nil then
        -- Try specific language first, fallback to "*" wildcard
        language_instructions = cmd_opts.language_instructions[language] 
            or cmd_opts.language_instructions["*"] 
            or ""
    end

    local final_args = command_args
    if (final_args == nil or final_args == "") and cmd_opts.default_prompt then
        final_args = cmd_opts.default_prompt
    end

    local replacements = {
        filetype = normalize_value(Utils.get_filetype()),
        text_selection = normalize_value(text_selection),
        command_args = normalize_value(final_args),
        language_instructions = normalize_value(language_instructions),
        language = normalize_value(language),
    }

    -- Use a single-pass gsub with a lookup function.
    -- This prevents nested/recursive macro evaluation (infinite mirroring) of user-provided
    -- content like text selections or command arguments. Additionally, since the return value of
    -- the callback function is inserted literally by gsub, escaping '%' signs is no longer required.
    local result = template:gsub("{{([%w_]+)}}", function(key)
        return replacements[key]
    end)

    return result
end

return Render
