-- Minimal init for running tests.
-- Adds the plugin and plenary.nvim to the runtime path.

-- Resolve the plugin root from this script's own location so the tests work
-- regardless of the current working directory (neotest runs from varying cwds).
local this_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(this_file, ":p:h:h")
vim.opt.rtp:prepend(plugin_root)

-- Search common locations for plenary.nvim (local installs and CI).
local data = vim.fn.stdpath("data")
local candidates = {
  data .. "/site/pack/vendor/start/plenary.nvim",
  data .. "/site/pack/packer/start/plenary.nvim",
  data .. "/lazy/plenary.nvim",
  vim.fn.expand("~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"),
}

for _, path in ipairs(candidates) do
  if vim.fn.isdirectory(path) == 1 then
    vim.opt.rtp:append(path)
    break
  end
end

vim.cmd("runtime plugin/plenary.vim")
