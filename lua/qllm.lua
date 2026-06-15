local Commands = require("qllm.commands")
local CommandsList = require("qllm.commands_list")
local Utils = require("qllm.utils")
local Ui = require("qllm.ui")
local History = require("qllm.history")
local qllmModule = {}

local function has_command_args(opts)
    local pattern = "%{%{command_args%}%}"
    return string.find(opts.user_message_template or "", pattern)
        or string.find(opts.system_message_template or "", pattern)
end

function qllmModule.get_status(...)
    return Commands.get_status(...)
end

function qllmModule.run_cmd(opts)
    local text_selection = Utils.get_selected_lines()
    local command_args = table.concat(opts.fargs, " ")
    local command = opts.fargs[1]
    local bufnr = nil
    local is_ui_window = false

    -- Determine Context and which buffer is History Owner
    local current_bufnr = vim.api.nvim_get_current_buf()
    local owner_bufnr = Ui.get_owner_bufnr(current_bufnr)

    if owner_bufnr then
        is_ui_window = true
        bufnr = owner_bufnr -- History is always the owner's
    else
        bufnr = current_bufnr -- History is the current buffer's
    end

    -- Handle `clear` as a special case that doesn't need validation
    -- 1. HANDLE UTILITY COMMANDS (Early Return)
    if command == "clear" and #opts.fargs == 1 then
        History.clear_history(bufnr)
        vim.b[bufnr].qllm_metadata = nil
        Ui.close_active_popup(current_bufnr)
        vim.notify("Chat history cleared for this buffer.", vim.log.levels.INFO, { title = "qLLM" })
        return -- Stop all further processing
    end

    local is_recall = command and command:find("^recall") ~= nil
    local show_question = command and command:find("q$") ~= nil
    local is_recall_action = false
    local recall_offset = 1
    
    if is_recall then
        if #opts.fargs == 1 then
            is_recall_action = true
            recall_offset = 1
        elseif #opts.fargs == 2 then
            local arg = opts.fargs[2]
            local num = tonumber(arg)
            if num and num > 0 and math.floor(num) == num then
                is_recall_action = true
                recall_offset = num
            elseif arg == "backward" then
                is_recall_action = true
                recall_offset = (vim.b[bufnr].qllm_recall_index or 0) + 1
            elseif arg == "forward" then
                is_recall_action = true
                recall_offset = math.max(1, (vim.b[bufnr].qllm_recall_index or 1) - 1)
            end
        end
    end

    if is_recall_action then
        local last_response, model, cmd, cursor_pos, question = History.get_last_response(bufnr, recall_offset)
        local display_text = show_question and question or last_response

        if display_text then
            if not show_question then
                -- Only store index and metadata if we are showing the answer (Pro features)
                vim.b[bufnr].qllm_recall_index = recall_offset
                vim.b[bufnr].qllm_metadata = { model = model, command = cmd }
            else
                -- If showing question, ensure we don't save cursor on close
                vim.b[bufnr].qllm_recall_index = nil
            end
            
            local start_row, start_col, end_row, end_col = Utils.get_visual_selection()
            Ui.popup(Utils.parse_lines(display_text), vim.g.qllm_text_popup_filetype, bufnr, start_row, start_col, end_row, end_col, (not show_question and cursor_pos or nil))
        else
            local msg = show_question and "question" or "assistant response"
            vim.notify(string.format("No %s found at history index %d for this buffer.", msg, recall_offset), vim.log.levels.WARN, { title = "qLLM" })
        end
        return
    end

    local is_undo = command == "undo"
    if is_undo and #opts.fargs == 1 then
        local success = History.undo_last_exchange(bufnr)
        if success then
            vim.notify("Last conversation exchange removed from history.", vim.log.levels.INFO, { title = "qLLM" })
        else
            vim.notify("No history to undo.", vim.log.levels.WARN, { title = "qLLM" })
        end
        return
    end

    -- Handle `help` as a special case
    if command == "help" and #opts.fargs == 1 then
        local Help = require("qllm.help")
        Help.show_help(bufnr)
        return
    end

    -- Handle `wiki_index` as a special case
    if command == "wiki_index" then
        local KB = require("qllm.providers.knowledge_base")
        KB.wiki_index()
        return
    end

    -- Handle `wiki_lint` as a special case
    if command == "wiki_lint" then
        local KB = require("qllm.providers.knowledge_base")
        KB.wiki_lint()
        return
    end

    -- Handle `wiki_save` as a special case
    if command == "wiki_save" then
        local KB = require("qllm.providers.knowledge_base")
        local filename = opts.fargs[2]
        if not filename then
            vim.notify("Usage: :Chat wiki_save <filename.md>", vim.log.levels.ERROR)
            return
        end
        KB.wiki_save(filename, text_selection)
        return
    end

    -- Handle `init` as a special case
    if command == "init" then
        local ProjectContext = require("qllm.project_context")
        ProjectContext.init_project()
        return
    end

    -- 2. RESOLVE PROVIDER & PRESETS
    local overrides = nil
    -- Command-to-Provider Mapping
    local provider_map = {
        Gemini = "gemini",
        Claude = "anthropic",
        Openai = "openai",
        Ollama = "ollama",
        Groq = "groq",
    }

    -- Detect Presets
    local preset_idx = opts.name:match("Chat(%d)$")
    if preset_idx then
        overrides = { preset = tonumber(preset_idx) }
    elseif provider_map[opts.name] then
        overrides = { 
            provider = provider_map[opts.name],
            -- By default, if they use a provider command for search, use that provider's native search
            search_provider = provider_map[opts.name]
        }
        -- Special case for Ollama + Search -> Local Grounding
        if command == "search" and opts.name == "Ollama" then
            overrides.search_provider = "local_grounding"
        end
    end

    -- 3. EXECUTION PIPELINE
    local function execute_with_fresh_context()
        local ContextEngine = require("qllm.context_engine")

        -- Universal Context Resolution (Files, Selection, Project Map)
        local resolved_command, resolved_command_args, resolved_text_selection, resolved_overrides = 
            ContextEngine.handle_context_command(command, opts.args, current_bufnr, text_selection, overrides)

        if resolved_command == nil then return end -- Handled internally (e.g. scan popup)

        command = resolved_command
        command_args = resolved_command_args
        text_selection = resolved_text_selection
        overrides = resolved_overrides

        -- Fetch Options for the Final Resolved Command
        local cmd_opts = CommandsList.get_cmd_opts(command, overrides)

        if command == nil or command == "" or cmd_opts == nil then
            vim.notify("No valid command or options found for: " .. (command or "unknown"), vim.log.levels.ERROR, {
                title = "qLLM",
            })
            return
        end

        -- Check if command requires context (selection or files)
        if not cmd_opts.allow_empty_text_selection and (text_selection == nil or text_selection == "") then
            vim.notify("This command (" .. command .. ") requires a visual selection or file context.", vim.log.levels.WARN, {
                title = "qLLM",
            })
            return
        end

        Commands.run_cmd(command, command_args, text_selection, bufnr, cmd_opts, overrides)
    end

    -- If command is context-heavy, ensure project context is fresh before proceeding.
    local is_context_heavy = command == "files" or command == "scan" or command == "explain" 
        or opts.args:find("%[") ~= nil -- Prompt contains file blocks

    if is_context_heavy then
        local ProjectContext = require("qllm.project_context")
        ProjectContext.ensure_fresh_context(execute_with_fresh_context)
    else
        execute_with_fresh_context()
    end
end

function qllmModule.recall(arg)
    local fargs = { "recall" }
    if arg then table.insert(fargs, tostring(arg)) end
    return qllmModule.run_cmd({ fargs = fargs, name = "Chat" })
end

function qllmModule.undo()
    return qllmModule.run_cmd({ fargs = { "undo" }, name = "Chat" })
end

function qllmModule.clear()
    return qllmModule.run_cmd({ fargs = { "clear" }, name = "Chat" })
end

function qllmModule.adjust_popup_size(delta_w, delta_h)
    local Window = require("qllm.window")
    Window.update_global_layout(delta_w, delta_h)
    return Ui.refresh_active_popup()
end

return qllmModule
