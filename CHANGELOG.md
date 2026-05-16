# Changelog

All notable changes to `md-harpoon.nvim` are documented here.

## [v0.2.2] — 2026-05-16 — ADR 0021 Phase 2 wrapper + smoke harness rtp fix

Internal refactor. Every previously hand-prefixed `vim.notify(
"md-harpoon: …")` call now flows through `lua/md-harpoon/log.lua`
so the auto-core ring captures the entry for `:AutoCoreLog`
triage. Toast surface is unchanged at every call site.

### Added — `lua/md-harpoon/log.lua`

Per ADR 0021 §6, every auto-family plugin owns one
`lua/<plugin>/log.lua` that delegates to `auto-core.log`. Feature
code in md-harpoon now calls `require("md-harpoon.log")`
exclusively; `auto-core.log` is reachable only through the
wrapper.

Exposes:

```lua
local log = require("md-harpoon.log")

log.error / .warn / .info / .debug / .trace  -- with md-harpoon.* component prefix
log.notify(msg, opts?)                        -- force-toast single emission
log.notifyIf(event, msg, opts?)               -- toast iff event subscribed
log.register_events(events)                   -- declare at setup
log.is_level_enabled(name)                    -- predicate
```

Soft-dep tolerant: when running against an auto-core older than
v0.1.11 (no `notify` / `notifyIf` / `events.register`), the
wrapper degrades to ring-only emissions and a
`[md-harpoon.<component>] <msg>` bare `vim.notify` fallback so
users without auto-core keep the v0.2.x toast surface.

### Changed — swept 13 bare `vim.notify` call sites

- `lua/md-harpoon/init.lua` (12 sites) — `open_slot`,
  `render_path`, `browser_resolve_source`, `open_in_browser`,
  `browser_open`, `find`. Each call site now routes through
  `log.<level>(component, msg)` with the literal `"md-harpoon: "`
  message prefix dropped (auto-core's
  `[AutoCore] [md-harpoon.<component>] [LEVEL]` formatting
  replaces it).
- `lua/md-harpoon/mailbox/commands.lua` (1 site) — the
  register-failed WARN now goes through
  `log.warn("mailbox.commands", …)`.

### Changed — `tests/smoke.lua` rtp prelude fixed

Latent bug surfaced by the Phase 2 work: the prelude hardcoded
`/home/johno/Source/Projects/nvim-plugins/md-harpoon.nvim` as an
rtp entry, but that's the BARE repo dir (no `lua/` underneath —
modules live in each worktree). The `require("md-harpoon")`
call therefore picked up whichever `~/.local/share/nvim/lazy/
md-harpoon.nvim` happened to be installed instead of the suite's
own working copy. Same family of bugs caught + codified in
`lua-nvim-plugin-development.md` rule 2.

Fixed: derive `plugin_root` from the smoke script's own path
(`:h:h:h` lands on the family workspace dir), iterate candidate
rtp entries with explicit `isdirectory` guards + visible WARN on
missing deps, list the canonical dev tip LAST so its prepend
wins.

### Tests

`tests/smoke.lua` 24 passed, 0 failed. No new assertions — this
is a routing change with byte-identical observable behavior at
every call site. The rtp prelude fix is its own load-bearing
improvement: the suite is now self-locating instead of
dependent on absolute paths matching one developer's machine.

### Migration

Soft. Consumers pin via `version = "^0.2.0"` and auto-update.
The wrapper soft-deps against pre-Phase-1 auto-core so consumers
can stage the upgrade in any order.

## [v0.2.1] — 2026-05-15 — register mailbox commands with auto-core

Adds `lua/md-harpoon/mailbox/commands.lua`, exposing three verbs
to auto-core's mailbox command registry:

- `harpoon_attach`        — pin a markdown path into a slot
- `view`                  — render a slot
- `render_browser`        — convert + open in default browser

Plus a tiny docs touch-up on the v0.2.0 install instructions
clarifying the auto-core hard dep + caret-pin guidance for
consumers pinning at `^0.1.0`.

(Tag landed at the time but a CHANGELOG entry was missed —
backfilled here for the v0.2.2 cut.)

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
