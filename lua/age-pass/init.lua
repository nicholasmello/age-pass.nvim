local config = require("age-pass.config")
local age = require("age-pass.age")
local uv = vim.uv or vim.loop

local M = {}

local GROUP = "AgePass"

---Per-buffer state. Only buffers holding a decrypted .age file have an entry.
---@type table<integer, { password: string, armor: boolean }>
local states = {}

local function notify(msg, level)
  vim.notify("age-pass: " .. msg, level or vim.log.levels.ERROR)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function valid_password(pw)
  if pw:find("%c") then
    return false, "passwords containing control characters are not supported"
  end
  if #pw > 1000 then
    return false, "password is too long"
  end
  return true
end

---@return string|nil  nil when cancelled or empty
local function ask_password(prompt)
  local ok, pw = pcall(vim.fn.inputsecret, prompt)
  vim.cmd("redraw")
  if not ok or pw == nil or pw == "" then
    return nil
  end
  return pw
end

local function is_armored(path)
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  local head = f:read(40) or ""
  f:close()
  return head:find("^%-%-%-%-%-BEGIN AGE ENCRYPTED FILE%-%-%-%-%-") ~= nil
end

local function forget(buf)
  local st = states[buf]
  if st then
    st.password = nil
  end
  states[buf] = nil
  -- Lua strings are immutable, so the best we can do is drop every reference
  -- and collect.
  collectgarbage("collect")
end

--- Make sure plaintext can't leak into swap/undo/backup files.
local function harden(buf)
  local bo = vim.bo[buf]
  bo.swapfile = false
  bo.undofile = false
  bo.buftype = "acwrite"
  bo.fixendofline = false
end

--- Leave the buffer empty and unwritable (used when decryption failed/cancelled).
local function lock(buf)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function load_text(buf, text)
  local eol = text:sub(-1) == "\n"
  if eol then
    text = text:sub(1, -2)
  end
  local lines = vim.split(text, "\n", { plain = true })

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("setlocal undolevels=-1") -- don't let `u` undo the initial load
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.cmd("setlocal undolevels<")
  end)
  vim.bo[buf].eol = eol
  vim.bo[buf].modified = false
end

local function detect_filetype(buf, path)
  local name = (vim.fn.fnamemodify(path, ":t"):gsub("%.age$", ""))
  local ft = vim.filetype.match({ filename = name, buf = buf })
  if ft then
    vim.bo[buf].filetype = ft
  end
end

---------------------------------------------------------------------------
-- Open
---------------------------------------------------------------------------

local function new_file(buf)
  local pw = ask_password("New .age file - choose a password: ")
  if not pw then
    notify("cancelled; buffer is read-only (use :edit! to try again)", vim.log.levels.WARN)
    return lock(buf)
  end
  local ok, err = valid_password(pw)
  if not ok then
    notify(err)
    return lock(buf)
  end
  if ask_password("Confirm password: ") ~= pw then
    notify("passwords do not match; buffer is read-only (use :edit! to try again)")
    return lock(buf)
  end

  states[buf] = { password = pw, armor = config.options.armor }
  vim.bo[buf].modifiable = true
  vim.bo[buf].eol = true
  vim.bo[buf].modified = false
end

local function looks_like_bad_password(err)
  err = err:lower()
  return err:find("incorrect", 1, true) ~= nil or err:find("passphrase", 1, true) ~= nil
end

---@param buf integer
function M.open(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  forget(buf)
  harden(buf)
  vim.bo[buf].modifiable = true

  if not uv.fs_stat(path) then
    return new_file(buf)
  end

  local armor = is_armored(path)
  local label = vim.fn.fnamemodify(path, ":t")
  local attempts = math.max(1, config.options.max_attempts)

  for i = 1, attempts do
    local pw = ask_password(("Password for %s: "):format(label))
    if not pw then
      notify("cancelled; buffer is read-only (use :edit! to try again)", vim.log.levels.WARN)
      return lock(buf)
    end

    local text, err = age.decrypt(path, pw)
    if text then
      states[buf] = { password = pw, armor = armor }
      load_text(buf, text)
      detect_filetype(buf, path)
      vim.api.nvim_exec_autocmds("BufReadPost", { buffer = buf })
      vim.api.nvim_echo({ { ('"%s" decrypted, %dL'):format(label, vim.api.nvim_buf_line_count(buf)) } }, false, {})
      return
    end

    if not looks_like_bad_password(err or "") then
      notify(("could not decrypt %s: %s"):format(label, err))
      return lock(buf)
    end
    notify(("wrong password (%d/%d)"):format(i, attempts), vim.log.levels.WARN)
  end

  notify("giving up; buffer is read-only (use :edit! to try again)")
  lock(buf)
end

---------------------------------------------------------------------------
-- Write
---------------------------------------------------------------------------

---@param buf integer
---@param target string  absolute path being written
function M.write(buf, target)
  local st = states[buf]
  if not st then
    return notify("no password for this buffer, refusing to write (use :edit! to reopen it)")
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  if vim.bo[buf].eol then
    text = text .. "\n"
  end

  local ok, err = age.encrypt(text, st.password, target, st.armor)
  if not ok then
    return notify("encryption failed, file NOT written: " .. tostring(err))
  end

  if vim.fs.normalize(target) == vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) then
    vim.bo[buf].modified = false
  end
  vim.api.nvim_echo({
    { ('"%s" encrypted and written, %dL, %dB'):format(vim.fn.fnamemodify(target, ":t"), #lines, #text) },
  }, false, {})
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function change_password()
  local buf = vim.api.nvim_get_current_buf()
  local st = states[buf]
  if not st then
    return notify("current buffer is not an open .age file", vim.log.levels.WARN)
  end
  local pw = ask_password("New password: ")
  if not pw then
    return
  end
  local ok, err = valid_password(pw)
  if not ok then
    return notify(err)
  end
  if ask_password("Confirm new password: ") ~= pw then
    return notify("passwords do not match")
  end
  st.password = pw
  vim.bo[buf].modified = true
  vim.api.nvim_echo({ { "age-pass: new password set, save the buffer to re-encrypt" } }, false, {})
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

---@param opts? AgePassConfig
function M.setup(opts)
  config.setup(opts)

  local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "*.age",
    desc = "age-pass: decrypt .age file",
    callback = function(args)
      M.open(args.buf)
    end,
  })

  -- Some versions fire BufNewFile instead for files that don't exist yet.
  vim.api.nvim_create_autocmd("BufNewFile", {
    group = group,
    pattern = "*.age",
    desc = "age-pass: create new .age file",
    callback = function(args)
      if not states[args.buf] then
        M.open(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    pattern = "*.age",
    desc = "age-pass: encrypt and write .age file",
    callback = function(args)
      M.write(args.buf, vim.fn.fnamemodify(args.file, ":p"))
    end,
  })

  -- Drop the password as soon as the buffer goes away (no pattern, so this
  -- also covers buffers that were renamed away from *.age).
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    desc = "age-pass: forget password",
    callback = function(args)
      forget(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    desc = "age-pass: forget all passwords",
    callback = function()
      for buf in pairs(states) do
        forget(buf)
      end
    end,
  })

  vim.api.nvim_create_user_command("AgePassChangePassword", change_password, {
    desc = "Set a new password for the current .age buffer (applied on next save)",
  })
end

return M
