-- gpg.nvim - Transparent GPG encryption/decryption for Neovim
-- Automatically encrypts on save and decrypts on read for .gpg files

local M = {}

--- @class GpgConfig
--- @field gpg_binary_path string Path to GPG binary
--- @field file_patterns string|string[] File patterns for encrypted files
--- @field default_recipient string|nil GPG recipient (nil = default-recipient-self)
--- @field use_armor boolean Use ASCII armor output
--- @field allow_clipboard boolean Allow the system clipboard in encrypted buffers
--- @field show_progress "spinner"|"toast"|"none" How to show encrypt/decrypt progress
M.config = {
  gpg_binary_path = "gpg",
  file_patterns = "*.gpg",
  default_recipient = nil,
  use_armor = false,
  -- When false (default), the system clipboard ('clipboard' option) is
  -- disabled while you are inside an encrypted buffer, so that yanking
  -- decrypted text does not leak it to the OS clipboard. Set true to keep
  -- your normal clipboard behaviour.
  allow_clipboard = false,
  -- How to indicate encrypt/decrypt progress:
  --   "spinner" - an animated spinner via fidget.nvim (default)
  --   "toast"   - a transient vim.notify message
  --   "none"    - no progress shown (errors are still reported)
  show_progress = "spinner",
}

-- Track setup state to prevent double initialization
local initialized = false

-- Saved value of 'clipboard' while inside an encrypted buffer (nil = not
-- currently overridden). Used to restore the user's setting on BufLeave.
local saved_clipboard = nil

-- Cached encryption key id for the default recipient (resolved lazily).
local cached_key_id = nil

local uv = vim.uv or vim.loop

--- Run GPG synchronously, capturing output in a binary-safe way.
--- vim.fn.system() mangles NUL bytes in binary output, which corrupts
--- encrypted data; vim.system() preserves bytes exactly.
--- @param args string[] Arguments to append after the common flags
--- @param stdin string|nil Data to pipe to GPG's stdin
--- @return vim.SystemCompleted result Completed process (code/stdout/stderr)
local function run_gpg(args, stdin)
  local cmd = { M.config.gpg_binary_path, "--quiet", "--yes", "--batch" }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end
  return vim.system(cmd, { stdin = stdin }):wait()
end

--- Start a progress indicator according to config.show_progress:
---   "spinner" -> an animated fidget.nvim progress handle
---   "toast"   -> a one-shot vim.notify message
---   "none"    -> nothing
--- @param message string
--- @return table|nil handle Opaque handle for finish_progress, or nil
local function start_progress(message)
  local mode = M.config.show_progress

  if mode == "spinner" then
    local ok, fidget_progress = pcall(require, "fidget.progress")
    if ok then
      return {
        fidget = fidget_progress.handle.create({
          title = "gpg.nvim",
          message = message,
          lsp_client = { name = "gpg.nvim" }, -- groups it like an LSP task
          percentage = nil,                   -- indeterminate -> spinner
        }),
      }
    end
    -- fidget not installed: fall back to a toast so there is still feedback.
    vim.notify(message, vim.log.levels.INFO, { title = "gpg.nvim" })
    return nil
  end

  if mode == "toast" then
    vim.notify(message, vim.log.levels.INFO, { title = "gpg.nvim" })
    return nil
  end

  return nil -- "none"
end

--- Finish a progress indicator started with start_progress.
--- @param handle table|nil
local function finish_progress(handle)
  if handle and handle.fidget then
    handle.fidget:finish()
  end
end

--- Resolve a human-readable label for the encryption key, cached.
--- Uses the configured recipient if set, otherwise the default secret key id.
--- @return string label
local function encryption_key_label()
  if M.config.default_recipient then
    return M.config.default_recipient
  end
  if cached_key_id then
    return cached_key_id
  end

  -- Parse the first secret key id from machine-readable output.
  local result = run_gpg({ "--list-secret-keys", "--keyid-format=long", "--with-colons" })
  if result.code == 0 and result.stdout then
    for line in result.stdout:gmatch("[^\n]+") do
      local fields = vim.split(line, ":", { plain = true })
      if fields[1] == "sec" and fields[5] and fields[5] ~= "" then
        cached_key_id = fields[5]
        break
      end
    end
  end

  cached_key_id = cached_key_id or "default key"
  return cached_key_id
end

--- Disable disk persistence that could leak decrypted content.
--- ShaDa stores registers, search/command history and marks; once an
--- encrypted file is opened we stop persisting it for the rest of the
--- session so decrypted snippets never reach disk. ShaDa and backups are
--- global options, so this is a deliberate security-over-convenience
--- tradeoff that takes effect only after you open an encrypted file.
local function disable_disk_persistence()
  vim.opt.shada = ""
  vim.opt.shadafile = "NONE"
  vim.opt.backup = false
  vim.opt.writebackup = false
end

--- Apply per-buffer protections against plaintext leaks.
--- @param protected_from_start boolean True when this runs at buffer
---        creation/read (so the buffer was never edited unprotected).
local function lockdown_buffer(protected_from_start)
  vim.opt_local.swapfile = false -- No swap file (security)
  vim.opt_local.undofile = false -- No persistent undo (security)
  vim.opt_local.modeline = false -- Don't honor modelines in decrypted text
  disable_disk_persistence()     -- No ShaDa/backup leaks for this session
  if protected_from_start then
    vim.b.gpg_protected_from_start = true
  end
end

--- Decrypt a GPG-encrypted file
--- @param file_path string Path to the encrypted file
--- @return string|nil content Decrypted content, or nil on failure
function M.decrypt(file_path)
  -- Skip empty/new files (nothing to decrypt yet)
  if vim.fn.filereadable(file_path) ~= 1 or vim.fn.getfsize(file_path) <= 0 then
    return ""
  end

  -- GPG automatically selects the correct secret key for decryption.
  -- "--" prevents filenames starting with "-" being parsed as options.
  local result = run_gpg({ "--decrypt", "--", file_path })

  if result.code ~= 0 then
    vim.notify("GPG decryption failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    return nil
  end
  return result.stdout or ""
end

--- Encrypt content using GPG
--- @param content string Content to encrypt
--- @return string|nil encrypted Encrypted content, or nil on failure
function M.encrypt(content)
  local args = { "--encrypt" }

  if M.config.use_armor then
    table.insert(args, "--armor")
  end

  if M.config.default_recipient then
    table.insert(args, "--recipient")
    table.insert(args, M.config.default_recipient)
  else
    table.insert(args, "--default-recipient-self")
  end

  local result = run_gpg(args, content)

  if result.code ~= 0 then
    vim.notify("GPG encryption failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
    return nil
  end
  return result.stdout
end

--- Atomically write data to a file with restrictive permissions.
--- Writes to a temp file in the same directory (created 0600 from the
--- start so ciphertext is never briefly world-readable), then renames it
--- over the target. The rename is atomic on the same filesystem, so the
--- original file is never left truncated if the write is interrupted.
--- @param file_path string Destination path
--- @param data string Data to write
--- @return boolean success
local function atomic_write(file_path, data)
  local tmp_path = file_path .. ".gpgtmp." .. vim.fn.getpid()
  local mode = tonumber("600", 8)

  -- O_WRONLY|O_CREAT|O_TRUNC with mode 0600
  local fd = uv.fs_open(tmp_path, "w", mode)
  if not fd then
    vim.notify("gpg.nvim: cannot create temp file for " .. file_path, vim.log.levels.ERROR)
    return false
  end

  local ok, write_err = uv.fs_write(fd, data)
  uv.fs_close(fd)

  if not ok then
    uv.fs_unlink(tmp_path)
    vim.notify("gpg.nvim: write failed: " .. tostring(write_err), vim.log.levels.ERROR)
    return false
  end

  -- Enforce 0600 regardless of the process umask
  uv.fs_chmod(tmp_path, mode)

  -- Atomic replace
  local rename_ok, rename_err = os.rename(tmp_path, file_path)
  if not rename_ok then
    uv.fs_unlink(tmp_path)
    vim.notify("gpg.nvim: rename failed: " .. tostring(rename_err), vim.log.levels.ERROR)
    return false
  end

  return true
end

--- Mark a buffer as failed-to-decrypt and lock it down so a later write
--- cannot overwrite the original file with re-encrypted garbage.
--- @param buf integer
local function mark_decrypt_failed(buf)
  vim.b[buf].gpg_decrypt_failed = true
  vim.bo[buf].bin = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = false
end

--- Place decrypted content into a buffer and restore a normal editing state.
--- @param buf integer
--- @param file_path string Original (encrypted) path, used for filetype
--- @param content string Decrypted text
local function populate_decrypted(buf, file_path, content)
  vim.bo[buf].modifiable = true

  local lines = { "" }
  if content ~= "" then
    lines = vim.split(content, "\n", { plain = true })
    if lines[#lines] == "" then
      table.remove(lines)
    end
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  vim.bo[buf].bin = false
  vim.bo[buf].modified = false
  vim.b[buf].gpg_decrypt_failed = false

  -- Trigger filetype detection on the underlying filename (strip .gpg)
  local inner_name = vim.fn.fnamemodify(file_path, ":t:r")
  if inner_name ~= "" then
    vim.filetype.match({ filename = inner_name, buf = buf })
  end
end

--- Decrypt a file into a buffer asynchronously so opening never blocks the
--- UI. The buffer is locked while GPG runs and populated on completion.
--- @param buf integer Target buffer
--- @param file_path string Path to the encrypted file
local function decrypt_into_buffer_async(buf, file_path)
  -- Prevent edits to the raw ciphertext while decryption is in flight.
  vim.bo[buf].modifiable = false

  local progress = start_progress("Decrypting " .. vim.fn.fnamemodify(file_path, ":t"))

  local cmd = {
    M.config.gpg_binary_path, "--quiet", "--yes", "--batch", "--decrypt", "--", file_path,
  }

  vim.system(cmd, {}, vim.schedule_wrap(function(result)
    -- The buffer may have been closed before GPG finished.
    if not vim.api.nvim_buf_is_valid(buf) then
      finish_progress(progress)
      return
    end

    if result.code ~= 0 then
      mark_decrypt_failed(buf)
      finish_progress(progress)
      vim.notify("GPG decryption failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
      return
    end

    populate_decrypted(buf, file_path, result.stdout or "")
    finish_progress(progress)
  end))
end

--- Set up autocmds for transparent GPG file handling
local function setup_autocmds()
  local group = vim.api.nvim_create_augroup("gpg_nvim", { clear = true })
  local pattern = M.config.file_patterns

  -- Before reading OR creating: lock down the buffer/session against
  -- plaintext leaks. BufNewFile is essential: when you create a *new* .gpg
  -- file, BufReadPre never fires (there is nothing to read), so without this
  -- the swap file and ShaDa would leak the plaintext you type.
  vim.api.nvim_create_autocmd({ "BufReadPre", "FileReadPre", "BufNewFile" }, {
    pattern = pattern,
    group = group,
    desc = "gpg.nvim: lock down buffer against plaintext leaks",
    callback = function(args)
      lockdown_buffer(true)

      -- Binary mode is only needed before an actual raw read that we then
      -- decrypt; a brand-new buffer has nothing to read.
      if args.event ~= "BufNewFile" then
        vim.opt_local.bin = true
      end
    end,
  })

  -- When an existing buffer is *renamed* to a .gpg name (e.g. :saveas or
  -- :file), apply protections from this point on. This cannot undo plaintext
  -- that already leaked while the buffer was edited under its old name, so we
  -- also warn the user.
  vim.api.nvim_create_autocmd("BufFilePost", {
    pattern = pattern,
    group = group,
    desc = "gpg.nvim: protect buffer renamed to an encrypted name",
    callback = function()
      if not vim.b.gpg_protected_from_start then
        lockdown_buffer(false)
        vim.b.gpg_leak_warned = true
        vim.notify(
          "gpg.nvim: this buffer was edited before becoming encrypted; "
            .. "earlier content may have leaked to swap/ShaDa this session. "
            .. "For secrets, open the file with a .gpg name from the start.",
          vim.log.levels.WARN
        )
      end
    end,
  })

  -- After reading: decrypt content
  vim.api.nvim_create_autocmd({ "BufReadPost", "FileReadPost" }, {
    pattern = pattern,
    group = group,
    desc = "gpg.nvim: decrypt file content",
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      local file_path = vim.fn.expand("%:p")

      -- New/empty file: nothing to decrypt, just leave it editable.
      if vim.fn.filereadable(file_path) ~= 1 or vim.fn.getfsize(file_path) <= 0 then
        vim.bo[buf].bin = false
        vim.b[buf].gpg_decrypt_failed = false
        return
      end

      -- Decrypt asynchronously so opening the file does not block the UI.
      -- Progress (fidget spinner or notification) is handled inside.
      decrypt_into_buffer_async(buf, file_path)
    end,
  })

  -- On write: encrypt content in memory and write atomically
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = pattern,
    group = group,
    desc = "gpg.nvim: encrypt and write file",
    callback = function()
      -- Never overwrite a file whose decryption failed
      if vim.b.gpg_decrypt_failed then
        vim.notify(
          "gpg.nvim: refusing to write -- decryption failed; original file left untouched",
          vim.log.levels.ERROR
        )
        return
      end

      -- Warn once if this content was edited before the buffer was protected
      -- (e.g. `:w secret.gpg` from a scratch buffer). The file will still be
      -- encrypted, but earlier plaintext may already have reached swap/ShaDa.
      if not vim.b.gpg_protected_from_start and not vim.b.gpg_leak_warned then
        vim.b.gpg_leak_warned = true
        vim.notify(
          "gpg.nvim: buffer was not protected before this write; earlier "
            .. "plaintext may have leaked to swap/ShaDa this session. For "
            .. "secrets, open the file with a .gpg name from the start.",
          vim.log.levels.WARN
        )
      end

      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local content = table.concat(lines, "\n") .. "\n"

      -- Resolve the actual write target. For `:w` this is the buffer's own
      -- file; for `:w other.gpg` it is the other file (a copy).
      local target = vim.fn.expand("<afile>:p")
      if target == "" then
        target = vim.fn.expand("%:p")
      end

      -- Show progress around encryption. The key label is built only when
      -- progress is shown (it may shell out to gpg --list-secret-keys).
      local progress
      if M.config.show_progress ~= "none" then
        progress = start_progress("Encrypting with key " .. encryption_key_label())
      end

      local encrypted = M.encrypt(content)
      if not encrypted then
        finish_progress(progress)
        return -- Encryption failed, buffer stays 'modified' so no data is lost
      end

      finish_progress(progress)

      if atomic_write(target, encrypted) then
        -- Clear 'modified' only when writing the buffer's own file (:w),
        -- not when writing a copy elsewhere (:w other.gpg).
        if target == vim.fn.expand("%:p") then
          vim.bo.modified = false
        end
      end
    end,
  })

  -- Optionally keep decrypted content out of the system clipboard. The
  -- 'clipboard' option is global, so we disable it on entering an encrypted
  -- buffer and restore the user's value on leaving. Explicit clipboard
  -- registers ("+/"*) still work for deliberate copies.
  if not M.config.allow_clipboard then
    vim.api.nvim_create_autocmd("BufEnter", {
      pattern = pattern,
      group = group,
      desc = "gpg.nvim: disable system clipboard in encrypted buffer",
      callback = function()
        if saved_clipboard == nil then
          saved_clipboard = vim.o.clipboard
        end
        vim.o.clipboard = ""
      end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
      pattern = pattern,
      group = group,
      desc = "gpg.nvim: restore system clipboard on leaving encrypted buffer",
      callback = function()
        if saved_clipboard ~= nil then
          vim.o.clipboard = saved_clipboard
          saved_clipboard = nil
        end
      end,
    })
  end
end

--- Initialize the plugin
--- @param opts GpgConfig|nil Configuration options
function M.setup(opts)
  if initialized then
    return
  end

  -- Requires vim.system() for binary-safe GPG I/O (Neovim 0.10+)
  if vim.fn.has("nvim-0.10") ~= 1 then
    vim.notify("gpg.nvim: requires Neovim 0.10 or later", vim.log.levels.ERROR)
    return
  end

  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Verify GPG is available
  if vim.fn.executable(M.config.gpg_binary_path) ~= 1 then
    vim.notify("gpg.nvim: " .. M.config.gpg_binary_path .. " not found in PATH", vim.log.levels.WARN)
    return
  end

  setup_autocmds()
  initialized = true
end

return M
