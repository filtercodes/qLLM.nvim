local curl = require("plenary.curl")
local Render = require("qllm.template_render")
local Utils = require("qllm.utils")
local Api = require("qllm.api")
local Queue = require("qllm.queue")
local Ui = require("qllm.ui")
local Logger = require("qllm.logger")

AnthropicProvider = {}

AnthropicProvider.has_streaming = true

function AnthropicProvider.make_request(command, cmd_opts, command_args, text_selection, bufnr)
    local past_messages = Queue.get_messages(bufnr)
    local new_user_message_text = Render.render(command, cmd_opts.user_message_template, command_args, text_selection, cmd_opts)
    local system_message = Render.render(command, cmd_opts.system_message_template, command_args, text_selection,
        cmd_opts)

    local messages_for_api = {}
    local include_queue = true
    if cmd_opts.is_search_command and vim.g.qllm_ground_include_queue == false then
        include_queue = false
    end

    if include_queue then
        for _, msg in ipairs(past_messages) do
            table.insert(messages_for_api, msg)
        end
    end
    table.insert(messages_for_api, {role="user", content=new_user_message_text})

    local model = cmd_opts.model
    local output_tokens = cmd_opts.output_tokens or 4096

    -- Default request
    local request = {
        model = model,
        max_tokens = output_tokens,
        system = system_message,
        messages = messages_for_api,
        stream = true,
        temperature = cmd_opts.temperature or 1.0,
    }

    -- Capability detection based on model ID
    local is_sonnet = model:find("sonnet") ~= nil
    local is_search = cmd_opts.is_search_command
    -- Use the unified thinking flag
    local should_think = cmd_opts.thinking

    if is_search or should_think then
        -- Default Search version if applicable
        if is_search then
            request.tools = {
                { type = "web_search_20250305", name = "web_search", max_uses = 5 }
            }
        end

        -- Enable thinking for Sonnet if requested or searching
        if is_sonnet then
            local budget = math.floor((tonumber(output_tokens) or 4096) * 0.5)
            if budget < 1024 then budget = 1024 end
            -- Ensure max_tokens is higher than budget
            if tonumber(output_tokens) < budget + 512 then
                request.max_tokens = budget + 512
            end
            request.thinking = { type = "enabled", budget_tokens = budget }
            request.temperature = 1.0
        end
    end

    return request, new_user_message_text
end

function AnthropicProvider.make_headers(payload)
    local api_key = vim.g.qllm_anthropic_api_key or os.getenv("ANTHROPIC_API_KEY")

    if not api_key then
        error("Anthropic API Key not found.")
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = api_key,
        ["anthropic-version"] = "2023-06-01",
    }

    -- Consolidate beta headers
    local betas = {}
    if payload.tools then
        for _, t in ipairs(payload.tools) do
            if t.type == "web_search_20260209" then
                table.insert(betas, "code-execution-web-tools-2026-02-09")
                break
            elseif t.type == "web_search_20250305" then
                table.insert(betas, "web-search-2025-03-05")
                break
            end
        end
    end

    if #betas > 0 then
        headers["anthropic-beta"] = table.concat(betas, ",")
    end

    return headers
end


function AnthropicProvider.make_call(payload, user_message_text, cb, bufnr)
    local url = "https://api.anthropic.com/v1/messages"
    local headers = AnthropicProvider.make_headers(payload)

    Api.run_started_hook()

    -- TRACE: Log the outgoing request
    Logger.log_request("anthropic", payload.command or "query", payload)

    if type(cb) == "table" then
        local payload_str = vim.fn.json_encode(payload)
        local partial_data = ""
        local full_text = ""
        local collected_sources = {}
        local Ui = require("qllm.ui")

        curl.post(url, {
            body = payload_str,
            headers = headers,
            raw = { "--no-buffer" },
            timeout = 30000,
            stream = function(err, chunk)
                if err then
                    vim.schedule(function()
                        vim.notify("Anthropic Curl Error: " .. vim.inspect(err), vim.log.levels.ERROR)
                        cb.on_error(tostring(err))
                        Api.run_finished_hook()
                    end)
                    return
                end
                
                if not chunk then
                    vim.schedule(function()
                        if #collected_sources > 0 and vim.g.qllm_show_search_sources then
                            local sources_text = "\n\n**Sources:**\n" .. table.concat(collected_sources, "\n")
                            full_text = full_text .. sources_text
                            cb.on_chunk(sources_text, false)
                        end

                        if Utils.handle_stream_end(partial_data, full_text, cb, "anthropic") then
                            Api.run_finished_hook()
                            return
                        end

                        -- TRACE: Log the final response
                        Logger.log_response("anthropic", payload.command or "query", full_text)
                        cb.on_complete(full_text)
                        Api.run_finished_hook()
                    end)
                    return 
                end

                partial_data = partial_data .. chunk
                local current_buffer = partial_data
                local processed_segment_end = 0

                while true do
                    local data_start_idx = string.find(current_buffer, "data: ", processed_segment_end + 1, true)
                    if not data_start_idx then break end

                    local json_start_idx = data_start_idx + string.len("data: ")

                    local ok, json, next_idx = Utils.decode_json_stream(current_buffer, json_start_idx)

                    if not ok then
                        -- Check if it's a [DONE] message or something without JSON
                        local end_line = string.find(current_buffer, "\n", json_start_idx, true)
                        if end_line then
                            local maybe_str = vim.trim(string.sub(current_buffer, json_start_idx, end_line - 1))
                            if maybe_str == "" or maybe_str == "[DONE]" then
                                processed_segment_end = end_line
                            else
                                break -- It's not empty, not done, and not JSON. Wait for more.
                            end
                        else
                            break -- No newline, wait for more data.
                        end
                    else
                        processed_segment_end = next_idx

                        if json then
                            if json.type == "error" then
                                vim.schedule(function()
                                    -- DELEGATION: All UI error rendering is now handled by the orchestration layer (commands.lua).
                                    cb.on_error(json.error)
                                    Api.run_finished_hook()
                                end)
                                return
                            elseif json.type == "content_block_start" then
                                local block = json.content_block
                                if block and block.type == "web_search_tool_result" and block.content then
                                    for _, result in ipairs(block.content) do
                                        if result.type == "web_search_result" and result.url then
                                            local title = result.title or "Untitled"
                                            table.insert(collected_sources, string.format("- [%s](%s)", title, result.url))
                                        end
                                    end
                                end
                            elseif json.type == "content_block_delta" and json.delta then
                                if json.delta.text then
                                    full_text = full_text .. json.delta.text
                                    cb.on_chunk(json.delta.text, false)
                                elseif json.delta.type == "text_delta" and json.delta.text then
                                    full_text = full_text .. json.delta.text
                                    cb.on_chunk(json.delta.text, false)
                                elseif json.delta.type == "thinking_delta" and json.delta.thinking then
                                    -- Thinking is NOT added to full_text (clean queue)
                                    cb.on_chunk(json.delta.thinking, true)
                                end
                            end
                        end
                    end

                    -- Move past trailing newlines and 'event: ...' lines
                    local next_newline = string.find(current_buffer, "\n", processed_segment_end + 1, true)
                    while next_newline do
                        local next_data = string.find(current_buffer, "data: ", processed_segment_end + 1, true)
                        if next_data and next_newline > next_data then break end
                        processed_segment_end = next_newline
                        next_newline = string.find(current_buffer, "\n", processed_segment_end + 1, true)
                    end
                end

                partial_data = string.sub(current_buffer, processed_segment_end + 1)
            end,
            on_error = function(err)
                cb.on_error(tostring(err.message or err))
                Api.run_finished_hook()
            end
        })
    else
        -- Legacy blocking mode
        payload.stream = false
        curl.post(url, {
            body = vim.fn.json_encode(payload),
            headers = headers,
            callback = function(res)
                vim.schedule(function()
                    if res.status ~= 200 then
                        print("Error: " .. res.status .. " " .. res.body)
                    else
                        local ok, json = pcall(vim.fn.json_decode, res.body)
                        if ok and json and json.content then
                            local txt = ""
                            for _, b in ipairs(json.content) do if b.text then txt = txt .. b.text end end
                            -- TRACE: Log the final response
                            Logger.log_response("anthropic", "legacy", txt)
                            Queue.add_message(bufnr, "user", user_message_text)
                            Queue.add_message(bufnr, "assistant", txt)
                            cb(Utils.parse_lines(txt))
                        end
                    end
                    Api.run_finished_hook()
                end)
            end
        })
    end
end

return AnthropicProvider
