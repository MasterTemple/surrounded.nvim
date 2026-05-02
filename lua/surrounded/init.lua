-- surrounded/lua/surrounded/init.lua

local M = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Default configuration
-- ─────────────────────────────────────────────────────────────────────────────

local DEFAULT_CONFIG = {
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
		{ key = "``", open = "```", close = "```", pad = "\r" },
	},
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Module-level state
-- ─────────────────────────────────────────────────────────────────────────────

local config = {}

-- Last successful operation, used for dot-repeat.
-- { open, close, space_count, newline_count, vis_mode }
local last_op = nil

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

local BYTE_CR = R("<CR>")
local BYTE_ESC = R("<Esc>")

-- ─────────────────────────────────────────────────────────────────────────────
-- Padding classification
-- ─────────────────────────────────────────────────────────────────────────────

local function is_space_pad(ch)
	for _, p in ipairs(config.padding) do
		local raw = R(p)
		if raw ~= BYTE_CR and ch == raw then
			return true
		end
	end
	return false
end

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
-- Delimiter lookup
-- ─────────────────────────────────────────────────────────────────────────────

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

-- Returns (exact_list|nil, can_extend:bool).
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
-- Timeout-aware getcharstr (libuv timer)
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
		return nil
	end
	return ch
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Indentation helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function line_indent(lnum)
	local text = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
	return text:match("^(%s*)") or ""
end

local function one_indent()
	if vim.bo.expandtab then
		return string.rep(" ", vim.fn.shiftwidth())
	else
		return "\t"
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Selection geometry (handles charwise, linewise, blockwise)
-- ─────────────────────────────────────────────────────────────────────────────

--[[
  Returns a list of "spans", one per logical region to surround.
  Each span: { srow, scol, erow, ecol }   (all 0-indexed, ecol exclusive)

  Visual modes (detected from vis_mode parameter, captured before <Esc>):
    "v"  – charwise   → one span covering the exact selection
    "V"  – linewise   → one span covering full lines (scol=0, ecol=line length)
    "\22"– blockwise  → one span per line in the block, same column bounds
]]

local VISUAL_BLOCK = R("<C-v>") -- "\22"

local function get_spans(vis_mode)
	local buf = vim.api.nvim_get_current_buf()

	local srow = vim.fn.line("'<") - 1
	local erow = vim.fn.line("'>") - 1

	-- Helper: safe exclusive end-col for a given 0-indexed row.
	-- Clamps to the actual byte length of that line.
	local function safe_ecol(row, raw_col)
		local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
		-- Neovim uses 2147483647 as a sentinel meaning "end of line" in some APIs
		if raw_col >= #line then
			return #line
		end
		return raw_col
	end

	if vis_mode == "V" then
		-- Linewise: span full lines.
		local spans = {}
		for row = srow, erow do
			local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
			-- Strip trailing newline sentinel if present, clamp to line length.
			table.insert(spans, { srow = row, scol = 0, erow = row, ecol = #line })
		end
		return spans
	elseif vis_mode == VISUAL_BLOCK then
		-- Blockwise: same column bounds on every row.
		-- col("'<") and col("'>") may be swapped if selection was made right→left;
		-- always use the smaller as start col.
		local c1 = vim.fn.col("'<") - 1
		local c2 = vim.fn.col("'>") -- exclusive

		-- Ensure c1 <= c2 - 1  (i.e. start <= end)
		local block_scol = math.min(c1, c2 - 1)
		local block_ecol = math.max(c1, c2 - 1) + 1 -- exclusive

		local spans = {}
		for row = srow, erow do
			local sc = safe_ecol(row, block_scol)
			local ec = safe_ecol(row, block_ecol)
			-- Skip rows that don't reach the block start column.
			if sc <= ec then
				table.insert(spans, { srow = row, scol = sc, erow = row, ecol = ec })
			end
		end
		return spans
	else
		-- Charwise (default).
		local sc = vim.fn.col("'<") - 1
		local ec = vim.fn.col("'>")
		ec = safe_ecol(erow, ec)
		return { { srow = srow, scol = sc, erow = erow, ecol = ec } }
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Core: apply surrounding to one span
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns the row offset introduced by the replacement (lines added - lines removed).
local function apply_span(buf, span, open, close, space_count, newline_count)
	local srow = span.srow
	local scol = span.scol
	local erow = span.erow
	local ecol = span.ecol

	local lines = vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {})
	if #lines == 0 then
		return 0
	end

	local replacement
	local row_delta = 0

	if newline_count > 0 then
		local base_indent = line_indent(srow + 1)
		local inner_indent = base_indent .. one_indent()

		local content = {}
		for i, l in ipairs(lines) do
			if i == 1 then
				content[i] = inner_indent .. l
			else
				content[i] = inner_indent .. (l:match("^%s*(.*)$") or l)
			end
		end

		replacement = { open }
		for _, cl in ipairs(content) do
			table.insert(replacement, cl)
		end
		table.insert(replacement, base_indent .. close)

		-- We replaced (erow - srow + 1) original lines with #replacement lines.
		row_delta = #replacement - (erow - srow + 1)
	else
		local pad = string.rep(" ", space_count)
		replacement = vim.deepcopy(lines)
		replacement[1] = open .. pad .. replacement[1]
		replacement[#replacement] = replacement[#replacement] .. pad .. close
		row_delta = 0 -- same number of lines
	end

	vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, replacement)
	return row_delta
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main apply entry-point (handles multi-span, cursor placement)
-- ─────────────────────────────────────────────────────────────────────────────

local function apply_surround(open, close, space_count, newline_count, vis_mode)
	local buf = vim.api.nvim_get_current_buf()
	local spans = get_spans(vis_mode)
	if #spans == 0 then
		return
	end

	-- Apply spans in reverse order so earlier row indices stay valid.
	local row_offsets = {}
	for i = #spans, 1, -1 do
		local delta = apply_span(buf, spans[i], open, close, space_count, newline_count)
		row_offsets[i] = delta
	end

	-- Move cursor to start of content in the first span.
	local first = spans[1]
	if newline_count > 0 then
		local inner_row = first.srow + 2 -- 1-indexed: srow+1 is open, srow+2 is content
		local base_indent = line_indent(first.srow + 1)
		local inner_col = #(base_indent .. one_indent())
		vim.api.nvim_win_set_cursor(0, { inner_row, inner_col })
	else
		local pad = string.rep(" ", space_count)
		vim.api.nvim_win_set_cursor(0, { first.srow + 1, first.scol + #open + #pad })
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Dot-repeat
-- ─────────────────────────────────────────────────────────────────────────────

--[[
  Dot-repeat strategy
  ───────────────────
  Neovim's native `.` repeats the last *normal-mode* change.  Visual-mode
  operations don't integrate with it automatically.

  Our approach:
    1. After every successful surround we store the parameters in `last_op`.
    2. We set `operatorfunc` to a thin wrapper that re-applies those parameters.
    3. We call `g@` with the motion `gv` (re-select last visual selection).
       In practice we map `.` in normal mode, temporarily, so that the very next
       `.` press re-runs the operation on the current visual selection (`gv`).

  The cleanest way that works without vim-repeat:
    - After success, store params.
    - Map `<dot>` in normal mode to: `gv` (re-enter visual) then trigger our
      operatorfunc via `<Cmd>lua require("surrounded")._repeat()<CR>`.
    - The repeat function reads `last_op`, re-enters visual (`gv`), and calls
      apply_surround with the same params.
    - We use a one-shot autocmd on ModeChanged to detect when the user leaves
      normal mode without using `.`, at which point we clear the dot mapping
      so it doesn't interfere with anything else.

  Note: we do NOT clobber the global `.` permanently – it is only active after a
  surround operation and is cleared the moment the user makes any other change.
]]

local dot_ns = vim.api.nvim_create_namespace("surrounded_dot")
local dot_augrp = vim.api.nvim_create_augroup("surrounded_dot", { clear = true })

local function clear_dot_repeat()
	-- Remove our temporary normal-mode `.` mapping.
	pcall(vim.keymap.del, "n", ".")
	vim.api.nvim_clear_autocmds({ group = dot_augrp })
end

local function setup_dot_repeat(op)
	last_op = op
	clear_dot_repeat() -- remove any previous binding first

	vim.keymap.set("n", ".", function()
		clear_dot_repeat()
		if not last_op then
			return
		end
		-- Re-select the previous visual selection then apply.
		-- We need to know the visual mode that was active; it is stored in last_op.
		local lo = last_op

		-- Re-enter the correct visual mode on '< '>
		local resel_key
		if lo.vis_mode == "V" then
			resel_key = R("'<V'>")
		elseif lo.vis_mode == R("<C-v>") then
			resel_key = R("'<") .. R("<C-v>") .. R("'>")
		else
			resel_key = R("'<v'>")
		end
		vim.api.nvim_feedkeys(resel_key, "nx", false)

		-- After the feedkeys the mode is visual; call apply directly.
		vim.schedule(function()
			-- ESC to commit '< '> then apply.
			vim.api.nvim_feedkeys(BYTE_ESC, "x", false)
			vim.schedule(function()
				apply_surround(lo.open, lo.close, lo.space_count, lo.newline_count, lo.vis_mode)
			end)
		end)
	end, {
		desc = "surrounded: repeat last surround",
		noremap = true,
		silent = true,
		buffer = false,
	})

	-- Clear dot mapping if the user does anything else (TextChanged, InsertEnter,
	-- any normal-mode key that isn't `.`).
	vim.api.nvim_create_autocmd({ "TextChanged", "InsertEnter", "CmdlineEnter" }, {
		group = dot_augrp,
		once = true,
		callback = function()
			-- Only clear if it wasn't a dot-repeat that caused TextChanged.
			vim.schedule(clear_dot_repeat)
		end,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Input loop
-- ─────────────────────────────────────────────────────────────────────────────

local function read_surround(vis_mode)
	local lookup = build_lookup()
	local accept_raw = R(config.accept)

	-- ── Phase 1: padding ─────────────────────────────────────────────────────
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
			break
		end
	end

	-- ── Phase 2: delimiter ───────────────────────────────────────────────────
	local prefix = ch

	while true do
		if prefix == BYTE_ESC then
			return
		end

		if prefix == accept_raw then
			vim.notify("surrounded: nothing to accept", vim.log.levels.WARN)
			return
		end

		local exact, extendable = find_candidates(lookup, prefix)

		if not exact and not extendable then
			vim.notify("surrounded: no surround mapped to '" .. prefix .. "'", vim.log.levels.WARN)
			return
		end

		if exact and not extendable then
			-- Unambiguous → instant execution.
			apply_surround(exact[1].open, exact[1].close, space_count, newline_count, vis_mode)
			setup_dot_repeat({
				open = exact[1].open,
				close = exact[1].close,
				space_count = space_count,
				newline_count = newline_count,
				vis_mode = vis_mode,
			})
			return
		end

		if exact and extendable then
			-- Ambiguous: valid shorter match exists, longer possible → use timeout.
			local next_ch = getchar_with_timeout(config.timeout)

			if next_ch == nil then
				-- Timed out → accept shorter.
				apply_surround(exact[1].open, exact[1].close, space_count, newline_count, vis_mode)
				setup_dot_repeat({
					open = exact[1].open,
					close = exact[1].close,
					space_count = space_count,
					newline_count = newline_count,
					vis_mode = vis_mode,
				})
				return
			end

			if next_ch == BYTE_ESC then
				return
			end

			if next_ch == accept_raw then
				apply_surround(exact[1].open, exact[1].close, space_count, newline_count, vis_mode)
				setup_dot_repeat({
					open = exact[1].open,
					close = exact[1].close,
					space_count = space_count,
					newline_count = newline_count,
					vis_mode = vis_mode,
				})
				return
			end

			-- Check if next_ch can extend the prefix.
			local extended = prefix .. next_ch
			local _, ext2 = find_candidates(lookup, extended)
			local exact2 = lookup[extended]

			if not exact2 and not ext2 then
				-- next_ch cannot extend prefix at all.
				if config.auto_terminate then
					-- Accept current exact match, feed next_ch back.
					apply_surround(exact[1].open, exact[1].close, space_count, newline_count, vis_mode)
					setup_dot_repeat({
						open = exact[1].open,
						close = exact[1].close,
						space_count = space_count,
						newline_count = newline_count,
						vis_mode = vis_mode,
					})
					-- Feed the unrecognised char back so Neovim processes it normally.
					vim.api.nvim_feedkeys(next_ch, "n", false)
					return
				else
					-- Without auto_terminate, warn and abort.
					vim.notify("surrounded: '" .. next_ch .. "' cannot extend '" .. prefix .. "'", vim.log.levels.WARN)
					return
				end
			end

			prefix = extended
		else
			-- extendable but no exact match: read more (no timeout, nothing valid yet).
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
		-- Capture the visual mode BEFORE leaving visual mode.
		-- mode() returns "v", "V", or "\22" (CTRL-V) while still in visual mode.
		local vis_mode = vim.fn.mode()

		-- Leave visual mode so '< and '> get committed.
		vim.api.nvim_feedkeys(BYTE_ESC, "x", false)

		vim.schedule(function()
			read_surround(vis_mode)
		end)
	end, {
		desc = "surrounded: surround visual selection",
		noremap = true,
		silent = true,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

function M.setup(user_config)
	config = merge(DEFAULT_CONFIG, user_config or {})
	register_keymap()
end

return M
