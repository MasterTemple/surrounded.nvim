-- surrounded/lua/surrounded/init.lua

local M = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Default configuration
-- ─────────────────────────────────────────────────────────────────────────────

local DEFAULT_CONFIG = {
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Module-level state
-- ─────────────────────────────────────────────────────────────────────────────

local config = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Utilities
-- ─────────────────────────────────────────────────────────────────────────────

local function merge(base, overrides)
	if type(overrides) ~= "table" then
		return base
	end
	local result = vim.deepcopy(base)
	for k, v in pairs(overrides) do
		if type(v) == "table" and type(result[k]) == "table" and not vim.islist(v) then
			result[k] = merge(result[k], v)
		else
			result[k] = v
		end
	end
	return result
end

-- Resolve a human-readable key string to the raw bytes getcharstr() returns.
local function R(s)
	return vim.api.nvim_replace_termcodes(s, true, true, true)
end

-- Pre-resolved constants.
local BYTE_CR = R("<CR>")
local BYTE_ESC = R("<Esc>")

-- ─────────────────────────────────────────────────────────────────────────────
-- Padding classification
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns true if `ch` (raw getcharstr byte) is a configured space-like pad.
local function is_space_pad(ch)
	for _, p in ipairs(config.padding) do
		local raw = R(p)
		if raw ~= BYTE_CR and ch == raw then
			return true
		end
	end
	return false
end

-- Returns true if `ch` is a newline-pad (<CR> listed in config.padding).
local function is_newline_pad(ch)
	if ch ~= BYTE_CR then
		return false
	end
	for _, p in ipairs(config.padding) do
		if R(p) == BYTE_CR then
			return true
		end
	end
	return false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Delimiter lookup table
-- ─────────────────────────────────────────────────────────────────────────────

--[[
  lookup[raw_key_bytes] = list of { open=string, close=string }

  Keys are stored as raw bytes so direct comparison with getcharstr() works.
  Multi-character keys (e.g. "**") are stored under their full raw byte string.
]]

local function build_lookup()
	local lookup = {}

	local function add(key_str, open, close)
		local raw = R(key_str)
		if not lookup[raw] then
			lookup[raw] = {}
		end
		table.insert(lookup[raw], { open = open, close = close })
	end

	for _, u in ipairs(config.units) do
		if type(u) == "string" then
			add(u, u, u)
		elseif type(u) == "table" then
			local delim = u.delimiter or u.key or u[1]
			local key = u.key or delim
			if u.pad then
				add(key, delim .. u.pad, u.pad .. delim)
			else
				add(key, delim, delim)
			end
		end
	end

	for _, p in ipairs(config.pairs) do
		local key = p.key or p.open
		local open = p.open
		local close = p.close
		if p.pad then
			open = open .. p.pad
			close = p.pad .. close
		end
		add(key, open, close)
	end

	return lookup
end

-- Returns (exact_list | nil, can_extend: bool) for a given raw prefix.
local function find_candidates(lookup, prefix)
	local exact = lookup[prefix]
	local extendable = false
	for k in pairs(lookup) do
		if #k > #prefix and k:sub(1, #prefix) == prefix then
			extendable = true
			break
		end
	end
	return exact, extendable
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Timeout-aware character read (libuv timer – reliable across all Neovim vers.)
-- ─────────────────────────────────────────────────────────────────────────────

local function getchar_with_timeout(ms)
	local uv = vim.uv or vim.loop
	local fired = false

	local timer = uv.new_timer()
	timer:start(
		ms,
		0,
		vim.schedule_wrap(function()
			if fired then
				return
			end
			fired = true
			timer:close()
			-- Feed a NUL to unblock getcharstr(); we detect it below.
			vim.api.nvim_feedkeys("\0", "n", false)
		end)
	)

	local ch = vim.fn.getcharstr()

	if not fired then
		fired = true
		timer:stop()
		timer:close()
	end

	if ch == "\0" or ch == "" then
		return nil -- timed out
	end
	return ch
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Indentation helpers
-- ─────────────────────────────────────────────────────────────────────────────

-- Leading whitespace of a given 1-indexed line number.
local function line_indent(lnum)
	local text = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
	return text:match("^(%s*)") or ""
end

-- One shiftwidth worth of indent (respects expandtab).
local function one_indent()
	if vim.bo.expandtab then
		return string.rep(" ", vim.fn.shiftwidth())
	else
		return "\t"
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Apply the surrounding
-- ─────────────────────────────────────────────────────────────────────────────

local function apply_surround(open, close, space_count, newline_count)
	local buf = vim.api.nvim_get_current_buf()

	-- '< / '> are 1-indexed; nvim_buf_{get,set}_text uses 0-indexed rows + byte cols.
	local srow = vim.fn.line("'<") - 1 -- 0-indexed, inclusive
	local scol = vim.fn.col("'<") - 1 -- 0-indexed byte col, inclusive
	local erow = vim.fn.line("'>") - 1 -- 0-indexed, inclusive
	local ecol = vim.fn.col("'>") -- exclusive byte col (col("'>") is the byte
	-- of the last char's START; for single-byte
	-- chars this equals the exclusive end)

	local lines = vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {})
	if #lines == 0 then
		return
	end

	local replacement

	if newline_count > 0 then
		-- ── Newline-padding mode ───────────────────────────────────────────────
		-- Layout:
		--   <open>
		--       <content lines, re-indented one level deeper>
		--   <base_indent><close>
		--
		-- base_indent = whitespace of the line the selection starts on.

		local base_indent = line_indent(srow + 1) -- srow is 0-indexed, lnum is 1-indexed
		local inner_indent = base_indent .. one_indent()

		local content = {}
		for i, l in ipairs(lines) do
			if i == 1 then
				-- First selected fragment is mid-line → just prepend inner indent
				content[i] = inner_indent .. l
			else
				-- Subsequent lines: strip original leading whitespace, re-apply inner indent
				content[i] = inner_indent .. (l:match("^%s*(.*)$") or l)
			end
		end

		replacement = { open }
		for _, cl in ipairs(content) do
			table.insert(replacement, cl)
		end
		table.insert(replacement, base_indent .. close)
	else
		-- ── Space-padding mode (or no padding) ────────────────────────────────
		local pad = string.rep(" ", space_count)
		replacement = vim.deepcopy(lines)
		replacement[1] = open .. pad .. replacement[1]
		replacement[#replacement] = replacement[#replacement] .. pad .. close
	end

	vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, replacement)

	-- Position cursor at the start of the inner content.
	if newline_count > 0 then
		local inner_row = srow + 2 -- row after the `open` line (1-indexed)
		local base_indent = line_indent(srow + 1)
		local inner_col = #(base_indent .. one_indent())
		vim.api.nvim_win_set_cursor(0, { inner_row, inner_col })
	else
		local pad = string.rep(" ", space_count)
		vim.api.nvim_win_set_cursor(0, { srow + 1, scol + #open + #pad })
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Input loop
-- ─────────────────────────────────────────────────────────────────────────────

local function read_surround()
	local lookup = build_lookup()
	local accept_raw = R(config.accept) -- raw bytes for the "accept" key

	-- ── Phase 1: padding collection ──────────────────────────────────────────
	-- Read characters.  Space-like chars increment space_count.
	-- <CR> (when configured as padding) increments newline_count.
	-- The first non-padding character starts the delimiter phase.

	local space_count = 0
	local newline_count = 0
	local ch = vim.fn.getcharstr()

	while true do
		if ch == BYTE_ESC then
			return
		end

		if is_newline_pad(ch) then
			newline_count = newline_count + 1
			ch = vim.fn.getcharstr()
		elseif is_space_pad(ch) then
			space_count = space_count + 1
			ch = vim.fn.getcharstr()
		else
			break -- `ch` is the first byte of the delimiter
		end
	end

	-- ── Phase 2: delimiter collection ────────────────────────────────────────
	-- Accumulate characters into `prefix`, checking the lookup after each one.
	--
	-- Execution rules:
	--   exact + not extendable  → run immediately (unambiguous)
	--   exact + extendable      → start timeout; accept shorter on timeout / <CR>
	--   not exact + extendable  → read next char (no timeout; not valid yet)
	--   not exact + not extendable → nothing matches, warn & abort

	local prefix = ch -- raw bytes accumulated so far

	while true do
		if prefix == BYTE_ESC then
			return
		end

		-- <CR> in delimiter phase = "accept current exact match"
		if prefix == accept_raw then
			vim.notify("surrounded: nothing to accept", vim.log.levels.WARN)
			return
		end

		local exact, extendable = find_candidates(lookup, prefix)

		if not exact and not extendable then
			-- Nothing will ever match this prefix.
			vim.notify("surrounded: no surround mapped to '" .. prefix .. "'", vim.log.levels.WARN)
			return
		end

		if exact and not extendable then
			-- Unambiguous – execute immediately, no delay.
			apply_surround(exact[1].open, exact[1].close, space_count, newline_count)
			return
		end

		if exact and extendable then
			-- Ambiguous: shorter match is valid but longer one is possible.
			-- Wait up to `timeout` ms.
			local next_ch = getchar_with_timeout(config.timeout)

			if next_ch == nil then
				-- Timed out → accept the shorter match.
				apply_surround(exact[1].open, exact[1].close, space_count, newline_count)
				return
			end

			if next_ch == BYTE_ESC then
				return
			end

			if next_ch == accept_raw then
				-- User explicitly accepted the shorter match.
				apply_surround(exact[1].open, exact[1].close, space_count, newline_count)
				return
			end

			-- Extend the prefix and loop.
			prefix = prefix .. next_ch
		else
			-- extendable but no exact match yet: keep reading (no timeout – not valid yet).
			local next_ch = vim.fn.getcharstr()
			if next_ch == BYTE_ESC then
				return
			end
			if next_ch == accept_raw then
				vim.notify("surrounded: incomplete delimiter '" .. prefix .. "'", vim.log.levels.WARN)
				return
			end
			prefix = prefix .. next_ch
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Keymap
-- ─────────────────────────────────────────────────────────────────────────────

local function register_keymap()
	vim.keymap.set("x", config.surround, function()
		-- Exit visual mode first so '< and '> are updated, then run the loop.
		vim.api.nvim_feedkeys(BYTE_ESC, "x", false)
		vim.schedule(read_surround)
	end, {
		desc = "surrounded: surround visual selection",
		noremap = true,
		silent = true,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

--- Set up the plugin.
--- @param user_config? table  Partial config merged with defaults.
function M.setup(user_config)
	config = merge(DEFAULT_CONFIG, user_config or {})
	register_keymap()
end

return M
