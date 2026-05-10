# Changelog

All notable changes to `md-harpoon.nvim` are documented here.

## [v0.2.0] — 2026-05-10 — auto-core consumer

First release on top of [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
(`^0.1.0`). Pins, cursor memory, file-filter prefs, and live-refresh
all delegate to the canonical auto-core surfaces.

### Added

- **Hard dependency on `auto-core ^0.1.0`** — sibling installed via
  lazy.nvim.
- **Per-project pin persistence.** Slot pins + last-cursor positions
  now persist across `nvim` restarts, scoped per-project (keyed by
  `core.workspace_root`). Switching worktrees / projects swaps the
  active pin map without touching the others. New
  `lua/md-harpoon/state.lua` is a thin wrapper over
  `auto-core.state.namespace("md-harpoon", { persist = "json" })`
  with per-workspace keying.
- **On-disk shape** at `<state>/auto-core/md-harpoon.json`:
  ```json
  { "pins": { "<sha256(workspace_root):sub(1,16)>": { "<slot>": { "source_path": "...", "last_cursor": [row, col] } } } }
  ```
  Workspace hash uses
  `vim.fn.sha256(workspace_root):sub(1,16)` — same pattern
  auto-agents uses. The single nested-table set sidesteps dot-path
  ambiguity (filesystem paths aren't dot-path-safe).
- **`doc:pinned` / `doc:unpinned` event topics** publish on
  `auto-core.events` whenever a slot opens or clears, so siblings
  (status lines, agent panels, future indexers) can react without
  polling.
- **Smoke test driver** at `tests/smoke.lua` (24/0 pass) covering the
  per-workspace pin scope, partial cursor updates, the doc:pinned
  surface, and the worktree:switched / core.file:modified
  subscribers.

### Changed

- **`ensure_slot`** hydrates `source_path` + `last_cursor` from the
  per-project pin map at first creation. **`M.focus`** rehydrates
  `source_bufnr` from `source_path` via `bufadd` + `bufload` when the
  slot was restored from a prior session.
- **`find()`** reads `auto-core.files.{get_show_hidden,get_show_dotfiles}`
  for the snacks-picker hidden/ignored opts. Layered:
  auto-core canonical → `opts.picker` user override → non-overridable
  cwd/ft/title/confirm. Snacks's `hidden` covers dotfiles; `ignored`
  covers gitignored. Toggles now stay in sync with auto-finder's
  filter prefs.
- **`M._wire_auto_core`** defined AFTER `local State = {}` so its
  subscriber closures capture `State` as an upvalue (not a nil
  global). Subscribes to:
  - `worktree:switched` — close floats, clear in-memory `State` so
    the next focus rehydrates the new workspace's pins.
  - `core.file:modified` — debounced 150 ms re-render of any visible
    slot whose `source_path` matches.

### Removed

- Unused `find = {}` default option (was never read).

### Migration notes

- Update your lazy.nvim spec to depend on `auto-core.nvim`:
  ```lua
  {
    "yongjohnlee80/md-harpoon.nvim",
    dependencies = {
      "yongjohnlee80/auto-core.nvim",
    },
  }
  ```
- No public API renames. Existing `pin` / `clear` / `focus` / `find`
  verbs and the slot keymaps all keep their shape.
- First open after upgrade has no per-project snapshot → pins start
  empty for that project. Subsequent restarts preserve them.

## [v0.1.4] and earlier

(See git tags `v0.1.0` … `v0.1.4` for incremental notes.)
