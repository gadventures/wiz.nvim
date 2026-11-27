---@mod wiz wiz.nvim: Wiz security scanning for Neovim
local M = {}

---@param opts table?
function M.setup(opts)
  require("wiz.config").setup(opts)
end

return M
