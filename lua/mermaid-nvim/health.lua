local M = {}

function M.check()
  vim.health.start('mermaid-nvim')

  local config = require('mermaid-nvim').config
  local cmd = config.cmd[1]

  if vim.fn.executable(cmd) == 1 then
    vim.health.ok(('Renderer found: `%s`'):format(cmd))
  else
    vim.health.error(
      ('Renderer not found: `%s`'):format(cmd),
      {
        ('Install it: pip install %s'):format(cmd),
        'Or configure a different renderer in setup({ cmd = { "your-tool" } })',
      }
    )
  end

  -- Check if render-markdown.nvim is installed and configured
  local has_render_md = pcall(require, 'render-markdown')
  if has_render_md then
    vim.health.info(
      'render-markdown.nvim detected. Recommend adding to its config: code = { disable = { "mermaid" } }'
    )
  end
end

return M
