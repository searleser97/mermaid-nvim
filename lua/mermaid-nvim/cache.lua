local M = {}

---@type table<string, string> hash -> rendered ASCII output
M.entries = {}

---Hash content + command + width to avoid stale cache
---@param content string
---@param cmd string[]
---@param width integer
---@return string
function M.hash(content, cmd, width)
  return vim.fn.sha256(table.concat(cmd, '\0') .. '\0' .. tostring(width) .. '\0' .. content)
end

---Get cached render output
---@param content_hash string
---@return string|nil
function M.get(content_hash)
  return M.entries[content_hash]
end

---Store render output in cache
---@param content_hash string
---@param output string
function M.set(content_hash, output)
  M.entries[content_hash] = output
end

---Clear cache entries for a buffer (no-op; cache is content-addressed)
---@param buf integer
function M.clear_buf(buf)
end

---Clear entire cache
function M.clear()
  M.entries = {}
end

return M
