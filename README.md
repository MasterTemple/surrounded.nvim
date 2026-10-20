# surrounded.nvim

Surround charwise, linewise, and blockwise visual selections with configurable, optionally padded, smart-terminated delimiters

---

## Features

- All three visual modes: `v` (charwise), `V` (linewise), `<C-v>` (blockwise)
- Space and newline padding
- Multi-character delimiters with proper ambiguity resolution and timeout
- `auto_terminate`: unknown chars accept shorter match and are fed back to Neovim
- Newlines inside `open`/`close` strings
- `visual_lines_separate`: control whether linewise mode surrounds each line or the whole region
- Native dot-repeat with `.` (and works in macros)

---

## Quick Start

```lua
-- lazy.nvim
{
  "MasterTemple/surrounded.nvim",
  event = "VeryLazy",
  opts  = {}, -- all defaults
}
```

---

## Behaviour

### Charwise

| Keys | Result (`are some` selected) |
|------|------------------------------|
| `S[` | `[are some]` |
| `S(` | `(are some)` |
| `S{` | `{are some}` |
| `S*` | `*are some*` |
| `S**` | `**are some**` |
| `S=` | `==are some==` |
| `S [` | `[ are some ]` |

### Newline padding (`<CR>` before delimiter)

Select `do_something()`, press `S<CR>{`:

```rust
// before
SomeEnum::A => do_something(),

// after
SomeEnum::A => {
    do_something()
},
```

### Visual block mode

Select a column of `todo!()` with `<C-v>`, press `S {`:

```rust
// before
SomeEnum::A => todo!(),
SomeEnum::B => todo!(),
SomeEnum::C => todo!(),

// after
SomeEnum::A => { todo!() },
SomeEnum::B => { todo!() },
SomeEnum::C => { todo!() },
```

### Newlines in `open`/`close`

```lua
-- In your config:
units = {
  { key = "``", open = "```\n", close = "\n```" },
}
```

Selecting `some code` and pressing
```
S``
```
gives:

````
```
some code
```
````

The `pad = "\n"` shorthand also works:

```lua
{ key = "``", open = "```", close = "```", pad = "\n" }
-- equivalent to: open = "```\n", close = "\n```"
```

### Visual linewise: separate vs. combined

```lua
visual_lines_separate = false,  -- default: treat all selected lines as one region
visual_lines_separate = true,   -- surround each line independently
```

Example with three lines selected (`V`) and `S[`:

```
-- visual_lines_separate = false
[line one
line two
line three]

-- visual_lines_separate = true
[line one]
[line two]
[line three]
```

### Auto-terminate

With `auto_terminate = true` (default) and both `*` / `**` configured:

- `S**` → `**…**` (unambiguous after two chars)
- `S*<CR>` → `*…*` (explicit accept)
- `S*j` → `*…*`, then `j` moves the cursor down (unrecognised char fed back)
- Timeout fires → auto-accepts `*…*`

### Dot-repeat

Surrounding is a real operator (implemented with `g@`/`'operatorfunc'`), so Neovim's native `.` repeats it, just like built-in visual operators such as `vU` or `v~`: the same surround is applied to the **same amount of text, starting at the cursor**, without asking for the delimiter again.

- charwise: the same number of characters (`veS"` then `W.` quotes the next word if it has the same length)
- linewise: the same number of lines
- blockwise: a block of the same size

Each surround (and each `.`) is a single undo step, and it works inside macros and `:normal`.

With `visual_repeat = true` (the default), you can also make a **new visual selection and press `.`** to apply the last surround to exactly that selection.

---

## Configuration

```lua
require("surrounded").setup({
  surround              = "S",     -- visual-mode trigger
  accept                = "<CR>",  -- accept ambiguous shorter match (delimiter phase)
  timeout               = 500,     -- ms before auto-accepting shorter ambiguous match
  visual_repeat         = true,    -- `.` in visual mode re-applies the last surround
  auto_terminate        = true,    -- accept shorter when next char can't extend prefix
  visual_lines_separate = false,   -- linewise: one region (false) or per-line (true)

  padding = { " ", "<CR>" },       -- space pad and newline pad

  units = {
    "*",
    "**",
    -- Explicit key:
    { key = "=",  delimiter = "==" },
    { delimiter = "|", pad = " " },
    -- Markdown fenced code block:
    { key = "``", delimiter = "```", pad = "\n" },
  },

  pairs = {
    { open = "[",  close = "]"  },
    { open = "(",  close = ")"  },
    { open = "{",  close = "}"  },
    { open = "<",  close = ">"  },
    -- Pad shorthand:
    -- { open = "[", close = "]", pad = " " }  →  [ … ]
  },
})
```

---

## lazy.nvim Examples

### Local

```lua
{
  dir  = "~/plugins/surrounded",
  opts = {
    timeout               = 300,
    auto_terminate        = true,
    visual_lines_separate = true,
    units = {
      "*", "**", "_", "__", "==",
      { key = "=",  delimiter = "==" },
      { key = "``", open = "```\n", close = "\n```" },
    },
  },
}
```

### GitHub

```lua
{
  "MasterTemple/surrounded.nvim",
  event = "VeryLazy",
  opts  = {},
}
```

## Attribution

Thank you Claude 🫡

---

## Tests

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
```
