-- Health check for gpg.nvim
-- Run with :checkhealth gpg

local M = {}

function M.check()
  vim.health.start("gpg.nvim")

  local gpg = require("gpg")
  local binary = gpg.config.gpg_binary_path

  -- Check GPG binary
  if vim.fn.executable(binary) == 1 then
    local version = vim.fn.system({ binary, "--version" })
    local first_line = vim.split(version, "\n")[1] or "unknown"
    vim.health.ok("GPG found: " .. first_line)
  else
    vim.health.error("GPG not found: " .. binary, {
      "Install GPG or set gpg_binary_path option",
    })
    return
  end

  -- Check for default key
  local keys = vim.fn.system({ binary, "--list-secret-keys", "--keyid-format=long" })
  if vim.v.shell_error == 0 and keys ~= "" then
    vim.health.ok("GPG secret key available")
  else
    vim.health.warn("No GPG secret key found", {
      "Run: gpg --full-generate-key",
    })
  end

  -- Check recipient config
  if gpg.config.default_recipient then
    vim.health.info("Recipient: " .. gpg.config.default_recipient)
  else
    vim.health.info("Using default recipient (--default-recipient-self)")
  end
end

return M
