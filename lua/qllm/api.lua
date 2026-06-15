local curl = require("plenary.curl")

local Api = {}

QLLM_CALLBACK_COUNTER = 0

local status_index = 0
Api.progress_bar_dots = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function Api.get_status(...)
    local Ui = require("qllm.ui")
    local bufnr = vim.api.nvim_get_current_buf()

    -- If we are in a UI window (split or popup), don't show the status here.
    if Ui.get_owner_bufnr(bufnr) then
        return ""
    end

    local last_command, last_model = Ui.get_active_status_info(bufnr)

    local is_running = QLLM_CALLBACK_COUNTER > 0
    local has_popup = Ui.has_active_popup(bufnr)

    local status = ""
    if is_running then
        status_index = status_index + 1
        if status_index > #Api.progress_bar_dots then
            status_index = 1
        end
        status = Api.progress_bar_dots[status_index]
    end

    -- We only show the info if a request is active OR if the user is looking at a popup
    if last_model and last_model ~= "" and (is_running or has_popup) then
        local model_info = string.format("%s  🤖 %s", last_command, last_model)
        if status ~= "" then
            status = status .. " " .. model_info
        else
            status = model_info
        end
        return status
    end

    return ""
end

function Api.run_started_hook()
    if vim.g.qllm_hooks["request_started"] ~= nil then
        vim.g.qllm_hooks["request_started"]()
    end

    QLLM_CALLBACK_COUNTER = QLLM_CALLBACK_COUNTER + 1
end

function Api.run_finished_hook()
    QLLM_CALLBACK_COUNTER = QLLM_CALLBACK_COUNTER - 1
    if QLLM_CALLBACK_COUNTER < 0 then
        QLLM_CALLBACK_COUNTER = 0
    end

    if QLLM_CALLBACK_COUNTER <= 0 then
        if vim.g.qllm_hooks["request_finished"] ~= nil then
            vim.g.qllm_hooks["request_finished"]()
        end
    end
end


return Api
