if vim.g.paneity_loaded then
    return
end
vim.g.paneity_loaded = true
vim.g.paneity_debug = true

-- Optionally lazy-load the plugin
vim.api.nvim_create_user_command(
    'TmuxPaneControl',
    function()
        require('paneity').setup()
    end,
    { desc = 'Initialize Paneity plugin' }
)
