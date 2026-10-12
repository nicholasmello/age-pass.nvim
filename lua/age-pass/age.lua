-- Thin wrapper around the `age` CLI for passphrase-encrypted files.
--
-- `age` refuses to take a passphrase from a pipe, an argument or the
-- environment: it only reads it from the controlling terminal. So we run it
-- in a pty, wait for its prompt, and type the passphrase into it.
--
-- Because the pty is age's stdin/stdout, the file contents travel through
-- named pipes (FIFOs) in Neovim's private (mode 0700) temp directory, so the
-- plaintext never touches the disk:
--   decrypt:  age -d -o <fifo> file.age   ->  `cat <fifo>`  ->  Neovim
--   encrypt:  Neovim -> `cat > <fifo>`    ->  age -p -o tmp <fifo>
--
-- All functions block (while still pumping the event loop) until done.

local config = require("age-pass.config")
local uv = vim.uv or vim.loop

local M = {}

-- Matches "Enter passphrase: ", "Confirm passphrase: " and the longer
-- "Enter passphrase (leave empty to autogenerate a secure one): ".
local PROMPT = "[Pp]assphrase[^\n]*:%s*$"

--- Strip terminal escapes, the prompts themselves and any trace of the secret.
local function clean_log(text, secret)
  text = text:gsub("\27%[[%d;?]*%a", ""):gsub("\r", "")
  if secret and secret ~= "" then
    local out, i = {}, 1
    while true do
      local s, e = text:find(secret, i, true)
      if not s then
        out[#out + 1] = text:sub(i)
        break
      end
      out[#out + 1] = text:sub(i, s - 1)
      out[#out + 1] = "***"
      i = e + 1
    end
    text = table.concat(out)
  end
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    if not line:find(PROMPT) and line:find("%S") then
      lines[#lines + 1] = vim.trim(line)
    end
  end
  return table.concat(lines, "\n")
end

local function stop(job, is_done)
  if job > 0 and not is_done() then
    pcall(vim.fn.jobstop, job)
    vim.wait(500, is_done, 10)
  end
end

--- Run age in a pty, answering its passphrase prompt(s).
---@param args string[]
---@param password string
---@param n_prompts integer how many passphrase prompts to answer
---@return integer|nil code, string log
local function run_age(args, password, n_prompts)
  local acc, log, sent, code = "", {}, 0, nil

  local job = vim.fn.jobstart(args, {
    pty = true,
    on_stdout = function(id, data)
      local chunk = table.concat(data, "\n")
      log[#log + 1] = chunk
      acc = acc .. chunk
      if sent < n_prompts and acc:find(PROMPT) then
        sent = sent + 1
        acc = ""
        -- Small delay so age has switched the tty to no-echo before we type.
        vim.defer_fn(function()
          pcall(vim.fn.chansend, id, password .. "\n")
        end, 30)
      end
    end,
    on_exit = function(_, c)
      code = c
    end,
  })

  if job <= 0 then
    return nil, ("could not start `%s`"):format(args[1])
  end

  local finished = vim.wait(config.options.timeout, function()
    return code ~= nil
  end, 10)

  if not finished then
    stop(job, function()
      return code ~= nil
    end)
    return nil, "timed out waiting for age"
  end

  return code, clean_log(table.concat(log), password)
end

local function make_fifo()
  local path = vim.fn.tempname() .. ".fifo"
  local res = vim.system({ "mkfifo", "-m", "600", path }):wait()
  if res.code ~= 0 then
    return nil, "mkfifo failed: " .. vim.trim(res.stderr or "")
  end
  return path
end

--- Decrypt `path` with `password`.
---@return string|nil plaintext, string|nil err
function M.decrypt(path, password)
  local fifo, ferr = make_fifo()
  if not fifo then
    return nil, ferr
  end

  local chunks, reader_done = nil, false
  local reader = vim.fn.jobstart({ "cat", fifo }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      chunks = data
    end,
    on_exit = function()
      reader_done = true
    end,
  })
  local function is_reader_done()
    return reader_done
  end

  local code, log = run_age({ config.options.age_cmd, "-d", "-o", fifo, "--", path }, password, 1)

  if code == 0 then
    -- age only opens the output lazily, so an empty plaintext never opens the
    -- FIFO and `cat` would wait forever; give it a moment, then move on.
    vim.wait(500, is_reader_done, 10)
  end
  stop(reader, is_reader_done)
  os.remove(fifo)

  if code ~= 0 then
    return nil, (log ~= "" and log) or "age exited with an error"
  end
  return chunks and table.concat(chunks, "\n") or ""
end

--- Encrypt `plaintext` with `password` into `out_path` (atomically).
---@param armor boolean
---@return boolean|nil ok, string|nil err
function M.encrypt(plaintext, password, out_path, armor)
  local fifo, ferr = make_fifo()
  if not fifo then
    return nil, ferr
  end

  out_path = uv.fs_realpath(out_path) or out_path
  local tmp = out_path .. ".age-pass.tmp"

  local writer_done = false
  local writer = vim.fn.jobstart({ "sh", "-c", 'cat > "$1"', "sh", fifo }, {
    on_exit = function()
      writer_done = true
    end,
  })
  local function is_writer_done()
    return writer_done
  end
  if writer <= 0 then
    os.remove(fifo)
    return nil, "could not start `cat`"
  end
  if plaintext ~= "" then
    vim.fn.chansend(writer, plaintext)
  end
  vim.fn.chanclose(writer, "stdin")

  local args = { config.options.age_cmd, "-p" }
  if armor then
    args[#args + 1] = "-a"
  end
  vim.list_extend(args, { "-o", tmp, "--", fifo })

  local code, log = run_age(args, password, 2)

  stop(writer, is_writer_done)
  os.remove(fifo)

  if code ~= 0 then
    os.remove(tmp)
    return nil, (log ~= "" and log) or "age exited with an error"
  end

  -- Keep the permissions of the file we are replacing.
  local st = uv.fs_stat(out_path)
  if st then
    pcall(uv.fs_chmod, tmp, bit.band(st.mode, 4095))
  end

  local ok, rerr = uv.fs_rename(tmp, out_path)
  if not ok then
    os.remove(tmp)
    return nil, "could not replace file: " .. tostring(rerr)
  end
  return true
end

return M
