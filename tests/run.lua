-- Headless test suite. Run from the repo root:
--   nvim --headless -u NONE -i NONE -l tests/run.lua

vim.opt.rtp:prepend(vim.fn.getcwd())
require("surrounded").setup({
	pairs = { { open = "(", close = ")" }, { open = "{", close = "}", pad = " " }, { open = "[", close = "]" } },
	units = { '"', "*", "**", "|" },
})

local fails = 0

local function check(name, ok, got)
	if not ok then
		fails = fails + 1
	end
	print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ("\n  got: " .. got)))
end

local function buffer(lines, cursor)
	vim.cmd("enew!")
	vim.bo.expandtab = true
	vim.bo.shiftwidth = 4
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	vim.api.nvim_win_set_cursor(0, cursor)
end

-- Type `keys` into a buffer holding `lines` and compare the result.
local function t(name, lines, cursor, keys, expect, ecursor)
	buffer(lines, cursor)
	vim.api.nvim_feedkeys(vim.keycode(keys), "tx", false)
	local got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local cur = vim.api.nvim_win_get_cursor(0)
	local ok = vim.deep_equal(got, expect) and (not ecursor or vim.deep_equal(cur, ecursor))
	check(name, ok, vim.inspect(got) .. " cursor " .. vim.inspect(cur))
end

-- Must run first: no surround has happened yet.
t("visual dot without op", { "ab" }, { 1, 0 }, "v.x", { "b" })

t("charwise", { "Here are some words." }, { 1, 5 }, "veeS(", { "Here (are some) words." }, { 1, 6 })
t("viw", { "foo bar" }, { 1, 5 }, 'viwS"', { 'foo "bar"' })
t("multibyte end", { "héé x" }, { 1, 0 }, "veS(", { "(héé) x" })
t("space pad", { "x" }, { 1, 0 }, "vS  [", { "[  x  ]" })
t("default pad", { "x y" }, { 1, 0 }, "vS{", { "{ x } y" }, { 1, 2 })
t("newline pad", { "    A => do_it()," }, { 1, 9 }, "v6lS<CR>{", { "    A => {", "        do_it()", "    }," })
t("linewise", { "a", "b", "c" }, { 1, 0 }, 'VjS"', { '"a"', '"b"', "c" })
t("block", { "x = todo!(),", "y = todo!()," }, { 1, 4 }, "<C-v>j6lS {", { "x = { todo!() },", "y = { todo!() }," })

t("ambiguous ** immediate", { "ab" }, { 1, 0 }, "vlS**", { "**ab**" })
t("ambiguous * accept", { "ab" }, { 1, 0 }, "vlS*<CR>", { "*ab*" })
t("ambiguous * auto_terminate", { "ab", "cd" }, { 1, 0 }, "vlS*j", { "*ab*", "cd" }, { 2, 1 })

t("esc aborts", { "aa" }, { 1, 0 }, "vlS<Esc>", { "aa" })
t("esc leaves visual", { "aa" }, { 1, 0 }, "vlS<Esc>x", { "a" })
t("unknown key", { "aa" }, { 1, 0 }, "vlSZ", { "aa" })

t("dot charwise", { "aaa bbb ccc" }, { 1, 0 }, 'veS"ww.', { '"aaa" "bbb" ccc' })
t("dot twice", { "aa bb cc" }, { 1, 0 }, "veS(ww.ww.", { "(aa) (bb) (cc)" })
t("dot after ambiguous", { "ab cd" }, { 1, 0 }, "vlS**W.", { "**ab** **cd**" })
t("dot linewise", { "a", "b", "c", "d" }, { 1, 0 }, "VjS(jj.", { "(a)", "(b)", "(c)", "(d)" })
t("dot block", { "ab", "cd", "ef", "gh" }, { 1, 0 }, "<C-v>jS(jj0.", { "(a)b", "(c)d", "(e)f", "(g)h" })
t("visual dot", { "a bbb cc" }, { 1, 0 }, "vS(Wviw.", { "(a) (bbb) cc" })
t("visual dot then normal dot", { "a bbb cc" }, { 1, 0 }, "vS(Wviw.W.", { "(a) (bbb) (cc)" })

t("undo is one step", { "aa" }, { 1, 0 }, "vlS(u", { "aa" })
t("dot undo", { "aa bb" }, { 1, 0 }, "veS(w.u", { "(aa) bb" })

-- Macros: keys already in typeahead must not run before the surround.
buffer({ "aa bb cc" }, { 1, 0 })
vim.fn.setreg("q", vim.keycode("veS(W"))
vim.api.nvim_feedkeys("@q@q", "tx", false)
local got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
check("macro", vim.deep_equal(got, { "(aa) (bb) cc" }), vim.inspect(got))

-- Timeout: feed without "x" so the event loop runs while we wait.
buffer({ "ab cd" }, { 1, 0 })
vim.api.nvim_feedkeys("vlS*", "t", false)
vim.wait(1000, function()
	return false
end)
vim.api.nvim_feedkeys("W.", "tx", false)
got = vim.api.nvim_buf_get_lines(0, 0, -1, false)
check("timeout then dot", vim.deep_equal(got, { "*ab* *cd*" }), vim.inspect(got))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
vim.cmd(fails == 0 and "qa!" or "cq!")
