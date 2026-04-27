# md-harpoon.nvim

Six-slot floating Markdown previewer for Neovim, with cursor memory and a fuzzy file picker. A wrapper around [`delphinus/md-render.nvim`](https://github.com/delphinus/md-render.nvim) that turns its single bundled float into six coexisting panels arranged in a 2×3 grid — useful when you're cross-referencing notes, ADRs, design docs, or a spec and its accompanying README.

```text
┌──────── q ────────┬──────── w ────────┬──────── e ────────┐
│  top-left         │  top-middle       │  top-right        │
├───────────────────┼───────────────────┼───────────────────┤
│  bottom-left      │  bottom-middle    │  bottom-right     │
└──────── a ────────┴──────── s ────────┴──────── d ────────┘
```

## What this is for

Reading and comparing several markdown documents at once without leaving Neovim — design docs vs. their PRs, an ADR vs. the implementation spec, three vendor READMEs you're evaluating, the same doc as both source and rendered preview. md-render does the actual rendering (tables with box-drawing borders, callouts with icons, fenced code with treesitter highlights, OSC 8 hyperlinks, inline images / video / Mermaid via the Kitty graphics protocol on Ghostty / Kitty / WezTerm). md-harpoon adds:

- **Six independent floats** — q/w/e on top, a/s/d on the bottom. Each owns its own buffer and source pointer.
- **Cursor memory** — when you dismiss a float and bring it back later, the cursor is restored to where you left it. Loading a *new* document into a slot resets to the top (what you almost certainly want).
- **`<leader>mf` fuzzy file picker** — pick any markdown file under the current working directory, then pick which panel to render it into. Uses `Snacks.picker.files` when available, falls back to `vim.ui.select` over a glob otherwise.

## Install

`md-harpoon` requires [`md-render.nvim`](https://github.com/delphinus/md-render.nvim) — it uses the `FloatWin` / `display_utils` / `preview.build_content` library API to do its rendering. Declare it as a dependency:

### lazy.nvim

```lua
{
  "yongjohnlee80/md-harpoon.nvim",
  dependencies = {
    { "delphinus/md-render.nvim", version = "*" },
  },
  ft = { "markdown", "markdown.mdx" },
  cmd = { "MdHarpoonFocus", "MdHarpoonRender", "MdHarpoonRenderPath", "MdHarpoonFind" },
  keys = {
    -- Lowercase: focus / open. Restores cursor.
    { "<leader>mq", function() require("md-harpoon").focus("q") end, desc = "md-harpoon: q (top-left)" },
    { "<leader>mw", function() require("md-harpoon").focus("w") end, desc = "md-harpoon: w (top-middle)" },
    { "<leader>me", function() require("md-harpoon").focus("e") end, desc = "md-harpoon: e (top-right)" },
    { "<leader>ma", function() require("md-harpoon").focus("a") end, desc = "md-harpoon: a (bottom-left)" },
    { "<leader>ms", function() require("md-harpoon").focus("s") end, desc = "md-harpoon: s (bottom-middle)" },
    { "<leader>md", function() require("md-harpoon").focus("d") end, desc = "md-harpoon: d (bottom-right)" },
    -- Uppercase: render current buffer here, cursor at top.
    { "<leader>mQ", function() require("md-harpoon").render_current("q") end, desc = "md-harpoon: render → q" },
    { "<leader>mW", function() require("md-harpoon").render_current("w") end, desc = "md-harpoon: render → w" },
    { "<leader>mE", function() require("md-harpoon").render_current("e") end, desc = "md-harpoon: render → e" },
    { "<leader>mA", function() require("md-harpoon").render_current("a") end, desc = "md-harpoon: render → a" },
    { "<leader>mS", function() require("md-harpoon").render_current("s") end, desc = "md-harpoon: render → s" },
    { "<leader>mD", function() require("md-harpoon").render_current("d") end, desc = "md-harpoon: render → d" },
    -- File picker → panel prompt.
    { "<leader>mf", function() require("md-harpoon").find() end, desc = "md-harpoon: find → pick panel" },
  },
}
```

## Quick start

| Key | Behavior |
|---|---|
| `<leader>m{q,w,e,a,s,d}` | **Lowercase** — focus / open the slot. If the float is open, jumps the cursor in. If closed but the slot has a remembered source, reopens it and restores cursor position. If the slot has never been used, renders the current buffer into it. |
| `<leader>m{Q,W,E,A,S,D}` | **Uppercase** — explicit "render the current buffer into this slot". Cursor at line 1. |
| `<leader>mf` | Fuzzy-find a `*.md` under the current working directory, then pick a panel. |
| `<leader>mt` *(via md-render)* | Full-screen tab preview of the current buffer. |
| `q` / `<Esc>` / `<CR>` *inside a float* | Dismiss the float (md-render default). Bring it back with the lowercase key — cursor remembered. |

The lowercase key collapses three behaviors into one keystroke:

1. **Float open** → jump cursor into it
2. **Float closed but slot has a remembered source** → reopen and restore cursor to where you left it
3. **Slot never used** → render the current buffer (first-use convenience — no need to remember the uppercase variant)

## Cursor memory

A `CursorMoved` autocmd in each slot's float buffer continuously saves the last cursor position into per-slot state. When the float closes (the buffer is `bufhidden=wipe`, so the autocmd dies with it) the position survives in module state. On reopen of the same source, the cursor is restored, clamped to the current line count in case the document shrank between renders.

Loading a *new* document into a slot — via uppercase keymaps, `render_current`, `render_path`, or the file picker — resets the saved cursor. That's the explicit "fresh load" semantic.

## Programmatic API

```lua
require("md-harpoon").focus(slot)             -- "q" | "w" | "e" | "a" | "s" | "d"
require("md-harpoon").render_current(slot)    -- render current buffer into slot
require("md-harpoon").render_path(slot, path) -- render file at path (no buffer switch)
require("md-harpoon").find({ cwd = "..." })   -- fuzzy file picker → panel prompt
```

`render_path` doesn't change your current buffer or window focus — it loads the file via `bufadd + bufload` into a hidden buffer and renders that. Handy for external tooling that wants to push a doc into a slot via nvim's RPC socket:

```sh
nvim --server "$NVIM" --remote-send \
  ":lua require('md-harpoon').render_path('a', [[/path/to/doc.md]])<CR>"
```

## User commands

| Command | Shape |
|---|---|
| `:MdHarpoonFocus {slot}` | `:MdHarpoonFocus q` |
| `:MdHarpoonRender {slot}` | `:MdHarpoonRender s` |
| `:MdHarpoonRenderPath {slot} {path}` | `:MdHarpoonRenderPath a /tmp/doc.md` |
| `:MdHarpoonFind` | Open the picker. |

`{slot}` arguments tab-complete to `q`/`w`/`e`/`a`/`s`/`d`.

## Layout details

Each panel:

- Width is content-driven, clamped to `[80, 120]` columns. Three max-width panels overlap on screens narrower than ~360 columns — intentional, since you can always focus the one you want.
- Height is `min(content_lines, ⌊(lines - 3) / 2⌋)` — ~half the screen, minus room for status + cmdline.
- Position uses a ⅓-column grid: `q`/`a` left, `w`/`s` middle, `e`/`d` right. Top row at row 1, bottom row offset by `top_height + 1` for a one-line gap between rows.

Panels use `auto_close = false` so they persist while focus moves between source buffers and other floats. Closing a float doesn't clear the slot's remembered source — that's how "lowercase to bring it back" works.

## Status

Pre-v0.1 — API may shift while the layout and picker UX settle. Open to feedback. The slot identity (q/w/e/a/s/d) is the public contract; `render_path` and `find` shapes are stable.

## Why "harpoon"

`harpoon.nvim` popularized the idea of pinning a small, fixed set of buffers to numbered slots for instant recall. md-harpoon does the same thing, but for *rendered* markdown floats — six panels you can keep "harpooned" to your screen while you bounce between source buffers.

## License

MIT — see [LICENSE](LICENSE). Built on top of `delphinus/md-render.nvim`, which is also MIT-licensed and does all the heavy lifting on the rendering side.
