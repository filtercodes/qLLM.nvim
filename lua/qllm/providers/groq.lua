local curl = require("plenary.curl")
local Render = require("qllm.template_render")
local Utils = require("qllm.utils")
local Api = require("qllm.api")
local History = require("qllm.history")
local Ui = require("qllm.ui")
local Logger = require("qllm.logger")

GroqProvider = {}

GroqProvider.has_streaming = true

function GroqProvider.make_request(command, cmd_opts, command_args, text_selection, bufnr)
    local past_messages = History.get_messages(bufnr)
    local new_user_message_text = Render.render(command, cmd_opts.user_message_template, command_args, text_selection, cmd_opts)
    local system_message_text = Render.render(command, cmd_opts.system_message_template, command_args, text_selection, cmd_opts)
    local messages_for_api = {}
    if system_message_text and system_message_text ~= "" then
        table.insert(messages_for_api, {role="system", content=system_message_text})
    end
    for _, msg in ipairs(past_messages) do
        table.insert(messages_for_api, msg)
    end
    table.insert(messages_for_api, {role="user", content=new_user_message_text})

    local request = {
        temperature = cmd_opts.temperature,
        n = cmd_opts.number_of_choices,
        model = cmd_opts.model,
        messages = messages_for_api,
        max_tokens = cmd_opts.max_tokens,
    }

    return request, new_user_message_text
end

local function curl_callback(response, user_message_text, cb, bufnr)
    local status = response.status
    local body = response.body
    if status ~= 200 then
        body = body:gsub("%s+", " ")
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
        local json = vim.fn.json_decode(msg)
        GroqProvider.handle_response(json, user_message_text, cb, bufnr)
    end)(body)

    Api.run_finished_hook()
end

function GroqProvider.make_headers()
    local token = vim.env["GROQ_API_KEY"]
    if not token then
        error(
            "GroqApi Key not found, set the env variable 'GROQ_API_KEY'"
        )
    end

    return { Content_Type = "application/json", Authorization = "Bearer " .. token }
end

function GroqProvider.handle_response(json, user_message_text, cb, bufnr)
    if json == nil then
        vim.notify("Groq Error: Response empty", vim.log.levels.ERROR)
    elseif json.error then
        Ui.popup(vim.split(vim.inspect(json), "\n"), "lua", bufnr)
    elseif not json.choices or 0 == #json.choices or not json.choices[1].message then
        print("Error: " .. vim.fn.json_encode(json))
    else
        local response_text = json.choices[1].message.content

        if response_text ~= nil then
            if type(response_text) ~= "string" or response_text == "" then
                print("Error: No response text " .. type(response_text))
            else
                -- TRACE: Log the final response
                Logger.log_response("groq", "legacy", response_text)
                History.add_message(bufnr, "user", user_message_text)
                History.add_message(bufnr, "assistant", response_text)

                if vim.g.qllm_clear_visual_selection and vim.api.nvim_buf_is_valid(bufnr) then
                    vim.api.nvim_buf_set_mark(bufnr, "<", 0, 0, {})
                    vim.api.nvim_buf_set_mark(bufnr, ">", 0, 0, {})
                end
                cb(Utils.parse_lines(response_text))
            end
        else
            print("Error: No message")
        end
    end
end

function GroqProvider.make_call(payload, user_message_text, cb, bufnr)
    local url = "https://api.groq.com/openai/v1/chat/completions"
    local headers = GroqProvider.make_headers()
    Api.run_started_hook()

    -- TRACE: Log the outgoing request
    Logger.log_request("groq", payload.command or "chat", payload)

    if type(cb) == "table" then
        -- Streaming Mode
        payload.stream = true
        local payload_str = vim.fn.json_encode(payload)

        local partial_data = ""
        local full_text = ""

        curl.post(url, {
            body = payload_str,
            headers = headers,
            raw = { "--no-buffer" },
            stream = function(err, chunk)
                if err then
                    vim.schedule(function()
                        cb.on_error(err)
                        Api.run_finished_hook()
                    end)
                    return
                end

                if not chunk then 
                    vim.schedule(function()
                        -- TRACE: Log the final response
                        Logger.log_response("groq", payload.command or "chat", full_text)
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

                    -- Check for [DONE]
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
                            return
                        elseif json.choices and json.choices[1] and json.choices[1].delta and json.choices[1].delta.content then
                            local text = json.choices[1].delta.content
                            full_text = full_text .. text
                            cb.on_chunk(text)
                        end
                    end
                end

                partial_data = string.sub(current_buffer, processed_segment_end + 1)
            end,
            on_error = function(err)
                cb.on_error(err.message)
                Api.run_finished_hook()
            end
        })
    else
        -- Legacy Mode
        payload.stream = false
        local payload_str = vim.fn.json_encode(payload)
        curl.post(url, {
            body = payload_str,
            headers = headers,
            callback = function(response)
                curl_callback(response, user_message_text, cb, bufnr)
            end,
            on_error = function(err)
                print('Error:', err.message)
                Api.run_finished_hook()
            end,
        })
    end
end

return GroqProvider
