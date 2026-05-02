# surrounded.nvim

A minimal, fully configurable Neovim plugin that lets you surround a visual selection by pressing a key.

---

## Features

- Press `S` (configurable) in visual mode, then type a delimiter
- Optional **padding**: press `<Space>` (or any configured pad chars) before the delimiter
- **Multi-character delimiters**: `**`, `==`, `__`, etc.
- **Ambiguity resolution**: if `*` and `**` are both configured, waits for a timeout or `<CR>` to decide
- Fully user-configurable via `setup()`

---

## Quick Start (lazy.nvim)

```lua
{
  dir = "/path/to/surrounded",   -- local clone
  -- OR for a GitHub repo:
  -- "yourusername/surrounded.nvim",
  config = function()
    require("surrounded").setup()  -- use all defaults
  end,
}
```

---

## Default Behaviour

| Keys typed (in visual mode) | Result (selection = `are some`) |
|-----------------------------|---------------------------------|
| `S[`   | `[are some]`   |
| `S(`   | `(are some)`   |
| `S{`   | `{are some}`   |
| `S"`   | `"are some"`   |
| `S'`   | `'are some'`   |
| `S\`` | `` `are some` `` |
| `S*`   | `*are some*`   |
| `S**`  | `**are some**` |
| `S=` or `S==` | `==are some==` |
| `S\|`  | `\| are some \|` (auto-padded) |
| `S [`  | `[ are some ]` (space = padding) |
| `S  [` | `[  are some  ]` (2 spaces = 2 pad) |

---

## Configuration Reference

```lua
require("surrounded").setup({
  -- Key pressed in visual mode to start surrounding
  surround = "S",

  -- Key to immediately accept an ambiguous shorter prefix
  -- (e.g. `*` when `**` is also defined)
  accept = "<CR>",

  -- Milliseconds to wait before auto-accepting a shorter prefix
  timeout = 500,

  -- Characters recognised as "padding" when typed between `S` and the delimiter.
  -- Each occurrence adds one space on both sides of the wrapped text.
  padding = { " " },

  -- ── Symmetric delimiters ────────────────────────────────────────────────
  -- The opening and closing text are the same.
  --
  -- String shorthand:  "**"        → key = "**", open = "**", close = "**"
  -- Table (key ≠ delim): { key = "=", delimiter = "==" }
  --                     → pressing `=` inserts `==…==`
  -- Table (auto-pad):   { delimiter = "|", pad = " " }
  --                     → pressing `|` inserts `| … |`
  units = {
    "*",
    "**",
    "==",
    { key = "=",  delimiter = "==" },     -- single `=` → `==`
    { delimiter = "|", pad = " " },        -- `|` always padded
  },

  -- ── Asymmetric delimiters ───────────────────────────────────────────────
  -- Opening and closing text differ.  The key defaults to `open`.
  --
  -- Basic:              { open = "[",  close = "]" }
  -- Explicit key:       { key = "[",  open = "[ ", close = " ]" }
  -- Pad shorthand:      { open = "[",  close = "]", pad = " " }
  --                     → equivalent to { open="[ ", close=" ]" }
  pairs = {
    { open = "[",  close = "]"  },
    { open = "(",  close = ")"  },
    { open = "{",  close = "}"  },
    { open = "<",  close = ">"  },
    { open = '"',  close = '"'  },
    { open = "'",  close = "'"  },
    { open = "`",  close = "`"  },
  },
})
```

---

## Ambiguity & Timeout

When you have both `"*"` and `"**"` configured:

1. You press `S*`.
2. The plugin has a valid match (`*`) but `**` could also match.
3. It waits up to `timeout` ms for another character.
   - Another `*` arrives → inserts `**…**`.
   - `<CR>` arrives     → accepts `*…*` immediately.
   - Timeout expires   → accepts `*…*` automatically.

---

## Installation Examples

### lazy.nvim (local directory)

```lua
{
  dir = "~/plugins/surrounded",
  config = function()
    require("surrounded").setup({
      timeout = 400,
      units = { "*", "**", "_", "__", "==", { key = "=", delimiter = "==" } },
      pairs = {
        { open = "[", close = "]" },
        { open = "(", close = ")" },
        { open = "{", close = "}" },
        { open = '"', close = '"' },
        { open = "'", close = "'" },
      },
    })
  end,
}
```

### lazy.nvim (GitHub)

```lua
{
  "yourusername/surrounded.nvim",
  event = "VeryLazy",
  opts = {
    surround = "S",
    timeout  = 500,
  },
}
```

> **Tip:** Using `opts = { … }` instead of `config = function() … end` automatically
> calls `require("surrounded").setup(opts)` for you via lazy.nvim.
