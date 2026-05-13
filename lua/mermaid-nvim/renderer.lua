local cache = require('mermaid-nvim.cache')

local M = {}

local ns = vim.api.nvim_create_namespace('mermaid_nvim')

---Render a single mermaid block
---@param buf integer
---@param block mermaid.Block
---@param config mermaid.Config
function M.render_block(buf, block, config)
  local content_hash = cache.hash(block.source, config.cmd)
  local cached = cache.get(content_hash)

  if cached then
    M.apply_extmarks(buf, block, cached)
    return
  end

  M.render_async(buf, block, config, content_hash)
end

---@param buf integer
---@param block mermaid.Block
---@param config mermaid.Config
---@param content_hash string
function M.render_async(buf, block, config, content_hash)
  -- Set PYTHONIOENCODING for tools like termaid that output Unicode
  local env = vim.fn.environ()
  env.PYTHONIOENCODING = 'utf-8'

  local cmd = vim.deepcopy(config.cmd)

  -- Remember the source we're rendering to verify on completion
  local expected_source = block.source

  vim.system(cmd, {
    stdin = block.source,
    text = true,
    env = env,
  }, function(result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end

      if result.code ~= 0 then
        local err = result.stderr or 'unknown error'
        M.handle_error(buf, block, err, config)
        return
      end

      local output = result.stdout or ''
      if output == '' then
        return
      end

      -- Remove trailing newline
      output = output:gsub('\n$', '')
      cache.set(content_hash, output)
      M.apply_extmarks(buf, block, output)
    end)
  end)
end

---Apply extmarks to conceal the block and show ASCII art
---@param buf integer
---@param block mermaid.Block
---@param ascii_output string
function M.apply_extmarks(buf, block, ascii_output)
  -- Clear existing marks for this block
  M.clear_block(buf, block)

  local ascii_lines = vim.split(ascii_output, '\n')

  -- Build virtual lines for the ASCII diagram (with right padding)
  local padding = string.rep(' ', 4)
  local virt_lines = {}
  for _, line in ipairs(ascii_lines) do
    virt_lines[#virt_lines + 1] = { { line .. padding, 'Comment' } }
  end

  -- Hide each source line and show ASCII art via virt_lines on the first line
  for row = block.start_row, block.end_row do
    local opts = {
      end_row = row,
      end_col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''),
      conceal = '',
    }
    -- Attach virtual lines and a clickable "Open" button to the first concealed line
    if row == block.start_row then
      opts.virt_lines = virt_lines
      opts.virt_lines_above = false
      opts.virt_lines_overflow = 'scroll'
      opts.virt_text = { { ' 🔍 Open in float ', 'DiagnosticInfo' } }
      opts.virt_text_pos = 'eol'
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, opts)
  end
end

---Open a mermaid diagram in a scrollable floating window
---@param ascii_output string
function M.open_float(ascii_output)
  local lines = vim.split(ascii_output, '\n')

  -- Calculate float dimensions
  local max_width = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max_width then max_width = w end
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - 2 -- account for cmdline + statusline
  local float_width = math.min(max_width + 2, editor_width - 4)
  local float_height = math.min(#lines, editor_height - 4)

  -- Create scratch buffer with diagram content
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false
  vim.bo[float_buf].bufhidden = 'wipe'
  vim.bo[float_buf].filetype = 'mermaid-preview'

  -- Open centered floating window
  local row = math.floor((editor_height - float_height) / 2)
  local col = math.floor((editor_width - float_width) / 2)
  local win = vim.api.nvim_open_win(float_buf, true, {
    relative = 'editor',
    width = float_width,
    height = float_height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Mermaid Diagram ',
    title_pos = 'center',
  })

  -- Close on q, <Esc>, or leaving the window
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = float_buf, nowait = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = float_buf, nowait = true })
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = float_buf,
    once = true,
    callback = close,
  })
end

---Handle render errors
---@param buf integer
---@param block mermaid.Block
---@param err string
---@param config mermaid.Config
function M.handle_error(buf, block, err, config)
  local msg = err:gsub('\n', ' '):sub(1, 120)

  if config.on_error == 'notify' then
    vim.notify('[mermaid-nvim] Render error: ' .. msg, vim.log.levels.ERROR)
  elseif config.on_error == 'virtual_text' then
    M.clear_block(buf, block)
    vim.api.nvim_buf_set_extmark(buf, ns, block.start_row, 0, {
      virt_lines = { { { '  ⚠ mermaid render error: ' .. msg, 'DiagnosticError' } } },
      virt_lines_above = false,
    })
  end
  -- 'silent' does nothing
end

---Clear extmarks for a specific block
---@param buf integer
---@param block mermaid.Block
function M.clear_block(buf, block)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { block.start_row, 0 }, { block.end_row, -1 }, {})
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(buf, ns, mark[1])
  end
end

---Clear all mermaid extmarks in a buffer
---@param buf integer
function M.clear_all(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

return M
