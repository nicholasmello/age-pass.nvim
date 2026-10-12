local M = {}

---@class AgePassConfig
---@field age_cmd string       Name or path of the `age` executable.
---@field max_attempts integer Password attempts allowed when opening a file.
---@field timeout integer      Max time (ms) for a single `age` invocation.
---@field armor boolean        ASCII-armor newly created files (existing files keep their format).
M.defaults = {
  age_cmd = "age",
  max_attempts = 3,
  timeout = 60000,
  armor = false,
}

---@type AgePassConfig
M.options = vim.deepcopy(M.defaults)

---@param opts? AgePassConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
