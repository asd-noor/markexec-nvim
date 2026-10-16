local M = {}

-- Header names that are not the interpreter's binary name. Anything else runs as-is,
-- e.g. ```python -> `python`. Code is fed on stdin.
local aliases = {
  py = 'python3',
  js = 'node',
  javascript = 'node',
  rb = 'ruby',
}

-- buf -> vim.SystemObj of the block currently running in that buffer
local running = {}
M._running = running

local function child(node, type)
  for c in node:iter_children() do
    if c:type() == type then return c end
  end
end

local function lang_of(block, buf)
  local info = child(block, 'info_string')
  local lang = info and child(info, 'language')
  return lang and vim.treesitter.get_node_text(lang, buf)
end

-- Rows (0-based) of the opening and closing fence, or nil if the fence is not closed.
local function fences(block)
  local rows = {}
  for c in block:iter_children() do
    if c:type() == 'fenced_code_block_delimiter' then table.insert(rows, (c:range())) end
  end
  if #rows == 2 then return rows[1], rows[2] end
end

local function block_at_cursor(buf)
  vim.treesitter.get_parser(buf, 'markdown'):parse()
  local node = vim.treesitter.get_node({ bufnr = buf, ignore_injections = true })
  while node and node:type() ~= 'fenced_code_block' do
    node = node:parent()
  end
  return node
end

local function output_lines(r, stamp)
  local text = vim.trim((r.stdout or '') .. (r.stderr or ''))
  local lines = text == '' and {} or vim.split(text, '\n')
  if r.code == 124 and r.signal == 15 then
    table.insert(lines, '[timeout]')
  elseif r.signal ~= 0 then
    table.insert(lines, '[killed]')
  elseif r.code ~= 0 then
    table.insert(lines, '[exit ' .. r.code .. ']')
  end
  table.insert(lines, 1, '```output ' .. stamp)
  table.insert(lines, 1, '')
  vim.list_extend(lines, { '```', '' })
  return lines
end

function M.run()
  local buf = vim.api.nvim_get_current_buf()
  if running[buf] then return vim.notify('markexec: already running', vim.log.levels.WARN) end

  local ok, block = pcall(block_at_cursor, buf)
  if not ok or not block then return vim.notify('markexec: not in a code block', vim.log.levels.WARN) end

  local lang = lang_of(block, buf)
  if not lang or lang == 'output' then return vim.notify('markexec: no language on code block', vim.log.levels.WARN) end
  local cmd = aliases[lang] or lang
  if vim.fn.executable(cmd) == 0 then return vim.notify('markexec: interpreter not found: ' .. cmd, vim.log.levels.ERROR) end

  local _, close = fences(block)
  if not close then return vim.notify('markexec: code fence not closed', vim.log.levels.WARN) end
  local content = child(block, 'code_fence_content')
  if not content then return end

  -- Region after the closing fence to replace: one blank line, then an output block
  -- directly below plus one blank line after it, if present.
  local function blank(row) return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] == '' end
  local first = close + 1
  local last = blank(first) and first + 1 or first
  local nxt = block:next_named_sibling()
  if nxt and nxt:type() == 'fenced_code_block' and lang_of(nxt, buf) == 'output' then
    local open2, close2 = fences(nxt)
    if open2 == last and close2 then
      last = close2 + 1
      if blank(last) then last = last + 1 end
    end
  end

  local stamp = os.date('%Y-%m-%d %H:%M:%S')
  local dir = vim.fn.expand('%:p:h')
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = false

  running[buf] = vim.system(
    { cmd },
    { text = true, stdin = vim.treesitter.get_node_text(content, buf), timeout = 30000, cwd = vim.fn.isdirectory(dir) == 1 and dir or nil },
    vim.schedule_wrap(function(r)
      running[buf] = nil
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.bo[buf].modifiable = modifiable
      vim.api.nvim_buf_set_lines(buf, first, last, false, output_lines(r, stamp))
    end)
  )
end

function M.stop()
  local job = running[vim.api.nvim_get_current_buf()]
  if job then job:kill(15) end
end

return M
