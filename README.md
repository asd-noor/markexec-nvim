# markexec-nvim

Run the fenced code block under the cursor in a Markdown buffer and write its
output into an `output` block right below it.

````markdown
```sh
echo hello
```
```output
hello
```
````

## Requirements

- Neovim 0.10 or newer
- The Markdown treesitter parser (bundled with Neovim; `nvim-treesitter` is not required)
- An interpreter on your `PATH` for each language you run (`sh`, `bash`, `python3`, ...)

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "asd-noor/markexec-nvim",
  ft = "markdown",
  keys = {
    { "<leader>x", "<cmd>MarkexecRun<cr>", ft = "markdown", desc = "Run code block" },
  },
}
```

## Usage

| Command         | Action                                            |
| --------------- | ------------------------------------------------- |
| `:MarkexecRun`  | Run the code block under the cursor               |
| `:MarkexecStop` | Stop the block running in the current buffer      |

- The block's language names the interpreter: ` ```python3 ` runs `python3`,
  ` ```zsh ` runs `zsh`. The code is passed on stdin.
- Short names are mapped: `py` to `python3`, `js` and `javascript` to `node`,
  `rb` to `ruby`.
- The command runs in the file's directory, with a 30 second timeout.
- Stdout and stderr go into the output block. A non-zero exit adds `[exit N]`;
  a timeout adds `[timeout]`; `:MarkexecStop` adds `[killed]`.
- Running the block again replaces an output block that sits directly under it.
- The buffer is read-only while a block runs, so the output always lands in the
  right place.

## Security

Running a block executes arbitrary code, and the block's language picks which
program runs. Read both the language and the code before running blocks in a
Markdown file you did not write. Nothing runs unless you call `:MarkexecRun`.

## Tests

```sh
nvim --headless --clean -l tests/run.lua
```

## License

[MIT](LICENSE)
