return {
	-- Key pressed in visual mode to trigger surrounding
	surround = "S",

	-- While reading a delimiter, press this to immediately accept a shorter
	-- ambiguous match (e.g. `*` when `**` is also configured).
	-- <CR> in the PADDING phase is a newline-pad, not accept.
	accept = "<CR>",

	-- Milliseconds to wait before auto-accepting a shorter ambiguous delimiter.
	-- Only fires when genuine ambiguity exists (e.g. `*` vs `**`).
	-- Non-ambiguous delimiters always execute instantly.
	timeout = 500,

	-- Characters treated as padding when typed between `S` and the delimiter.
	--   " "    → space pad  : each press adds one space on each side
	--   "<CR>" → newline pad: splits selection onto its own indented line(s)
	padding = { " ", "<CR>" },

	-- ── Symmetric delimiters ─────────────────────────────────────────────────
	-- open == close.
	-- Shapes:
	--   "**"                        key="**", open="**", close="**"
	--   { key="=", delimiter="==" } pressing `=` yields ==…==
	--   { delimiter="|", pad=" " }  pressing `|` yields | … |
	units = {
		"'",
		'"',
		"`",
		"*",
		"**",
		{ key = "=", delimiter = "==" },
		{ key = "b", delimiter = "**" },
		{ delimiter = "|", pad = " " },
	},

	-- ── Asymmetric delimiters ────────────────────────────────────────────────
	-- open ≠ close.  Key defaults to `open`.
	-- Shapes:
	--   { open="[", close="]" }
	--   { key="[", open="[ ", close=" ]" }
	--   { open="[", close="]", pad=" " }   →  open="[ ", close=" ]"
	pairs = {
		{ open = "[", close = "]" },
		{ open = "(", close = ")" },
		{ open = "{", close = "}" },
		{ open = "<", close = ">" },
	},
}
