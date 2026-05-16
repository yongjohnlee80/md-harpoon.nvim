-- Headless smoke tests for md-harpoon.nvim.
-- Run with: nvim --headless -u NONE -l tests/smoke.lua
--
-- First version landed alongside the auto-core consumer migration:
-- per-workspace pin persistence (via auto-core.state.namespace),
-- doc:pinned / doc:unpinned events, core.file:modified live refresh
-- subscription, and the auto-core.files-driven find() filter prefs.
--
-- Open-slot rendering needs md-render + an actual markdown buffer
-- and is too entangled to drive headless cleanly; we cover the
-- state + events + filter wiring instead. Live verification of the
-- 6-pane float layout is the user's daily flow.

-- Derive plugin_root from the smoke script's own path so the driver
-- runs on any machine. `tests/smoke.lua` is two `:h` levels below
-- the worktree root (e.g. `…/md-harpoon.nvim/comms-1`). The bare-
-- repo top (`…/md-harpoon.nvim/`) does NOT contain `lua/` — modules
-- live under each worktree. The family workspace dir (parent of
-- bare repo) needs `:h:h:h`. Surfaced + codified as
-- `lua-nvim-plugin-development.md` rule 2 / synthesis L11 on
-- 2026-05-16.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins_workspace = vim.fn.fnamemodify(plugin_root, ":h:h")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
-- Each candidate prepends in order — LAST prepend wins, so list the
-- canonical / development tip last.
for _, p in ipairs({
  LAZY .. "/plenary.nvim",
  LAZY .. "/md-render.nvim",  -- soft-dep used by open_slot only
  plugins_workspace .. "/auto-core.nvim/main",
  plugins_workspace .. "/auto-core.nvim/comms-2",  -- post-v0.1.11 dev tip
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  else
    -- Visible warning rather than silent fallback (rule 2 §smoke-rtp).
    vim.notify("smoke: rtp candidate not found: " .. p,
      vim.log.levels.WARN)
  end
end

vim.o.columns = 200
vim.o.lines   = 60
vim.o.swapfile = false
vim.o.hidden   = true

vim.fn.delete("/tmp/md-harpoon-smoke-config", "rf")
vim.fn.delete("/tmp/md-harpoon-smoke-state",  "rf")
vim.env.XDG_CONFIG_HOME = "/tmp/md-harpoon-smoke-config"
vim.env.XDG_STATE_HOME  = "/tmp/md-harpoon-smoke-state"

local fail_count, pass_count = 0, 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

-- ───────── 1. require + public API surface ─────────
print("\n[1] require + public API surface")
local mh = require("md-harpoon")
ok("require returns a module", type(mh) == "table")
for _, fn in ipairs({
  "setup", "render_current", "render_path", "focus", "close_all",
  "browser_open", "find",
}) do
  ok(("public function exported: M." .. fn), type(mh[fn]) == "function")
end
ok("M.SLOTS exposed", type(mh.SLOTS) == "table" and #mh.SLOTS == 6)

-- ───────── 2. state.lua per-workspace pin persistence ─────────
print("\n[2] state.lua per-workspace pin persistence")
local mh_state = require("md-harpoon.state")
mh_state._reset_for_tests()

local core = require("auto-core")
-- Set workspace A and pin slot 1.
core.git.worktree.set_workspace_root("/tmp/workspace-A")
mh_state.workspace_changed("/tmp/workspace-A")
mh_state.set_pin("1", { source_path = "/abs/note-A.md", last_cursor = { 5, 0 } })

local pin_a = mh_state.get_pin("1")
ok("workspace A: get_pin('1').source_path", pin_a
  and pin_a.source_path == "/abs/note-A.md",
  vim.inspect(pin_a))
ok("workspace A: get_pin('1').last_cursor",
  pin_a and pin_a.last_cursor[1] == 5 and pin_a.last_cursor[2] == 0)

-- Switch to workspace B — slot 1 should be empty for the new
-- workspace. Workspace A's pin must still be retrievable on flip-back.
core.git.worktree.set_workspace_root("/tmp/workspace-B")
mh_state.workspace_changed("/tmp/workspace-B")
local pin_b = mh_state.get_pin("1")
ok("workspace B: slot 1 has no pin (per-workspace scope)",
  pin_b == nil)

mh_state.set_pin("1", { source_path = "/abs/note-B.md" })
local pin_b2 = mh_state.get_pin("1")
ok("workspace B: setting slot 1 doesn't touch A",
  pin_b2 and pin_b2.source_path == "/abs/note-B.md")

core.git.worktree.set_workspace_root("/tmp/workspace-A")
mh_state.workspace_changed("/tmp/workspace-A")
local pin_a2 = mh_state.get_pin("1")
ok("workspace A still holds its original pin after B mutation",
  pin_a2 and pin_a2.source_path == "/abs/note-A.md")

-- Per-workspace clear.
mh_state.clear_pin("1")
ok("clear_pin('1') drops the slot in current workspace",
  mh_state.get_pin("1") == nil)
core.git.worktree.set_workspace_root("/tmp/workspace-B")
mh_state.workspace_changed("/tmp/workspace-B")
ok("clear in A didn't touch B",
  mh_state.get_pin("1") and mh_state.get_pin("1").source_path == "/abs/note-B.md")

-- set_last_cursor partial update.
mh_state.set_last_cursor("1", 42, 7)
local p = mh_state.get_pin("1")
ok("set_last_cursor updates without touching source_path",
  p.source_path == "/abs/note-B.md"
    and p.last_cursor[1] == 42 and p.last_cursor[2] == 7)

-- all_pins() returns the current workspace's slot map only.
mh_state.set_pin("a", { source_path = "/abs/sec.md" })
local all = mh_state.all_pins()
ok("all_pins includes all current-workspace slots",
  type(all) == "table" and all["1"] and all["a"])

-- ───────── 3. doc:pinned topic + setup() wires events ─────────
print("\n[3] auto-core wiring (setup + topic subscriptions)")
local got_pinned = nil
core.events.subscribe("doc:pinned", function(p) got_pinned = p end)

-- M.setup() runs _wire_auto_core; the doc:pinned publish happens
-- inside open_slot which we can't drive headless without md-render.
-- Instead we exercise the topic surface via direct publish to
-- confirm the registry has the topic + a subscriber wakes.
require("md-harpoon").setup({})
core.events.publish("doc:pinned", {
  slot = "2", path = "/abs/x.md", source_bufnr = 99,
})
vim.wait(20)
ok("doc:pinned subscriber fires with payload",
  got_pinned and got_pinned.slot == "2" and got_pinned.path == "/abs/x.md")

-- ───────── 4. find() reads auto-core.files for filter prefs ─────────
print("\n[4] find() consumes auto-core.files for snacks picker prefs")
-- Stub snacks.picker.files to capture the opts md-harpoon passes
-- so we can verify the hidden / ignored values track auto-core.
package.loaded["snacks"] = {
  picker = {
    files = function(opts) _G._captured_picker_opts = opts end,
  },
}

core.files._reset_for_tests()
core.files.set_show_hidden(true)
core.files.set_show_dotfiles(true)
mh.find({ cwd = "/tmp" })
ok("find() with show_hidden=true/show_dotfiles=true → ignored=true,hidden=true",
  _G._captured_picker_opts
    and _G._captured_picker_opts.ignored == true
    and _G._captured_picker_opts.hidden == true,
  vim.inspect(_G._captured_picker_opts))

core.files.set_show_hidden(false)
core.files.set_show_dotfiles(false)
mh.find({ cwd = "/tmp" })
ok("find() with show_*=false → ignored=false,hidden=false",
  _G._captured_picker_opts.ignored == false
    and _G._captured_picker_opts.hidden == false)

-- Per-call opts.picker overrides auto-core.
core.files.set_show_hidden(false)
core.files.set_show_dotfiles(false)
mh.find({ cwd = "/tmp", picker = { hidden = true } })
ok("find() opts.picker overrides auto-core defaults",
  _G._captured_picker_opts.hidden == true
    and _G._captured_picker_opts.ignored == false)

-- ───────── 5. core.file:modified live-refresh subscription wired ─────────
print("\n[5] core.file:modified subscription wired (live-refresh path)")
-- We can't actually verify a re-render without a real float, but
-- we CAN verify the subscription was installed. Count subscribers
-- on core.file:* — md-harpoon's setup should have added one.
local sub_count = core.events.count_subscribers("core.file:*")
ok("setup() installed a core.file:* subscriber",
  type(sub_count) == "number" and sub_count >= 1,
  "count=" .. tostring(sub_count))

-- ───────── 6. workspace_changed wires correctly via worktree:switched ─────────
print("\n[6] worktree:switched re-hydrates per-project pins")
core.events.subscribe("worktree:switched", function(_) end)  -- ensure topic exists
core.events.publish("worktree:switched",
  { from = "/tmp/workspace-A", to = "/tmp/workspace-B", cwd = "/tmp/workspace-B" })
vim.wait(20)
-- After the publish, md-harpoon's subscriber should have called
-- workspace_changed("/tmp/workspace-B") on its state module.
ok("workspace_key updated after worktree:switched",
  mh_state.workspace_key()
    == vim.fn.sha256("/tmp/workspace-B"):sub(1, 16))

-- Cleanup.
mh_state._reset_for_tests()
core.files._reset_for_tests()
package.loaded["snacks"] = nil
_G._captured_picker_opts = nil

-- ───────────────────── summary ─────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
