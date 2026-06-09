# gpg.nvim

Transparent GPG encryption/decryption for Neovim. Automatically decrypts `.gpg` files when opened and encrypts them when saved.

## Requirements

- Neovim 0.10+ (uses `vim.system` for binary-safe GPG I/O)
- GPG installed and configured with a default key

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "dijeferson/gpg.nvim",
  opts = {}
}
```

## Configuration

```lua
require("gpg").setup({
  -- Path to GPG binary (default: "gpg")
  gpg_binary_path = "gpg",
  -- File patterns to treat as GPG encrypted (default: "*.gpg")
  -- Can be a string or array of patterns
  file_patterns = "*.gpg",
  -- GPG recipient for encryption (default: nil, uses --default-recipient-self)
  default_recipient = nil,
  -- Use ASCII armor output (default: false)
  use_armor = false,
  -- Allow the system clipboard while editing an encrypted buffer
  -- (default: false). When false, the 'clipboard' option is disabled inside
  -- encrypted buffers so yanks do not leak decrypted text to the OS
  -- clipboard; it is restored when you leave the buffer.
  allow_clipboard = false,
  -- Show transient encrypt/decrypt notifications, e.g.
  -- "Encrypting with key <id>" (default: true). Routed through vim.notify,
  -- so it renders via fidget/snacks/noice if you use one.
  show_progress = true,
})
```

### Examples

```lua
-- Use GPG2 with a specific recipient
require("gpg").setup({
  gpg_binary_path = "/usr/local/bin/gpg2",
  default_recipient = "me@example.com",
})

-- Handle multiple file extensions with armor
require("gpg").setup({
  file_patterns = { "*.gpg", "*.asc" },
  use_armor = true,
})
```

## Workflow

**Decide a file is secret before you start typing, and open it with a `.gpg`
name.** The leak protections (no swap, no undo file, no ShaDa, clipboard off)
only apply to buffers whose name matches your `file_patterns`.

### ✅ Safe flow

```vim
:e secret.txt.gpg     " (or: nvim secret.txt.gpg)
" ...type your secret...
:w                    " encrypted on save; protected the whole time
```

Open the file with its `.gpg` name first. Every protection is active from the
moment the buffer exists, so plaintext never reaches swap or ShaDa.

### ⚠️ Unsafe flow (avoid)

```vim
:enew                 " unnamed / non-.gpg buffer
" ...type your secret...
:saveas secret.gpg    " or  :w secret.gpg
```

The **file is still written encrypted** — but while you were typing, the
buffer was *not* a `.gpg` buffer, so swap and ShaDa were live. Your plaintext
may already have leaked to `~/.local/state/nvim` (verified: it does). Saving
encrypted afterwards cannot scrub what already leaked.

If you do this, the plugin applies protection from the rename onward and
**warns you** that earlier content may have leaked. The remedy for next time
is the safe flow above.

## How It Works

1. **On read**: Locks the buffer/session against plaintext leaks, decrypts content, detects filetype from the underlying filename
2. **On write**: Encrypts content in memory, then writes the ciphertext atomically (temp file + rename) with `0600` permissions

## Security

What the plugin does to keep plaintext off disk:

- **Swap files** disabled for encrypted buffers (`noswapfile`)
- **Persistent undo** disabled for encrypted buffers (`noundofile`)
- **ShaDa** disabled for the session once an encrypted file is opened
  (`shada=`, `shadafile=NONE`). ShaDa otherwise persists registers, search
  and command history, and marks — any of which can capture decrypted
  snippets. This is global, so it is a deliberate
  security-over-convenience tradeoff that only takes effect after you open
  an encrypted file.
- **Backups** disabled (`nobackup`, `nowritebackup`)
- **Modelines** disabled for encrypted buffers, so decrypted content cannot
  execute settings via a planted modeline
- Decrypted content lives only in buffer memory; plaintext is piped to GPG
  over stdin and never written to a temp file
- Writes are **atomic** and the encrypted file is created `0600` from the
  start (never briefly world-readable)
- **Failed decryption locks the buffer** (`nomodifiable`) and blocks writes,
  so a wrong key or corrupted file can never be overwritten with garbage
- **System clipboard** is disabled inside encrypted buffers by default
  (`allow_clipboard = false`) so yanks do not leak decrypted text to the OS
  clipboard; set `allow_clipboard = true` to opt out

Things outside the plugin's control — be aware:

- Explicit clipboard registers (`"+`/`"*`) still copy to the system
  clipboard even with `allow_clipboard = false`, since that is a deliberate
  user action.
- The plugin encrypts but does not **sign**, and does not verify signatures
  on decrypt. This is intentional for encryption-at-rest; it is not an
  authenticity guarantee.
- While a file is open, decrypted content exists in Neovim's memory.

## Health Check

Run `:checkhealth gpg` to verify your setup.

## Testing

Requires [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). Run the
suite (also used by CI):

```sh
make test
```

Or invoke it directly:

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

Lint and format:

```sh
make lint          # selene
make format        # stylua (in place)
make format-check  # stylua --check
```

## License

MIT
