return {
	-- Key pressed in visual mode to trigger surrounding.
	surround = "S",

	-- While reading a delimiter, pressing this key immediately accepts a shorter
	-- ambiguous match (e.g. `*` when `**` is also configured).
	-- NOTE: in the PADDING phase <CR> is still a newline-pad, not accept.
	accept = "<CR>",

	-- Milliseconds to wait before auto-accepting a shorter ambiguous delimiter.
	-- Only starts when genuine ambiguity exists. Non-ambiguous keys are instant.
	timeout = 500,

	-- When true, any character that cannot extend the current prefix (and is not
	-- accept/ESC) immediately accepts the shorter match and feeds the character
	-- back to Neovim as if it was never consumed.
	-- Example: `S*j` with auto_terminate=true → surrounds with `*`, then `j`
	--           moves the cursor down as usual.
	auto_terminate = true,

	-- Characters treated as padding between `S` and the delimiter.
	--   " "    → space pad : each press adds one space on each side of selection
	--   "<CR>" → newline pad: splits selection onto its own indented line
	padding = { " ", "<CR>" },

	-- When true, visual LINE mode (`V`) surrounds each selected line individually.
	-- When false, the whole line-range is treated as one region.
	visual_lines_separate = true,

	-- ── Symmetric delimiters ─────────────────────────────────────────────────
	-- You can say: { delimiter = "|", pad = " " },
	units = {
		-- Single as Single
		"`",
		"~",
		"!",
		"@",
		"#",
		"$",
		"%",
		"^",
		"&",
		"*",
		"**",
		"-",
		"_",
		"+",
		"'",
		'"',
		"|",
		"/",

		-- Single as Double
		{ key = "=", delimiter = "==" },

		-- Double as Double
		-- "**",

		-- Special
		-- Italics
		{ key = "i", delimiter = "*" },
		{ key = "I", delimiter = "*" },
		-- Bold
		{ key = "b", delimiter = "**" },
		{ key = "B", delimiter = "**" },
		-- Highlight
		{ key = "h", delimiter = "==" },
		{ key = "H", delimiter = "==" },
	},

	-- ── Asymmetric delimiters ─────────────────────────────────────────────────
	pairs = {
		{ open = "[", close = "]" },
		{ open = "(", close = ")" },
		{ open = "{", close = "}" },
		{ open = "<", close = ">" },
		{ key = "``", open = "```", close = "```", pad = "\n" },
	},
}
