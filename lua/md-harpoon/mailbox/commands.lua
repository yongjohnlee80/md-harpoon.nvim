---md-harpoon.mailbox.commands — register md-harpoon-owned commands
---into auto-core's mailbox command whitelist.
---
---auto-core's `mailbox.commands` registry (security boundary for
---inbound `kind = "command"` messages) is generic — plugins opt in
---by registering names + handlers. This module is md-harpoon's
---contribution. Mirrors the `auto-agents.mailbox.commands` shape so
---a peer agent can send the same `kind="command"` JSON to the `nvim`
---executioner regardless of which plugin owns the verb.
---
---Three commands ship:
---
---  * `harpoon_attach` — pin a markdown file at `path` into a slot.
---    Wraps `md-harpoon.render_path(slot, path)`.
---  * `harpoon_view` — focus / open the float for an already-pinned
---    slot (or render the current buffer if the slot is empty).
---    Wraps `md-harpoon.focus(slot)`.
---  * `harpoon_render_browser` — render the slot's source (or a path,
---    or the current buffer when both are nil) to standalone HTML
---    and open it in the default browser. Wraps
---    `md-harpoon.browser_open({ slot, path })`.
---
---@module 'md-harpoon.mailbox.commands'

local M = {}

---@type table<string, boolean>
local _registered = {}

---@type table<string, boolean>
local VALID_SLOTS = {
  ["1"] = true, ["2"] = true, ["3"] = true,
  a     = true, s     = true, d     = true,
}

local function valid_slot(s)
  return type(s) == "string" and VALID_SLOTS[s] == true
end

local function err(code, message)
  return { ok = false, code = code, error = message }
end

---@param args table
---@return table
local function handle_attach(args)
  if type(args) ~= "table" then
    return err("invalid_args", "args (table) required")
  end
  if not valid_slot(args.slot) then
    return err("invalid_slot",
      "args.slot must be one of '1','2','3','a','s','d'")
  end
  if type(args.path) ~= "string" or args.path == "" then
    return err("invalid_args", "args.path (non-empty string) required")
  end
  local ok_mh, mh = pcall(require, "md-harpoon")
  if not ok_mh then
    return err("plugin_unavailable", "md-harpoon not loadable: " .. tostring(mh))
  end
  local ok, e = pcall(mh.render_path, args.slot, args.path)
  if not ok then
    return err("render_failed", tostring(e))
  end
  return { ok = true, slot = args.slot, path = args.path }
end

---@param args table
---@return table
local function handle_view(args)
  if type(args) ~= "table" then
    return err("invalid_args", "args (table) required")
  end
  if not valid_slot(args.slot) then
    return err("invalid_slot",
      "args.slot must be one of '1','2','3','a','s','d'")
  end
  local ok_mh, mh = pcall(require, "md-harpoon")
  if not ok_mh then
    return err("plugin_unavailable", "md-harpoon not loadable: " .. tostring(mh))
  end
  local ok, e = pcall(mh.focus, args.slot)
  if not ok then
    return err("focus_failed", tostring(e))
  end
  return { ok = true, slot = args.slot }
end

---@param args table?
---@return table
local function handle_render_browser(args)
  args = args or {}
  if type(args) ~= "table" then
    return err("invalid_args", "args (table) required if provided")
  end
  if args.slot ~= nil and not valid_slot(args.slot) then
    return err("invalid_slot",
      "args.slot, when provided, must be one of '1','2','3','a','s','d'")
  end
  if args.path ~= nil and (type(args.path) ~= "string" or args.path == "") then
    return err("invalid_args", "args.path, when provided, must be a non-empty string")
  end
  local ok_mh, mh = pcall(require, "md-harpoon")
  if not ok_mh then
    return err("plugin_unavailable", "md-harpoon not loadable: " .. tostring(mh))
  end
  local ok, e = pcall(mh.browser_open, { slot = args.slot, path = args.path })
  if not ok then
    return err("render_failed", tostring(e))
  end
  return { ok = true, slot = args.slot, path = args.path }
end

local SPECS = {
  harpoon_attach = {
    owner       = "md-harpoon",
    description = "Pin a markdown file at `path` into a harpoon slot. Slot is one of '1','2','3','a','s','d'.",
    schema      = { slot = "string", path = "string" },
    handler     = handle_attach,
  },
  harpoon_view = {
    owner       = "md-harpoon",
    description = "Focus / open the harpoon float for `slot`. Restores the slot's last-pinned source when available; renders the current buffer otherwise.",
    schema      = { slot = "string" },
    handler     = handle_view,
  },
  harpoon_render_browser = {
    owner       = "md-harpoon",
    description = "Render a markdown source to standalone HTML (pandoc) and open it in the default browser. Optional `slot` or `path`; both nil falls through to the focused slot / current buffer.",
    schema      = { slot = "string?", path = "string?" },
    handler     = handle_render_browser,
  },
}

---Register every md-harpoon-owned mailbox command. Idempotent —
---safe to call on every wire-up (auto-core allows re-register from
---the same owner). No-op when auto-core's mailbox subsystem isn't
---available. Returns `{ registered = string[], skipped = string[] }`.
---@return { registered: string[], skipped: string[] }
function M.register_all()
  local out = { registered = {}, skipped = {} }
  local ok_core, core = pcall(require, "auto-core")
  if not ok_core or type(core) ~= "table"
      or not core.mailbox or not core.mailbox.commands
      or type(core.mailbox.commands.register) ~= "function" then
    for name in pairs(SPECS) do out.skipped[#out.skipped + 1] = name end
    return out
  end
  for name, spec in pairs(SPECS) do
    local rok, rerr = core.mailbox.commands.register(name, spec)
    if rok then
      _registered[name] = true
      out.registered[#out.registered + 1] = name
    else
      out.skipped[#out.skipped + 1] = name
      vim.notify(
        string.format("md-harpoon mailbox.commands.register('%s') failed: %s",
          name, tostring(rerr)),
        vim.log.levels.WARN)
    end
  end
  return out
end

---Test-only: unregister every command we own.
function M._reset_for_tests()
  local ok, core = pcall(require, "auto-core")
  if not ok or not core.mailbox or not core.mailbox.commands then return end
  for name in pairs(_registered) do
    pcall(core.mailbox.commands.unregister, name)
  end
  _registered = {}
end

return M