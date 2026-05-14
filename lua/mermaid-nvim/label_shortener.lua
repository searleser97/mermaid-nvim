local M = {}

--- Minimum label length to be shortened (shorter labels are kept as-is)
local MIN_LABEL_LENGTH = 4

--- Generate short IDs: A, B, ..., Z, AA, AB, ...
---@param index integer 1-based
---@return string
local function generate_id(index)
  if index <= 26 then
    return string.char(64 + index) -- A=1, B=2, ...
  end
  local first = math.floor((index - 1) / 26)
  local second = ((index - 1) % 26) + 1
  return string.char(64 + first) .. string.char(64 + second)
end

--- Detect diagram type from mermaid source
---@param source string
---@return 'flowchart'|'sequence'|'unsupported'
local function detect_type(source)
  for line in source:gmatch('[^\n]+') do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed ~= '' and not trimmed:match('^%%%%') then
      if trimmed:match('^graph%s') or trimmed:match('^graph$') or
         trimmed:match('^flowchart%s') or trimmed:match('^flowchart$') then
        return 'flowchart'
      elseif trimmed:match('^sequenceDiagram') then
        return 'sequence'
      else
        return 'unsupported'
      end
    end
  end
  return 'unsupported'
end

--- Flowchart node shape delimiters (opening -> closing)
local flowchart_shapes = {
  { open = '%[%[', close = '%]%]', open_lit = '[[', close_lit = ']]' },
  { open = '%[%(', close = '%)%]', open_lit = '[(', close_lit = ')]' },
  { open = '%[%/', close = '%/%]', open_lit = '[/', close_lit = '/]' },
  { open = '%[\\', close = '\\%]', open_lit = '[\\', close_lit = '\\]' },
  { open = '%[%/', close = '\\%]', open_lit = '[/', close_lit = '\\]' },
  { open = '%[\\', close = '%/%]', open_lit = '[\\', close_lit = '/]' },
  { open = '%(%(', close = '%)%)', open_lit = '((', close_lit = '))' },
  { open = '%(%[', close = '%]%)', open_lit = '([', close_lit = '])' },
  { open = '{{', close = '}}', open_lit = '{{', close_lit = '}}' },
  { open = '%[', close = '%]', open_lit = '[', close_lit = ']' },
  { open = '%(', close = '%)', open_lit = '(', close_lit = ')' },
  { open = '{', close = '}', open_lit = '{', close_lit = '}' },
  { open = '>', close = '%]', open_lit = '>', close_lit = ']' },
}

--- Try to extract a node declaration from a flowchart line segment
---@param segment string A portion of a line (before any arrow)
---@return string|nil id The node ID
---@return string|nil label The label text
---@return string|nil full_match The full matched text
---@return table|nil shape The shape spec used
local function extract_flowchart_node(segment)
  for _, shape in ipairs(flowchart_shapes) do
    local pattern = '^%s*([%w_]+)%s*' .. shape.open .. '(.-)' .. shape.close
    local id, label = segment:match(pattern)
    if id and label then
      return id, label, segment, shape
    end
  end
  return nil
end

--- Process flowchart source
---@param source string
---@return table|nil result { source: string, mappings: { short: string, label: string }[] }
local function shorten_flowchart(source)
  local lines = vim.split(source, '\n')
  local mappings = {} ---@type { short: string, label: string }[]
  local id_to_short = {} ---@type table<string, string>
  local used_shorts = {} ---@type table<string, boolean>
  local next_id_index = 1

  -- First pass: collect all node IDs that exist
  for _, line in ipairs(lines) do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed == '' or trimmed:match('^%%%%') or trimmed:match('^graph') or trimmed:match('^flowchart') then
      goto continue_first
    end
    -- Split on arrows to isolate node segments
    local segments = vim.split(trimmed, '%s*%-%-%-+%s*')
    if #segments == 1 then segments = vim.split(trimmed, '%s*%-%-+>%s*') end
    if #segments == 1 then segments = vim.split(trimmed, '%s*==%s*') end
    if #segments == 1 then segments = vim.split(trimmed, '%s*%.%-%->%s*') end

    for _, seg in ipairs(segments) do
      local id = extract_flowchart_node(seg)
      if id then
        -- Reserve existing short IDs (single uppercase letters)
        if id:match('^%u$') then
          used_shorts[id] = true
        end
      end
    end
    ::continue_first::
  end

  -- Helper to get or assign a short ID for a node
  local function get_short(node_id, label)
    if id_to_short[node_id] then
      return id_to_short[node_id]
    end

    -- Skip shortening for labels that are already short
    if #label <= MIN_LABEL_LENGTH then
      id_to_short[node_id] = nil
      return nil
    end

    -- If node ID is already a single uppercase letter, use it as the short form
    if node_id:match('^%u$') then
      id_to_short[node_id] = node_id
      mappings[#mappings + 1] = { short = node_id, label = label }
      return node_id
    end

    -- Generate next available short ID
    local short
    repeat
      short = generate_id(next_id_index)
      next_id_index = next_id_index + 1
    until not used_shorts[short]
    used_shorts[short] = true

    id_to_short[node_id] = short
    mappings[#mappings + 1] = { short = short, label = label }
    return short
  end

  -- Arrow patterns to split on (order matters: longest first)
  local arrow_patterns = {
    '%-%-%-+', '%-%-+>', '==%>', '%.%-%->', '%-%.%->', '%-%-+', '==+', '%-%->',
  }

  --- Split a line into segments and arrows
  ---@param line string
  ---@return string[] segments, string[] arrows
  local function split_by_arrows(line)
    local segments = {}
    local arrows = {}
    local remaining = line

    while remaining ~= '' do
      local best_start, best_end, best_arrow = nil, nil, nil
      for _, ap in ipairs(arrow_patterns) do
        local s, e = remaining:find('%s*' .. ap .. '%s*')
        if s and (not best_start or s < best_start) then
          best_start, best_end = s, e
          best_arrow = remaining:sub(s, e)
        end
      end

      if best_start then
        segments[#segments + 1] = remaining:sub(1, best_start - 1)
        arrows[#arrows + 1] = best_arrow
        remaining = remaining:sub(best_end + 1)
      else
        segments[#segments + 1] = remaining
        break
      end
    end

    return segments, arrows
  end

  --- Try to shorten a node in a segment
  ---@param segment string
  ---@return string
  local function shorten_segment(segment)
    for _, shape in ipairs(flowchart_shapes) do
      local pattern = '^(%s*)([%w_]+)(%s*)' .. shape.open .. '(.-)' .. shape.close .. '(.*)$'
      local leading, id, space, label, trailing = segment:match(pattern)
      if id and label then
        local short = get_short(id, label)
        if short then
          return leading .. id .. space .. shape.open_lit .. short .. shape.close_lit .. trailing
        end
        return leading .. id .. space .. shape.open_lit .. label .. shape.close_lit .. trailing
      end
    end
    return segment
  end

  -- Second pass: replace labels
  local new_lines = {}
  for _, line in ipairs(lines) do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed == '' or trimmed:match('^%%%%') or trimmed:match('^graph') or trimmed:match('^flowchart') or trimmed:match('^subgraph') or trimmed:match('^end$') then
      new_lines[#new_lines + 1] = line
      goto continue_second
    end

    local segments, arrows = split_by_arrows(line)
    local new_segments = {}
    for _, seg in ipairs(segments) do
      new_segments[#new_segments + 1] = shorten_segment(seg)
    end

    -- Reassemble line with arrows
    local new_line = new_segments[1] or ''
    for i, arrow in ipairs(arrows) do
      new_line = new_line .. arrow .. (new_segments[i + 1] or '')
    end

    new_lines[#new_lines + 1] = new_line
    ::continue_second::
  end

  if #mappings == 0 then
    return nil
  end

  return { source = table.concat(new_lines, '\n'), mappings = mappings }
end

--- Process sequence diagram source
---@param source string
---@return table|nil result { source: string, mappings: { short: string, label: string }[] }
local function shorten_sequence(source)
  local lines = vim.split(source, '\n')
  local mappings = {} ---@type { short: string, label: string }[]
  local alias_to_short = {} ---@type table<string, string>
  local used_shorts = {} ---@type table<string, boolean>
  local next_id_index = 1
  local new_lines = {}

  -- First pass: reserve existing short aliases
  for _, line in ipairs(lines) do
    local trimmed = line:match('^%s*(.-)%s*$')
    local alias = trimmed:match('^participant%s+([%w_%-]+)%s+as%s+')
    if not alias then
      alias = trimmed:match('^actor%s+([%w_%-]+)%s+as%s+')
    end
    if alias and #alias <= MIN_LABEL_LENGTH then
      used_shorts[alias] = true
    end
  end

  for _, line in ipairs(lines) do
    local trimmed = line:match('^%s*(.-)%s*$')

    -- Match: participant/actor ALIAS as LABEL
    local keyword, alias, label = trimmed:match('^(participant%s+)([%w_%-]+)%s+as%s+(.+)$')
    if not keyword then
      keyword, alias, label = trimmed:match('^(actor%s+)([%w_%-]+)%s+as%s+(.+)$')
    end

    if keyword and alias and label and #label > MIN_LABEL_LENGTH then
      -- If alias is already short, keep it as the display name
      if #alias <= MIN_LABEL_LENGTH then
        alias_to_short[alias] = alias
        mappings[#mappings + 1] = { short = alias, label = label }
        -- Rewrite: participant ALIAS as SHORT
        new_lines[#new_lines + 1] = line:gsub('as%s+.+$', 'as ' .. alias)
      else
        -- Generate a new short ID
        local short
        repeat
          short = generate_id(next_id_index)
          next_id_index = next_id_index + 1
        until not used_shorts[short]
        used_shorts[short] = true

        alias_to_short[alias] = short
        mappings[#mappings + 1] = { short = short, label = label }
        new_lines[#new_lines + 1] = line:gsub('as%s+.+$', 'as ' .. short)
      end
    else
      -- Also match: participant LABEL (no alias) with long label
      local kw, name = trimmed:match('^(participant%s+)([%w_%-]+)%s*$')
      if not kw then
        kw, name = trimmed:match('^(actor%s+)([%w_%-]+)%s*$')
      end
      if kw and name and #name > MIN_LABEL_LENGTH then
        local short
        repeat
          short = generate_id(next_id_index)
          next_id_index = next_id_index + 1
        until not used_shorts[short]
        used_shorts[short] = true

        alias_to_short[name] = short
        mappings[#mappings + 1] = { short = short, label = name }
        -- Use word boundary to avoid replacing inside other words
        new_lines[#new_lines + 1] = line:gsub(name, short)
      else
        new_lines[#new_lines + 1] = line
      end
    end
  end

  if #mappings == 0 then
    return nil
  end

  -- Replace aliases in message lines (only whole-word matches)
  for i, line in ipairs(new_lines) do
    for alias, short in pairs(alias_to_short) do
      if alias ~= short then
        -- Use pattern with word boundaries to avoid replacing inside other words
        new_lines[i] = new_lines[i]:gsub('(%f[%w_])' .. vim.pesc(alias) .. '(%f[^%w_])', '%1' .. short .. '%2')
      end
    end
  end

  return { source = table.concat(new_lines, '\n'), mappings = mappings }
end

--- Shorten labels in a mermaid diagram
---@param source string The mermaid diagram source
---@return table|nil result { source: string, mappings: { short: string, label: string }[] }
---@return string|nil warning Warning message if diagram type is unsupported
function M.shorten(source)
  local dtype = detect_type(source)

  if dtype == 'flowchart' then
    local result = shorten_flowchart(source)
    if not result then
      return nil, nil -- no labels to shorten, just render as-is
    end
    return result, nil
  elseif dtype == 'sequence' then
    local result = shorten_sequence(source)
    if not result then
      return nil, nil
    end
    return result, nil
  else
    return nil, 'shorten_labels: unsupported diagram type (only flowchart and sequence are supported)'
  end
end

--- Format mappings as legend lines
---@param mappings { short: string, label: string }[]
---@return string[]
function M.format_legend(mappings)
  local lines = {}
  for _, m in ipairs(mappings) do
    lines[#lines + 1] = '  ' .. m.short .. ': ' .. m.label
  end
  return lines
end

return M
