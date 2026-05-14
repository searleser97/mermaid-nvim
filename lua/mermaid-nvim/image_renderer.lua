local M = {}

--- Check if we can send escape sequences to the terminal
---@return boolean
function M.is_available()
  return true
end

--- Render mermaid source to a PNG file using mmdc
---@param source string Mermaid diagram source
---@param opts { cmd: string[], width?: integer, height?: integer, scale?: number, theme?: string, background?: string }
---@param callback fun(png_path: string|nil, err: string|nil)
function M.render_to_png(source, opts, callback)
  local tmp_input = vim.fn.tempname() .. '.mmd'
  local tmp_output = vim.fn.tempname() .. '.png'

  local f = io.open(tmp_input, 'w')
  if not f then
    callback(nil, 'Failed to create temp input file')
    return
  end
  f:write(source)
  f:close()

  local cmd = vim.deepcopy(opts.cmd or { 'mmdc' })
  vim.list_extend(cmd, { '-i', tmp_input, '-o', tmp_output, '-e', 'png' })

  if opts.width then
    vim.list_extend(cmd, { '--width', tostring(opts.width) })
  end
  if opts.height then
    vim.list_extend(cmd, { '--height', tostring(opts.height) })
  end
  if opts.scale then
    vim.list_extend(cmd, { '--scale', tostring(opts.scale) })
  end
  if opts.theme then
    vim.list_extend(cmd, { '--theme', opts.theme })
  end
  if opts.background then
    vim.list_extend(cmd, { '--backgroundColor', opts.background })
  end

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      os.remove(tmp_input)

      if result.code ~= 0 then
        os.remove(tmp_output)
        local err = result.stderr or 'mmdc failed with exit code ' .. tostring(result.code)
        callback(nil, err)
      else
        callback(tmp_output, nil)
      end
    end)
  end)
end

--- Display a PNG using iTerm2 inline images protocol (OSC 1337)
--- Supported by WezTerm, iTerm2, and other terminals
---@param png_path string Path to PNG file
---@param opts? { width?: integer, height?: integer } Size in terminal cells
---@return boolean success
function M.display_iterm2(png_path, opts)
  local file = io.open(png_path, 'rb')
  if not file then return false end
  local data = file:read('*all')
  file:close()

  local encoded = vim.base64.encode(data)

  local params = 'inline=1;preserveAspectRatio=1'
  if opts and opts.width then
    params = params .. ';width=' .. opts.width
  end
  if opts and opts.height then
    params = params .. ';height=' .. opts.height
  end

  vim.api.nvim_chan_send(2, '\x1b]1337;File=' .. params .. ':' .. encoded .. '\x07')
  return true
end

--- Open a mermaid diagram as an image in a floating window
---@param source string Mermaid diagram source
---@param config table Plugin config
function M.open_float(source, config)
  local cmd_name = config.cmd[1]
  if vim.fn.executable(cmd_name) ~= 1 then
    vim.notify('[mermaid-nvim] Command not found: ' .. cmd_name .. '. Is it in your PATH?', vim.log.levels.ERROR)
    return
  end

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - vim.o.cmdheight - 1

  local float_width = math.floor(editor_width * 0.8)
  local float_height = math.floor(editor_height * 0.8)

  -- Create float buffer and window
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].bufhidden = 'wipe'
  vim.bo[float_buf].buftype = 'nofile'
  vim.bo[float_buf].filetype = 'mermaid-image-preview'

  local empty_lines = {}
  for i = 1, float_height do
    empty_lines[i] = ''
  end
  local msg_line = math.floor(float_height / 2)
  empty_lines[msg_line] = string.rep(' ', math.floor(float_width / 2) - 10) .. '⏳ Rendering diagram...'
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, empty_lines)
  vim.bo[float_buf].modifiable = false

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

  -- Close keymaps
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  vim.keymap.set('n', 'q', close, { buffer = float_buf, nowait = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = float_buf, nowait = true })

  -- Render mermaid to PNG
  local pixel_width = float_width * 16
  local render_opts = {
    cmd = config.cmd,
    width = pixel_width,
    scale = 2,
    background = 'transparent',
  }

  M.render_to_png(source, render_opts, function(png_path, err)
    if err then
      if vim.api.nvim_win_is_valid(win) then
        vim.bo[float_buf].modifiable = true
        local err_lines = { '', '  ⚠ Render error:', '' }
        for line in err:gmatch('[^\n]+') do
          table.insert(err_lines, '  ' .. line)
        end
        vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, err_lines)
        vim.bo[float_buf].modifiable = false
      end
      vim.notify('[mermaid-nvim] Image render error: ' .. err, vim.log.levels.ERROR)
      return
    end

    if not vim.api.nvim_win_is_valid(win) then
      os.remove(png_path)
      return
    end

    -- Clear loading text
    vim.bo[float_buf].modifiable = true
    local empty = {}
    for i = 1, float_height do empty[i] = '' end
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, empty)
    vim.bo[float_buf].modifiable = false
    vim.cmd('redraw')

    -- Display image using iTerm2 protocol (OSC 1337)
    M.display_iterm2(png_path, { width = float_width - 4 })

    -- Clean up on close
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = float_buf,
      once = true,
      callback = function()
        os.remove(png_path)
      end,
    })
  end)
end

--- Open a mermaid diagram as an image in a new tab
---@param source string Mermaid diagram source
---@param config table Plugin config
function M.open_tab(source, config)
  local cmd_name = config.cmd[1]
  if vim.fn.executable(cmd_name) ~= 1 then
    vim.notify('[mermaid-nvim] Command not found: ' .. cmd_name .. '. Is it in your PATH?', vim.log.levels.ERROR)
    return
  end

  vim.cmd('tabnew')
  local tab_buf = vim.api.nvim_get_current_buf()
  local tab_win = vim.api.nvim_get_current_win()
  vim.bo[tab_buf].bufhidden = 'wipe'
  vim.bo[tab_buf].buftype = 'nofile'
  vim.bo[tab_buf].filetype = 'mermaid-image-preview'

  local win_width = vim.api.nvim_win_get_width(tab_win)
  local win_height = vim.api.nvim_win_get_height(tab_win)

  -- Show loading message
  local lines = {}
  for i = 1, win_height do lines[i] = '' end
  lines[math.floor(win_height / 2)] = string.rep(' ', math.floor(win_width / 2) - 10) .. '⏳ Rendering diagram...'
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

  -- Render mermaid to PNG
  local pixel_width = win_width * 16
  local render_opts = {
    cmd = config.cmd,
    width = pixel_width,
    scale = 2,
    background = 'transparent',
  }

  M.render_to_png(source, render_opts, function(png_path, err)
    if err then
      if vim.api.nvim_buf_is_valid(tab_buf) then
        vim.bo[tab_buf].modifiable = true
        local err_lines = { '', '  ⚠ Render error:', '' }
        for line in err:gmatch('[^\n]+') do
          table.insert(err_lines, '  ' .. line)
        end
        vim.api.nvim_buf_set_lines(tab_buf, 0, -1, false, err_lines)
        vim.bo[tab_buf].modifiable = false
      end
      vim.notify('[mermaid-nvim] Image render error: ' .. err, vim.log.levels.ERROR)
      return
    end

    if not vim.api.nvim_buf_is_valid(tab_buf) then
      os.remove(png_path)
      return
    end

    -- Clear loading text
    vim.bo[tab_buf].modifiable = true
    local empty = {}
    for i = 1, win_height do empty[i] = '' end
    vim.api.nvim_buf_set_lines(tab_buf, 0, -1, false, empty)
    vim.bo[tab_buf].modifiable = false
    vim.cmd('redraw')

    -- Display image using iTerm2 protocol (OSC 1337)
    -- Only constrain width; height follows aspect ratio
    M.display_iterm2(png_path, { width = win_width - 4 })

    -- Clean up on close
    vim.api.nvim_create_autocmd('BufWipeout', {
      buffer = tab_buf,
      once = true,
      callback = function()
        os.remove(png_path)
      end,
    })
  end)
end

--- Render inline (not yet supported)
---@param buf integer
---@param block table
---@param config table
function M.render_inline(buf, block, config)
  -- Not supported yet
end

--- Clear inline images for a buffer
---@param buf integer
function M.clear_inline(buf)
  -- No-op for now
end

return M
