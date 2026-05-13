local scanner = require('mermaid-nvim.scanner')
local renderer = require('mermaid-nvim.renderer')
local cache = require('mermaid-nvim.cache')

local M = {}

---@class mermaid.Config
---@field cmd string[] Command to run for rendering (receives mermaid source via stdin)
---@field enabled boolean Whether to render on BufEnter/TextChanged
---@field debounce_ms integer Debounce time in ms before re-rendering
---@field on_error 'virtual_text'|'notify'|'silent' How to display render errors
local default_config = {
  cmd = { 'termaid' },
  enabled = true,
  debounce_ms = 300,
  on_error = 'virtual_text',
}

---@type mermaid.Config
M.config = vim.deepcopy(default_config)

---@type table<integer, boolean> bufnr -> toggled blocks exist
M.attached_bufs = {}

---@type table<integer, table<integer, boolean>> buf -> { start_row -> true } for blocks in source mode
M.source_blocks = {}

function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', default_config, opts or {})

  vim.api.nvim_create_user_command('MermaidToggle', function()
    M.toggle_block()
  end, { desc = 'Toggle mermaid block under cursor between preview and source' })

  vim.api.nvim_create_user_command('MermaidRender', function()
    M.render_buf(0)
  end, { desc = 'Render all mermaid blocks in the current buffer' })

  vim.api.nvim_create_user_command('MermaidClear', function()
    M.clear_buf(0)
  end, { desc = 'Clear all mermaid previews in the current buffer' })

  if M.config.enabled then
    local group = vim.api.nvim_create_augroup('MermaidNvim', { clear = true })

    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      pattern = 'markdown',
      callback = function(ev)
        M.attach(ev.buf)
      end,
    })

    -- Attach to already-open markdown buffers (handles lazy-load timing)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'markdown' then
        M.attach(buf)
      end
    end

    -- Also attach the current buffer if it's markdown (lazy.nvim ft trigger)
    local cur = vim.api.nvim_get_current_buf()
    if vim.bo[cur].filetype == 'markdown' then
      M.attach(cur)
    end
  end
end

---@param buf integer
function M.attach(buf)
  if M.attached_bufs[buf] then
    return
  end
  M.attached_bufs[buf] = true

  -- Ensure conceallevel is set so conceal extmarks work
  vim.api.nvim_create_autocmd('BufWinEnter', {
    buffer = buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.wo[win].conceallevel < 2 then
        vim.wo[win].conceallevel = 2
      end
    end,
  })
  -- Set for the current window immediately
  if vim.wo.conceallevel < 2 then
    vim.wo.conceallevel = 2
  end

  local group = vim.api.nvim_create_augroup('MermaidNvim_' .. buf, { clear = true })
  local timer = vim.uv.new_timer()

  local function debounced_render()
    timer:stop()
    timer:start(M.config.debounce_ms, 0, vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(buf) then
        M.render_buf(buf)
      end
    end))
  end

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    group = group,
    buffer = buf,
    callback = debounced_render,
  })

  vim.api.nvim_create_autocmd('BufDelete', {
    group = group,
    buffer = buf,
    callback = function()
      timer:stop()
      timer:close()
      M.attached_bufs[buf] = nil
      M.source_blocks[buf] = nil
      cache.clear_buf(buf)
    end,
  })

  -- Initial render
  M.render_buf(buf)
end

---@param buf integer
function M.render_buf(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf

  -- Clear all existing extmarks then re-render (handles moved/deleted blocks)
  renderer.clear_all(buf)

  local blocks = scanner.find_blocks(buf)
  local buf_source = M.source_blocks[buf] or {}

  for _, block in ipairs(blocks) do
    if not buf_source[block.start_row] then
      renderer.render_block(buf, block, M.config)
    end
  end
end

---@param buf integer
function M.clear_buf(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  renderer.clear_all(buf)
  M.source_blocks[buf] = nil
end

function M.toggle_block()
  local buf = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
  local blocks = scanner.find_blocks(buf)

  for _, block in ipairs(blocks) do
    if cursor_row >= block.start_row and cursor_row <= block.end_row then
      if not M.source_blocks[buf] then
        M.source_blocks[buf] = {}
      end

      if M.source_blocks[buf][block.start_row] then
        -- Switch back to preview
        M.source_blocks[buf][block.start_row] = nil
        renderer.render_block(buf, block, M.config)
      else
        -- Switch to source
        M.source_blocks[buf][block.start_row] = true
        renderer.clear_block(buf, block)
      end
      return
    end
  end

  vim.notify('[mermaid-nvim] No mermaid block under cursor', vim.log.levels.WARN)
end

return M
