-- surrounded/plugin/surrounded.lua
-- Entry point: loads only once, defers setup to the lua module

if vim.g.loaded_surrounded then
	return
end
vim.g.loaded_surrounded = true

require("surrounded").setup()
