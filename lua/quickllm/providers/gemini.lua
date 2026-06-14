local curl = require("plenary.curl")
local Render = require("quickllm.template_render")
local Utils = require("quickllm.utils")
local Api = require("quickllm.api")
local History = require("quickllm.history")
local Ui = require("quickllm.ui")
local Logger = require("quickllm.logger")

GeminiProvider = {}


function GeminiProvider.make_request(command, cmd_opts, command_args, text_selection, bufnr)
    -- Get the history of past messages
    local past_messages = History.get_messages(bufnr)

    -- Render new user message
    local new_user_message_text = Render.render(command, cmd_opts.user_message_template, command_args, text_selection, cmd_opts)

    -- Payload
    local messages_for_api = {}
    local include_history = true
    if cmd_opts.is_search_command and vim.g.quickllm_ground_with_history == false then
        include_history = false
    end

    if include_history then
        for _, msg in ipairs(past_messages) do
            local role = (msg.role == "assistant" and "model" or "user")
            if msg.content and vim.trim(msg.content) ~= "" then
                table.insert(messages_for_api, {
                    role = role,
                    parts = { { text = msg.content } },
                })
            end
        end
    end
    table.insert(messages_for_api, {
        role = "user",
        parts = { { text = new_user_message_text } },
    })

    -- Request object
    local request = {
        contents = messages_for_api,
        model = cmd_opts.model,
    }

    -- 1. Construct generationConfig only if needed
    local gen_config = {}
    local has_config = false

    if cmd_opts.thinking then
        gen_config.thinking_config = {
            include_thoughts = true
        }
        has_config = true
    end

    if cmd_opts.temperature then
        gen_config.temperature = cmd_opts.temperature
        has_config = true
    end

    if cmd_opts.max_tokens then
        gen_config.maxOutputTokens = cmd_opts.max_tokens
        has_config = true
    end

    -- Add extra_params to generationConfig if they match Gemini's spec
    if cmd_opts.extra_params then
        for k, v in pairs(cmd_opts.extra_params) do
            gen_config[k] = v
            has_config = true
        end
    end

    if has_config then
        request.generationConfig = gen_config
    end

    if cmd_opts.is_search_command then
        request.tools = {
            { google_search = vim.empty_dict() }
        }
    end

    return request, new_user_message_text
end

function GeminiProvider.make_headers()
    local api_key = vim.g.quickllm_gemini_api_key or os.getenv("GEMINI_API_KEY")

    if not api_key then
        error(
            "Gemini API Key not found, set in vim with 'quickllm_gemini_api_key' or as the env variable 'GEMINI_API_KEY'"
        )
    end

    return {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = api_key,
    }
end


local function curl_callback(response, user_message_text, cb, bufnr)
    local status = response.status
    local body = response.body
    if status ~= 200 then
        print("Error: " .. status .. " " .. body)
        Api.run_finished_hook()
        return
    end

    if body == nil or body == "" then
        print("Error: No body")
        Api.run_finished_hook()
        return
    end

    vim.schedule_wrap(function(msg)
        local ok, json = pcall(vim.fn.json_decode, msg)
        GeminiProvider.handle_response(json, user_message_text, cb, bufnr)
    end)(body)

    Api.run_finished_hook()
end


function GeminiProvider.handle_response(json, user_message_text, cb, bufnr)
    if json == nil then
        vim.notify("Gemini Error: Response empty", vim.log.levels.ERROR)
    elseif json.error then
        Ui.popup(vim.split(vim.inspect(json), "\n"), "lua", bufnr)
    elseif not json.candidates or not json.candidates[1] then
        print("Response is incomplete. Payload: " .. vim.fn.json_encode(json))
    else
        local candidate = json.candidates[1]
        if candidate.content and candidate.content.parts then
            local response_text = ""

            for _, part in ipairs(candidate.content.parts) do
                local is_thought = (part.thought == true) or (part.thought and type(part.thought) == "string")

                -- Skip thoughts for editor/history
                if not is_thought and part.text and type(part.text) == "string" then
                    response_text = response_text .. part.text
                end
            end

            -- Append search sources
            if candidate.groundingMetadata and candidate.groundingMetadata.groundingChunks then
                 local sources = {}
                 for i, chunk in ipairs(candidate.groundingMetadata.groundingChunks) do
                     if chunk.web and chunk.web.uri then
                         local title = chunk.web.title or "Untitled"
                         table.insert(sources, string.format("[%d] %s - %s", i, title, chunk.web.uri))
                     end
                 end
                 if #sources > 0 then
                     response_text = response_text .. "\n\n**Sources:**\n" .. table.concat(sources, "\n")
                 end
            end

            if response_text ~= "" then
                -- TRACE: Log the final response
                Logger.log_response("gemini", "legacy", response_text)
                History.add_message(bufnr, "user", user_message_text)
                History.add_message(bufnr, "assistant", response_text)

                if vim.g.quickllm_clear_visual_selection and vim.api.nvim_buf_is_valid(bufnr) then
                    vim.api.nvim_buf_set_mark(bufnr, "<", 0, 0, {})
                    vim.api.nvim_buf_set_mark(bufnr, ">", 0, 0, {})
                end
                cb(Utils.parse_lines(response_text))
            else
                print("Error: No completion found in response parts")
            end
        else
            print("Error: No completion")
        end
    end
end

GeminiProvider.has_streaming = true

function GeminiProvider.make_call(payload, user_message_text, cb, bufnr)
    local model_name = payload.model
    if not model_name or model_name == "" then
        print("Error: Gemini provider requires a model to be configured for the command.")
        Api.run_finished_hook()
        return
    end
    payload.model = nil -- remove model from payload
    local payload_str = vim.fn.json_encode(payload)
    
    local headers = GeminiProvider.make_headers()
    Api.run_started_hook()

    -- TRACE: Log the outgoing request
    Logger.log_request("gemini", payload.command or "chat", payload)

    if type(cb) == "table" then
        -- Streaming Mode
        local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model_name .. ":streamGenerateContent?alt=sse"
        
        local partial_data = ""
        local full_text = ""
        local collected_sources = {}

        curl.post(url, {
            body = payload_str,
            headers = headers,
            raw = { "--no-buffer" },
            timeout = 20000, -- 20 seconds timeout
            stream = function(err, chunk)
                if err then
                    vim.schedule(function()
                        vim.notify("Gemini Curl Error: " .. vim.inspect(err), vim.log.levels.ERROR)
                        cb.on_error(err)
                        Api.run_finished_hook()
                    end)
                    return
                end

                if not chunk then 
                    -- End of stream
                    vim.schedule(function()
                        if #collected_sources > 0 and vim.g.quickllm_show_search_sources then
                             local sources_text = "\n\n**Sources:**\n" .. table.concat(collected_sources, "\n")
                             full_text = full_text .. sources_text
                             cb.on_chunk(sources_text, false)
                        end

                        if full_text == "" then
                            vim.notify("Gemini returned empty text", vim.log.levels.WARN)
                        end
                        -- TRACE: Log the final response
                        Logger.log_response("gemini", payload.command or "chat", full_text)
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

                    -- Check for [DONE] which doesn't need JSON decoding
                    if string.sub(current_buffer, json_start_idx, json_start_idx + 5) == "[DONE]" then
                        processed_segment_end = json_start_idx + 6
                        break
                    end

                    local ok, json, next_idx = Utils.decode_json_stream(current_buffer, json_start_idx)
                    if not ok then break end -- Wait for more data

                    processed_segment_end = next_idx

                    if json then
                        if json.error then
                            vim.schedule(function()
                                -- DELEGATION: All UI error rendering is now handled by the orchestration layer (commands.lua).
                                cb.on_error(json.error)
                                Api.run_finished_hook()
                            end)
                            break
                        end

                        if json.candidates and json.candidates[1] then
                            local candidate = json.candidates[1]
                            if candidate.content and candidate.content.parts then
                                -- LINEAR PROCESSING: Emit each part immediately in order
                                for _, part in ipairs(candidate.content.parts) do
                                    local is_thought = (part.thought == true) or (part.thought and type(part.thought) == "string")
                                    local text = ""

                                    if is_thought then
                                        text = (type(part.thought) == "string" and part.thought) or part.text or ""
                                    else
                                        text = part.text or ""
                                        -- Only add regular text to history
                                        full_text = full_text .. text
                                    end

                                    if text ~= "" then
                                        cb.on_chunk(text, is_thought)
                                    end
                                end
                            end

                            -- Collect grounding sources
                            if candidate.groundingMetadata and candidate.groundingMetadata.groundingChunks then
                                for i, chunk in ipairs(candidate.groundingMetadata.groundingChunks) do
                                    if chunk.web and chunk.web.uri then
                                        local title = chunk.web.title or "Untitled"
                                        table.insert(collected_sources, string.format("[%d] %s - %s", i, title, chunk.web.uri))
                                    end
                                end
                            end
                        end
                    end

                    -- Skip trailing newlines
                    local next_char_idx = processed_segment_end + 1
                    while next_char_idx <= #current_buffer and string.sub(current_buffer, next_char_idx, next_char_idx) == "\n" do
                        processed_segment_end = next_char_idx
                        next_char_idx = next_char_idx + 1
                    end
                end

                partial_data = string.sub(current_buffer, processed_segment_end + 1)
            end,
            on_error = function(err)
                print('Curl error:', err.message)
                cb.on_error(err.message)
                Api.run_finished_hook()
            end,
        })

    else
        -- Legacy / Blocking Mode
        local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model_name .. ":generateContent"
        curl.post(url, {
            body = payload_str,
            headers = headers,
            callback = function(response)
                curl_callback(response, user_message_text, cb, bufnr)
            end,
            on_error = function(err)
                print('Curl error:', err.message)
                Api.run_finished_hook()
            end,
        })
    end
end

return GeminiProvider
