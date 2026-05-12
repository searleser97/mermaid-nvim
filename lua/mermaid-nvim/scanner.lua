local M = {}

---@class mermaid.Block
---@field start_row integer 0-indexed row of the opening marker
---@field end_row integer 0-indexed row of the closing marker
---@field content_start integer 0-indexed row of first content line
---@field content_end integer 0-indexed row of last content line
---@field source string The mermaid diagram source text
---@field marker 'fence'|'container' Whether it's ```mermaid or :::mermaid

local opening_patterns = {
  { capture = '^%s*(```+)%s*mermaid%s*$', closing_capture = '^%s*(```+)%s*$', marker = 'fence' },
  { capture = '^%s*(:::+)%s*mermaid%s*$', closing_capture = '^%s*(:::+)%s*$', marker = 'container' },
}

---Find all mermaid blocks in a buffer
---@param buf integer
---@return mermaid.Block[]
function M.find_blocks(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local blocks = {}
  local i = 1

  while i <= #lines do
    local line = lines[i]
    for _, spec in ipairs(opening_patterns) do
      local marker_match = line:match(spec.capture)
      if marker_match then
        -- Require closing marker with at least the same number of marker chars
        local marker_len = #marker_match
        local close_row = nil
        for j = i + 1, #lines do
          local close_match = lines[j]:match(spec.closing_capture)
          if close_match and #close_match >= marker_len then
            close_row = j
            break
          end
        end

        if close_row then
          local content_lines = {}
          for k = i + 1, close_row - 1 do
            content_lines[#content_lines + 1] = lines[k]
          end

          blocks[#blocks + 1] = {
            start_row = i - 1, -- 0-indexed
            end_row = close_row - 1, -- 0-indexed
            content_start = i, -- 0-indexed (line after opening)
            content_end = close_row - 2, -- 0-indexed (line before closing)
            source = table.concat(content_lines, '\n'),
            marker = spec.marker,
          }
          i = close_row + 1
          goto continue
        end
      end
    end
    i = i + 1
    ::continue::
  end

  return blocks
end

return M
