local cache = require('mermaid-nvim.cache')

local M = {}

local ns = vim.api.nvim_create_namespace('mermaid_nvim')
local ns_button = vim.api.nvim_create_namespace('mermaid_nvim_buttons')

-- Button highlight: use reverse of a theme color for visibility
vim.api.nvim_set_hl(0, 'MermaidButton', { link = 'Search' })

---Render a single mermaid block
---@param buf integer
---@param block mermaid.Block
---@param config mermaid.Config
function M.render_block(buf, block, config)
  -- Detect image mode from command name
  local cmd_name = vim.fn.fnamemodify(config.cmd[1], ':t'):gsub('%.exe$', '')
  local is_image = ({ mmdc = true })[cmd_name]

  if is_image then
    local image_renderer = require('mermaid-nvim.image_renderer')
    image_renderer.render_inline(buf, block, config)
    return
  end

  -- Apply label shortening if enabled
  local render_source = block.source
  local legend_lines = nil
  if config.shorten_labels then
    local shortener = require('mermaid-nvim.label_shortener')
    local result, warning = shortener.shorten(block.source)
    if warning and config.on_error == 'notify' then
      vim.notify('[mermaid-nvim] ' .. warning, vim.log.levels.WARN)
    end
    if result then
      render_source = result.source
      legend_lines = shortener.format_legend(result.mappings)
    end
  end

  local content_hash = cache.hash(render_source, config.cmd)
  local cached = cache.get(content_hash)

  if cached then
    M.apply_extmarks(buf, block, cached, legend_lines)
    return
  end

  M.render_async(buf, block, config, content_hash, render_source, legend_lines)
end

---@param buf integer
---@param block mermaid.Block
---@param config mermaid.Config
---@param content_hash string
---@param render_source string
---@param legend_lines string[]|nil
function M.render_async(buf, block, config, content_hash, render_source, legend_lines)
  -- Set PYTHONIOENCODING for tools like termaid that output Unicode
  local env = vim.fn.environ()
  env.PYTHONIOENCODING = 'utf-8'

  local cmd = vim.deepcopy(config.cmd)

  vim.system(cmd, {
    stdin = render_source,
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
      M.apply_extmarks(buf, block, output, legend_lines)
    end)
  end)
end

---Apply extmarks to show ASCII art below the block
---@param buf integer
---@param block mermaid.Block
---@param ascii_output string
---@param legend_lines string[]|nil
function M.apply_extmarks(buf, block, ascii_output, legend_lines)
  -- Clear existing marks for this block
  M.clear_block(buf, block)

  local ascii_lines = vim.split(ascii_output, '\n')

  -- Build virtual lines for the ASCII diagram (with right padding)
  local padding = string.rep(' ', 4)
  local virt_lines = {}

  -- Prepend legend if available
  if legend_lines and #legend_lines > 0 then
    for _, lline in ipairs(legend_lines) do
      virt_lines[#virt_lines + 1] = { { lline .. padding, 'DiagnosticInfo' } }
    end
    virt_lines[#virt_lines + 1] = { { '', 'Normal' } } -- blank separator
  end

  for _, line in ipairs(ascii_lines) do
    virt_lines[#virt_lines + 1] = { { line .. padding, 'Comment' } }
  end

  -- Show ASCII art above the block
  vim.api.nvim_buf_set_extmark(buf, ns, block.start_row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = true,
    virt_lines_overflow = 'scroll',
  })

  -- Show button (separate namespace, survives toggle)
  M.set_button(buf, block)
end

---Place the expand button on a block's opening fence line
---@param buf integer
---@param block mermaid.Block
function M.set_button(buf, block)
  M._set_button_text(buf, block.start_row, ' ⛶ Expand Diagram ')
end

---Show loading state on a block's button
---@param buf integer
---@param block mermaid.Block
function M.set_button_loading(buf, block)
  M._set_button_text(buf, block.start_row, ' ⏳ Loading... ')
end

---@param buf integer
---@param row integer
---@param text string
function M._set_button_text(buf, row, text)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns_button, { row, 0 }, { row, -1 }, {})
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(buf, ns_button, mark[1])
  end
  vim.api.nvim_buf_set_extmark(buf, ns_button, row, 0, {
    virt_text = {
      { '  ', 'Normal' },
      { text, 'MermaidButton' },
    },
    virt_text_pos = 'eol',
  })
end

---Open a mermaid diagram in a scrollable floating window
---@param ascii_output string

--- Replace buffer content in-place and re-center
---@param buf integer
---@param win integer
---@param new_output string
---@param opts mermaid.Config
function M.replace_content(buf, win, new_output, opts)
  local lines = vim.split(new_output, '\n')
  local max_width = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max_width then max_width = w end
  end

  local win_width = vim.api.nvim_win_get_width(win)
  local win_height = vim.api.nvim_win_get_height(win)

  -- Center content horizontally by padding
  local should_center = opts and opts.float_initial_view_centered ~= nil and opts.float_initial_view_centered or true
  if should_center and max_width < win_width then
    local pad = string.rep(' ', math.floor((win_width - max_width) / 2))
    for i, line in ipairs(lines) do
      lines[i] = pad .. line
    end
  end

  -- Center content vertically by prepending empty lines
  if should_center and #lines < win_height then
    local top_pad = math.floor((win_height - #lines) / 2)
    for _ = 1, top_pad do
      table.insert(lines, 1, '')
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Re-center view
  if max_width > win_width then
    local center_col = math.max(0, math.floor((max_width - win_width) / 2))
    local cursor_col = math.min(center_col + math.floor(win_width / 2), max_width - 1)
    local cursor_row = math.min(math.max(1, math.floor(#lines / 2)), #lines)
    vim.fn.winrestview({ leftcol = center_col, topline = 1 })
    vim.api.nvim_win_set_cursor(win, { cursor_row, cursor_col })
  else
    local cursor_row = math.min(math.max(1, math.floor(#lines / 2)), #lines)
    vim.api.nvim_win_set_cursor(win, { cursor_row, 0 })
    vim.fn.winrestview({ leftcol = 0, topline = 1 })
  end
end

--- Setup preview window keymaps, settings, and centering
---@param buf integer Buffer handle
---@param win integer Window handle
---@param lines string[] Content lines
---@param max_width integer Max display width of content
---@param opts mermaid.Config
local function setup_preview_window(buf, win, lines, max_width, opts)
  local win_width = vim.api.nvim_win_get_width(win)
  local win_height = vim.api.nvim_win_get_height(win)

  -- Window settings
  vim.wo[win].wrap = false
  vim.wo[win].virtualedit = 'all'

  -- Navigation keymaps
  local h_step = (opts and opts.float_scroll_step_horizontal) or 6
  local v_step = (opts and opts.float_scroll_step_vertical) or 6
  vim.keymap.set('n', '<Left>', function() vim.cmd('normal! ' .. h_step .. 'zh') end, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Right>', function() vim.cmd('normal! ' .. h_step .. 'zl') end, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Up>', function()
    local keys = vim.api.nvim_replace_termcodes(v_step .. '<C-y>', true, false, true)
    vim.api.nvim_feedkeys(keys, 'nx', false)
  end, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Down>', function()
    local keys = vim.api.nvim_replace_termcodes(v_step .. '<C-e>', true, false, true)
    vim.api.nvim_feedkeys(keys, 'nx', false)
  end, { buffer = buf, nowait = true })
  vim.keymap.set('n', 'H', function() vim.fn.winrestview({ leftcol = 0 }) end, { buffer = buf, nowait = true })
  vim.keymap.set('n', 'L', function() vim.fn.winrestview({ leftcol = math.max(0, max_width - win_width) }) end, { buffer = buf, nowait = true })
  vim.keymap.set('n', '0', function() vim.fn.winrestview({ leftcol = 0 }) end, { buffer = buf, nowait = true })
  vim.keymap.set('n', 'c', function()
    local center_col = math.max(0, math.floor((max_width - win_width) / 2))
    local center_line = math.max(1, math.floor((#lines - win_height) / 2) + 1)
    local mid_line = math.max(1, math.floor(#lines / 2))
    local mid_col = math.max(0, math.floor(max_width / 2))
    vim.api.nvim_win_set_cursor(win, { mid_line, mid_col })
    vim.fn.winrestview({ leftcol = center_col, topline = center_line })
  end, { buffer = buf, nowait = true })

  local function center_top()
    local cur_win_width = vim.api.nvim_win_get_width(win)
    local cur_win_height = vim.api.nvim_win_get_height(win)
    if max_width > cur_win_width then
      local center_col = math.max(0, math.floor((max_width - cur_win_width) / 2))
      -- Place cursor in the visible center area so Neovim doesn't snap the view
      local cursor_col = math.min(center_col + math.floor(cur_win_width / 2), max_width - 1)
      local cursor_row = math.min(math.floor(cur_win_height / 2), #lines)
      vim.fn.winrestview({ leftcol = center_col, topline = 1 })
      vim.api.nvim_win_set_cursor(win, { math.max(1, cursor_row), cursor_col })
    else
      -- Content fits horizontally — just center cursor on content
      local cursor_col = math.floor(max_width / 2)
      local cursor_row = math.min(math.max(1, math.floor(#lines / 2)), #lines)
      vim.api.nvim_win_set_cursor(win, { cursor_row, cursor_col })
      vim.fn.winrestview({ leftcol = 0, topline = 1 })
    end
  end

  vim.keymap.set('n', 't', center_top, { buffer = buf, nowait = true })

  -- Apply initial centering
  local should_center = opts and opts.float_initial_view_centered ~= nil and opts.float_initial_view_centered or true
  if should_center then
    center_top()
  end
end

--- Open a mermaid diagram in a floating window (text/ASCII output)
---@param ascii_output string
---@param opts mermaid.Config
---@param on_toggle_shorten function|nil Callback to re-render with toggled shorten_labels
function M.open_float(ascii_output, opts, on_toggle_shorten)
  local lines = vim.split(ascii_output, '\n')

  -- Calculate float dimensions
  local max_width = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max_width then max_width = w end
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - vim.o.cmdheight - 1
  local float_width = math.min(max_width + 2, editor_width - 4)
  local float_height = math.min(#lines, editor_height - 4)

  -- Center content horizontally by padding lines
  local float_center = opts and opts.float_initial_view_centered ~= nil and opts.float_initial_view_centered or true
  if float_center and max_width < float_width then
    local pad = string.rep(' ', math.floor((float_width - max_width) / 2))
    for i, line in ipairs(lines) do
      lines[i] = pad .. line
    end
  end

  -- Create scratch buffer with diagram content
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false
  vim.bo[float_buf].bufhidden = 'wipe'
  vim.bo[float_buf].filetype = 'mermaid-preview'

  -- Open centered floating window
  local row = math.floor((editor_height - float_height - 2) / 2)
  local col = math.floor((editor_width - float_width - 2) / 2)
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

  -- Toggle shorten_labels with 's' — replaces content in-place
  if on_toggle_shorten then
    vim.keymap.set('n', 's', function()
      on_toggle_shorten(float_buf, win)
    end, { buffer = float_buf, nowait = true })
  end

  setup_preview_window(float_buf, win, lines, max_width, opts)
end

--- Open a mermaid diagram in a new tab (text/ASCII output)
---@param ascii_output string
---@param opts mermaid.Config
---@param on_toggle_shorten function|nil Callback that returns new content string (or nil)
function M.open_tab(ascii_output, opts, on_toggle_shorten)
  local lines = vim.split(ascii_output, '\n')

  -- Calculate content dimensions
  local max_width = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max_width then max_width = w end
  end

  vim.cmd('tabnew')
  local tab_buf = vim.api.nvim_get_current_buf()
  local tab_win = vim.api.nvim_get_current_win()
  local tab_width = vim.api.nvim_win_get_width(tab_win)

  -- Center content horizontally by padding lines
  local should_center = opts and opts.float_initial_view_centered ~= nil and opts.float_initial_view_centered or true
  if should_center and max_width < tab_width then
    local pad = string.rep(' ', math.floor((tab_width - max_width) / 2))
    for i, line in ipairs(lines) do
      lines[i] = pad .. line
    end
  end

  -- Center content vertically by prepending empty lines
  local tab_height = vim.api.nvim_win_get_height(tab_win)
  if should_center and #lines < tab_height then
    local top_pad = math.floor((tab_height - #lines) / 2)
    for _ = 1, top_pad do
      table.insert(lines, 1, '')
    end
  end

  vim.bo[tab_buf].bufhidden = 'wipe'
  vim.bo[tab_buf].buftype = 'nofile'
  vim.bo[tab_buf].filetype = 'mermaid-preview'

  vim.api.nvim_buf_set_lines(tab_buf, 0, -1, false, lines)
  vim.bo[tab_buf].modifiable = false

  -- Close with q or Esc
  local function close()
    if vim.api.nvim_buf_is_valid(tab_buf) then
      vim.cmd('bwipeout! ' .. tab_buf)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = tab_buf, nowait = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = tab_buf, nowait = true })

  -- Toggle shorten_labels with 's' — replaces content in-place
  if on_toggle_shorten then
    vim.keymap.set('n', 's', function()
      on_toggle_shorten(tab_buf, tab_win)
    end, { buffer = tab_buf, nowait = true })
  end

  setup_preview_window(tab_buf, tab_win, lines, max_width, opts)
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
  -- Also clear inline images if image renderer was used
  local ok, image_renderer = pcall(require, 'mermaid-nvim.image_renderer')
  if ok then
    image_renderer.clear_inline(buf)
  end
end

return M
