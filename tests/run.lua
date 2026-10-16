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

-- named blocks: prerequisites run first, recursively, wherever they are in the file
local function run_at(row)
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  markexec.run()
  assert(vim.wait(5000, function() return not markexec._running[buf] end))
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  '```sh c b', 'echo three', '```',
  '```sh other', 'echo other', '```',
  '```sh a', 'echo one', '```',
  '```sh b a', 'echo two', '```',
})
run_at(2)
want = {
  '```sh c b', 'echo three', '```', '', '```output TS', 'three', '```', '',
  '```sh other', 'echo other', '```',
  '```sh a', 'echo one', '```', '', '```output TS', 'one', '```', '',
  '```sh b a', 'echo two', '```', '', '```output TS', 'two', '```', '',
}
assert(vim.deep_equal(lines(), want), 'prerequisite output wrong')
assert(vim.bo[buf].modifiable, 'buffer should be unlocked after prerequisites')

-- stops at the first failing prerequisite
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '```sh a', 'exit 3', '```', '```sh b a', 'echo two', '```' })
run_at(5)
want = { '```sh a', 'exit 3', '```', '', '```output TS', '[exit 3]', '```', '', '```sh b a', 'echo two', '```' }
assert(vim.deep_equal(lines(), want), 'should stop on failing prerequisite')
assert(vim.bo[buf].modifiable)

-- a cycle runs nothing
want = { '```sh a b', 'echo a', '```', '```sh b a', 'echo b', '```' }
vim.api.nvim_buf_set_lines(buf, 0, -1, false, want)
run_at(2)
assert(vim.deep_equal(lines(), want), 'cycle should run nothing')
assert(vim.bo[buf].modifiable)

-- chunks: <<name>> pastes code (nested, indented); heredocs untouched
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  '```sh env', 'URL=one', '```',
  '```sh auth', '<<env>>', 'T="$URL-two"', '```',
  '```sh get', '<<auth>>', 'cat <<EOF', '$T', 'EOF', '```',
})
run_at(10)
local got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(got[16] == 'one-two', 'nested chunk not expanded')

vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  '```python3 greet', 'print("hi")', '```',
  '```py main', 'def main():', '    <<greet>>', 'main()', '```',
})
run_at(5)
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[11] == 'hi', 'indented python chunk wrong')

-- language mismatch, cycles and unknown names run nothing
for _, case in ipairs({
  { '```sh env', 'X=1', '```', '```python3 p', '<<env>>', '```' },
  { '```sh a', '<<b>>', '```', '```sh b', '<<a>>', '```' },
  { '```sh a', 'X=1', '```', '```sh b', '<<nope>>', '```' },
}) do
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, case)
  run_at(5)
  assert(vim.deep_equal(lines(), case), 'bad chunk should run nothing')
  assert(vim.bo[buf].modifiable)
end

-- pipes: stdout of listed prerequisites goes to stdin, in listed order, across languages
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  '```sh a', 'echo one', '```',
  '```python3 b', 'print("two")', '```',
  '```sh c a', 'tr a-z A-Z', '```',
  '```python3 d c b', 'import sys', 'print(sys.stdin.read().split())', '```',
})
run_at(11)
got = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
assert(got[#got - 2] == "['ONE', 'two']", 'pipe output wrong: ' .. got[#got - 2])
-- c's own input was only a's output, not b's
assert(vim.tbl_contains(got, 'ONE') , 'c should uppercase a')

print('ok')
