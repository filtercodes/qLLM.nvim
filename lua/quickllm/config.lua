vim.g.quickllm_chat_completions_url = "https://api.openai.com/v1/chat/completions"

-- Read old config if it exists
if vim.g.quickllm_openai_api_provider and #vim.g.quickllm_openai_api_provider > 0 then
    vim.g.quickllm_api_provider = vim.g.quickllm_openai_api_provider
end

-- Alternative provider
vim.g.quickllm_api_provider = vim.g.quickllm_api_provider or "openai"

-- Default Models for Providers
vim.g.quickllm_provider_defaults = vim.tbl_extend("force", {
    openai = {
        model = "gpt-5.4-nano",
        reasoning = { effort = "medium" },
    },
    ollama = {
        model = "qwen3:8b",
    },
    anthropic = {
        model = "claude-haiku-4-5-20251001",
        max_tokens = 4096,
    },
    gemini = {
        model = "gemini-2.5-flash",
    },
    groq = {
        model = "qwen/qwen3-32b",
    },
    local_grounding = {
        model = "qwen3:8b",
    },
}, vim.g.quickllm_provider_defaults or {})

-- Default Search Models per Provider
vim.g.quickllm_search_model_defaults = vim.tbl_extend("force", {
    gemini = { model = "gemini-2.5-flash" },
    anthropic = { model = "claude-sonnet-4-6" },
    openai = { model = "gpt-5.5" },
    local_grounding = { model = "qwen3:8b" },
}, vim.g.quickllm_search_model_defaults or {})

-- Chat Presets
for i = 1, 3 do
    local provider_key = "quickllm_api_provider" .. i
    local search_key = "quickllm_search_provider" .. i
    local defaults_key = "quickllm_commands_defaults" .. i

    vim.g[provider_key] = vim.g[provider_key] or vim.g.quickllm_api_provider
    vim.g[search_key] = vim.g[search_key] or "gemini"
    vim.g[defaults_key] = vim.g[defaults_key] or nil
end

-- Clears visual selection after completion
vim.g.quickllm_clear_visual_selection = true

-- Print the model name in a notification before each request
if vim.g.quickllm_print_model == nil then
    vim.g.quickllm_print_model = true
end

-- Ensure user commands table exists
vim.g.quickllm_commands = vim.g.quickllm_commands or {}

vim.g.quickllm_hooks = {
    request_started = nil,
    request_finished = nil,
}

-- Style to use for the popup border (e.g. "rounded", "single", "double", "solid", "shadow")
vim.g.quickllm_popup_style = "rounded"

-- Passes native Neovim window options (vim.wo) to the popup window.
-- For example: { wrap = true, spell = false, cursorline = true, foldenable = false }
vim.g.quickllm_popup_window_options = {
    wrap = true,
    linebreak = true,
}

-- Set the filetype of a text popup is markdown
vim.g.quickllm_text_popup_filetype = "markdown"

-- Set the type of ui to use for the popup, options are "popup", "vertical" or "horizontal"
vim.g.quickllm_popup_type = "popup"

-- Whether to show the thinking process in the UI (if supported by the provider)
vim.g.quickllm_show_thinking = true

-- Set the layout of the popup window
vim.g.quickllm_popup_layout = {
  relative = "editor",
  position = "50%",
  size = {
    width = "100%",
    height = "80%"
  }
}

-- Set the height of the horizontal popup
vim.g.quickllm_horizontal_popup_size = "40%"

-- Set the width of the vertical popup
vim.g.quickllm_vertical_popup_size = "50%"

-- History (short-term memory) configuration
vim.g.quickllm_history_opts = vim.tbl_extend("force", {
    timeout = 1800,
    max_messages = 50,
    time_based_expiry = false,
    summarize_history = true,
}, vim.g.quickllm_history_opts or {})

-- Knowledge Base Namespace (Wiki & Project Context)
local kb_defaults = {
    -- 1. INFRASTRUCTURE
    db_path = vim.g.quickllm_kb_db_path or (vim.fn.stdpath("data") .. "/quickllm_kb.db"),
    sqlite_vec_path = vim.g.quickllm_kb_sqlite_vec_path or "",

    -- 2. WIKI
    wiki_folder = vim.g.quickllm_kb_folder or (vim.fn.getcwd() .. "/.quickllm_kb"),
    style = vim.g.quickllm_kb_style or "simple", -- simple | complex

    -- 3. EMBEDDINGS
    provider = vim.g.quickllm_kb_provider or "ollama",
    model = vim.g.quickllm_kb_embedding_model or "nomic-embed-text",
    dimension = vim.g.quickllm_kb_embedding_dimension or 768,

    -- 4. PROJECT CONTEXT
    project_provider = (vim.g.quickllm_project_defaults and vim.g.quickllm_project_defaults.provider) or "ollama",
    project_model = (vim.g.quickllm_project_defaults and vim.g.quickllm_project_defaults.model) or "qwen3:8b",
    auto_init = true,
    auto_check_freshness = true,

    -- 5. ORCHESTRATION
    scan_context = vim.g.quickllm_scan_context or 3,
    sync_strategy = "auto",      -- "auto" (background) | "manual"
    neighborhood_size = 5,       -- Number of related files to weave
}

-- Apply backward compatibility for Project Defaults if they exist
if vim.g.quickllm_project_defaults then
    if vim.g.quickllm_project_defaults.auto_init ~= nil then
        kb_defaults.auto_init = vim.g.quickllm_project_defaults.auto_init
    end
    if vim.g.quickllm_project_defaults.auto_check_freshness ~= nil then
        kb_defaults.auto_check_freshness = vim.g.quickllm_project_defaults.auto_check_freshness
    end
end

vim.g.quickllm_kb_opts = vim.tbl_extend("force", kb_defaults, vim.g.quickllm_kb_opts or {})

-- Model Intelligence Strategies (based on provider capabilities)
vim.g.quickllm_provider_capabilities = {
    ["openai"] = { strategy = "god_prompt" },
    ["anthropic"] = { strategy = "god_prompt" },
    ["gemini"] = { strategy = "god_prompt" },
    ["ollama"] = { strategy = "lazy" },
    ["groq"] = { strategy = "lazy" },
}

-- Default Command Templates
vim.g.quickllm_commands_defaults = {
    ["wiki"] = {
        provider = "knowledge_base",
        callback_type = "text_popup",
        user_message_template = "{{command_args}}",
        allow_empty_text_selection = true,
    },
    ["wiki_index"] = {
        allow_empty_text_selection = true,
    },
    ["wiki_save"] = {
        allow_empty_text_selection = true,
    },
    ["files"] = {
        allow_empty_text_selection = true,
    },
    ["scan"] = {
        allow_empty_text_selection = true,
    },
    ["init"] = {
        allow_empty_text_selection = true,
    },
    ["complete"] = {
        user_message_template =
        "I have the following {{language}} code: \n\n{{text_selection}}\n\nComplete the rest. Use best practices and descriptive commenting. {{language_instructions}} Only return the code snippet and nothing else.",
        language_instructions = {
            ["*"] = "Use modern {{language}} syntax and features.",
        },
        callback_type = "replace_lines",
        thinking = false,
    },
    ["edit"] = {
        user_message_template =
        "I have the following {{language}} code: \n{{filetype}}\n\n{{text_selection}}\n\n{{command_args}}.\n{{language_instructions}} Only return the code snippet and nothing else.",
        language_instructions = {
            ["*"] = "Use modern {{language}} syntax and features.",
        },
        callback_type = "replace_lines",
    },
    ["explain"] = {
        user_message_template =
        "Explain the following {{language}} code: ```{{filetype}}\n{{text_selection}}``` Explain as if you were explaining to another developer.",
        callback_type = "text_popup",
    },
    ["debug"] = {
        user_message_template =
        "Analyze the following {{language}} code for bugs: ```{{filetype}}\n{{text_selection}}```",
        callback_type = "text_popup",
    },
    ["doc"] = {
        user_message_template =
        "I have the following {{language}} code:\n{{filetype}}\n\n{{text_selection}}\n\nWrite comprehensive documentation using best practices for the given language. Attention paid to documenting parameters, return types, any exceptions or errors.\n{{language_instructions}} Only return the code snippet and nothing else.",
        language_instructions = {
            ["*"] = "Use the standard documentation style (e.g. Docstrings, JSDoc, Doxygen) typical for {{language}}.",
        },
        callback_type = "replace_lines",
    },
    ["opt"] = {
        user_message_template =
        "I have the following {{language}} code: \n{{filetype}}\n\n{{text_selection}}\n\nOptimize this code. {{language_instructions}} Only return the code snippet and nothing else.",
        language_instructions = {
            ["*"] = "Use modern {{language}} syntax and best practices.",
        },
        callback_type = "replace_lines",
    },
    ["tests"] = {
        user_message_template =
        "I have the following {{language}} code: ```{{filetype}}\n{{text_selection}}```\nWrite robust unit tests using best practices for the given language. {{language_instructions}} Only return the unit tests. Only return the code snippet and nothing else. ",
        callback_type = "code_popup",
        language_instructions = {
            ["*"] = "Use modern {{language}} syntax. Generate unit tests using a standard testing framework appropriate for {{language}}.",
        },
        callback_type = "code_popup",
    },
    ["chat"] = {
        user_message_template = "{{command_args}}",
        callback_type = "text_popup",
        allow_empty_text_selection = true,
    },
    ["search"] = {
        user_message_template = "{{command_args}}",
        system_message_template = "You are a helpful assistant. Use the web search tool to find up-to-date information to answer the user's query comprehensively.",
        callback_type = "text_popup",
        allow_empty_text_selection = true,
        is_search_command = true,
        loading_message = "Searching the web...",
    },
    ["clear"] = {
        allow_empty_text_selection = true,
    },
    ["recall"] = {
        allow_empty_text_selection = true,
    },
    ["undo"] = {
        allow_empty_text_selection = true,
    },
    ["help"] = {
        allow_empty_text_selection = true,
    },
}

-- Search Options
if vim.g.quickllm_show_search_sources == nil then
    vim.g.quickllm_show_search_sources = true
end

if vim.g.quickllm_ground_with_history == nil then
    vim.g.quickllm_ground_with_history = false
end

-- Popup commands
vim.g.quickllm_ui_commands = {
    quit = "q",
    use_as_output = "<c-o>",
    use_as_input = "<c-i>",
}

-- Additional way to quit popup with double escape (within 500ms)
if vim.g.quickllm_quit_with_double_esc == nil then
    vim.g.quickllm_quit_with_double_esc = true
end

vim.g.quickllm_ui_custom_commands = {}
