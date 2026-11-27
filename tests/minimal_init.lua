local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = os.getenv("PLENARY_DIR") or (root .. "/.deps/plenary.nvim")
if vim.fn.isdirectory(plenary .. "/lua/plenary") == 0 then
  vim.fn.delete(plenary, "rf")
  local out =
    vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", plenary })
  if vim.v.shell_error ~= 0 then
    error("failed to clone plenary.nvim:\n" .. out)
  end
end
vim.opt.rtp:prepend(plenary)
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/plenary.vim")
vim.opt.swapfile = false
