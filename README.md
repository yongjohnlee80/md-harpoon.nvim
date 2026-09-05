# md-harpoon.nvim

Six-slot floating Markdown previewer for Neovim, with cursor memory and a fuzzy file picker. A wrapper around [`delphinus/md-render.nvim`](https://github.com/delphinus/md-render.nvim) that turns its single bundled float into six coexisting panels arranged in a cascade — useful when you're cross-referencing notes, ADRs, design docs, or a spec and its accompanying README.

```text
 ┌── 1 ──┐  ┌── 2 ──┐  ┌── 3 ──┐
 │ upper │  │ upper │  │ upper │
 │ left  │  │  mid  │  │ right │
 │   ┌── a ──┐ ┌── s ──┐ ┌── d ──┐
 │   │ left  │ │  mid  │ │ right │
 └───┤ …     │ │  …    │ │  …    │
     └───────┘ └───────┘ └───────┘
```

`1`/`2`/`3` sit at the top of the screen; `a`/`s`/`d` cascade half a column right and a few rows down of their pair (`a` from `1`, `s` from `2`, `d` from `3`) so the bottom panels sit roughly between the top ones. All six share the same height — overlap is intentional; the focus keys keep it usable.

Top row uses **digits** (`1`/`2`/`3`) instead of `q`/`w`/`e` so the namespace doesn't clash with vim's macro-record key.

## What this is for

Reading and comparing several markdown documents at once without leaving Neovim — design docs vs. their PRs, an ADR vs. the implementation spec, three vendor READMEs you're evaluating, the same doc as both source and rendered preview. md-render does the actual rendering (tables with box-drawing borders, callouts with icons, fenced code with treesitter highlights, OSC 8 hyperlinks, inline images / video / Mermaid via the Kitty graphics protocol on Ghostty / Kitty / WezTerm). md-harpoon adds:

- **Six independent floats** — `1`/`2`/`3` on top, `a`/`s`/`d` on the bottom. Each owns its own buffer and source pointer.
- **Cursor memory** — when you dismiss a float and bring it back later, the cursor is restored to where you left it. Loading a *new* document into a slot resets to the top (what you almost certainly want).
- **`<leader>mf` fuzzy file picker** — pick any markdown file under the current working directory, then pick which panel to render it into. Uses `Snacks.picker.files` when available, falls back to `vim.ui.select` over a glob otherwise. Panel prompt shows human-readable labels ("upper left (1)" / "left (a)" / …).
- **`<leader>mc` close-all** — wipes every visible float in one keystroke without forgetting the slots' sources or cursor positions; the lowercase / digit key brings each one back to where you left it.

## Install

`md-harpoon` has two hard dependencies as of v0.2.0:

- [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
  `^0.1.0` — foundation library for the AutoVim plugin family. Provides the
  shared event bus, namespaced state store (per-project pin persistence),
  and the global file-filter prefs (`auto-core.files`) that md-harpoon's
  `find()` reads.
- [`md-render.nvim`](https://github.com/delphinus/md-render.nvim) — does the
  actual markdown rendering. md-harpoon wraps its `FloatWin` /
  `display_utils` / `preview.build_content` library API to add the
  multi-float layout and cursor memory.

### lazy.nvim

```lua
{
  "yongjohnlee80/md-harpoon.nvim",
  version = "^0.2.0",  -- v0.2.0 is the auto-core consumer release
  dependencies = {
    "yongjohnlee80/auto-core.nvim",                        -- foundation library; hard dep as of v0.2.0
    { "delphinus/md-render.nvim", version = "*" },
  },
  ft = { "markdown", "markdown.mdx" },
  cmd = { "MdHarpoonFocus", "MdHarpoonRender", "MdHarpoonRenderPath", "MdHarpoonFind", "MdHarpoonCloseAll" },
  keys = {
    -- Digits / lowercase: focus / open. Restores cursor.
    { "<leader>m1", function() require("md-harpoon").focus("1") end, desc = "md-harpoon: upper left (1)"   },
    { "<leader>m2", function() require("md-harpoon").focus("2") end, desc = "md-harpoon: upper middle (2)" },
    { "<leader>m3", function() require("md-harpoon").focus("3") end, desc = "md-harpoon: upper right (3)"  },
    { "<leader>ma", function() require("md-harpoon").focus("a") end, desc = "md-harpoon: left (a)"         },
    { "<leader>ms", function() require("md-harpoon").focus("s") end, desc = "md-harpoon: middle (s)"       },
    { "<leader>md", function() require("md-harpoon").focus("d") end, desc = "md-harpoon: right (d)"        },
    -- Shifted digits / uppercase: render current buffer here, cursor at top.
    { "<leader>m!", function() require("md-harpoon").render_current("1") end, desc = "md-harpoon: render → 1" },
    { "<leader>m@", function() require("md-harpoon").render_current("2") end, desc = "md-harpoon: render → 2" },
    { "<leader>m#", function() require("md-harpoon").render_current("3") end, desc = "md-harpoon: render → 3" },
    { "<leader>mA", function() require("md-harpoon").render_current("a") end, desc = "md-harpoon: render → a" },
    { "<leader>mS", function() require("md-harpoon").render_current("s") end, desc = "md-harpoon: render → s" },
    { "<leader>mD", function() require("md-harpoon").render_current("d") end, desc = "md-harpoon: render → d" },
    -- File picker → panel prompt; close-all wipes every visible float.
    { "<leader>mf", function() require("md-harpoon").find()      end, desc = "md-harpoon: find → pick panel" },
    { "<leader>mc", function() require("md-harpoon").close_all() end, desc = "md-harpoon: close all floats"  },
  },
}
```

> **Caret pin (`^0.2.0`)**: future v0.2.x releases auto-include without a
> manual bump. The `auto-core` family follows an additive-only minor-bump
> rule — no v0.X.Y release renames, removes, or break-shapes any existing
> public surface. Crossing to a future v0.3.0 requires bumping the caret
> deliberately.

> **Per-project pins**: as of v0.2.0, slot pins + cursor positions persist
> per-project via `auto-core.state.namespace("md-harpoon")`, keyed by
> `sha256(workspace_root):sub(1,16)`. Switching worktrees / projects swaps
> the active pin map automatically (subscribes to `worktree:switched` on
> `auto-core.events`). First open in a project starts with empty slots;
> subsequent restarts replay what you had loaded last time.

## Quick start

| Key | Behavior |
|---|---|
| `<leader>m{1,2,3,a,s,d}` | **Digits + home row** — focus / open the slot. If the float is open, jumps the cursor in. If closed but the slot has a remembered source, reopens it and restores cursor position. If the slot has never been used, renders the current buffer into it. |
| `<leader>m{!,@,#,A,S,D}` | **Shifted** — explicit "render the current buffer into this slot". Cursor at line 1. |
| `<leader>mf` | Fuzzy-find a `*.md` under the current working directory, then pick a panel. The panel prompt shows human-readable labels. |
| `<leader>mc` | Close every open slot float. Sources + cursor positions are preserved — bring any slot back with its lowercase / digit key. |
| `<leader>mt` *(via md-render)* | Full-screen tab preview of the current buffer. |
| `q` / `<Esc>` / `<CR>` *inside a float* | Dismiss the float (md-render default). Bring it back with the lowercase key — cursor remembered. |

The digit / lowercase key collapses three behaviors into one keystroke:

1. **Float open** → jump cursor into it
2. **Float closed but slot has a remembered source** → reopen and restore cursor to where you left it
3. **Slot never used** → render the current buffer (first-use convenience — no need to remember the shifted variant)

## Cursor memory

A `CursorMoved` autocmd in each slot's float buffer continuously saves the last cursor position into per-slot state. When the float closes (the buffer is `bufhidden=wipe`, so the autocmd dies with it) the position survives in module state. On reopen of the same source, the cursor is restored, clamped to the current line count in case the document shrank between renders.

Loading a *new* document into a slot — via shifted keymaps, `render_current`, `render_path`, or the file picker — resets the saved cursor. That's the explicit "fresh load" semantic.

## Programmatic API

```lua
require("md-harpoon").focus(slot)             -- "1" | "2" | "3" | "a" | "s" | "d"
require("md-harpoon").render_current(slot)    -- render current buffer into slot
require("md-harpoon").render_path(slot, path) -- render file at path (no buffer switch)
require("md-harpoon").find({ cwd = "..." })   -- fuzzy file picker → panel prompt
require("md-harpoon").close_all()             -- close every open float (preserves sources + cursors)
```

`render_path` doesn't change your current buffer or window focus — it loads the file via `bufadd + bufload` into a hidden buffer and renders that. Handy for external tooling that wants to push a doc into a slot via nvim's RPC socket:

```sh
nvim --server "$NVIM" --remote-send \
  ":lua require('md-harpoon').render_path('a', [[/path/to/doc.md]])<CR>"
```

## User commands

| Command | Shape |
|---|---|
| `:MdHarpoonFocus {slot}` | `:MdHarpoonFocus 1` |
| `:MdHarpoonRender {slot}` | `:MdHarpoonRender s` |
| `:MdHarpoonRenderPath {slot} {path}` | `:MdHarpoonRenderPath a /tmp/doc.md` |
| `:MdHarpoonFind` | Open the picker. |
| `:MdHarpoonCloseAll` | Close every open float. |

`{slot}` arguments tab-complete to `1`/`2`/`3`/`a`/`s`/`d`.

## Layout details

Each panel:

- Width is content-driven, clamped to `[80, 120]` columns. Three max-width panels overlap on screens narrower than ~360 columns — intentional.
- Height is `min(content_lines, ⌊lines × 0.85⌋)` — same for all six slots; the cascade is purely an offset, not a half-screen split.
- Column placement uses a ⅓-grid: `1` left, `2` middle, `3` right. `a`/`s`/`d` shift right of their pair by `CASCADE_X_FRAC × column-step` — at the default `0.5`, the bottom row sits halfway between adjacent top panels.
- Row placement: 1/2/3 at row 1; a/s/d at row 1 + `CASCADE_Y` (default 4 rows).

Tweak `CASCADE_X_FRAC` / `CASCADE_Y` (top of `lua/md-harpoon/init.lua`) to spread the cascade further or tighten it. Bump `MIN_PANEL_WIDTH` / `MAX_PANEL_WIDTH` to resize.

Panels use `auto_close = false` so they persist while focus moves between source buffers and other floats. Closing a float doesn't clear the slot's remembered source — that's how the digit / lowercase key brings it back.

## Continuous integration

`.github/workflows/ci.yml` runs two jobs, and the split between them is
the point.

**`lua` — the gate.** Every push to `main` and every pull request. It
installs a pinned toolchain and hands the verdict to `tests/run-all.sh`.
Everything is pinned, so a red run means *this change* rather than
something that moved underneath it:

| Pinned by | What | Why |
|---|---|---|
| commit SHA | `actions/checkout` | a tag can be moved to different code under the same name |
| version **and SHA-256** | Neovim `v0.12.5` | a release asset can be replaced under the same tag and name, so the version alone is not reproducible |
| commit SHA | `auto-core.nvim`, `plenary.nvim`, [`md-render.nvim`](https://github.com/delphinus/md-render.nvim) | reproducibility; the pin's age is reported (see below) |

**`drift` — the early warning.** The same suite, with **auto-core resolved
at its default branch** instead of the commit `lua` pins. A regression in
auto-core reaches its consumers before anyone notices, and a consumer
pinned to a frozen auto-core is precisely the thing that cannot notice.
Both properties are wanted and they conflict, so they are split rather
than traded.

`drift` runs on a **schedule (Mondays, 06:00 UTC) and manual dispatch
only** — deliberately *not* on push or pull request. On push it would
redden the merge run for an upstream change unrelated to the PR being
merged, and would put a code path on the merge that no PR run exercised.

### `tests/run-all.sh` is the whole verdict

CI does not reimplement the gate; it supplies the environment and lets the
runner be the judge. `run-all.sh` runs every suite and treats a **missing**
`N passed, M failed` summary line as a hard failure, rather than parsing
whatever partial PASS lines a suite emitted before it stopped. That
sentinel is the only thing that catches a C-level crash mid-run, which is
why running a single suite by hand is **not** a substitute:

```sh
./tests/run-all.sh                              # the gate
nvim --headless -u NONE -l tests/smoke.lua      # one suite, while iterating
```

### A failing `drift` run has an addressee

A red row in the Actions tab is not a signal — nobody is obliged to open
it, and the one time a drift job caught a real regression in this family,
it was caught because somebody dispatched it by hand while investigating
something unrelated. Left to the schedule it would have gone red and sat
there. So on failure the job opens an **issue**, which has an addressee
that outlives a run's log retention and records *when* divergence started:

- **One issue per repo**, found by the **`ci-drift` label**, not by title.
  Title matching breaks the moment somebody edits the title — the next
  failure opens a duplicate instead of commenting.
- Reopened and commented rather than duplicated, so a month of Mondays is
  one thread instead of four issues nobody triages.
- **Closed automatically on the next green** drift run, with a comment
  saying the divergence cleared.

A `ci-drift` issue does **not** mean this plugin is broken for its users:
the gating job pins auto-core and is green. It means auto-core has moved in
a way this suite does not accept yet, and one of the two has to change
before the pin is bumped.

### Exercising the notifier, and the pin's age

`workflow_dispatch` takes a **`force_drift_failure`** boolean that fails the
drift job deliberately:

```sh
gh workflow run ci.yml --repo yongjohnlee80/md-harpoon.nvim --ref main \
  -f force_drift_failure=true
```

The whole premise of the notifier is that an unread signal is not a signal
— so an untested notifier is the same bug one layer up, and there has to be
a way to make it fire without waiting for auto-core to break something.

Proven here, both halves, on the real runner: a forced dispatch opened
[#4](https://github.com/yongjohnlee80/md-harpoon.nvim/issues/4)
and the next green drift run closed it again.

The `lua` job also reports **how stale the auto-core pin is**, as routine
output rather than something discovered while debugging.
It is
reported and never acted on: **bumping the pin is a deliberate, reviewed
change, never automatic.** A gating job that changes under a PR
reintroduces exactly the mystery failure on unrelated work that pinning was
adopted to prevent.

Two guards keep that report honest, and both exist because the first
version was wrong:

- It reads the compare API's **`ahead_by`**, not `behind_by`. For
  `compare/PIN...main`, `behind_by` is always `0` when the pin is an
  ancestor — the first version printed `0` on a pin eight commits stale,
  ran green, and would have called the pin current for as long as the repo
  existed. An unparseable answer now emits a `::warning` saying staleness
  was **not determined**, because `0` reads as "current".
- It **counts the `AUTO_CORE_REF` values in the file** and fails with
  `::error` if there is more than one. When this design was rolled out
  across the family, the step arrived carrying the pilot repo's SHA — every
  copy would have reported the age of a pin it does not use, in a step
  whose whole job is noticing staleness, with nothing about the copy
  looking wrong.
## Status

Pre-v0.1 — API may shift while the layout and picker UX settle. Open to feedback. The slot identity (`1`/`2`/`3`/`a`/`s`/`d`) is the public contract; `render_path`, `find`, and `close_all` shapes are stable.

## Why "harpoon"

`harpoon.nvim` popularized the idea of pinning a small, fixed set of buffers to numbered slots for instant recall. md-harpoon does the same thing, but for *rendered* markdown floats — six panels you can keep "harpooned" to your screen while you bounce between source buffers.

## License

MIT — see [LICENSE](LICENSE). Built on top of `delphinus/md-render.nvim`, which is also MIT-licensed and does all the heavy lifting on the rendering side.
