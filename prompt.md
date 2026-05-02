NeoVim, create a plugin (called `surrounded`) that lets me have a visual selection then press "S" and then a key to surround my current text
Here are examples of what I want supported

Imagine I have: `Here |are some| words.` where `are some` is selected

`S[` -> `Here [are some] words.`
`S{` -> `Here {are some} words.`
`S(` -> `Here (are some) words.`
`S'` -> `Here 'are some' words.`
`S"` -> `Here "are some" words.`

Optionally, allow for a list of custom characters that can be pressed to pad both sides

For example, if I press `<space>` before the next character (allow for any number of spaces)

`S [` -> `Here [ are some ] words.`
`S {` -> `Here { are some } words.`
`S (` -> `Here ( are some ) words.`
`S '` -> `Here ' are some ' words.`
`S "` -> `Here " are some " words.`

Additionally, I want support for multiple characters as possible

`S*` -> `Here *are some* words.`
`S**` -> `Here **are some** words.`
`S_` -> `Here _are some_ words.`
`S__` -> `Here __are some__ words.`
`S==` -> `Here ==are some== words.`

Important: You must if both `*` and `**` (1 and 2 asterisks are possible combinations, only execute 2 `**` immediately, wait after 1 `*` and wait for the `Enter` key or a timeout specified by the user)

Note: These will all be specified by the user config, but there will be defaults available

```lua
{
    -- Initial character
    surround = "S",
    -- Accept shorter selections that could be longer (example: 1 asterisk when 2 is supported)
    accept = "<CR>",
    -- Timeout for shorter selections that could be longer (example: 1 asterisk when 2 is supported) (500ms)
    timeout = 500,
    -- Characters that can be used to pad the selection before receiving the surrounding delimiters
    -- Listen for these after `S` and before any of the delimeters
    padding = {
        " ",
    },
    -- When the text at the beginning and close of a selection is the same
    units = {
        -- Key & Delimter are the same
        "*",
        "**",
        "==",
        -- So that I only have to press `=` once and I will get 2 `==`
        { key = "=", delimeter = "==", }
        -- The key is always the delimter, unless explicitly specified otherwise
        -- Pressing `|` will be automatically padded
        { delimeter = "|", pad = " " }
    },
    -- When the text at the beginning and close of a selection are different
    -- The key is always the open delimter, unless explicitly specified otherwise
    pairs = {
        { open = "[", close = "]" },
        { open = "(", close = ")" },
        { open = "{", close = "}" },
        -- When I want the input key to be different than the open delimeter (this case will always pad [ ])
        { key = "[", open = "[ ", close = " ]" },
        -- Alternatively, another syntax could be (support both)
        { open = "[", close = "]", pad = " " },
    },
}
```

Let me load this plugin with lazy.nvim

---

Very good,

- However it doesn't work with 2 asterisks, it early terminates at the first asterisk

- Also, please make it so that I can pad with enter as well

For example

if my visual selection is around `do_something()`
inside 
```rust
match some_enum {
    SomeEnum::A => do_something(),
    _ => ()
}
```

I want to be able to press `S<CR>{` and then pad it with newlines **at the appropriate indentation**

This would result in

```rust
match some_enum {
    SomeEnum::A => {
        do_something()
    },
    _ => ()
}
```

- The timeout should only be for when there are multiple of the same character/overlapping characters, not for executing the command in general

---

Very good

- Now add a setting that will allow any character that is not part of a sequence to early terminate a shorter sequence (`auto_terminate = true`)
For example, instead of only breaking immediately when typing `S*<CR>`, allow for `S*j` (when the user would move down and not have any binding that is `*j`)

- There is a bug that sometimes says `end_col` is out of range.
```lua
	vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, replacement)
```
It occurs when I am in visual line mode (and have the full line selected).

- Also support visual block mode

```rust
match some_enum {
    SomeEnum::A => todo!(),
    SomeEnum::B => todo!(),
    SomeEnum::C => todo!(),
}
```

If my visual selection is

```
todo!()
todo!()
todo!()
```

and I press `S {`

I want it to apply to each line separately, not as 1 selection:

```rust
match some_enum {
    SomeEnum::A => { todo!() },
    SomeEnum::B => { todo!() },
    SomeEnum::C => { todo!() },
}
```

- Lastly, if there is any way to do this, add dot `.` repeats
For example, if I press `S"`, and then I have another visual selection (without any other operation in between), pressing `.` should execute `S"` again

---

- Make it so I can include newlines in the replacement

I want to do something like this

```lua
{ key = "``", open = "```", close = "```", pad = "\n" },
-- or
{ key = "``", open = "```\n", close = "\n```" },
```

- Provide a configuration option to specify whether or not visual line selection should treat each line separately, or as 1 region (`visual_lines_separate = true/false`), currently it only treats each line separately

- Dot/repeat support doesn't actually work

- The early-terminate timeout doesn't actually work

- Support `viwS"`?

