local scanner = require('mermaid-nvim.scanner')
local renderer = require('mermaid-nvim.renderer')
local cache = require('mermaid-nvim.cache')

local M = {}

---@class mermaid.Config
---@field cmd string[] Command to run for rendering. Use { 'termaid' } for ASCII or { 'mmdc' } for image output.
---@field enabled boolean Whether to attach to markdown buffers (buttons, keymaps, auto-render)
---@field preview_mode 'tab'|'float' Whether to open diagrams in a new tab or a floating window
---@field exclude_bufs string[] Buffer names to exclude from mermaid-nvim (no window settings or rendering)
---@field shorten_labels boolean Replace long node labels with short IDs and show a legend above the diagram
---@field render_inline_on_open boolean Whether to render diagrams inline when the buffer is opened
---@field float_initial_view_centered boolean Whether to center the viewport in the float window on open
---@field float_scroll_step_horizontal integer Number of columns to scroll per arrow key press in float
---@field float_scroll_step_vertical integer Number of lines to scroll per arrow key press in float
---@field inline_render_delay_ms integer Delay in ms after typing stops before re-rendering inline diagrams
---@field on_error 'virtual_text'|'notify'|'silent' How to display render errors
local default_config = {
  cmd = { 'termaid' },
  enabled = true,
  preview_mode = 'tab',
  exclude_bufs = {},
  shorten_labels = false,
  render_inline_on_open = true,
  float_initial_view_centered = true,
  float_scroll_step_horizontal = 6,
  float_scroll_step_vertical = 6,
  inline_render_delay_ms = 300,
  on_error = 'virtual_text',
}

-- Commands that produce image output (PNG) instead of text
local image_commands = { mmdc = true }

---@type mermaid.Config
M.config = vim.deepcopy(default_config)

---@type table<integer, boolean> bufnr -> toggled blocks exist
M.attached_bufs = {}

---@type table<integer, table<integer, boolean>> buf -> { start_row -> true } for blocks in source mode
M.source_blocks = {}

--- Returns true if the current cmd produces image output
---@return boolean
function M.is_image_mode()
  local cmd_name = vim.fn.fnamemodify(M.config.cmd[1], ':t'):gsub('%.exe$', '')
  return image_commands[cmd_name] == true
end

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

  -- Check if buffer name matches any exclusion
  local buf_name = vim.api.nvim_buf_get_name(buf)
  for _, pattern in ipairs(M.config.exclude_bufs) do
    if buf_name:find(pattern, 1, true) then
      return
    end
  end

  M.attached_bufs[buf] = true

  local group = vim.api.nvim_create_augroup('MermaidNvim_' .. buf, { clear = true })

  local timer = vim.uv.new_timer()

  local function debounced_render()
    timer:stop()
    timer:start(M.config.inline_render_delay_ms, 0, vim.schedule_wrap(function()
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

  -- Buffer-local <CR> and double-click: open float if on a mermaid block
  local function try_open_float()
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local blocks = scanner.find_blocks(buf)
    for _, block in ipairs(blocks) do
      if cursor_row >= block.start_row and cursor_row <= block.end_row then
        M.float_block()
        return true
      end
    end
    return false
  end

  vim.keymap.set('n', '<CR>', function()
    if not try_open_float() then
      local key = vim.api.nvim_replace_termcodes('<CR>', true, false, true)
      vim.api.nvim_feedkeys(key, 'n', false)
    end
  end, { buffer = buf, desc = 'Open mermaid diagram in float or default <CR>' })

  vim.keymap.set('n', '<LeftRelease>', function()
    -- Only trigger on the opening fence line (where the button is)
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local blocks = scanner.find_blocks(buf)
    for _, block in ipairs(blocks) do
      if cursor_row == block.start_row then
        M.float_block()
        return
      end
    end
    local key = vim.api.nvim_replace_termcodes('<LeftRelease>', true, false, true)
    vim.api.nvim_feedkeys(key, 'n', false)
  end, { buffer = buf, desc = 'Open mermaid diagram in float on click' })

  -- Initial render
  if not M.config.render_inline_on_open then
    -- Mark all blocks as source-only (no inline diagram), but still place buttons
    M.source_blocks[buf] = {}
    local blocks = scanner.find_blocks(buf)
    for _, block in ipairs(blocks) do
      M.source_blocks[buf][block.start_row] = true
      renderer.set_button(buf, block)
    end
  else
    M.render_buf(buf)
  end
end

---@param buf integer
function M.render_buf(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf

  -- Clear all existing extmarks then re-render (handles moved/deleted blocks)
  renderer.clear_all(buf)

  local blocks = scanner.find_blocks(buf)
  local buf_source = M.source_blocks[buf] or {}

  for _, block in ipairs(blocks) do
    renderer.set_button(buf, block)
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

---@param shorten_override boolean|nil Override shorten_labels for this render (nil = use config)
function M.float_block(shorten_override)
  local buf = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local blocks = scanner.find_blocks(buf)
  local use_tab = M.config.preview_mode == 'tab'
  local shortener = require('mermaid-nvim.label_shortener')

  local use_shorten = shorten_override
  if use_shorten == nil then
    use_shorten = M.config.shorten_labels
  end

  for _, block in ipairs(blocks) do
    if cursor_row >= block.start_row and cursor_row <= block.end_row then
      -- Build toggle callback that replaces content in the existing preview buffer
      local function on_toggle_shorten(preview_buf, preview_win)
        local alt_shorten = not use_shorten
        local alt_source = block.source
        local alt_legend = nil

        if alt_shorten then
          local alt_result, alt_warning = shortener.shorten(block.source)
          if alt_warning and M.config.on_error ~= 'silent' then
            vim.notify('[mermaid-nvim] ' .. alt_warning, vim.log.levels.WARN)
          end
          if alt_result then
            alt_source = alt_result.source
            alt_legend = shortener.format_legend(alt_result.mappings)
          end
        end

        local alt_hash = cache.hash(alt_source, M.config.cmd)
        local alt_cached = cache.get(alt_hash)

        local function apply_output(output)
          if alt_legend then
            output = table.concat(alt_legend, '\n') .. '\n\n' .. output
          end
          renderer.replace_content(preview_buf, preview_win, output, M.config)
          -- Flip the toggle state for next press
          use_shorten = alt_shorten
        end

        if alt_cached then
          apply_output(alt_cached)
        else
          -- Show loading feedback in the buffer
          renderer.replace_content(preview_buf, preview_win, '⏳ Rendering...', M.config)

          local env = vim.fn.environ()
          env.PYTHONIOENCODING = 'utf-8'
          vim.system(vim.deepcopy(M.config.cmd), {
            stdin = alt_source,
            text = true,
            env = env,
          }, function(result)
            vim.schedule(function()
              if result.code == 0 and result.stdout and result.stdout ~= '' then
                local output = result.stdout:gsub('\n$', '')
                cache.set(alt_hash, output)
                apply_output(output)
              else
                vim.notify('[mermaid-nvim] Render error', vim.log.levels.ERROR)
              end
            end)
          end)
        end
      end

      -- Apply label shortening if enabled
      local render_source = block.source
      local legend_lines = nil
      if use_shorten then
        local result, warning = shortener.shorten(block.source)
        if warning then
          if M.config.on_error ~= 'silent' then
            vim.notify('[mermaid-nvim] ' .. warning, vim.log.levels.WARN)
          end
        end
        if result then
          render_source = result.source
          legend_lines = shortener.format_legend(result.mappings)
        end
      end

      -- Image renderer path
      if M.is_image_mode() then
        local image_renderer = require('mermaid-nvim.image_renderer')
        if not image_renderer.is_available() then
          vim.notify('[mermaid-nvim] Image display not available', vim.log.levels.ERROR)
          return
        end
        renderer.set_button_loading(buf, block)
        if use_tab then
          image_renderer.open_tab(render_source, M.config)
        else
          image_renderer.open_float(render_source, M.config)
        end
        vim.defer_fn(function()
          renderer.set_button(buf, block)
        end, 500)
        return
      end

      -- Text renderer path
      local content_hash = cache.hash(render_source, M.config.cmd)
      local cached = cache.get(content_hash)
      if cached then
        local output = cached
        if legend_lines then
          output = table.concat(legend_lines, '\n') .. '\n\n' .. output
        end
        if use_tab then
          renderer.open_tab(output, M.config, on_toggle_shorten)
        else
          renderer.open_float(output, M.config, on_toggle_shorten)
        end
      else
        renderer.set_button_loading(buf, block)
        local env = vim.fn.environ()
        env.PYTHONIOENCODING = 'utf-8'
        vim.system(vim.deepcopy(M.config.cmd), {
          stdin = render_source,
          text = true,
          env = env,
        }, function(result)
          vim.schedule(function()
            renderer.set_button(buf, block)
            if result.code == 0 and result.stdout and result.stdout ~= '' then
              local output = result.stdout:gsub('\n$', '')
              cache.set(content_hash, output)
              if legend_lines then
                output = table.concat(legend_lines, '\n') .. '\n\n' .. output
              end
              if use_tab then
                renderer.open_tab(output, M.config, on_toggle_shorten)
              else
                renderer.open_float(output, M.config, on_toggle_shorten)
              end
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
