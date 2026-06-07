local Utils = require("quickllm.utils")
local Ui = require("quickllm.ui")

local M = {}

local command_descriptions = {
    chat = "General purpose chat assistant. Use this for general questions, brainstorming, or when no code is selected. It maintains conversation history.",
    search = "Triggers a web search (grounding) before answering to provide up-to-date information and reduce LLM hallucinations.",
    complete = "Completes the current code selection. Useful for finishing a function or block of code based on the context provided by the selection.",
    edit = "Modifies the selected code based on your instructions. Use this to refactor, change logic, or apply specific transformations to existing code.",
    explain = "Provides a detailed explanation of the selected code. It breaks down the logic and explains it in simple terms, useful for understanding complex legacy code.",
    files = "Reads multiple local project files (supports wildcards) and passes their content as context to the prompt.",
    scan = "Performs a hybrid search (fuzzy/literal) across local project files and sends relevant chunks to the LLM.",
    wiki = "Performs a semantic search across your local Knowledge Base using Hierarchical RAG (Map & Territory).",
    wiki_index = "Scans your KB folder and performs a 'one-pass' indexing with LLM-generated summaries and vectors.",
    wiki_lint = "Runs the Global Auditor to find 'Shadow Concepts' and 'Orphan Files', populating the Quickfix list.",
    wiki_save = "Saves your current buffer or visual selection directly into the Knowledge Base for future retrieval.",
    doc = "Generates documentation for the selected code. It produces function/method documentation (e.g., Javadoc, Doxygen) following best practices for the language.",
    tests = "Generates unit tests for the selected code. It attempts to use standard testing frameworks appropriate for the language (e.g., JUnit for Java, gtest for C++).",
    opt = "Suggests optimizations for the selected code. It looks for performance improvements or cleaner ways to implement the same logic.",
    debug = "Analyzes the selected code for potential bugs or issues. It acts as a static analysis tool to spot logical errors or common pitfalls.",
    recall = "Displays the last response from the assistant in a popup window. Accepts an optional number to go further back (e.g., `:Chat recall 2` for the second-to-last response).",
    undo = "Removes the last exchange (your prompt and the assistant's response) from the chat history. Useful for undoing a bad conversation turn.",
    clear = "Clears the chat history for the current buffer. This resets the conversation context.",
    help = "Displays this help file, listing available commands, keybindings, and configuration options.",
}

function M.get_help_lines()
    local lines = {
        "# QuickLLM.nvim Help",
        "",
        "## Usage",
        "- `:Chat <prompt>`: Send a general prompt to the LLM.",
        "- `:Chat <command>`: Execute a specific command (e.g., `:Chat explain`).",
        "- `:'<,'>Chat <command>`: Execute a command on a visual selection.",
        "",
        "## UI Keybindings",
    }

    local ui_cmds = vim.g.quickllm_ui_commands
    table.insert(lines, "- `" .. ui_cmds.quit .. "`: Quit window")
    table.insert(lines, "- `" .. ui_cmds.use_as_output .. "`: Use as output (replace original selection with response)")
    table.insert(lines, "- `" .. ui_cmds.use_as_input .. "`: Use as input (select response and start new chat)")
    
    table.insert(lines, "")
    table.insert(lines, "## Commands")

    local commnds_listed = {
        "chat", "search", "complete", "edit",
        "explain", "files", "scan",
        "wiki", "wiki_index", "wiki_save", "wiki_lint",
        "doc", "tests", "opt", "debug",
        "recall", "undo", "clear", "help"
    }

    local all_commands = {}
    local seen = {}

    for _, name in ipairs(commnds_listed) do
        -- Only add it if it actually exists in the defaults or descriptions
        if command_descriptions[name] or (vim.g.quickllm_commands_defaults and vim.g.quickllm_commands_defaults[name]) then
            table.insert(all_commands, name)
            seen[name] = true
        end
    end
    
    local function collect_cmds(source)
        if not source then return end
        for name, _ in pairs(source) do
            if not seen[name] then
                table.insert(all_commands, name)
                seen[name] = true
            end
        end
    end

    collect_cmds(vim.g.quickllm_commands_defaults)
    collect_cmds(vim.g.quickllm_commands)

    for _, name in ipairs(all_commands) do
        local desc = command_descriptions[name] or "Custom user command."
        table.insert(lines, "### " .. name)
        table.insert(lines, desc)
        table.insert(lines, "")
    end

    table.insert(lines, "### Configuration")
    table.insert(lines, "You can customize QuickLLM by setting global variables in your Neovim config (init.lua).")
    table.insert(lines, "")
    
    table.insert(lines, "### Provider Settings")
    table.insert(lines, "`vim.g.quickllm_api_provider` (string)")
    table.insert(lines, "Sets the active LLM provider. Default: `'openai'`.")
    table.insert(lines, "Available options: `'openai'`, `'anthropic'`, `'gemini'`, `'ollama'`, `'groq'`.")
    table.insert(lines, "")
    
    table.insert(lines, "### Model Configuration")
    table.insert(lines, "To change the model or other settings, use the unified defaults table.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_commands_defaults` (table)")
    table.insert(lines, "A dual-purpose table. Flat keys act as global defaults for all commands. Nested tables override settings for a specific command.")
    table.insert(lines, "Example:")
    table.insert(lines, "```lua")
    table.insert(lines, "vim.g.quickllm_commands_defaults = {")
    table.insert(lines, "  model = 'gpt-5.4-nano', -- Global")
    table.insert(lines, "  thinking = true,      -- Global")
    table.insert(lines, "  complete = {")
    table.insert(lines, "    thinking = false    -- Override for 'complete'")
    table.insert(lines, "  }")
    table.insert(lines, "}")
    table.insert(lines, "```")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_commands` (table)")
    table.insert(lines, "User-defined commands. These have the highest precedence.")
    table.insert(lines, "")

    table.insert(lines, "### Search (Grounding)")
    table.insert(lines, "To set the search model.")
    table.insert(lines, "")
    table.insert(lines, "Example: `vim.g.quickllm_search_provider = 'anthropic'`")
    table.insert(lines, "`vim.g.quickllm_commands_defaults = { search_model = 'claude-sonnet-4-6' }`")
    table.insert(lines, "Overrides default grounding model. Be aware that API specs might be different for older models")
    table.insert(lines, "")

    table.insert(lines, "### Chat History (Memory)")
    table.insert(lines, "`vim.g.quickllm_chat_history_max_messages` (number)")
    table.insert(lines, "Maximum number of messages to retain in the chat context window. Default: `20`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_chat_history_timeout` (number)")
    table.insert(lines, "Time in seconds before the chat history expires and is cleared. Default: `900` (15 minutes).")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_chat_history_time_based_expiry` (boolean)")
    table.insert(lines, "Whether to auto-clear history after the timeout. Default: `false`.")
    table.insert(lines, "")

    table.insert(lines, "### UI Customization")
    table.insert(lines, "`vim.g.quickllm_popup_type` (string)")
    table.insert(lines, "Determines how the result window opens.")
    table.insert(lines, "Options:")
    table.insert(lines, "- `'popup'`: Centered floating window (default).")
    table.insert(lines, "- `'horizontal'`: Split window at the bottom.")
    table.insert(lines, "- `'vertical'`: Split window on the right.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_horizontal_popup_size` (string)")
    table.insert(lines, "Height of the horizontal split. Default: `'20%'`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_vertical_popup_size` (string)")
    table.insert(lines, "Width of the vertical split. Default: `'20%'`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_popup_border` (table)")
    table.insert(lines, "Border style for the popup window. Default: `{ style = 'rounded' }`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_text_popup_filetype` (string)")
    table.insert(lines, "Filetype for the result window (for syntax highlighting). Default: `'markdown'`.")
    table.insert(lines, "")
    table.insert(lines, "`vim.g.quickllm_ui_commands` (table)")
    table.insert(lines, "Customizes keybindings within the QuickLLM window.")
    table.insert(lines, "Default:")
    table.insert(lines, "```lua")
    table.insert(lines, "vim.g.quickllm_ui_commands = {")
    table.insert(lines, "    quit = 'q',")
    table.insert(lines, "    use_as_output = '<c-o>',")
    table.insert(lines, "    use_as_input = '<c-i>'")
    table.insert(lines, "}")
    table.insert(lines, "```")
    table.insert(lines, "")
    
    table.insert(lines, "### Miscellaneous")
    table.insert(lines, "`vim.g.quickllm_clear_visual_selection` (boolean)")
    table.insert(lines, "Whether to clear the visual selection after a command runs. Default: `true`.")

    table.insert(lines, "")
    table.insert(lines, "## Workflow Examples")
    
    table.insert(lines, "### 1. The Multi-File Context Architect")
    table.insert(lines, "Need the LLM to understand multiple files before answering?")
    table.insert(lines, "1. Type `:Chat files \"src/main.lua\" \"src/utils.lua\"`")
    table.insert(lines, "2. Add your prompt: `How do these files interact?`")
    table.insert(lines, "3. Press Enter. The LLM will read both files and answer.")
    table.insert(lines, "4. *Pro Tip*: Use `<Tab>` after typing `files` to get native file path autocomplete!")
    table.insert(lines, "")

    table.insert(lines, "### 2. The Iterative Refactor (with Context Injection)")
    table.insert(lines, "1. Select a function visually.")
    table.insert(lines, "2. Press `<C-i>` inside an empty Chat popup to start a chat with that code.")
    table.insert(lines, "3. Type: `Make this more functional style` and hit Enter.")
    table.insert(lines, "4. The model answers. If it needs tweaking, select the new code and press `<C-i>` again.")
    table.insert(lines, "5. Type: `Also add type annotations.`")
    table.insert(lines, "6. Once satisfied, press `<C-o>` (Use as Output) to replace your original code in the editor.")
    table.insert(lines, "")

    table.insert(lines, "### 3. The Local Knowledge Base (RAG)")
    table.insert(lines, "Ask questions against your local markdown notes without sending data to the cloud.")
    table.insert(lines, "1. Ensure you have markdown files in your configured `wiki_folder`.")
    table.insert(lines, "2. Run `:Chat wiki_index` to map the folder (only needed when files change).")
    table.insert(lines, "3. Ask a question: `:Chat wiki What are our deployment steps?`")
    table.insert(lines, "4. The LLM will search your local files, find the right context, and synthesize an answer.")
    table.insert(lines, "")

    table.insert(lines, "### 4. The History Navigator")
    table.insert(lines, "Want to review a previous answer or prompt?")
    table.insert(lines, "1. Run `:Chat recall` to view the last assistant answer.")
    table.insert(lines, "2. Run `:Chat recallq` to view the *prompt* you sent to get that answer.")
    table.insert(lines, "3. Use your custom keybindings (e.g., `<leader>qw` or `<leader>qf`) to walk backward and forward through the conversation history.")
    
    return lines
end

function M.show_help(bufnr)
    local lines = M.get_help_lines()
    local start_row, start_col, end_row, end_col = Utils.get_visual_selection()
    
    -- If no visual selection, we still need generic coordinates for the popup
    -- The popup function handles "empty" coordinates gracefully by centering or defaulting
    Ui.popup(lines, "markdown", bufnr, start_row, start_col, end_row, end_col)
end

return M
