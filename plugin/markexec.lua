vim.api.nvim_create_user_command('MarkexecRun', function() require('markexec').run() end, {})
vim.api.nvim_create_user_command('MarkexecStop', function() require('markexec').stop() end, {})
