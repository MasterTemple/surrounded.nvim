# surrounded.nvim

A minimal, fully configurable Neovim plugin that lets you surround a visual selection with delimiters.

---

## Features

- Press `S` (configurable) in visual mode, then type a delimiter
- **Space padding**: each `<Space>` before the delimiter adds a space on both sides
- **Newline padding**: pressing `<CR>` before the delimiter splits the selection onto its own indented line(s), respecting `shiftwidth` and `expandtab`
- **Multi-character delimiters**: `**`, `==`, `__`, etc.
- **Ambiguity resolution**: if `*` and `**` are both configured, a libuv timer waits for a timeout or explicit `<CR>` — non-ambiguous delimiters always execute **instantly** with no delay
- Fully user-configurable via `setup()`

---

## Quick Start (lazy.nvim)

```lua
{
  dir = "~/path/to/surrounded",   -- local clone
  -- OR a GitHub repo: "yourusername/surrounded.nvim"
  config = function()
    require("surrounded").setup()  -- use all defaults
  end,
}
```

---

## Default Behaviour

### Space padding

| Keys (visual mode) | Result (`are some` selected) |
|--------------------|------------------------------|
| `S[`    | `[are some]`    |
| `S(`    | `(are some)`    |
| `S{`    | `{are some}`    |
| `S"`    | `"are some"`    |
| `S'`    | `'are some'`    |
| `S*`    | `*are some*`    |
| `S**`   | `**are some**`  |
| `S=`    | `==are some==`  (mapped via `{ key="=", delimiter="==" }`) |
| `S==`   | `==are some==`  |
| `S\|`   | `\| are some \|` (auto-padded via config) |
| `S [`   | `[ are some ]`  (one space = one pad unit) |
| `S  [`  | `[  are some  ]` (two spaces = two pad units) |

### Newline padding (`<CR>` before the delimiter)

Given:
```rust
match some_enum {
    SomeEnum::A => do_something(),
    _ => ()
}
```
Select `do_something()`, then press `S<CR>{`:
```rust
match some_enum {
    SomeEnum::A => {
        do_something()
    },
    _ => ()
}
```
- The selection's base indentation is detected automatically.
- Content is re-indented one `shiftwidth` deeper.
- `expandtab` is respected (spaces vs tabs).
- Multiple `<CR>` presses before the delimiter are supported (reserved for future use; currently behaves the same as one).

---

## Ambiguity & Timeout

When `"*"` and `"**"` are both configured:

1. You press `S*`.
2. An exact match (`*`) exists, but `**` could still match.
3. A libuv timer starts (`timeout` ms).
   - Another `*` arrives in time → inserts `**…**`.
   - `<CR>` arrives → accepts `*…*` immediately.
   - Timer fires → accepts `*…*` automatically.

Delimiters with **no ambiguity** (e.g. `S[`) execute **instantly** — no timeout.

---

## Configuration Reference

```lua
require("surrounded").setup({
  -- Key that triggers surrounding in visual mode
  surround = "S",

  -- While reading a delimiter, press this to accept the shorter ambiguous match.
  -- In the padding phase, <CR> is still a newline-pad (not accept).
  accept = "<CR>",

  -- ms to wait before auto-accepting an ambiguous shorter delimiter.
  -- Only fires when genuine ambiguity exists.
  timeout = 500,

  -- Padding characters (typed between `S` and the delimiter).
  --   " "    → space pad  (one space per press on each side)
  --   "<CR>" → newline pad (splits onto indented line)
  padding = { " ", "<CR>" },

  -- Symmetric delimiters
  units = {
    "*",
    "**",
    "==",
    { key = "=",  delimiter = "==" },      -- `=` → ==…==
    { delimiter = "|", pad = " " },         -- `|` always pads: | … |
  },

  -- Asymmetric delimiters
  pairs = {
    { open = "[",  close = "]"  },
    { open = "(",  close = ")"  },
    { open = "{",  close = "}"  },
    { open = "<",  close = ">"  },
    { open = '"',  close = '"'  },
    { open = "'",  close = "'"  },
    { open = "`",  close = "`"  },
    -- explicit key different from open:
    -- { key = "b", open = "**", close = "**" }
    -- pad shorthand:
    -- { open = "[", close = "]", pad = " " }   →   [ … ]
  },
})
```

---

## lazy.nvim Examples

### Local directory

```lua
{
  dir = "~/plugins/surrounded",
  config = function()
    require("surrounded").setup({
      timeout = 400,
      units = {
        "*", "**",
        "_", "__",
        "==",
        { key = "=", delimiter = "==" },
      },
    })
  end,
}
```

### GitHub + `opts` shorthand

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

> `opts = { … }` automatically calls `require("surrounded").setup(opts)` — no
> `config` function needed.
