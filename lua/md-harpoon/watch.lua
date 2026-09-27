---md-harpoon.watch — a directory watch for each open slot's source file (ADR-0200 §4.9).
---
---The live refresh in init.lua listens to `core.file:*`. Those events used to arrive because auto-finder
---watched the whole cwd recursively; auto-finder now watches only the directories expanded in its files
---slot, so a pinned file's changes would go unseen (and a pin outside the cwd never refreshed at all).
---
---One non-recursive `auto-core.fs.watch` per directory, held while an open slot float shows a file in it
---and released when that float closes. At most one per slot — six — and none while no float is open.
---Soft-dep on auto-core: without it `hold` does nothing.
---@module 'md-harpoon.watch'

local M = {}

-- dir → { handle = <fs.watch handle>, slots = { [slot] = true } }
local _dirs = {}
-- slot → { dir = string, win = integer }
local _held = {}

local function fs_watch()
  local ok, w = pcall(require, "auto-core.fs.watch")
  if ok and type(w) == "table" and type(w.start) == "function" then return w end
end

---Release whatever `slot` holds. With `win`, only when the hold belongs to that float — a WinClosed for an
---old float must not release the hold of the float that replaced it.
---@param slot string
---@param win integer?
function M.release(slot, win)
  local h = _held[slot]
  if not h or (win and h.win ~= win) then return end
  _held[slot] = nil
  local d = _dirs[h.dir]
  if not d then return end
  d.slots[slot] = nil
  if next(d.slots) == nil then
    local w = fs_watch()
    if w then pcall(w.stop, d.handle) end
    _dirs[h.dir] = nil
  end
end

---Watch the directory of `path` for the float `win` of `slot`; the hold is released when `win` closes.
---@param slot string
---@param path string?  absolute source path (nil for an unnamed buffer: nothing to watch)
---@param win integer
function M.hold(slot, path, win)
  M.release(slot)
  if type(path) ~= "string" or path == "" then return end
  local w = fs_watch()
  if not w then return end
  local dir = vim.fs.dirname(path)
  local d = _dirs[dir]
  if not d then
    -- ignore = {}: fs.watch's default list (/build/, /dist/, /target/, …) matches the FULL path, so a note
    -- anywhere below such a directory would never refresh. A non-recursive watch has nothing to filter.
    local handle = w.start(dir, { recursive = false, self_extend = false, ignore = {} })
    if not handle then return end
    d = { handle = handle, slots = {} }
    _dirs[dir] = d
  end
  d.slots[slot] = true
  _held[slot] = { dir = dir, win = win }
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() M.release(slot, win) end,
  })
end

---Directories watched right now (tests).
---@return string[]
function M.dirs()
  local out = {}
  for dir in pairs(_dirs) do out[#out + 1] = dir end
  table.sort(out)
  return out
end

---Test-only: stop every handle and forget every hold.
function M._reset_for_tests()
  local w = fs_watch()
  for _, d in pairs(_dirs) do
    if w then pcall(w.stop, d.handle) end
  end
  _dirs, _held = {}, {}
end

return M
