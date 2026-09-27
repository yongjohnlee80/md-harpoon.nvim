-- tests/pin-watch.lua — an open slot watches its source file's directory (ADR-0200 §4.9).
-- Run with: nvim --headless -u NONE -l tests/pin-watch.lua
--
-- auto-finder no longer watches the whole cwd, so the core.file:* events md-harpoon's live refresh listens
-- to only arrive for a directory somebody watches. md-harpoon.watch holds one non-recursive auto-core
-- fs.watch per directory while an open slot float shows a file in it. The cells drive the real
-- render_path → open_slot path (md-render on the runtimepath) and count live auto-core handles.

local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins_workspace = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  LAZY .. "/md-render.nvim",
  LAZY .. "/auto-core.nvim",
  plugins_workspace .. "/auto-core.nvim/main",
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end

-- XDG sandbox: unique per run, removed at exit (tests never touch the developer's environment)
local SANDBOX = vim.fn.tempname() .. "-md-harpoon-pin-watch"
for _, k in ipairs({ "CONFIG", "STATE", "CACHE" }) do
  local d = SANDBOX .. "/" .. k:lower()
  vim.fn.mkdir(d, "p")
  vim.env["XDG_" .. k .. "_HOME"] = d
end

vim.o.columns, vim.o.lines, vim.o.swapfile, vim.o.hidden = 200, 60, false, true

local pass, fail = 0, 0
local function ok(name, cond, detail)
  print((cond and "  PASS  " or "  FAIL  ") .. name .. ((not cond and detail ~= nil) and ("  — " .. tostring(detail)) or ""))
  if cond then pass = pass + 1 else fail = fail + 1 end
end
local function wait(pred, ms) return vim.wait(ms or 2000, pred, 10) end

print("[0] provenance")
ok("md-render is on the runtimepath", pcall(require, "md-render"))
ok("auto-core.fs.watch is on the runtimepath", pcall(require, "auto-core.fs.watch"))
ok("the loaded md-harpoon.watch is this worktree's",
  vim.startswith(vim.api.nvim_get_runtime_file("lua/md-harpoon/watch.lua", false)[1] or "", plugin_root))

local fs_watch = require("auto-core.fs.watch")
local mh = require("md-harpoon")
local watch = require("md-harpoon.watch")
mh.setup({})

-- live non-recursive auto-core handles rooted at `dir`
local function live(dir)
  local n = 0
  for _, st in ipairs(fs_watch.list()) do
    if st.root == dir and st.opts and st.opts.recursive == false then n = n + 1 end
  end
  return n
end

-- the fixture lives OUTSIDE the cwd: the case the old cwd-wide walk never covered
local DIR = vim.fn.tempname() .. "-notes"
vim.fn.mkdir(DIR, "p")
DIR = vim.uv.fs_realpath(DIR)
local NOTE, OTHER = DIR .. "/note.md", DIR .. "/other.md"
vim.fn.writefile({ "# note", "", "one" }, NOTE)
vim.fn.writefile({ "# other" }, OTHER)
ok("precondition: the fixture is outside the cwd", not vim.startswith(DIR, vim.fn.getcwd() .. "/"))

-- spy on the refresh's re-render (the subscriber calls M.render_path through the module table)
local real_render = mh.render_path
local refreshes = {}
local function spy_on() mh.render_path = function(slot, path) refreshes[#refreshes + 1] = { slot, path }; return real_render(slot, path) end end
local function spy_off() mh.render_path = real_render end
local function slot_win(slot)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" and (cfg.title and vim.inspect(cfg.title):find("slot " .. slot, 1, true)) then return w end
    local _ = b
  end
end

print("\n[1] opening a slot watches its file's directory")
ok("precondition: nothing watched before any slot opens", #watch.dirs() == 0 and live(DIR) == 0)
real_render("1", NOTE)
ok("the slot's float is open", slot_win("1") ~= nil)
ok("exactly one non-recursive handle on the note's directory", live(DIR) == 1 and vim.deep_equal(watch.dirs(), { DIR }),
  vim.inspect(watch.dirs()))

print("\n[2] an external write re-renders the open slot")
spy_on()
vim.wait(300)
refreshes = {}
vim.fn.writefile({ "# note", "", "two" }, NOTE)
wait(function() return #refreshes > 0 end, 2500)
ok("the write reached the live refresh (render_path for slot 1)",
  #refreshes >= 1 and refreshes[1][1] == "1" and refreshes[1][2] == NOTE, vim.inspect(refreshes))
spy_off()
wait(function() return slot_win("1") ~= nil end)
ok("after the re-render: still exactly one handle (the old float's close released, the new one held)",
  live(DIR) == 1, live(DIR))

print("\n[3] two slots in one directory share one handle")
real_render("2", OTHER)
ok("slot 2 open", slot_win("2") ~= nil)
ok("still exactly one handle for the shared directory", live(DIR) == 1, live(DIR))
vim.api.nvim_win_close(slot_win("1"), true)
ok("closing slot 1 keeps the handle slot 2 still needs", live(DIR) == 1, live(DIR))
vim.api.nvim_win_close(slot_win("2"), true)
ok("closing slot 2 releases it: zero handles", live(DIR) == 0 and #watch.dirs() == 0, live(DIR))

print("\n[4] a closed slot costs nothing and refreshes nothing")
spy_on()
refreshes = {}
vim.fn.writefile({ "# note", "", "three" }, NOTE)
vim.wait(900)
ok("no handle, no re-render while no float shows the file", live(DIR) == 0 and #refreshes == 0,
  vim.inspect(refreshes))
spy_off()

print("\n[5] close_all and a worktree switch release every hold")
real_render("1", NOTE); real_render("a", OTHER)
ok("precondition: two slots open, one handle", slot_win("1") and slot_win("a") and live(DIR) == 1)
mh.close_all()
ok("close_all: zero handles", live(DIR) == 0 and #watch.dirs() == 0, live(DIR))
real_render("3", NOTE)
ok("precondition: slot 3 open, one handle", slot_win("3") ~= nil and live(DIR) == 1)
require("auto-core").events.publish("worktree:switched", { from = "/tmp/a", to = "/tmp/b" })
wait(function() return live(DIR) == 0 end, 1000)
ok("worktree:switched closes the floats and releases their handles", live(DIR) == 0 and #watch.dirs() == 0, live(DIR))

print("\n[6] the guard fires: a hold released by a stale float close would leak the new one")
real_render("s", NOTE)
local w1 = slot_win("s")
watch.release("s", w1 + 100000) -- a close event for some other window
ok("a WinClosed for another window does not release the slot's hold", live(DIR) == 1, live(DIR))
vim.api.nvim_win_close(w1, true)
ok("its own float closing does", live(DIR) == 0, live(DIR))

watch._reset_for_tests()
vim.fn.delete(DIR, "rf")
vim.fn.delete(SANDBOX, "rf")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
