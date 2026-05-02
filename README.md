# surrounded.nvim

A minimal, fully configurable Neovim plugin for surrounding visual selections with delimiters.

---

## Features

- **All visual modes**: charwise (`v`), linewise (`V`), blockwise (`<C-v>`)
- **Space padding**: each `<Space>` before the delimiter adds a space on each side
- **Newline padding**: `<CR>` before the delimiter splits selection onto its own indented line
- **Multi-character delimiters** with ambiguity resolution (`*` vs `**`)
- **Auto-terminate** (`auto_terminate = true`): any character that can't extend the current prefix immediately accepts the shorter match and feeds the key back to Neovim
- **Dot-repeat**: after a surround, `.` re-applies it to the previous visual selection

---

## Quick Start

```lua
-- lazy.nvim
{
  dir = "~/path/to/surrounded",
  config = function()
    require("surrounded").setup()
  end,
}
```

---

## Behaviour Reference

### Charwise / linewise

| Keys (visual mode) | Result (`are some` selected) |
|--------------------|------------------------------|
| `S[`  | `[are some]`   |
| `S(`  | `(are some)`   |
| `S{`  | `{are some}`   |
| `S"`  | `"are some"`   |
| `S*`  | `*are some*`   |
| `S**` | `**are some**` |
| `S=`  | `==are some==` |
| `S [` | `[ are some ]` |
| `S "` | `" are some "` |

### Newline padding (`<CR>` before the delimiter)

Selection: `do_something()` inside a match arm.

```
S<CR>{
```

Before:
```rust
SomeEnum::A => do_something(),
```
After:
```rust
SomeEnum::A => {
    do_something()
},
```

- Base indentation is detected from the selection's start line.
- Content is re-indented by one `shiftwidth` (respects `expandtab`).

### Visual block mode

Select a column of `todo!()` calls with `<C-v>`, then `S {`:

Before:
```rust
SomeEnum::A => todo!(),
SomeEnum::B => todo!(),
SomeEnum::C => todo!(),
```
After:
```rust
SomeEnum::A => { todo!() },
SomeEnum::B => { todo!() },
SomeEnum::C => { todo!() },
```

Each row of the block is surrounded independently.

### Auto-terminate

With `auto_terminate = true` (the default) and both `*` and `**` configured:

- `S*<CR>` → `*…*` (explicit accept)
- `S*j`    → `*…*` then the cursor moves down (j is fed back to Neovim)
- `S**`    → `**…**`

Without `auto_terminate`, unrecognised characters after an ambiguous prefix warn and abort.

### Dot-repeat

After `S"`:
1. Make a new visual selection.
2. Press `.` in normal mode.
3. The previous surround (`"…"`) is re-applied to the new selection.

The dot-repeat binding is temporary — it clears itself on the next `TextChanged`, `InsertEnter`, or `CmdlineEnter` event so it never interferes with normal `.` behaviour.

---

## Configuration

```lua
require("surrounded").setup({
  surround       = "S",      -- visual-mode trigger key
  accept         = "<CR>",   -- accept ambiguous shorter match while in delimiter phase
  timeout        = 500,      -- ms to wait before auto-accepting shorter ambiguous match
  auto_terminate = true,     -- accept shorter match when next char can't extend prefix

  -- Padding characters (between `S` and the delimiter)
  padding = { " ", "<CR>" }, -- space pad and newline pad

  -- Symmetric delimiters
  units = {
    "*",
    "**",
    "==",
    { key = "=",  delimiter = "==" },   -- `=` → ==…==
    { delimiter = "|", pad = " " },      -- `|` → | … |
  },

  -- Asymmetric delimiters (key defaults to `open`)
  pairs = {
    { open = "[",  close = "]"  },
    { open = "(",  close = ")"  },
    { open = "{",  close = "}"  },
    { open = "<",  close = ">"  },
    { open = '"',  close = '"'  },
    { open = "'",  close = "'"  },
    { open = "`",  close = "`"  },
    -- Explicit key:
    -- { key = "b", open = "**", close = "**" }
    -- Pad shorthand (equivalent to specifying open/close with spaces):
    -- { open = "[", close = "]", pad = " " }
  },
})
```

---

## lazy.nvim Examples

### Local directory

```lua
{
  dir = "~/plugins/surrounded",
  opts = {
    timeout        = 300,
    auto_terminate = true,
    units = { "*", "**", "_", "__", "==" },
  },
}
```

### GitHub

```lua
{
  "MasterTemple/surrounded.nvim",
  event = "VeryLazy",
  opts  = {},   -- all defaults
}
```

> `opts = { … }` automatically calls `require("surrounded").setup(opts)`.
