---md-harpoon.state — auto-core.state namespace wrapper.
---
---v0.X.0 migration step (per the kb's auto-core-todos plan): per-
---slot pinned source paths + cursor memory move out of the in-
---module `State` table and into
---`auto-core.state.namespace("md-harpoon", { persist = "json" })`,
---which writes to `<state>/auto-core/md-harpoon.json`.
---
---**Per-project scope.** The persisted shape is keyed by a hash of
---`core.workspace_root` (the canonical workspace key worktree.nvim
---maintains since ADR 0007 Phase 1). Switching workspaces
---(`<leader>gw` / `<leader>gW`) re-hydrates from the new workspace's
---pin map; slots are blank until the user pins something. This is
---the right scope: docs you pin in repo A aren't relevant in repo B.
---
---On-disk shape:
---```json
---{
---  "pins": {
---    "<workspace_hash_16>": {
---      "1": { "source_path": "/abs/path.md", "last_cursor": [12, 0] },
---      "a": { ... }
---    },
---    "<another_workspace_hash>": { ... }
---  }
---}
---```
---
---Public surface:
---
---  state.setup()                          -- claim namespace; idempotent
---  state.namespace()                      -- raw handle (advanced)
---
---  state.get_pin(slot)                    → { source_path, last_cursor }?
---  state.set_pin(slot, pin_or_nil)
---  state.clear_pin(slot)                  -- equivalent to set_pin(slot, nil)
---  state.all_pins()                       → table<slot, pin>  for current workspace
---
---  state.set_last_cursor(slot, row, col)  -- partial update (no source change)
---
---  state.workspace_key()                  → string  current workspace hash
---  state.workspace_changed(new_root)      -- called on worktree:switched; flips the
---                                            "current workspace" pointer used by
---                                            get_pin/set_pin (read-side hydration
---                                            happens in init.lua via all_pins())
---
---Topics consumed (by init.lua, not this module):
---  worktree:switched   → re-hydrate State + close floats from prior workspace
---  core.file:modified  → re-render visible slots whose source matches
---@module 'md-harpoon.state'

local core = require("auto-core")

local M = {}

local NS_NAME = "md-harpoon"

local DEFAULTS = {
  pins = {},  -- [workspace_hash] = { [slot] = { source_path, last_cursor } }
}

local _ns = nil
local _current_workspace_key = nil  -- cached; recomputed on workspace_changed

---Idempotent claim of the auto-core namespace.
---@return any AutoCoreStateNamespace
function M.setup()
  if _ns then return _ns end
  _ns = core.state.namespace(NS_NAME, {
    defaults = DEFAULTS,
    persist  = "json",
  })
  return _ns
end

function M.namespace()
  if not _ns then M.setup() end
  return _ns
end

---Compute the stable per-workspace key. Hashes `core.workspace_root`
---(falls back to cwd when auto-core hasn't been seeded yet — same
---fallback worktree.graph uses).
---@param explicit_root string?
---@return string
local function _compute_workspace_key(explicit_root)
  local root = explicit_root
  if not root and core.git and core.git.worktree
      and type(core.git.worktree.get_workspace_root) == "function" then
    root = core.git.worktree.get_workspace_root()
  end
  if type(root) ~= "string" or root == "" then
    root = vim.fn.getcwd()
  end
  return vim.fn.sha256(root):sub(1, 16)
end

---@return string
function M.workspace_key()
  if not _current_workspace_key then
    _current_workspace_key = _compute_workspace_key()
  end
  return _current_workspace_key
end

---Called by init.lua's `worktree:switched` subscriber. Updates the
---cached workspace key so subsequent get_pin / set_pin operate
---against the new workspace's slot map.
---@param new_root string?
function M.workspace_changed(new_root)
  _current_workspace_key = _compute_workspace_key(new_root)
end

---@param slot string
---@return { source_path: string?, last_cursor: integer[]? }?
function M.get_pin(slot)
  local pins = M.namespace():get("pins") or {}
  return (pins[M.workspace_key()] or {})[slot]
end

---@return table<string, { source_path: string?, last_cursor: integer[]? }>
function M.all_pins()
  local pins = M.namespace():get("pins") or {}
  return pins[M.workspace_key()] or {}
end

---Set or clear a slot's pin for the current workspace. Pass nil to
---clear. The setter writes the entire `pins` table back (single
---namespace mutation) because workspace_keys contain non-dot-path-
---safe characters; `:set("pins.<hash>.<slot>", ...)` would interpret
---the hash as a nested-table path.
---@param slot string
---@param pin { source_path: string?, last_cursor: integer[]? }?
function M.set_pin(slot, pin)
  local ns = M.namespace()
  local pins = ns:get("pins") or {}
  local wk = M.workspace_key()
  pins[wk] = pins[wk] or {}
  pins[wk][slot] = pin
  ns:set("pins", pins)
end

function M.clear_pin(slot)
  M.set_pin(slot, nil)
end

---Partial update: cursor only. Used after the user moves around
---inside a pinned slot's float so the position survives close/reopen
---and nvim restart. Skipped if the slot has no remembered source.
---@param slot string
---@param row integer
---@param col integer
function M.set_last_cursor(slot, row, col)
  local ns = M.namespace()
  local pins = ns:get("pins") or {}
  local wk = M.workspace_key()
  pins[wk] = pins[wk] or {}
  local cur = pins[wk][slot]
  if not cur or not cur.source_path then return end
  cur.last_cursor = { row, col }
  ns:set("pins", pins)
end

---Test-only: clear the namespace + current-workspace cache.
function M._reset_for_tests()
  if _ns then pcall(function() _ns:set("pins", {}) end) end
  _ns = nil
  _current_workspace_key = nil
end

return M
