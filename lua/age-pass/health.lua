local M = {}

function M.check()
  local config = require("age-pass.config")
  local health = vim.health

  health.start("age-pass.nvim")

  -- Neovim version -------------------------------------------------------
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim 0.10 or newer is required", { "Upgrade Neovim" })
  end

  -- Platform -------------------------------------------------------------
  if vim.fn.has("win32") == 1 then
    health.error("Windows is not supported (needs a pty and named pipes)", { "Use WSL" })
    return
  end

  -- age ------------------------------------------------------------------
  local cmd = config.options.age_cmd
  local age_ok = false
  if vim.fn.executable(cmd) == 1 then
    local res = vim.system({ cmd, "--version" }, { text = true }):wait()
    local version = vim.trim((res.stdout or "") .. (res.stderr or ""))
    if res.code == 0 then
      age_ok = true
      health.ok(("`%s` found: %s"):format(cmd, version ~= "" and version or "unknown version"))
    else
      health.error(("`%s --version` failed: %s"):format(cmd, version))
    end
  else
    health.error(("`%s` is not installed or not in $PATH"):format(cmd), {
      "Install age: https://github.com/FiloSottile/age#installation",
      "e.g. `apt install age`, `brew install age`, `pacman -S age`",
      "Or set `age_cmd` in require('age-pass').setup({ age_cmd = '/path/to/age' })",
    })
  end

  -- Helper tools -----------------------------------------------------------
  local tools_ok = true
  for _, tool in ipairs({ "mkfifo", "cat", "sh" }) do
    if vim.fn.executable(tool) == 1 then
      health.ok(("`%s` found"):format(tool))
    else
      tools_ok = false
      health.error(("`%s` not found in $PATH"):format(tool), { "It is part of coreutils / POSIX" })
    end
  end

  -- Plugin wiring ------------------------------------------------------------
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = "AgePass", event = "BufReadCmd" })
  if ok and #autocmds > 0 then
    health.ok("autocommands registered for *.age")
  else
    health.warn("autocommands are not registered", { "Call require('age-pass').setup() in your config" })
  end

  -- End-to-end self test -------------------------------------------------------
  if age_ok and tools_ok then
    local agelib = require("age-pass.age")
    local file = vim.fn.tempname() .. ".age"
    local secret = "age-pass health check\n"
    local pw = "health-check-password"

    local pass, err = pcall(function()
      local enc_ok, enc_err = agelib.encrypt(secret, pw, file, false)
      assert(enc_ok, "encrypt failed: " .. tostring(enc_err))
      local plain, dec_err = agelib.decrypt(file, pw)
      assert(plain, "decrypt failed: " .. tostring(dec_err))
      assert(plain == secret, "round-trip mismatch")
    end)
    os.remove(file)

    if pass then
      health.ok("encrypt/decrypt round trip works (passphrase prompt driven through a pty)")
    else
      health.error("encrypt/decrypt round trip failed: " .. tostring(err), {
        "age may have changed its prompts, or no pty could be allocated",
        "Check that `age -p -o /tmp/x.age /tmp/some-file` works in a terminal",
      })
    end
  end
end

return M
