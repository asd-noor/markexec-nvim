-- nvim --headless -l tests/run.lua
vim.opt.rtp:prepend('.')
local markexec = require('markexec')

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = 'markdown'
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# t', '', '```sh', 'sleep 0.3; echo hi', '```', '', 'after' })

local function run()
  vim.api.nvim_win_set_cursor(0, { 4, 0 })
  markexec.run()
  assert(not vim.bo[buf].modifiable, 'buffer should be locked while running')
  assert(vim.wait(5000, function() return not markexec._running[buf] end), 'run did not finish')
  assert(vim.bo[buf].modifiable, 'buffer should be unlocked after run')
end

-- buffer lines with the output timestamp replaced by TS
local function lines()
  return vim.tbl_map(function(l)
    return (l:gsub('^```output %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$', '```output TS'))
  end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
end

local want = { '# t', '', '```sh', 'sleep 0.3; echo hi', '```', '', '```output TS', 'hi', '```', '', 'after' }
run()
assert(vim.deep_equal(lines(), want), 'first run output wrong')
run()
assert(vim.deep_equal(lines(), want), 'second run should replace, not duplicate')

-- stop: kill a long run, lock released, [killed] written
vim.api.nvim_buf_set_lines(buf, 3, 4, false, { 'sleep 10' })
vim.api.nvim_win_set_cursor(0, { 4, 0 })
markexec.run()
markexec.stop()
assert(vim.wait(5000, function() return not markexec._running[buf] end), 'stop did not finish')
assert(vim.bo[buf].modifiable)
assert(vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1] == '[killed]', 'expected [killed]')

-- interpreter comes from the header
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '```python3', 'print(1 + 1)', '```' })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
markexec.run()
assert(vim.wait(5000, function() return not markexec._running[buf] end))
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[6] == '2', 'python3 block output wrong')

print('ok')
