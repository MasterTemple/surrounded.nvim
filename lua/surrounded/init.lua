-- surrounded/lua/surrounded/init.lua

local M = {}

-- ─────────────────────────────────────────────
-- Default configuration
-- ─────────────────────────────────────────────

local DEFAULT_CONFIG = {
	-- Key pressed in visual mode to trigger surrounding
	surround = "S",

	-- Key to accept an "ambiguous" shorter prefix (e.g. `*` when `**` is also defined)
	accept = "<CR>",

	-- Milliseconds to wait before auto-accepting a shorter prefix
	timeout = 500,

	-- Characters that may appear between `S` and the delimiter to add padding
	padding = { " " },

	-- Symmetric delimiters  (open == close, or a single key with explicit delimiter)
	-- Supported shapes:
	--   "**"                          → key="**", delimiter="**"
	--   { key="=", delimiter="==" }   → key="=",  delimiter="=="  (key differs from delimiter)
	--   { delimiter="|", pad=" " }    → key="|",  delimiter="|",  always padded
	units = {
		"*",
		"**",
		"==",
		{ key = "=", delimiter = "==" },
		{ delimiter = "|", pad = " " },
	},

	-- Asymmetric delimiters (open ≠ close)
	-- Supported shapes:
	--   { open="[", close="]" }                    → key="["
	--   { key="[", open="[ ", close=" ]" }         → explicit key, open/close with padding
	--   { open="[", close="]", pad=" " }           → pad applied to open/close
	pairs = {
		{ open = "[", close = "]" },
		{ open = "(", close = ")" },
		{ open = "{", close = "}" },
		{ open = "<", close = ">" },
		{ open = '"', close = '"' },
		{ open = "'", close = "'" },
		{ open = "`", close = "`" },
	},
}

-- ─────────────────────────────────────────────
-- Internal state
-- ─────────────────────────────────────────────

local config = {}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

--- Deep-merge `overrides` into `base` (non-destructive on base).
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

--- Translate a keycode string like "<CR>" or "<Space>" to the actual byte(s)
--- getcharstr() returns for that key.
local function keycode(s)
	return vim.api.nvim_replace_termcodes(s, true, true, true)
end

--- Is `ch` (raw char from getcharstr) one of the configured padding characters?
local function is_padding(ch)
	for _, p in ipairs(config.padding) do
		if ch == p or ch == keycode(p) then
			return true
		end
	end
	return false
end

--- Return the number of leading/trailing pad characters to add.
--- `raw_padding` is the string of padding chars collected before the delimiter.
local function count_padding(raw_padding)
	-- Each padding character counts as one space on each side
	return #raw_padding
end

-- ─────────────────────────────────────────────
-- Build lookup tables from config
-- ─────────────────────────────────────────────

--[[
  Lookup structure (built at setup time):
    lookup[key_string] = list of candidate entries, each:
    {
      key        = "**",
      open       = "**",   -- text inserted before selection
      close      = "**",   -- text inserted after  selection
      auto_pad   = false,  -- always add one extra space of padding around content
    }
  Entries are sorted longest-key-first so the trie walk always tries to extend.
]]

local function build_lookup()
	local lookup = {} -- key → list of {key, open, close, auto_pad}

	local function add(key, open, close, auto_pad)
		if not lookup[key] then
			lookup[key] = {}
		end
		table.insert(lookup[key], {
			key = key,
			open = open,
			close = close,
			auto_pad = auto_pad or false,
		})
	end

	-- units (symmetric)
	for _, u in ipairs(config.units) do
		if type(u) == "string" then
			add(u, u, u, false)
		elseif type(u) == "table" then
			local delim = u.delimiter or u.key or u[1]
			local key = u.key or delim
			local pad = u.pad
			if pad then
				add(key, delim .. pad, pad .. delim, false)
			else
				add(key, delim, delim, false)
			end
		end
	end

	-- pairs (asymmetric)
	for _, p in ipairs(config.pairs) do
		local key = p.key or p.open
		local open = p.open
		local close = p.close
		if p.pad then
			open = open .. p.pad
			close = p.pad .. close
		end
		add(key, open, close, false)
	end

	return lookup
end

-- ─────────────────────────────────────────────
-- Ambiguity resolution (timeout / accept key)
-- ─────────────────────────────────────────────

--[[
  Given the current collected key string (`prefix`) we need to decide:
  - If there is exactly one match and no other entry could extend it → execute immediately.
  - If there are multiple entries that share this prefix           → wait for more input.
  - If nothing matches                                             → abort.

  We support multi-character keys like "**" by reading one character at a time
  and accumulating.
]]

local function find_candidates(lookup, prefix)
	-- Exact match
	local exact = lookup[prefix]
	-- Potential extensions: any key that starts with `prefix` and is longer
	local extendable = false
	for k, _ in pairs(lookup) do
		if k ~= prefix and k:sub(1, #prefix) == prefix then
			extendable = true
			break
		end
	end
	return exact, extendable
end

-- ─────────────────────────────────────────────
-- Core surrounding logic
-- ─────────────────────────────────────────────

local function apply_surround(open, close, pad_count)
	-- Build padding string (spaces)
	local pad = string.rep(" ", pad_count)

	-- Get visual selection marks
	-- After leaving visual mode with <Esc> or an operator, '< and '> are set.
	local srow = vim.fn.line("'<") - 1
	local scol = vim.fn.col("'<") - 1
	local erow = vim.fn.line("'>") - 1
	local ecol = vim.fn.col("'>")

	-- nvim_buf_get_text uses 0-indexed rows, byte columns
	-- ecol from col("'>") is 1-indexed, and col() gives the byte position of the
	-- *last* selected character's start, so we need +charlen to go past it.
	local buf = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {})

	if #lines == 0 then
		return
	end

	-- Build replacement: open + pad + <original lines> + pad + close
	local replacement = vim.deepcopy(lines)
	replacement[1] = open .. pad .. replacement[1]
	replacement[#replacement] = replacement[#replacement] .. pad .. close

	vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, replacement)

	-- Place cursor after the inserted open delimiter + pad
	local new_col = scol + #open + #pad
	vim.api.nvim_win_set_cursor(0, { srow + 1, new_col })
end

-- ─────────────────────────────────────────────
-- Interactive key-reading loop
-- ─────────────────────────────────────────────

local function read_surround()
	local lookup = build_lookup()

	-- 1. Collect optional padding characters
	local pad_count = 0
	local ch = vim.fn.getcharstr()

	while is_padding(ch) do
		pad_count = pad_count + 1
		ch = vim.fn.getcharstr()
	end

	-- 2. Collect delimiter key(s) with ambiguity resolution
	local prefix = ch
	local accept_key = keycode(config.accept)

	while true do
		-- Check for user-pressed accept key
		if prefix == accept_key then
			-- Nothing accumulated before accept → abort
			return
		end

		local exact, extendable = find_candidates(lookup, prefix)

		if not exact and not extendable then
			-- No match at all → abort silently
			vim.notify("surrounded: no surround for '" .. prefix .. "'", vim.log.levels.WARN)
			return
		end

		if exact and not extendable then
			-- Unambiguous → execute immediately
			-- If multiple exact entries somehow share the same key, use the first
			local entry = exact[1]
			apply_surround(entry.open, entry.close, pad_count)
			return
		end

		if exact and extendable then
			-- Ambiguous: we have a valid shorter match but could extend.
			-- Wait `timeout` ms for another character.
			local ok, next_ch = pcall(function()
				return vim.fn.getcharstr(config.timeout)
			end)

			if not ok or next_ch == "" or next_ch == nil then
				-- Timeout → accept the shorter match
				local entry = exact[1]
				apply_surround(entry.open, entry.close, pad_count)
				return
			end

			if next_ch == accept_key then
				-- Explicit accept → use current exact match
				local entry = exact[1]
				apply_surround(entry.open, entry.close, pad_count)
				return
			end

			-- Extend the prefix and loop
			prefix = prefix .. next_ch
		else
			-- No exact yet, but extendable → keep reading
			local next_ch = vim.fn.getcharstr()
			if next_ch == accept_key then
				-- User gave up → abort (nothing valid yet)
				return
			end
			prefix = prefix .. next_ch
		end
	end
end

-- ─────────────────────────────────────────────
-- Keymap registration
-- ─────────────────────────────────────────────

local function register_keymap()
	local surround_key = config.surround

	-- Map in visual and select modes
	vim.keymap.set("x", surround_key, function()
		-- Store the visual selection end mark before dropping out of visual mode.
		-- Feeding <Esc> updates '< and '> correctly.
		local esc = keycode("<Esc>")
		vim.api.nvim_feedkeys(esc, "x", false)
		-- Schedule so that '< '> are committed before we read them
		vim.schedule(function()
			read_surround()
		end)
	end, {
		desc = "surrounded: surround visual selection",
		noremap = true,
		silent = true,
	})
end

-- ─────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────

--- Configure and activate the plugin.
--- @param user_config? table  Partial config to merge with defaults.
function M.setup(user_config)
	config = merge(DEFAULT_CONFIG, user_config or {})
	register_keymap()
end

return M
