-- claude_support.lua
-- Contains the configuration mapping and model detection logic for Anthropic's Claude models.

local M = {}

-- Rules are checked sequentially from top to bottom; the first matching rule is applied.
local rules = {
    -- Claude Fable 5
    {
        pattern = "fable.*5",
        spec = {
            thinking_type = "adaptive",
            supports_effort = true,
            default_effort = "high",
            allow_sampling = false,
            display_thinking = "summarized",
            always_on_thinking = true,
        }
    },
    -- Claude Mythos 5
    {
        pattern = "mythos.*5",
        spec = {
            thinking_type = "adaptive",
            supports_effort = true,
            default_effort = "high",
            allow_sampling = false,
            display_thinking = "summarized",
            always_on_thinking = true,
        }
    },
    -- Claude Opus 4.8
    {
        pattern = "opus.*4.*8",
        spec = {
            thinking_type = "adaptive",
            supports_effort = true,
            default_effort = "xhigh",
            allow_sampling = false,
            display_thinking = "summarized",
        }
    },
    -- Claude Opus 4.7
    {
        pattern = "opus.*4.*7",
        spec = {
            thinking_type = "adaptive",
            supports_effort = true,
            default_effort = "xhigh",
            allow_sampling = false,
            display_thinking = "summarized",
        }
    },
    -- Claude Opus 4.6
    {
        pattern = "opus.*4.*6",
        spec = {
            thinking_type = "manual",
            supports_effort = false,
            allow_sampling = true,
            display_thinking = nil,
        }
    },
    -- Claude Opus 4.5
    {
        pattern = "opus.*4.*5",
        spec = {
            thinking_type = "none",
            supports_effort = false,
            allow_sampling = true,
            display_thinking = nil,
        }
    },
    -- Claude Sonnet 5
    {
        pattern = "sonnet.*5",
        spec = {
            thinking_type = "adaptive",
            supports_effort = true,
            default_effort = "xhigh",
            allow_sampling = false,
            display_thinking = "summarized",
            disable_thinking_if_inactive = true,
        }
    },
    -- Claude Sonnet 4.6
    {
        pattern = "sonnet.*4.*6",
        spec = {
            thinking_type = "manual",
            supports_effort = false,
            allow_sampling = true,
            display_thinking = nil,
        }
    },
    -- Claude Sonnet fallback
    {
        pattern = "sonnet",
        spec = {
            thinking_type = "manual",
            supports_effort = false,
            allow_sampling = true,
            display_thinking = nil,
        }
    },
    -- Claude Haiku 4.5
    {
        pattern = "haiku.*4.*5",
        spec = {
            thinking_type = "manual",
            supports_effort = false,
            allow_sampling = true,
            display_thinking = nil,
        }
    },
    -- Fallback for older or unrecognized models (e.g. Haiku 3.5, etc.)
    {
        pattern = ".*",
        spec = {
            thinking_type = "none",
            supports_effort = false,
            allow_sampling = true,
            display_thinking = nil,
        }
    }
}

--- Resolves a model name to its capabilities specification table.
--- @param model_name string|nil The name/ID of the Claude model.
--- @return table The specifications table containing capabilities configurations.
function M.get_spec(model_name)
    if not model_name then
        return rules[#rules].spec
    end
    
    -- Normalize the model name to lowercase for consistent pattern matching
    local lower_name = string.lower(model_name)
    for _, rule in ipairs(rules) do
        if string.find(lower_name, rule.pattern) then
            return rule.spec
        end
    end
    return rules[#rules].spec
end

return M
