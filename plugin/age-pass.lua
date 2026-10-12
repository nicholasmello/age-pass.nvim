if vim.g.loaded_age_pass then
  return
end
vim.g.loaded_age_pass = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("age-pass.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

-- Register with defaults; calling require("age-pass").setup(opts) later
-- simply replaces this registration.
require("age-pass").setup()
