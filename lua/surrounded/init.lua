-- surrounded/lua/surrounded/init.lua  (v4)

local M = {}

local DEFAULT_CONFIG = require("surrounded.config")

-- ─────────────────────────────────────────────────────────────────────────────
-- Module-level state
-- ─────────────────────────────────────────────────────────────────────────────

local config = {}
local last_op = nil -- saved for dot-repeat

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

local BYTE_CR = R("<CR>") -- \r
local BYTE_ESC = R("<Esc>") -- \27
local BYTE_CTRLV = R("<C-v>") -- \22  (visual block mode indicator)

-- Split a string on literal "\n" characters into a list of lines.
-- "foo\nbar"  →  {"foo", "bar"}
-- "foo"       →  {"foo"}
-- "\nfoo"     →  {"", "foo"}
local function split_lines(s)
	local lines = {}
	local pos = 1
	while true do
		local nl = s:find("\n", pos, true)
		if nl then
			table.insert(lines, s:sub(pos, nl - 1))
			pos = nl + 1
		else
			table.insert(lines, s:sub(pos))
			break
		end
	end
	return lines
end

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

--[[
  lookup[raw_key_bytes] = list of { open=string, close=string }

  Keys are raw bytes (output of R()) so comparisons with getcharstr() work.
  open/close may contain "\n"; split_lines() handles them at apply time.
]]

local function build_lookup()
	local lookup = {}

	local function add(key_str, open, pad, close)
		local raw = R(key_str)
		if not lookup[raw] then
			lookup[raw] = {}
		end
		table.insert(lookup[raw], { open = open, pad = pad, close = close })
	end

	for _, u in ipairs(config.units) do
		if type(u) == "string" then
			add(u, u, u)
		elseif type(u) == "table" then
			local delim = u.delimiter or u.key or u[1]
			local key = u.key or delim
			-- if u.pad then
			-- 	add(key, delim .. u.pad, u.pad .. delim)
			-- else
			add(key, delim, u.pad, delim)
			-- end
		end
	end

	for _, p in ipairs(config.pairs) do
		local key = p.key or p.open
		local open = p.open
		local close = p.close
		-- if p.pad then
		-- 	open = open .. p.pad
		-- 	close = p.pad .. close
		-- end
		add(key, open, p.pad, close)
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
-- Timeout-aware getchar  (polling loop – works from blocking context)
-- ─────────────────────────────────────────────────────────────────────────────
--[[
  vim.schedule_wrap cannot fire while getcharstr() is blocking the main thread,
  so a libuv timer with a scheduled callback never actually interrupts it.

  Solution: poll with getchar(1) (non-blocking, returns 0 when nothing is
  pending) in a tight loop, sleeping 10 ms between polls via vim.uv.sleep()
  which yields to libuv without requiring the Neovim scheduler.
]]

local function getchar_with_timeout(ms)
	local uv = vim.uv or vim.loop
	local elapsed = 0
	local poll_ms = 10 -- granularity

	while elapsed < ms do
		local c = vim.fn.getchar(1) -- non-blocking; 0 = no input
		if c ~= 0 then
			-- A character is waiting – consume it properly.
			-- getchar(1) just peeks; we need to drain it.
			-- Call getcharstr() now – it will return immediately.
			local ch = vim.fn.getcharstr()
			if ch == "\0" or ch == "" then
				return nil
			end
			return ch
		end
		uv.sleep(poll_ms)
		elapsed = elapsed + poll_ms
	end

	return nil -- timed out
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
-- Selection geometry
-- ─────────────────────────────────────────────────────────────────────────────

local function get_spans(vis_mode)
	local buf = vim.api.nvim_get_current_buf()
	local srow = vim.fn.line("'<") - 1 -- 0-indexed
	local erow = vim.fn.line("'>") - 1

	-- Clamp a column to [0, #line] so buf API never gets an out-of-range index.
	local function safe_col(row, col)
		local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
		return math.min(col, #line)
	end

	if vis_mode == "V" then
		if config.visual_lines_separate then
			-- Each line is its own span.
			local spans = {}
			for row = srow, erow do
				local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
				table.insert(spans, { srow = row, scol = 0, erow = row, ecol = #line })
			end
			return spans
		else
			-- Whole line range is one span.
			local last_line = vim.api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1] or ""
			return { { srow = srow, scol = 0, erow = erow, ecol = #last_line } }
		end
	elseif vis_mode == BYTE_CTRLV then
		-- Blockwise: one span per row, same column bounds.
		local c1 = vim.fn.col("'<") - 1 -- 0-indexed inclusive
		local c2 = vim.fn.col("'>") - 1 -- 0-indexed inclusive
		local block_scol = math.min(c1, c2)
		local block_ecol = math.max(c1, c2) + 1 -- exclusive

		local spans = {}
		for row = srow, erow do
			local sc = safe_col(row, block_scol)
			local ec = safe_col(row, block_ecol)
			if sc < ec then
				table.insert(spans, { srow = row, scol = sc, erow = row, ecol = ec })
			end
		end
		return spans
	else
		-- Charwise.
		local sc = vim.fn.col("'<") - 1
		local ec = safe_col(erow, vim.fn.col("'>"))
		return { { srow = srow, scol = sc, erow = erow, ecol = ec } }
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Build replacement lines from open/close strings + content
-- ─────────────────────────────────────────────────────────────────────────────

--[[
  open and close may contain "\n".  We split both into line arrays and
  assemble the final replacement list by concatenating:

    open_lines[1..n-1]  (own lines, if any)
    open_lines[n] .. space_pad .. content_lines[1]
    content_lines[2..m-1]
    content_lines[m] .. space_pad .. close_lines[1]
    close_lines[2..p]   (own lines, if any)

  When newline_count > 0 the content is indented and the open/close go on
  their own lines regardless of whether they already contain "\n".
]]

local function build_replacement(open, close, content_lines, space_count, newline_count, base_indent)
	local open_parts = split_lines(open)
	local close_parts = split_lines(close)
	local pad = string.rep(" ", space_count)

	if newline_count > 0 then
		-- Newline-padding mode: indent content one level deeper.
		local inner_indent = base_indent .. one_indent()
		local indented = {}
		for i, l in ipairs(content_lines) do
			if i == 1 then
				indented[i] = inner_indent .. l
			else
				indented[i] = inner_indent .. (l:match("^%s*(.*)$") or l)
			end
		end

		-- open goes on its own line(s); close is prefixed with base_indent.
		-- If open itself contains newlines, preserve them.
		local result = {}
		for _, l in ipairs(open_parts) do
			table.insert(result, l)
		end
		for _, l in ipairs(indented) do
			table.insert(result, l)
		end
		-- Prefix every close_part line with base_indent.
		for i, l in ipairs(close_parts) do
			table.insert(result, (i == 1 and base_indent or base_indent) .. l)
		end
		return result
	end

	-- Flat (space-pad or no pad) mode.
	-- Merge open into the front and close into the back of the content.
	local result = vim.deepcopy(content_lines)

	-- Attach last open_part to front of content, prepend earlier open_parts.
	result[1] = open_parts[#open_parts] .. pad .. result[1]
	for i = #open_parts - 1, 1, -1 do
		table.insert(result, 1, open_parts[i])
	end

	-- Attach first close_part to back of content, append later close_parts.
	result[#result] = result[#result] .. pad .. close_parts[1]
	for i = 2, #close_parts do
		table.insert(result, close_parts[i])
	end

	return result
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Apply surrounding to a single span
-- ─────────────────────────────────────────────────────────────────────────────

-- Returns the number of new lines introduced (replacement_lines - original_lines).
local function apply_span(buf, span, open, pad, close, space_count, newline_count)
	-- Apply default padding late, if no other padding was explicitly provided
	if space_count == 0 and newline_count == 0 and pad ~= nil then
		open = open .. pad
		close = pad .. close
	end
	local srow = span.srow
	local scol = span.scol
	local erow = span.erow
	local ecol = span.ecol

	local content = vim.api.nvim_buf_get_text(buf, srow, scol, erow, ecol, {})
	if #content == 0 then
		return 0
	end

	local base_indent = line_indent(srow + 1)
	local replacement = build_replacement(open, close, content, space_count, newline_count, base_indent)

	vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, replacement)
	return #replacement - #content -- net line delta
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Main apply entry-point
-- ─────────────────────────────────────────────────────────────────────────────

local function apply_surround(open, pad, close, space_count, newline_count, vis_mode)
	local buf = vim.api.nvim_get_current_buf()
	local spans = get_spans(vis_mode)
	if #spans == 0 then
		return
	end

	-- Process in reverse so row indices of earlier spans stay valid.
	for i = #spans, 1, -1 do
		apply_span(buf, spans[i], open, pad, close, space_count, newline_count)
	end

	-- Cursor: place at the start of content in the first span.
	local first = spans[1]
	local open_parts = split_lines(open)

	if newline_count > 0 then
		-- Content starts on the line after all open_parts lines.
		local content_row = first.srow + #open_parts + 1 -- 1-indexed
		local base_indent = line_indent(first.srow + 1)
		local inner_col = #(base_indent .. one_indent())
		vim.api.nvim_win_set_cursor(0, { content_row, inner_col })
	else
		local pad = string.rep(" ", space_count)
		-- open may have multiple lines; cursor is after the last open_part + pad.
		local cursor_row = first.srow + #open_parts -- 1-indexed (srow+1 + open_parts-1)
		local cursor_col = (
			#open_parts == 1 and first.scol + #open_parts[#open_parts] + #pad or #open_parts[#open_parts] + #pad
		)
		vim.api.nvim_win_set_cursor(0, { cursor_row, cursor_col })
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Dot-repeat
-- ─────────────────────────────────────────────────────────────────────────────
--[[
  Strategy
  ────────
  After every successful surround we store the operation params in `last_op`
  and install a temporary `n .` keymap.

  When `.` is pressed:
    • `'<` / `'>` still hold the marks from the previous visual selection.
    • We call apply_surround directly with those marks and the saved params.
    • No re-entering of visual mode is needed or wanted.

  The `.` keymap is cleared on the next TextChanged / InsertEnter /
  CmdlineEnter so it never permanently replaces the native `.`.

  Why not operatorfunc / g@?
    g@ requires a motion and the result is counted as a normal-mode change,
    which means the native `.` will try to replay `g@<motion>` on subsequent
    presses, which is fragile.  Our one-shot keymap approach is simpler and
    more reliable.
]]

local dot_augrp = vim.api.nvim_create_augroup("surrounded_dot", { clear = true })

local function clear_dot_repeat()
	pcall(vim.keymap.del, "n", ".")
	vim.api.nvim_clear_autocmds({ group = dot_augrp })
end

local function setup_dot_repeat(op)
	last_op = op
	clear_dot_repeat()

	vim.keymap.set("n", ".", function()
		clear_dot_repeat()
		local lo = last_op
		if not lo then
			return
		end
		-- '< and '> still point at the last visual selection.
		-- Apply directly; no need to re-enter visual mode.
		apply_surround(lo.open, lo.pad, lo.close, lo.space_count, lo.newline_count, lo.vis_mode)
		-- Re-arm so the user can press `.` again.
		setup_dot_repeat(lo)
	end, {
		desc = "surrounded: repeat last surround",
		noremap = true,
		silent = true,
	})

	-- Disarm when the user does anything other than `.`.
	vim.api.nvim_create_autocmd({ "TextChanged", "InsertEnter", "CmdlineEnter" }, {
		group = dot_augrp,
		once = true,
		callback = vim.schedule_wrap(clear_dot_repeat),
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Input loop
-- ─────────────────────────────────────────────────────────────────────────────

-- Finish a successful operation: apply + arm dot-repeat.
-- local function finish(open, close, space_count, newline_count, vis_mode)
local function finish(entry, space_count, newline_count, vis_mode)
	local open = entry.open
	local close = entry.close
	local pad = entry.pad
	apply_surround(open, pad, close, space_count, newline_count, vis_mode)
	setup_dot_repeat({
		open = open,
		close = close,
		pad = pad,
		space_count = space_count,
		newline_count = newline_count,
		vis_mode = vis_mode,
	})
end

local function read_surround(vis_mode)
	local lookup = build_lookup()
	local accept_raw = R(config.accept)

	-- ── Phase 1: collect padding ──────────────────────────────────────────────
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

	-- ── Phase 2: collect delimiter ────────────────────────────────────────────
	--
	-- Rules (evaluated after each character is accumulated into `prefix`):
	--
	--   A) exact + not extendable  →  execute immediately (unambiguous, no delay)
	--   B) exact + extendable      →  wait up to `timeout` ms for the next char
	--        timeout / ESC / accept key  → accept the shorter match
	--        char that cannot extend     → accept shorter (auto_terminate) OR warn+abort
	--        char that can  extend       → extend prefix, loop
	--   C) not exact + extendable  →  read next char (blocking, no timeout; not valid yet)
	--   D) not exact + not extendable → abort

	local prefix = ch

	while true do
		if prefix == BYTE_ESC then
			return
		end

		-- <CR> pressed as the very first delimiter character means "nothing to accept".
		if prefix == accept_raw then
			vim.notify("surrounded: nothing to accept", vim.log.levels.WARN)
			return
		end

		local exact, extendable = find_candidates(lookup, prefix)

		-- ── D ────────────────────────────────────────────────────────────────
		if not exact and not extendable then
			vim.notify("surrounded: no surround mapped to '" .. prefix .. "'", vim.log.levels.WARN)
			return
		end

		-- ── A ────────────────────────────────────────────────────────────────
		if exact and not extendable then
			finish(exact[1], space_count, newline_count, vis_mode)
			return
		end

		-- ── B ────────────────────────────────────────────────────────────────
		if exact and extendable then
			local next_ch = getchar_with_timeout(config.timeout)

			if next_ch == nil then
				-- Timed out.
				finish(exact[1], space_count, newline_count, vis_mode)
				return
			end

			if next_ch == BYTE_ESC then
				return
			end

			if next_ch == accept_raw then
				finish(exact[1], space_count, newline_count, vis_mode)
				return
			end

			-- Can this character extend the current prefix?
			local extended = prefix .. next_ch
			local exact2, ext2 = find_candidates(lookup, extended)

			if not exact2 and not ext2 then
				-- Cannot extend.
				if config.auto_terminate then
					finish(exact[1], space_count, newline_count, vis_mode)
					vim.api.nvim_feedkeys(next_ch, "n", false)
					return
				else
					vim.notify("surrounded: '" .. next_ch .. "' cannot extend '" .. prefix .. "'", vim.log.levels.WARN)
					return
				end
			end

			prefix = extended
			-- Loop back: re-evaluate the new prefix (may itself be exact / extendable).
		end

		-- ── C ────────────────────────────────────────────────────────────────
		if not exact and extendable then
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
		local vis_mode = vim.fn.mode() -- capture BEFORE leaving visual mode
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
