-- Tests for gpg.nvim
-- Run with: nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
--
-- These tests are hermetic: instead of invoking the real `gpg` binary (which
-- depends on the user's keyring and may even hit the network), tests that
-- exercise encrypt/decrypt point `gpg_binary_path` at a small shell stub whose
-- behaviour we control.

--- Create an executable stub script that mimics a gpg invocation.
--- @param body string Shell script body (after the shebang)
--- @return string path Path to the executable stub
local function make_stub(body)
  local path = vim.fn.tempname()
  vim.fn.writefile({ "#!/bin/sh", body }, path)
  vim.fn.setfperm(path, "rwxr-xr-x")
  return path
end

describe("gpg.nvim", function()
  local gpg

  before_each(function()
    -- Fresh require to reset state (initialized flag, config)
    package.loaded["gpg"] = nil
    gpg = require("gpg")
  end)

  describe("config", function()
    it("has sensible defaults", function()
      assert.equals("gpg", gpg.config.gpg_binary_path)
      assert.equals("*.gpg", gpg.config.file_patterns)
      assert.is_nil(gpg.config.default_recipient)
      assert.is_false(gpg.config.use_armor)
      assert.is_false(gpg.config.allow_clipboard)
      assert.equals("spinner", gpg.config.show_progress)
    end)
  end)

  describe("setup", function()
    it("merges user options with defaults", function()
      gpg.setup({ default_recipient = "test@example.com", use_armor = true })
      assert.equals("gpg", gpg.config.gpg_binary_path)
      assert.equals("test@example.com", gpg.config.default_recipient)
      assert.is_true(gpg.config.use_armor)
    end)

    it("accepts a custom gpg binary path", function()
      gpg.setup({ gpg_binary_path = "/opt/bin/gpg2" })
      assert.equals("/opt/bin/gpg2", gpg.config.gpg_binary_path)
    end)

    it("accepts an array of patterns", function()
      gpg.setup({ file_patterns = { "*.gpg", "*.asc" } })
      assert.same({ "*.gpg", "*.asc" }, gpg.config.file_patterns)
    end)

    it("creates the autocmd group", function()
      gpg.setup()
      local autocmds = vim.api.nvim_get_autocmds({ group = "gpg_nvim" })
      assert.is_true(#autocmds > 0)
    end)
  end)

  describe("decrypt", function()
    it("returns empty string for a nonexistent file", function()
      gpg.setup()
      assert.equals("", gpg.decrypt("/nonexistent/file.gpg"))
    end)

    it("returns empty string for an empty file", function()
      gpg.setup()
      local tmp = vim.fn.tempname() .. ".gpg"
      vim.fn.writefile({}, tmp)
      assert.equals("", gpg.decrypt(tmp))
      vim.fn.delete(tmp)
    end)

    it("returns decrypted output on success", function()
      -- Stub prints fixed plaintext and exits 0
      local stub = make_stub("echo decrypted-content")
      gpg.config.gpg_binary_path = stub

      local tmp = vim.fn.tempname() .. ".gpg"
      vim.fn.writefile({ "ciphertext" }, tmp) -- non-empty so decrypt runs
      local result = gpg.decrypt(tmp)
      assert.equals("decrypted-content\n", result)

      vim.fn.delete(tmp)
      vim.fn.delete(stub)
    end)

    it("returns nil when gpg exits non-zero", function()
      local stub = make_stub("echo error >&2; exit 2")
      gpg.config.gpg_binary_path = stub

      local tmp = vim.fn.tempname() .. ".gpg"
      vim.fn.writefile({ "ciphertext" }, tmp)
      assert.is_nil(gpg.decrypt(tmp))

      vim.fn.delete(tmp)
      vim.fn.delete(stub)
    end)
  end)

  describe("encrypt", function()
    it("returns encrypted output on success", function()
      -- Stub wraps stdin so we can confirm content is piped through
      local stub = make_stub("printf 'ENC:'; cat")
      gpg.config.gpg_binary_path = stub

      local result = gpg.encrypt("secret")
      assert.equals("ENC:secret", result)
      vim.fn.delete(stub)
    end)

    it("returns nil when gpg exits non-zero", function()
      local stub = make_stub("echo failed >&2; exit 2")
      gpg.config.gpg_binary_path = stub

      assert.is_nil(gpg.encrypt("secret"))
      vim.fn.delete(stub)
    end)
  end)

  describe("leak prevention", function()
    it("locks down a brand-new encrypted file (swap/undo/shada)", function()
      gpg.setup()

      -- A path that does not exist yet -> BufNewFile, not BufReadPre
      local tmp = vim.fn.tempname() .. ".gpg"
      pcall(vim.cmd, "edit " .. vim.fn.fnameescape(tmp))

      assert.is_false(vim.bo.swapfile) -- no plaintext swap file
      assert.is_false(vim.bo.undofile) -- no persistent undo
      assert.is_false(vim.bo.modeline) -- no modeline execution
      assert.equals("", vim.o.shada) -- no register/history persistence
      assert.is_true(vim.b.gpg_protected_from_start)

      vim.cmd("silent! bwipeout!")
      vim.fn.delete(tmp)
    end)

    it("marks a buffer renamed into a .gpg name as not protected from start", function()
      gpg.setup()

      vim.cmd("enew")
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited before encryption" })
      local tmp = vim.fn.tempname() .. ".gpg"
      pcall(vim.cmd, "saveas " .. vim.fn.fnameescape(tmp)) -- BufFilePost fires

      -- Protections now applied, but flagged as a late/unsafe transition
      assert.is_nil(vim.b.gpg_protected_from_start)
      assert.is_false(vim.bo.swapfile)
      assert.equals("", vim.o.shada)

      vim.cmd("silent! bwipeout!")
      vim.fn.delete(tmp)
    end)
  end)

  describe("clipboard protection", function()
    after_each(function()
      vim.o.clipboard = ""
      vim.cmd("silent! %bwipeout!")
    end)

    it("disables the system clipboard inside an encrypted buffer by default", function()
      vim.o.clipboard = "unnamedplus"
      gpg.setup()

      local tmp = vim.fn.tempname() .. ".gpg"
      pcall(vim.cmd, "edit " .. vim.fn.fnameescape(tmp)) -- BufEnter fires
      assert.equals("", vim.o.clipboard)

      -- Leaving the encrypted buffer restores the user's setting
      vim.cmd("enew") -- BufLeave fires on the gpg buffer
      assert.equals("unnamedplus", vim.o.clipboard)

      vim.fn.delete(tmp)
    end)

    it("leaves the clipboard untouched when allow_clipboard = true", function()
      vim.o.clipboard = "unnamedplus"
      gpg.setup({ allow_clipboard = true })

      local tmp = vim.fn.tempname() .. ".gpg"
      pcall(vim.cmd, "edit " .. vim.fn.fnameescape(tmp))
      assert.equals("unnamedplus", vim.o.clipboard)

      vim.fn.delete(tmp)
    end)
  end)

  describe("write guard on failed decryption", function()
    -- Note: driving decryption through `:edit` inside a plenary busted
    -- coroutine is unreliable (vim.system():wait() in an autocmd does not
    -- complete in that context), so we set the documented post-failure state
    -- directly and assert the actual safety property: the write autocmd must
    -- refuse to overwrite the original file. The decrypt-returns-nil case is
    -- covered separately by the "decrypt" tests.
    it("refuses to overwrite the original file when decryption failed", function()
      gpg.setup()

      -- A non-empty encrypted file with known sentinel content on disk
      local tmp = vim.fn.tempname() .. ".gpg"
      vim.fn.writefile({ "ORIGINAL-CIPHERTEXT" }, tmp)

      -- Open WITHOUT autocmds (no decrypt), then simulate the state the
      -- BufReadPost handler sets when decryption fails.
      vim.cmd("noautocmd edit " .. vim.fn.fnameescape(tmp))
      vim.b.gpg_decrypt_failed = true

      -- A normal write must trigger the guard and leave the file untouched
      pcall(vim.cmd, "silent! write")

      local on_disk = vim.fn.readfile(tmp)
      assert.same({ "ORIGINAL-CIPHERTEXT" }, on_disk)

      vim.cmd("silent! bwipeout!")
      vim.fn.delete(tmp)
    end)
  end)
end)
