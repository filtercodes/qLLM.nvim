local OpenAIProvider = require("qllm.providers.openai")
local AnthropicProvider = require("qllm.providers.anthropic")
local OllaMaProvider = require("qllm.providers.ollama")
local GroqProvider = require("qllm.providers.groq")
local GeminiProvider = require("qllm.providers.gemini")
local LocalGroundingProvider = require("qllm.providers.local_grounding")
local KnowledgeBaseProvider = require("qllm.providers.knowledge_base")

local Providers = {}

function Providers.get_provider(overrides)
    local provider_name = (overrides and (overrides.search_provider or overrides.provider))
    local provider
    if provider_name then
        provider = vim.fn.tolower(provider_name)
    else
        provider = vim.fn.tolower(vim.g.qllm_api_provider or "openai")
    end

    if provider == "openai" then
        return OpenAIProvider
    elseif provider == "anthropic" then
        return AnthropicProvider
    elseif provider == "ollama" then
        return OllaMaProvider
    elseif provider == "groq" then
        return GroqProvider
    elseif provider == "gemini" then
        return GeminiProvider
    elseif provider == "local_grounding" then
        return LocalGroundingProvider
    elseif provider == "knowledge_base" or provider == "wiki" then
        return KnowledgeBaseProvider
    else
        error("Provider not found: " .. provider)
    end
end

return Providers
