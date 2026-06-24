local curl = require("plenary.curl")
local Render = require("qllm.template_render")
local Utils = require("qllm.utils")
local Api = require("qllm.api")
local History = require("qllm.history")

local LocalGroundingProvider = {}

LocalGroundingProvider.has_streaming = true

function LocalGroundingProvider.make_request(command, cmd_opts, command_args, text_selection, bufnr)
    -- We just need the rendered user message.
    -- The actual payload construction for Ollama will happen in make_call after Tavily returns.
    local new_user_message_text = Render.render(command, cmd_opts.user_message_template, command_args, text_selection, cmd_opts)

    local thinking = false

    local request = {
        temperature = cmd_opts.temperature,
        model = cmd_opts.model,
        stream = false,
        think = thinking,
    }

    return request, new_user_message_text
end

local function call_tavily(query, cb)
    local api_key = vim.g.qllm_tavily_api_key or os.getenv("TAVILY_API_KEY")
    if not api_key then
        error("Tavily API Key not found. Set 'qllm_tavily_api_key' or TAVILY_API_KEY environment variable.")
    end

    local url = "https://api.tavily.com/search"
    local payload = {
        query = query,
        search_depth = "basic",
        max_results = 5,
    }

    curl.post(url, {
        body = vim.fn.json_encode(payload),
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
        },
        callback = function(response)
            vim.schedule(function()
                if response.status ~= 200 then
                    local body_str = response.body
                    if type(body_str) == "table" then
                        body_str = table.concat(body_str, "")
                    end
                    cb(nil, "Tavily Error: " .. response.status .. " " .. (body_str or ""))
                    return
                end

                local body = response.body
                if type(body) == "table" then
                    body = table.concat(body, "")
                end

                local ok, json = pcall(vim.json.decode, body)
                if not ok then
                    ok, json = pcall(vim.fn.json_decode, body)
                end

                if not ok or not json then
                    cb(nil, "Error decoding Tavily response: " .. tostring(json))
                    return
                end
                cb(json)
            end)
        end,
        on_error = function(err)
            vim.schedule(function()
                cb(nil, "Tavily Curl Error: " .. tostring(err))
            end)
        end,
    })
end

function LocalGroundingProvider.make_call(payload, user_message_text, cb, bufnr, overrides)
    local Providers = require("qllm.providers")
    local provider_instance = Providers.get_provider({ provider = payload.provider or "ollama" })
    
    -- Call Tavily
    call_tavily(user_message_text, function(tavily_json, err)
        if err then
            if type(cb) == "table" then
                cb.on_error(err)
            else
                print(err)
            end
            return
        end

        -- Process Tavily Results
        local sources = {}
        local context_text = "SEARCH RESULTS:\n"
        for _, result in ipairs(tavily_json.results or {}) do
            context_text = context_text .. "- " .. result.content .. "\n"
            table.insert(sources, string.format("- %s (%s)", result.title, result.url))
        end

        if overrides then
            if not overrides.history_metadata then
                overrides.history_metadata = {}
            end
            overrides.history_metadata.search_results = context_text
        end

        -- Construct LLM Prompt
        local past_messages = History.get_messages(bufnr)
        local messages = {}
        
        if vim.g.qllm_ground_with_history ~= false then
            for _, msg in ipairs(past_messages) do
                table.insert(messages, msg)
            end
        end

        local final_user_content = context_text .. "\nUsing the search results above, answer the following question. If the search results are insufficient to fully answer the question, you must first state that the search results were insufficient, and then answer from your general knowledge.\n\nQuestion:\n" .. user_message_text

        table.insert(messages, {role = "user", content = final_user_content})

        local llm_payload = vim.deepcopy(payload)
        llm_payload.messages = messages

        -- Call LLM through the resolved provider (e.g. OpenAI, Gemini, etc.)
        if type(cb) == "table" then
            -- Streaming Mode: Wrap callbacks to append sources
            local wrapped_cb = {
                on_chunk = cb.on_chunk,
                on_error = cb.on_error,
                on_complete = function(full_text)
                    if #sources > 0 and vim.g.qllm_show_search_sources then
                        local sources_text = "\n\n**Sources:**\n" .. table.concat(sources, "\n")
                        cb.on_chunk(sources_text)
                    end
                    cb.on_complete(full_text)
                end
            }
            provider_instance.make_call(llm_payload, user_message_text, wrapped_cb, bufnr)
        else
            -- Non-Streaming Mode: Wrap callback to append sources
            provider_instance.make_call(llm_payload, user_message_text, function(lines)
                local response_text = table.concat(lines, "\n")
                if #sources > 0 and vim.g.qllm_show_search_sources then
                    response_text = response_text .. "\n\n**Sources:**\n" .. table.concat(sources, "\n")
                end
                cb(Utils.parse_lines(response_text))
            end, bufnr)
        end
    end)
end

return LocalGroundingProvider
