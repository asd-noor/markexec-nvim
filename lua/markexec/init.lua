local M = {}

-- Header names that are not the interpreter's binary name. Anything else runs as-is,
-- e.g. ```python -> `python`. Code runs from a temp script file: `<interpreter> <file>`.
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

-- Fence header ```<lang> [name] [prereq...] -> lang, name, { prereq... }
local function info_of(block, buf)
  local info = child(block, 'info_string')
  if not info then return end
  local words = vim.split(vim.treesitter.get_node_text(info, buf), '%s+', { trimempty = true })
  return words[1], words[2], { unpack(words, 3) }
end

-- Rows (0-based) of the opening and closing fence, or nil if the fence is not closed.
local function fences(block)
  local rows = {}
  for c in block:iter_children() do
    if c:type() == 'fenced_code_block_delimiter' then table.insert(rows, (c:range())) end
  end
  if #rows == 2 then return rows[1], rows[2] end
end

local function parse(buf)
  return vim.treesitter.get_parser(buf, 'markdown'):parse()[1]:root()
end

local function block_at_cursor(buf)
  parse(buf)
  local node = vim.treesitter.get_node({ bufnr = buf, ignore_injections = true })
  while node and node:type() ~= 'fenced_code_block' do
    node = node:parent()
  end
  return node
end

-- Interpreter for a fence language.
local function interpreter(lang)
  return aliases[lang] or lang
end

-- Code of a block, without the trailing newline.
local function code_of(block, buf)
  local content = child(block, 'code_fence_content')
  return content and (vim.treesitter.get_node_text(content, buf):gsub('\n$', '')) or ''
end

-- name -> { node, cmd, code, deps } for every named code block (not output blocks).
local query
local function all_blocks(buf)
  query = query or vim.treesitter.query.parse('markdown', '(fenced_code_block) @b')
  local out = {}
  for _, node in query:iter_captures(parse(buf), buf) do
    table.insert(out, node)
  end
  return out
end

local function named_blocks(buf)
  local out = {}
  for _, node in ipairs(all_blocks(buf)) do
    local lang, name, deps = info_of(node, buf)
    if name and lang ~= 'output' then
      if out[name] then error('duplicate block name: ' .. name, 0) end
      out[name] = { node = node, cmd = interpreter(lang), code = code_of(node, buf), deps = deps }
    end
  end
  return out
end

-- Names to run for `name`, prerequisites first (depth-first, each block once).
local function plan(blocks, name)
  local order, state = {}, {}
  local function visit(n)
    if state[n] == 'done' then return end
    if state[n] == 'visiting' then error('dependency cycle at: ' .. n, 0) end
    local b = blocks[n] or error('no block named: ' .. n, 0)
    state[n] = 'visiting'
    for _, d in ipairs(b.deps) do visit(d) end
    state[n] = 'done'
    table.insert(order, n)
  end
  visit(name)
  return order
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

-- Replace each whole-line <<name>> with that block's code, indented like
-- the reference, recursively. `seen` holds the names being expanded, to catch cycles.
local function expand(code, cmd, blocks, seen)
  local out = {}
  for _, line in ipairs(vim.split(code, '\n')) do
    local indent, ref = line:match('^(%s*)<<([%w_.-]+)>>%s*$')
    local b = ref and blocks[ref]
    if not ref then
      table.insert(out, line)
    elseif not b then
      error('no block named: <<' .. ref .. '>>', 0)
    else
      if seen[ref] then error('reference cycle at: <<' .. ref .. '>>', 0) end
      if b.cmd ~= cmd then error(('<<%s>>: %s block in %s block'):format(ref, b.cmd, cmd), 0) end
      seen[ref] = true
      for _, l in ipairs(vim.split(expand(b.code, cmd, blocks, seen), '\n')) do
        table.insert(out, l == '' and l or indent .. l)
      end
      seen[ref] = nil
    end
  end
  return table.concat(out, '\n')
end

-- Run one block with `input` on stdin and write its output block. Calls done(result)
-- after writing. Returns false (after notifying) when the block cannot run.
local function run_block(buf, block, blocks, input, done)
  local lang, name = info_of(block, buf)
  if not lang or lang == 'output' then
    vim.notify('markexec: no language on code block', vim.log.levels.WARN)
    return false
  end
  local cmd = interpreter(lang)
  if vim.fn.executable(cmd) == 0 then
    vim.notify('markexec: interpreter not found: ' .. cmd, vim.log.levels.ERROR)
    return false
  end
  local _, close = fences(block)
  if not close then
    vim.notify('markexec: code fence not closed', vim.log.levels.WARN)
    return false
  end
  local ok, code = pcall(expand, code_of(block, buf), cmd, blocks, name and { [name] = true } or {})
  if not ok then
    vim.notify('markexec: ' .. code, vim.log.levels.ERROR)
    return false
  end

  -- Region after the closing fence to replace: one blank line, then an output block
  -- directly below plus one blank line after it, if present.
  local function blank(row) return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] == '' end
  local first = close + 1
  local last = blank(first) and first + 1 or first
  local nxt = block:next_named_sibling()
  if nxt and nxt:type() == 'fenced_code_block' and info_of(nxt, buf) == 'output' then
    local open2, close2 = fences(nxt)
    if open2 == last and close2 then
      last = close2 + 1
      if blank(last) then last = last + 1 end
    end
  end

  local stamp = os.date('%Y-%m-%d %H:%M:%S')
  local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ':p:h')
  local script = vim.fn.tempname()
  vim.fn.writefile(vim.split(code, '\n'), script)
  running[buf] = vim.system(
    { cmd, script },
    {
      text = true,
      stdin = input,
      timeout = 30000,
      cwd = vim.fn.isdirectory(dir) == 1 and dir or nil,
    },
    vim.schedule_wrap(function(r)
      running[buf] = nil
      os.remove(script)
      if not vim.api.nvim_buf_is_valid(buf) then return end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, first, last, false, output_lines(r, stamp))
      vim.bo[buf].modifiable = false
      done(r)
    end)
  )
  return true
end

-- Run the block under the cursor. A named block (```sh build setup deps) first runs its
-- prerequisites in order, recursively, each once; it stops at the first failure. The
-- stdout of the prerequisites a block lists is piped into it: { setup; deps; } | build.
function M.run()
  local buf = vim.api.nvim_get_current_buf()
  if running[buf] then return vim.notify('markexec: already running', vim.log.levels.WARN) end

  local ok, block = pcall(block_at_cursor, buf)
  if not ok or not block then return vim.notify('markexec: not in a code block', vim.log.levels.WARN) end

  local _, name = info_of(block, buf)
  local order = { false } -- false = the cursor block itself
  if name then
    local planned, res = pcall(function() return plan(named_blocks(buf), name) end)
    if not planned then return vim.notify('markexec: ' .. res, vim.log.levels.ERROR) end
    order = res
  end

  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = false
  local function finish()
    if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = modifiable end
  end

  local stdout = {} -- name -> stdout from this run

  -- Output blocks shift rows, so look each block up by name right before it runs.
  local function step(k)
    local ok_blocks, blocks = pcall(named_blocks, buf)
    if not ok_blocks then
      vim.notify('markexec: ' .. blocks, vim.log.levels.ERROR)
      return finish()
    end
    local b = order[k] and blocks[order[k]].node or block
    local input = {}
    for _, d in ipairs(order[k] and blocks[order[k]].deps or {}) do
      table.insert(input, stdout[d])
    end
    local started = run_block(buf, b, blocks, table.concat(input), function(r)
      if order[k] then stdout[order[k]] = r.stdout end
      if k < #order and r.code == 0 and r.signal == 0 then step(k + 1) else finish() end
    end)
    if not started then finish() end
  end
  step(1)
end

-- Delete every output block in the buffer, with the blank line after each.
function M.clear()
  local buf = vim.api.nvim_get_current_buf()
  if running[buf] then return vim.notify('markexec: already running', vim.log.levels.WARN) end
  local blocks = all_blocks(buf)
  for i = #blocks, 1, -1 do -- bottom-up, so earlier rows stay valid
    local open, close = fences(blocks[i])
    if info_of(blocks[i], buf) == 'output' and close then
      local after = vim.api.nvim_buf_get_lines(buf, close + 1, close + 2, false)[1]
      vim.api.nvim_buf_set_lines(buf, open, close + (after == '' and 2 or 1), false, {})
    end
  end
end

function M.stop()
  local job = running[vim.api.nvim_get_current_buf()]
  if job then job:kill(15) end
end

return M
