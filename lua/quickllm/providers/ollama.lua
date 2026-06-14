local curl = require("plenary.curl")
local Render = require("quickllm.template_render")
local Utils = require("quickllm.utils")
local Api = require("quickllm.api")
local History = require("quickllm.history")
local Ui = require("quickllm.ui")
local Logger = require("quickllm.logger")

OllaMaProvider = {}


---Creates a stateful parser for the Ollama stream to handle tags like <think>.
---@return table parser An object with a :feed(content) method.
local function create_stream_parser()
    return {
        is_thinking = false,
        tag_buffer = "",

        ---Processes a chunk of text and returns detected segments.
        ---@param self table The parser instance.
        ---@param content string The new chunk of text from the API.
        ---@return table segments A list of {text, is_thinking} tables.
        feed = function(self, content)
            self.tag_buffer = self.tag_buffer .. content
            local segments = {}

            -- Loop until the buffer is exhausted or we hit a partial tag at the end
            while self.tag_buffer ~= "" do
                if not self.is_thinking then
                    local start_idx = self.tag_buffer:find("<think>")
                    if start_idx then
                        -- Text before the tag is regular answer
                        local before = self.tag_buffer:sub(1, start_idx - 1)
                        if before ~= "" then
                            table.insert(segments, { text = before, is_thinking = false })
                        end
                        self.is_thinking = true
                        self.tag_buffer = self.tag_buffer:sub(start_idx + 7)
                    else
                        -- No start tag found. Check for a partial tag at the end (e.g. "<thi")
                        local partial_match = false
                        local tag = "<think>"
                        for len = #tag - 1, 1, -1 do
                            if self.tag_buffer:sub(-len) == tag:sub(1, len) then
                                local flush_len = #self.tag_buffer - len
                                if flush_len > 0 then
                                    local to_flush = self.tag_buffer:sub(1, flush_len)
                                    table.insert(segments, { text = to_flush, is_thinking = false })
                                    self.tag_buffer = self.tag_buffer:sub(flush_len + 1)
                                end
                                partial_match = true
                                break
                            end
                        end

                        if not partial_match then
                            table.insert(segments, { text = self.tag_buffer, is_thinking = false })
                            self.tag_buffer = ""
                        else
                            break -- Wait for more data to complete the tag
                        end
                    end
                else
                    -- Currently in a thinking block, look for </think>
                    local end_idx = self.tag_buffer:find("</think>")
                    if end_idx then
                        -- Text before the tag is thought
                        local thought = self.tag_buffer:sub(1, end_idx - 1)
                        if thought ~= "" then
                            table.insert(segments, { text = thought, is_thinking = true })
                        end
                        self.is_thinking = false
                        self.tag_buffer = self.tag_buffer:sub(end_idx + 8)
                    else
                        -- Look for partial end tag at the end (e.g. "</thi")
                        local partial_match = false
                        local tag = "</think>"
                        for len = #tag - 1, 1, -1 do
                            if self.tag_buffer:sub(-len) == tag:sub(1, len) then
                                local flush_len = #self.tag_buffer - len
                                if flush_len > 0 then
                                    local to_flush = self.tag_buffer:sub(1, flush_len)
                                    table.insert(segments, { text = to_flush, is_thinking = true })
                                    self.tag_buffer = self.tag_buffer:sub(flush_len + 1)
                                end
                                partial_match = true
                                break
                            end
                        end

                        if not partial_match then
                            table.insert(segments, { text = self.tag_buffer, is_thinking = true })
                            self.tag_buffer = ""
                        else
                            break -- Wait for more data
                        end
                    end
                end
            end
            return segments
        end
    }
end


function OllaMaProvider.make_request(command, cmd_opts, command_args, text_selection, bufnr)
    -- Get the history of past messages
    local past_messages = History.get_messages(bufnr)

    -- Render the new user message
    local new_user_message_text = Render.render(command, cmd_opts.user_message_template, command_args, text_selection, cmd_opts)

    -- Render the system message
    local system_message_text = Render.render(command, cmd_opts.system_message_template, command_args, text_selection, cmd_opts)

    -- Construct the payload for the request
    local messages_for_api = {}
    if system_message_text and system_message_text ~= "" then
        table.insert(messages_for_api, {role="system", content=system_message_text})
    end
    for _, msg in ipairs(past_messages) do
        table.insert(messages_for_api, msg)
    end
    table.insert(messages_for_api, {role="user", content=new_user_message_text})

    -- Request object
    local request = {
        model = cmd_opts.model,
        messages = messages_for_api,
        stream = false,
        think = cmd_opts.thinking,
    }

    if cmd_opts.temperature then
        request.temperature = cmd_opts.temperature
    end

    return request, new_user_message_text
end

function OllaMaProvider.make_headers()
    return { ["Content-Type"] = "application/json" }
end

function OllaMaProvider.handle_response(json, user_message_text, cb, bufnr)
    if json == nil then
        vim.notify("Ollama Error: Response empty", vim.log.levels.ERROR)
    elseif json.error then
        Ui.popup(vim.split(vim.inspect(json), "\n"), "lua", bufnr)
    elseif json.done == nil or json.done == false then
        print("Response is incomplete " .. vim.fn.json_encode(json))
    elseif json.message == nil or json.message.content == nil then
        print("Error: No response content. Full response: " .. vim.fn.json_encode(json))
    else
        local response_text = json.message.content

        if response_text ~= nil then
            if type(response_text) ~= "string" or response_text == "" then
                print("Error: No response text " .. type(response_text))
            else
                -- Bulletproof non-streaming: strip thinking tags from final response
                response_text = Utils.strip_thinking_tags(response_text)

                -- TRACE: Log the final response
                Logger.log_response("ollama", "legacy", response_text)
                -- Add both user and assistant messages to history at the same time
                History.add_message(bufnr, "user", user_message_text)
                History.add_message(bufnr, "assistant", response_text)

                if vim.g.quickllm_clear_visual_selection and vim.api.nvim_buf_is_valid(bufnr) then
                    vim.api.nvim_buf_set_mark(bufnr, "<", 0, 0, {})
                    vim.api.nvim_buf_set_mark(bufnr, ">", 0, 0, {})
                end
                cb(Utils.parse_lines(response_text))
            end
        else
            print("Error: No text")
        end
    end
end

local function curl_callback(response, user_message_text, cb, bufnr)
    local status = response.status
    local body = response.body
    if status ~= 200 then
        body = body:gsub("%s+", " ")
        print("Error: " .. status .. " " .. body)
        return
    end

    if body == nil or body == "" then
        print("Error: No body")
        return
    end

    vim.schedule_wrap(function(msg)
        local json = vim.fn.json_decode(msg)
        OllaMaProvider.handle_response(json, user_message_text, cb, bufnr)
    end)(body)

    Api.run_finished_hook()
end

OllaMaProvider.has_streaming = true

function OllaMaProvider.make_call(payload, user_message_text, cb, bufnr)
    local url = vim.g.quickllm_ollama_url or "http://127.0.0.1:11434/api/chat"
    local headers = OllaMaProvider.make_headers()
    Api.run_started_hook()

    -- TRACE: Log the outgoing request
    Logger.log_request("ollama", payload.command or "chat", payload)

    if type(cb) == "table" then
        -- Streaming Mode
        payload.stream = true
        local payload_str = vim.fn.json_encode(payload)
        
        local partial_data = ""
        local full_text = ""
        local parser = create_stream_parser()

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
                     -- End of stream: Flush any remaining tag buffer as text
                     vim.schedule(function()
                        if parser.tag_buffer ~= "" then
                            cb.on_chunk(parser.tag_buffer, parser.is_thinking)
                        end
                        -- TRACE: Log the final response
                        Logger.log_response("ollama", payload.command or "chat", full_text)
                        cb.on_complete(full_text)
                        Api.run_finished_hook()
                    end)
                    return 
                end

                -- Process synchronously (off-main-thread)
                partial_data = partial_data .. chunk
                
                local current_buffer = partial_data
                local processed_segment_end = 0

                while true do
                    local ok, json, next_idx = Utils.decode_json_stream(current_buffer, processed_segment_end + 1)
                    if not ok then break end -- Wait for more data

                    processed_segment_end = next_idx

                    if json then
                        -- Handle Ollama API errors in the stream
                        if json.error then
                            vim.schedule(function()
                                -- DELEGATION: All UI error rendering is now handled by the orchestration layer (commands.lua).
                                cb.on_error(json.error)
                                Api.run_finished_hook()
                            end)
                            return
                        end

                        if json.message then
                            -- Handle dedicated thinking fields (used by models like Qwen)
                            local thinking = json.message.thinking or json.message.reasoning_content
                            if thinking and thinking ~= "" then
                                cb.on_chunk(thinking, true)
                            end

                            local content = json.message.content
                            if content and content ~= "" then
                                -- Feed the stream parser and iterate over results
                                local segments = parser:feed(content)
                                for _, segment in ipairs(segments) do
                                    if not segment.is_thinking then
                                        full_text = full_text .. segment.text
                                    end
                                    cb.on_chunk(segment.text, segment.is_thinking)
                                end
                            end
                        end
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
        payload.stream = false
        local payload_str = vim.fn.json_encode(payload)
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

return OllaMaProvider
