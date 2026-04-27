-- md-harpoon.nvim — user-command surface.
--
-- Lazy-loaded by both `cmd` and `keys` in lazy.nvim specs; this file just
-- defines the commands. The keymaps are the user's to set (or via the
-- spec's `keys = {...}`) — see README for the recommended bindings.

if vim.g.loaded_md_harpoon then return end
vim.g.loaded_md_harpoon = 1

local SLOTS = { "q", "w", "e", "a", "s", "d" }

local function require_slot(arg)
  if not arg or arg == "" then
    vim.notify("md-harpoon: slot required (one of " .. table.concat(SLOTS, ", ") .. ")", vim.log.levels.WARN)
    return nil
  end
  if not vim.tbl_contains(SLOTS, arg) then
    vim.notify("md-harpoon: unknown slot " .. arg, vim.log.levels.WARN)
    return nil
  end
  return arg
end

local function complete_slots(arg_lead)
  return vim.tbl_filter(function(s) return s:sub(1, #arg_lead) == arg_lead end, SLOTS)
end

vim.api.nvim_create_user_command("MdHarpoonFocus", function(o)
  local slot = require_slot(o.args)
  if slot then require("md-harpoon").focus(slot) end
end, { nargs = 1, complete = complete_slots, desc = "md-harpoon: focus / open slot" })

vim.api.nvim_create_user_command("MdHarpoonRender", function(o)
  local slot = require_slot(o.args)
  if slot then require("md-harpoon").render_current(slot) end
end, { nargs = 1, complete = complete_slots, desc = "md-harpoon: render current buffer into slot" })

vim.api.nvim_create_user_command("MdHarpoonRenderPath", function(o)
  local args = vim.split(o.args, "%s+", { trimempty = true })
  local slot = require_slot(args[1])
  local path = args[2]
  if not slot then return end
  if not path or path == "" then
    vim.notify("md-harpoon: path required", vim.log.levels.WARN)
    return
  end
  require("md-harpoon").render_path(slot, path)
end, { nargs = "+", desc = "md-harpoon: render <slot> <path> into slot" })

vim.api.nvim_create_user_command("MdHarpoonFind", function()
  require("md-harpoon").find()
end, { nargs = 0, desc = "md-harpoon: fuzzy-find a markdown file, then pick a slot" })
