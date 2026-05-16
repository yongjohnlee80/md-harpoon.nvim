---md-harpoon.log — single-file logging surface for the plugin.
---
---Per ADR 0021 §6 (the "wrapper rule"), every auto-family plugin
---owns exactly one `lua/<plugin>/log.lua` that delegates to
---`auto-core.log`. Feature code in md-harpoon calls THIS module;
---feature code MUST NOT `require("auto-core").log` directly.
---
---md-harpoon's pre-ADR-0021 pattern was hand-prefixed
---`vim.notify("md-harpoon: …", level)` calls scattered across
---`init.lua` and `mailbox/commands.lua`. The Phase 2 sweep replaces
---each with `log.<level>(component, msg)` — the literal
---"md-harpoon: " prefix is now the wrapper's namespace responsibility.
---
---@module 'md-harpoon.log'

local core_log
do
  local ok, core = pcall(require, "auto-core")
  if ok and type(core) == "table" and type(core.log) == "table" then
    core_log = core.log
  end
end

local NS = "md-harpoon"

local M = {}

M.levels = core_log and core_log.levels or {
  ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5,
}

---Prefix `component` with `md-harpoon.` so logs are namespaced
---under the family root. Idempotent.
---@param component any
---@return string
local function ns(component)
  if type(component) ~= "string" or component == "" then
    return NS
  end
  if component == NS or component:sub(1, #NS + 1) == (NS .. ".") then
    return component
  end
  return NS .. "." .. component
end

-- Pre-auto-core fallback. Preserves the v0.2.x "md-harpoon: " toast
-- prefix shape so users without auto-core installed see the same
-- notification surface they did before this sweep.
local function _legacy_notify(component, msg, level)
  local prefix = (type(component) == "string" and component ~= "")
    and (NS .. "." .. component) or NS
  vim.notify(("[" .. prefix .. "] ") .. tostring(msg), level)
end

local function level_call(level_fn, fallback_level, component, ...)
  if level_fn then
    if type(component) ~= "string" then
      level_fn(NS, component, ...)
    else
      level_fn(ns(component), ...)
    end
    return
  end
  local parts = type(component) == "string" and { ... } or { component, ... }
  local out = {}
  for i, p in ipairs(parts) do
    if type(p) == "table" or type(p) == "boolean" then
      out[i] = vim.inspect(p)
    else
      out[i] = tostring(p)
    end
  end
  _legacy_notify(
    type(component) == "string" and component or nil,
    table.concat(out, " "), fallback_level)
end

function M.error(component, ...)
  level_call(core_log and core_log.error, vim.log.levels.ERROR, component, ...)
end
function M.warn(component, ...)
  level_call(core_log and core_log.warn, vim.log.levels.WARN, component, ...)
end
function M.info(component, ...)
  level_call(core_log and core_log.info, vim.log.levels.INFO, component, ...)
end
function M.debug(component, ...)
  level_call(core_log and core_log.debug, vim.log.levels.DEBUG, component, ...)
end
function M.trace(component, ...)
  level_call(core_log and core_log.trace, vim.log.levels.TRACE, component, ...)
end

function M.notify(msg, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.component ~= nil then opts.component = ns(opts.component) end
  if core_log and type(core_log.notify) == "function" then
    return core_log.notify(msg, opts)
  end
  -- Legacy fallback.
  local level = opts.level or vim.log.levels.INFO
  if type(level) == "string" then
    local map = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }
    level = map[level] or vim.log.levels.INFO
  end
  _legacy_notify(opts.component, tostring(msg), level)
end

function M.notifyIf(event, msg, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.component ~= nil then opts.component = ns(opts.component) end
  local fq_event = event
  if type(event) == "string"
      and event ~= NS
      and event:sub(1, #NS + 1) ~= (NS .. ".") then
    fq_event = NS .. "." .. event
  end
  if core_log and type(core_log.notifyIf) == "function" then
    return core_log.notifyIf(fq_event, msg, opts)
  end
  return M.info(opts.component, msg)
end

function M.register_events(events)
  if not core_log or type(core_log.events) ~= "table"
      or type(core_log.events.register) ~= "function" then
    return
  end
  return core_log.events.register(NS, events)
end

return M
