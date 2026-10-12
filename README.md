# age-pass.nvim

Edit passphrase-encrypted [age](https://github.com/FiloSottile/age) files in
Neovim as if they were plain text.

- Only activates for `*.age` files.
- Opening one prompts for the password (masked), decrypts it, and shows the
  plaintext. The ciphertext is never displayed.
- `:w` re-encrypts with the same password. The write is atomic: the old file is
  only replaced once age succeeds.
- The password is dropped when the buffer is unloaded/wiped (and on exit).
- Any number of `.age` files can be open at once, each with its own password.
- Opening a path that doesn't exist yet creates a new encrypted file (asks for
  the password twice).
- Swap, undo and backup files are disabled for these buffers so plaintext
  isn't written to disk. Plaintext also never goes to disk while
  decrypting/encrypting (named pipes in Neovim's private temp dir are used).

## Requirements

- Neovim 0.10+
- [`age`](https://github.com/FiloSottile/age#installation) in `$PATH`
- Linux / macOS / BSD (`mkfifo`, `cat`, `sh`); Windows is not supported (use WSL)

Run `:checkhealth age-pass` to verify. It also does a real encrypt/decrypt
round trip to make sure the prompt handling works on your system.

## Install

lazy.nvim:

```lua
{
  "nicholasmello/age-pass.nvim",
  lazy = false, -- must load at startup so `.age` file hooks are registered
  opts = {},
}
```

Any other manager: install it, then optionally call
`require("age-pass").setup({...})`. It also self-registers with defaults.

## Options

```lua
require("age-pass").setup({
  age_cmd = "age",     -- executable name or path
  max_attempts = 3,    -- wrong-password retries when opening
  timeout = 60000,     -- ms allowed per age invocation
  armor = false,       -- ASCII-armor *new* files (existing files keep their format)
})
```

## Commands

| Command | |
|---|---|
| `:AgePassChangePassword` | Set a new password for the current buffer; applied on next `:w` |

If decryption is cancelled or fails the buffer stays empty and read-only, and
`:w` is refused so the real file can't be overwritten. `:edit!` tries again.

## Limitations & security notes

- **Passphrase (scrypt) files only.** Files encrypted to X25519/SSH recipients
  need an identity file and are not handled.
- **Text files only.** Embedded NUL bytes are not preserved. Don't use it on
  binary data.
- **Wiping memory is best-effort.** Lua strings are immutable, so the password
  can't be overwritten in place; the plugin drops every reference and runs a
  garbage collection when the buffer closes. The password also passes briefly
  through Neovim's pty/job buffers. Don't treat this as protection against an
  attacker who can read Neovim's memory while you're editing.
- Plaintext lives in Neovim's buffers and may reach registers or ShaDa if you
  yank text. Consider `:set shada=` / `:set clipboard=` when editing secrets.
- `:w other.txt` writes plaintext (normal Neovim behaviour for non-`.age`
  targets). Range writes (`:1,5w x.age`) and `:r file.age` are not supported.
- How it works: `age` only accepts passphrases from a terminal, so the plugin
  runs it in a pty and types the password in when the prompt appears.
- AI coding use: This was with the use of an LLM and I have not audited all of
  the code yet
