local scanner = require('mermaid-nvim.scanner')
local renderer = require('mermaid-nvim.renderer')
local cache = require('mermaid-nvim.cache')

local M = {}

---@class mermaid.Config
---@field cmd string[] Command to run for rendering (receives mermaid source via stdin)
---@field enabled boolean Whether to render on BufEnter/TextChanged
---@field debounce_ms integer Debounce time in ms before re-rendering
---@field on_error 'virtual_text'|'notify'|'silent' How to display render errors
---@field nowrap boolean Set nowrap + virtualedit=all on markdown windows for horizontal scrolling
local default_config = {
  cmd = { 'termaid' },
  enabled = true,
  debounce_ms = 300,
  on_error = 'virtual_text',
  nowrap = true,
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

  vim.api.nvim_create_user_command('MermaidToggleAll', function()
    M.toggle_all()
  end, { desc = 'Toggle all mermaid blocks between preview and source' })

  vim.api.nvim_create_user_command('MermaidFloat', function()
    M.float_block()
  end, { desc = 'Open mermaid block under cursor in a floating window' })

  if M.config.enabled then
    local group = vim.api.nvim_create_augroup('MermaidNvim', { clear = true })

    vim.api.nvim_create_autocmd({ 'FileType' }, {
      group = group,
      pattern = 'markdown',
      callback = function(ev)
        M.attach(ev.buf)
      end,
    })

    vim.api.nvim_create_autocmd('BufWinEnter', {
      group = group,
      callback = function(ev)
        if vim.bo[ev.buf].filetype == 'markdown' then
          M.attach(ev.buf)
        end
      end,
    })

    -- Attach all markdown buffers that already exist.
    -- The current buffer may have changed (e.g. Telescope) by the time
    -- setup runs, so scan all loaded buffers.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'markdown' then
        M.attach(buf)
      end
    end
  end
end

---@param buf integer
function M.attach(buf)
  if M.attached_bufs[buf] then
    return
  end
  M.attached_bufs[buf] = true

  -- Set nowrap for markdown so virt_lines_overflow="scroll" works
  -- Set virtualedit=all so cursor can move past line ends to scroll to wide diagrams
  -- Set smoothscroll so Ctrl-e/Ctrl-y scroll through tall diagrams line by line
  if M.config.nowrap then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win].wrap = false
      vim.wo[win].virtualedit = 'all'
      vim.wo[win].smoothscroll = true
    end
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

function M.toggle_all()
  local buf = vim.api.nvim_get_current_buf()
  local blocks = scanner.find_blocks(buf)
  if #blocks == 0 then
    vim.notify('[mermaid-nvim] No mermaid blocks found', vim.log.levels.WARN)
    return
  end

  -- If any block is in preview mode, switch all to source; otherwise switch all to preview
  local any_previewed = false
  local buf_source = M.source_blocks[buf] or {}
  for _, block in ipairs(blocks) do
    if not buf_source[block.start_row] then
      any_previewed = true
      break
    end
  end

  if not M.source_blocks[buf] then
    M.source_blocks[buf] = {}
  end

  if any_previewed then
    -- Switch all to source
    renderer.clear_all(buf)
    for _, block in ipairs(blocks) do
      M.source_blocks[buf][block.start_row] = true
    end
  else
    -- Switch all to preview
    M.source_blocks[buf] = {}
    for _, block in ipairs(blocks) do
      renderer.render_block(buf, block, M.config)
    end
  end
end

function M.float_block()
  local buf = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blocks = scanner.find_blocks(buf)

  for _, block in ipairs(blocks) do
    if cursor_row >= block.start_row and cursor_row <= block.end_row then
      local content_hash = cache.hash(block.source, M.config.cmd)
      local cached = cache.get(content_hash)
      if cached then
        renderer.open_float(cached)
      else
        -- Render first, then open float
        local env = vim.fn.environ()
        env.PYTHONIOENCODING = 'utf-8'
        vim.system(vim.deepcopy(M.config.cmd), {
          stdin = block.source,
          text = true,
          env = env,
        }, function(result)
          vim.schedule(function()
            if result.code == 0 and result.stdout and result.stdout ~= '' then
              local output = result.stdout:gsub('\n$', '')
              cache.set(content_hash, output)
              renderer.open_float(output)
            else
              vim.notify('[mermaid-nvim] Render error', vim.log.levels.ERROR)
            end
          end)
        end)
      end
      return
    end
  end

  vim.notify('[mermaid-nvim] No mermaid block under cursor', vim.log.levels.WARN)
end

return M
