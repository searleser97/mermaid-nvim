local cache = require('mermaid-nvim.cache')

local M = {}

local ns = vim.api.nvim_create_namespace('mermaid_nvim')

---Render a single mermaid block
---@param buf integer
---@param block mermaid.Block
---@param config mermaid.Config
function M.render_block(buf, block, config)
  local win_width = vim.api.nvim_win_get_width(0)
  local content_hash = cache.hash(block.source, config.cmd, win_width)
  local cached = cache.get(content_hash)

  if cached then
    M.apply_extmarks(buf, block, cached)
    return
  end

  -- Capture changedtick to detect stale results
  local tick = vim.api.nvim_buf_get_changedtick(buf)

  M.render_async(buf, block, config, content_hash, tick)
end

---@param buf integer
---@param block mermaid.Block
---@param config mermaid.Config
---@param content_hash string
---@param tick integer changedtick at time of request
function M.render_async(buf, block, config, content_hash, tick)
  -- Set PYTHONIOENCODING for tools like termaid that output Unicode
  local env = vim.fn.environ()
  env.PYTHONIOENCODING = 'utf-8'

  -- Build command with width constraint
  local cmd = vim.deepcopy(config.cmd)
  local win_width = vim.api.nvim_win_get_width(0)
  if cmd[1] == 'termaid' then
    vim.list_extend(cmd, { '--width', tostring(win_width) })
  end

  vim.system(cmd, {
    stdin = block.source,
    text = true,
    env = env,
  }, function(result)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end

      -- Discard stale results: buffer was edited since we started
      if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
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

  -- Build virtual lines for the ASCII diagram
  local virt_lines = {}
  for _, line in ipairs(ascii_lines) do
    virt_lines[#virt_lines + 1] = { { line, 'Comment' } }
  end

  -- Hide each source line and show ASCII art via virt_lines on the first line
  for row = block.start_row, block.end_row do
    local opts = {
      end_row = row,
      end_col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''),
      conceal = '',
    }
    -- Attach virtual lines to the first concealed line
    if row == block.start_row then
      opts.virt_lines = virt_lines
      opts.virt_lines_above = false
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, opts)
  end
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
