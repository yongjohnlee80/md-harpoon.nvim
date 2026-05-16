-- md-harpoon.nvim — six-slot floating Markdown previewer with cursor memory.
--
-- Wraps `delphinus/md-render.nvim` (which does the actual rendering) and adds
-- a slot manager that lets you keep up to six markdown files open as
-- coexisting floats. The layout is a cascade — 1/2/3 at the top of the
-- screen, a/s/d offset half-a-column right and a few rows down of their
-- 1/2/3 pair so the bottom row sits roughly between the top panels. Each
-- slot remembers the cursor position you left it at.
--
-- Why this exists: md-render's bundled `MdPreview.show()` keeps a single
-- module-local FloatWin and `close_if_valid`s it on every call, so calling
-- show() multiple times can't yield multiple coexisting floats. The plugin's
-- library-level API (FloatWin / display_utils / preview.build_content) is
-- the supported escape hatch — we use it to replicate show()'s rendering
-- pipeline with per-slot state.
--
-- Notable differences from `MdPreview.show()`:
--   * `auto_close = false` on every slot's FloatWin so floats persist while
--     focus moves between source buffers and other floats.
--   * Geometry is a six-panel cascade. Per-panel width clamps to
--     [config.min_panel_width, config.max_panel_width] and tracks content;
--     all six panels share the same height (~85% of screen rows). Layout
--     anchors panel 1 to the top-left and panel d to the bottom-right of
--     the screen, then derives the rest — corners always fit, overlap in
--     the middle is acceptable. a/s/d are offset right by cascade_x and
--     down by cascade_y from their 1/2/3 pair.
--   * Cursor sync-back to source on close is intentionally dropped — with
--     six slots open against different sources, syncing them all back is
--     more confusing than helpful.
--   * Per-slot cursor memory: leaving a slot saves the cursor; reopening
--     the same source restores it. Loading a NEW document (uppercase
--     keymaps / `render_current` / file-picker) resets to the top.

local M = {}

-- Defaults. Overridable via M.setup({...}). Calling setup is optional —
-- if the user never calls it, these values are used as-is.
--
--   min_panel_width / max_panel_width — per-slot width clamp. Layout
--     anchoring uses max as the assumed width; per-panel width still
--     tracks content (max(min, min(max, content+2))).
--   panel_height_frac — vertical fraction of screen each panel occupies.
--   cascade_x_frac    — bottom-row horizontal offset as a fraction of
--     the slack between the two corner panels (1 and d). 0.5 = a sits
--     halfway between 1 and 2 on a wide screen; on a narrow screen the
--     slack shrinks so cascade_x shrinks with it.
--   cascade_y         — bottom-row vertical offset, in rows.
local DEFAULTS = {
  min_panel_width   = 60,
  max_panel_width   = 120,
  panel_height_frac = 0.85,
  cascade_x_frac    = 0.5,
  cascade_y         = 4,

  -- Browser export. M.browser_open() converts a source markdown buffer to
  -- standalone HTML and opens it via vim.ui.open. Pandoc is the only
  -- external dependency.
  --
  --   browser_converter         — currently "pandoc" only. Kept as a
  --     config key so a future cmark-gfm path can land without breaking
  --     the API.
  --   browser_cache_dir         — where rendered HTML lands. nil falls
  --     back to stdpath("cache") .. "/md-harpoon".
  --   browser_css               — absolute path to a user CSS file (ends
  --     in .css → linked via --css; otherwise treated as a raw HTML
  --     header fragment for --include-in-header). nil uses the small
  --     built-in stylesheet.
  --   browser_resolve_wikilinks — rewrite [[page]] and ![[asset]] before
  --     pandoc runs so the same file renders in both Obsidian and a
  --     browser. Disable if your sources already use plain markdown
  --     links.
  --   browser_mermaid         — when to inject the mermaid.js loader.
  --     "auto" (default) — inject only if the source contains
  --     ```mermaid blocks. "on" — always inject. "off" — never. The
  --     loader uses a dynamic <script> tag (created at view-time) so
  --     pandoc's --embed-resources does not try to inline the mermaid
  --     library at generation time. View-time needs internet to fetch
  --     mermaid.min.js from CDN.
  browser_converter         = "pandoc",
  browser_cache_dir         = nil,
  browser_css               = nil,
  browser_resolve_wikilinks = true,
  browser_mermaid           = "auto",
}

local config = vim.deepcopy(DEFAULTS)

--- Merge user options into the config table. Calling this is optional;
--- defaults are applied at module load.
---@param opts? table
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  -- Late-bound dispatch via M.* picks up the function defined further
  -- down in the file (after `State` is declared so its closures
  -- capture the right upvalue).
  M._wire_auto_core()
end

-- Top row uses digits (1/2/3) instead of q/w/e to avoid clashing with
-- vim's macro-record key (`q`). Bottom row stays on the home row.
local SLOT_POS = {
  ["1"] = { row = "top",    col = "left"   },
  ["2"] = { row = "top",    col = "middle" },
  ["3"] = { row = "top",    col = "right"  },
  a     = { row = "bottom", col = "left"   },
  s     = { row = "bottom", col = "middle" },
  d     = { row = "bottom", col = "right"  },
}

M.SLOTS = { "1", "2", "3", "a", "s", "d" }

-- Human-readable labels used by the file-picker's panel-prompt. The
-- format_item callback in M.find resolves these so the user sees
-- "upper left (1)" instead of a bare "1".
local SLOT_LABELS = {
  ["1"] = "upper left (1)",
  ["2"] = "upper middle (2)",
  ["3"] = "upper right (3)",
  a     = "left (a)",
  s     = "middle (s)",
  d     = "right (d)",
}

---@class MdHarpoonSlotState
---@field float_win MdRender.FloatWin
---@field source_bufnr integer? bufnr last rendered into this slot
---@field source_path string? absolute path of the source (stable across bufnr churn)
---@field last_cursor integer[]? {row, col} from the last time the user was in the float

---@type table<string, MdHarpoonSlotState>
local State = {}

-- Idempotent auto-core wiring: claims the md-harpoon state.namespace,
-- subscribes to worktree:switched (re-hydrate per-project pins), and
-- subscribes to core.file:modified (live-refresh visible slots whose
-- pinned source changed on disk). Soft-dep on auto-core — no-op when
-- auto-core isn't installed.
--
-- Defined AFTER `State` so its inner closures (subscriber callbacks)
-- capture `State` as an upvalue, not as a (nil) global. M.setup
-- dispatches via `M._wire_auto_core()` which is late-bound table
-- access — order of definition vs M.setup doesn't matter for that
-- call, only for upvalue capture.
local _wired = false
function M._wire_auto_core()
  if _wired then return end
  local ok, core = pcall(require, "auto-core")
  if not ok or type(core) ~= "table" or not core.events or not core.state then
    return
  end
  _wired = true

  pcall(function() require("md-harpoon.state").setup() end)

  -- Register md-harpoon-owned mailbox commands (harpoon_attach,
  -- harpoon_view, harpoon_render_browser) into auto-core's command
  -- whitelist so peer agents can drive the harpoon via outgoing
  -- `kind="command"` messages to the `nvim` executioner. No-op when
  -- the mailbox subsystem isn't available (auto-core present but
  -- without mailbox, or stub install).
  pcall(function() require("md-harpoon.mailbox.commands").register_all() end)

  -- Worktree switch: per-workspace pin scope flips. Close every
  -- open float (the prior workspace's docs aren't relevant in the
  -- new one), clear the in-memory State so subsequent focus(slot)
  -- rehydrates from the new workspace's pin map. No auto-open of
  -- new pins — the user re-focuses manually if they want them.
  core.events.subscribe("worktree:switched", function(payload)
    pcall(function()
      require("md-harpoon.state").workspace_changed(payload and payload.to)
    end)
    for _, slot in ipairs(M.SLOTS) do
      local s = State[slot]
      if s then
        if s.float_win then s.float_win:close_if_valid() end
        s.source_bufnr = nil
        s.source_path = nil
        s.last_cursor = nil
      end
    end
  end)

  -- Live refresh: when the pinned source file changes on disk, re-
  -- render any visible slot whose source_path matches. Debounced
  -- 150ms (matches auto-finder's fs-watch refresh cadence) so a
  -- save burst doesn't fire one render per intermediate write.
  local refresh_pending = {}
  core.events.subscribe("core.file:*", function(payload, _topic)
    if type(payload) ~= "table" or type(payload.path) ~= "string" then
      return
    end
    for _, slot in ipairs(M.SLOTS) do
      local s = State[slot]
      if s and s.source_path == payload.path
          and s.float_win and s.float_win.win
          and vim.api.nvim_win_is_valid(s.float_win.win)
          and not refresh_pending[slot] then
        refresh_pending[slot] = true
        vim.defer_fn(function()
          refresh_pending[slot] = nil
          if State[slot] and State[slot].source_path == payload.path then
            pcall(M.render_path, slot, payload.path)
          end
        end, 150)
      end
    end
  end)
end

local function ensure_slot(slot)
  assert(SLOT_POS[slot], "md-harpoon: unknown slot " .. tostring(slot))
  if not State[slot] then
    State[slot] = {
      float_win = require("md-render").FloatWin.new("md_harpoon_slot_" .. slot),
      source_bufnr = nil,
      source_path = nil,
      last_cursor = nil,
    }
    -- Seed from auto-core.state.namespace per-project pin map (when
    -- auto-core is installed). source_bufnr stays nil — bufnrs are
    -- session-local; the next focus() will resolve source_path back
    -- to a live buffer via bufadd + bufload.
    pcall(function()
      local pin = require("md-harpoon.state").get_pin(slot)
      if pin and type(pin.source_path) == "string" then
        State[slot].source_path = pin.source_path
        State[slot].last_cursor = pin.last_cursor
      end
    end)
  end
  return State[slot]
end

-- Width policy:
--   * Per-panel width clamps to [config.min_panel_width, config.max_panel_width]
--     and tracks its own content (max(min, min(max, content+2))).
--   * Layout positions are computed from a single "layout_W" so panels with
--     short content don't shift the cascade. layout_W starts at max_panel_width
--     and shrinks toward min_panel_width if the two corner panels (1 and d)
--     wouldn't otherwise both fit on screen.
--
-- Column placement (anchor-corners): panel 1 is pinned to the left margin;
-- panel d is pinned flush to the right margin. 3 sits cascade_x to the left
-- of d, 2 is centered between 1 and 3, and a/s sit cascade_x right of 1/2.
-- This guarantees both screen corners are always visible, replacing the old
-- ⅓-grid + post-hoc clamp that would collapse multiple panels onto the same
-- column on narrow terminals.
--
-- Row placement: 1/2/3 at row 1, a/s/d at row 1 + cascade_y. All six panels
-- share the same height (panel_height_frac × screen rows).
local function compute_layout()
  local cols = vim.o.columns
  local margin = 1
  local layout_W = config.max_panel_width
  local available = cols - 2 * margin

  -- cascade_x scales with the slack between the two corner panels: at
  -- cascade_x_frac=0.5, a sits halfway between 1 and 2 on a wide screen,
  -- and shrinks toward 0 as the screen narrows.
  local function cascade_for(W)
    local slack = available - W
    if slack <= 0 then return 0 end
    return math.floor((slack * config.cascade_x_frac) / 2)
  end

  -- Shrink layout_W until both corners (1 and d) fit. Floor at min_panel_width;
  -- if even that doesn't fit, drop cascade_x to 0 (overlap is acceptable;
  -- off-screen is not).
  local cascade_x = cascade_for(layout_W)
  while 2 * layout_W + cascade_x > available and layout_W > config.min_panel_width do
    layout_W = layout_W - 1
    cascade_x = cascade_for(layout_W)
  end
  if 2 * layout_W + cascade_x > available then cascade_x = 0 end

  local x1 = margin
  local xd = math.max(margin, cols - layout_W - margin)
  local x3 = math.max(margin, xd - cascade_x)
  local x2 = math.floor((x1 + x3) / 2)
  local xa = x1 + cascade_x
  local xs = x2 + cascade_x

  return {
    layout_W  = layout_W,
    cascade_x = cascade_x,
    cols_by_slot = {
      ["1"] = x1, ["2"] = x2, ["3"] = x3,
      a = xa, s = xs, d = xd,
    },
  }
end

-- Returns (row, col, width, height) for a slot.
local function geometry(slot, content_lines, content_max_width)
  local lines = vim.o.lines
  local layout = compute_layout()
  local width = math.max(config.min_panel_width,
    math.min(config.max_panel_width, content_max_width + 2))
  local height = math.min(content_lines, math.floor(lines * config.panel_height_frac))

  local pos = SLOT_POS[slot]
  local row = (pos.row == "top") and 1 or (1 + config.cascade_y)
  local col = layout.cols_by_slot[slot]
  return row, col, width, height
end

local function is_markdown(bufnr)
  if vim.bo[bufnr].filetype == "markdown" then return true end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match("%.md$") ~= nil or name:match("%.markdown$") ~= nil
end

local function source_id(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":p") or nil
end

-- Open a slot float displaying `source_bufnr`. Caller is responsible for
-- closing any existing float in this slot first (the entry points below
-- handle that). Mirrors `MdPreview.show()` but with our geometry, persistent
-- (`auto_close = false`) FloatWin, and cursor-position memory.
local function open_slot(slot, source_bufnr)
  local s = ensure_slot(slot)
  if not is_markdown(source_bufnr) then
    require("md-harpoon.log").warn("open", "buffer is not markdown")
    return
  end

  -- Decide whether this open should restore cursor or land at the top.
  -- "Same source" = same resolved path (or, if buf is unnamed, same bufnr).
  local new_id = source_id(source_bufnr) or ("buf:" .. source_bufnr)
  local prev_id = s.source_path or (s.source_bufnr and ("buf:" .. s.source_bufnr))
  local same_source = (prev_id ~= nil) and (prev_id == new_id)
  if not same_source then
    s.last_cursor = nil
  end

  local md = require("md-render")
  md.setup_highlights()

  local source_lines = vim.api.nvim_buf_get_lines(source_bufnr, 0, -1, false)
  local source_name = vim.api.nvim_buf_get_name(source_bufnr)
  -- Content wraps at max_panel_width - 4 to leave room for the rounded
  -- border + a 1-col right-edge margin.
  local opts = {
    buf_dir = vim.fn.fnamemodify(source_name, ":h"),
    max_width = config.max_panel_width - 4,
  }
  local fold_state, expand_state = {}, {}

  local content
  local function build()
    opts.fold_state = fold_state
    opts.expand_state = expand_state
    content = md.preview.build_content(source_lines, opts)
    return content
  end
  build()

  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace("md_harpoon_slot_" .. slot)
  md.display_utils.apply_content_to_buffer(buf, ns, content)

  local content_max_width = 0
  for _, line in ipairs(content.lines) do
    content_max_width = math.max(content_max_width, vim.api.nvim_strwidth(line))
  end
  local row, col, width, height = geometry(slot, #content.lines, content_max_width)

  local title = (" %s — slot %s "):format(vim.fn.fnamemodify(source_name, ":t"), slot)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })

  vim.wo[win].wrap = true
  vim.wo[win].cursorline = true
  vim.wo[win].statusline = " "
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  -- Force normal mode on entry. The slot's keymap (e.g. <leader>m1) is
  -- bound on `n`+`t` modes, so when invoked from a terminal-insert
  -- buffer the `<cmd>...<cr>` mapping carries an "insert intent"
  -- through the focus switch. Even though this buffer is
  -- nomodifiable, single-keystroke navigation (h/j/k/l, gg/G, q to
  -- close, <Home>/<End>/<PageUp>/<PageDown>) doesn't fire as n-mode
  -- until the user presses <Esc>. Explicit stopinsert here is the
  -- canonical fix — same pattern auto-agents.nvim's dock uses (commit
  -- 31ac8ec on github.com/yongjohnlee80/auto-agents).
  vim.cmd("stopinsert")

  -- auto_close = false so the float persists across WinEnter/CursorMoved.
  -- Required for slots to coexist while the user moves between sources.
  s.float_win:setup(win, { auto_close = false })
  s.source_bufnr = source_bufnr
  s.source_path = source_id(source_bufnr)

  -- v0.X.0: persist this pin (per-workspace, keyed by core.workspace_root)
  -- via auto-core.state.namespace + publish doc:pinned so siblings react.
  pcall(function()
    require("md-harpoon.state").set_pin(slot, {
      source_path = s.source_path,
      last_cursor = s.last_cursor,
    })
    require("auto-core").events.publish("doc:pinned", {
      slot         = slot,
      path         = s.source_path,
      source_bufnr = source_bufnr,
    })
  end)

  for _, fold in ipairs(content.callout_folds) do
    fold_state[fold.source_line] = fold.collapsed
  end

  -- Restore last cursor position when reopening the same source. Clamp to
  -- the current line count in case the doc shrank between renders.
  if same_source and s.last_cursor then
    local line_count = vim.api.nvim_buf_line_count(buf)
    local r = math.max(1, math.min(s.last_cursor[1], line_count))
    local c = math.max(0, s.last_cursor[2] or 0)
    pcall(vim.api.nvim_win_set_cursor, win, { r, c })
  end

  -- Track cursor moves inside the float so we can restore on next reopen.
  -- Buffer-scoped autocmd dies with the (bufhidden=wipe) buffer when the
  -- float closes — no manual cleanup needed.
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then return end
      if vim.api.nvim_win_get_buf(win) ~= buf then return end
      local r, c = unpack(vim.api.nvim_win_get_cursor(win))
      s.last_cursor = { r, c }
    end,
  })

  local image_state
  image_state = md.display_utils.setup_images(win, content, ns, {
    buf = buf,
    build_content = build,
  })

  -- Re-render after a fold/expand toggle. Keeps the existing window layout;
  -- only the buffer contents are replaced.
  local function rebuild()
    build()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    md.display_utils.apply_content_to_buffer(buf, ns, content)
    vim.bo[buf].modifiable = false
    local any_expanded = false
    for _, v in pairs(expand_state) do
      if v then
        any_expanded = true
        break
      end
    end
    vim.wo[win].wrap = not any_expanded
  end

  md.display_utils.setup_float_keymaps(buf, ns, win, content, s.float_win, {
    get_content = function() return content end,
    on_fold_toggle = function(source_line, collapsed)
      fold_state[source_line] = collapsed
      rebuild()
      image_state = md.display_utils.update_images(image_state, win, content)
    end,
    on_expand_toggle = function(block_id, expanded)
      expand_state[block_id] = expanded
      rebuild()
      image_state = md.display_utils.update_images(image_state, win, content)
    end,
  })
end

--- Render the current buffer into `slot`. If the slot already has an open
--- float, it is replaced. Cursor is repositioned to the top — explicitly
--- "load a new document here". Notifies if the current buffer isn't
--- markdown.
---@param slot "1"|"2"|"3"|"a"|"s"|"d"
function M.render_current(slot)
  local s = ensure_slot(slot)
  s.float_win:close_if_valid()
  s.last_cursor = nil
  open_slot(slot, vim.api.nvim_get_current_buf())
end

--- Render a markdown file at `path` into `slot` without making it the
--- current buffer. Cursor positions to the top (this is a fresh load by
--- definition). Used by the file picker and as a programmatic entry point
--- (e.g. external RPC: `render_path('a', '/path/to/file.md')`).
---@param slot "1"|"2"|"3"|"a"|"s"|"d"
---@param path string absolute or `~`-prefixed path to a markdown file
function M.render_path(slot, path)
  local resolved = vim.fn.expand(path)
  if vim.fn.filereadable(resolved) ~= 1 then
    require("md-harpoon.log").warn("render", "file not readable: " .. resolved)
    return
  end
  local s = ensure_slot(slot)
  s.float_win:close_if_valid()
  s.last_cursor = nil
  -- bufadd + bufload: creates the buffer if absent, reuses if already
  -- loaded (cheap), populates lines without making the buffer current.
  local bufnr = vim.fn.bufadd(resolved)
  vim.fn.bufload(bufnr)
  open_slot(slot, bufnr)
end

--- Focus slot `slot`. Three-way behavior:
---   1. Float currently open  → jump the cursor into it.
---   2. Float closed but slot has a remembered source → reopen with it,
---      restoring the cursor to where you left it.
---   3. Slot never rendered yet → render the current buffer (handy: the
---      lowercase / digit key "just works" the first time without
---      making the user remember the uppercase / shift variant).
---@param slot "1"|"2"|"3"|"a"|"s"|"d"
function M.focus(slot)
  local s = ensure_slot(slot)
  local win = s.float_win.win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    vim.cmd("stopinsert")
    return
  end
  if s.source_bufnr and vim.api.nvim_buf_is_valid(s.source_bufnr) then
    open_slot(slot, s.source_bufnr)
    return
  end
  -- Rehydrate from a per-project pin: source_path is set (from
  -- auto-core.state.namespace) but source_bufnr is nil (bufnrs are
  -- session-local). Resolve the path back to a live buffer.
  if s.source_path and vim.fn.filereadable(s.source_path) == 1 then
    local bufnr = vim.fn.bufadd(s.source_path)
    vim.fn.bufload(bufnr)
    if is_markdown(bufnr) then
      open_slot(slot, bufnr)
      return
    end
  end
  open_slot(slot, vim.api.nvim_get_current_buf())
end

--- Close every open slot float without touching the slots' remembered
--- sources or cursor positions. Pressing the lowercase / digit focus
--- key for any slot afterwards reopens it with the cursor exactly where
--- you left it. Useful when six floats have piled up and you want a
--- clean screen for a moment.
function M.close_all()
  for _, slot in ipairs(M.SLOTS) do
    local s = State[slot]
    if s then s.float_win:close_if_valid() end
  end
end

-- ============================================================================
-- Browser export
--
-- Convert a source markdown buffer to standalone HTML and open it via
-- vim.ui.open. Pandoc is the only external dependency. Wikilinks
-- ([[page]] and ![[asset]]) are preprocessed in Lua before pandoc runs so
-- the same source renders in both Obsidian and a browser.
-- ============================================================================

-- Tiny default stylesheet — system font, readable max-width, code blocks
-- with subtle background. Designed to cost ~1 KB and look reasonable
-- against arbitrary user content. Override entirely via config.browser_css.
local DEFAULT_CSS = [[
<style>
  body { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; max-width: 760px; margin: 2em auto; padding: 0 1em; line-height: 1.55; color: #222; background: #fafafa; }
  h1, h2, h3, h4 { line-height: 1.25; margin-top: 1.6em; }
  h1 { border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
  pre { background: #f0f0f0; padding: 0.8em; overflow-x: auto; border-radius: 4px; }
  code { background: #f0f0f0; padding: 0.1em 0.35em; border-radius: 3px; font-size: 0.92em; }
  pre code { padding: 0; background: none; }
  blockquote { border-left: 3px solid #ccc; padding-left: 1em; color: #555; margin: 1em 0; }
  table { border-collapse: collapse; margin: 1em 0; }
  th, td { border: 1px solid #ddd; padding: 0.4em 0.8em; }
  th { background: #f4f4f4; }
  img { max-width: 100%; }
  a { color: #06c; text-decoration: none; }
  a:hover { text-decoration: underline; }
  hr { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
  .mermaid { text-align: center; margin: 1em 0; background: #fff; padding: 0.5em; border-radius: 4px; }
  .mermaid svg { max-width: 100%; height: auto; }
</style>
]]

-- Mermaid loader — injected via --include-in-header when the source has
-- mermaid blocks. Uses a *dynamically created* <script> tag (rather than
-- a static <script src=...>) so pandoc's --embed-resources doesn't try to
-- inline the mermaid library at generation time. Mermaid loads from CDN
-- at view-time; offline rendering would need a local-file variant.
--
-- Selector handles both pandoc-default output (<pre class="mermaid">
-- <code>…</code></pre>) and the Prism / highlight.js convention
-- (<pre><code class="language-mermaid">…</code></pre>).
local MERMAID_HEADER = [[
<script>
  document.addEventListener('DOMContentLoaded', function() {
    var pres = new Set();
    document.querySelectorAll('pre.mermaid').forEach(function(p) { pres.add(p); });
    document.querySelectorAll('pre > code.language-mermaid, pre > code.mermaid').forEach(function(c) {
      pres.add(c.parentElement);
    });
    if (pres.size === 0) return;
    pres.forEach(function(pre) {
      var code = pre.querySelector('code');
      var text = code ? code.textContent : pre.textContent;
      var div = document.createElement('div');
      div.className = 'mermaid';
      div.textContent = text;
      pre.replaceWith(div);
    });
    var script = document.createElement('script');
    script.src = 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js';
    script.onload = function() {
      mermaid.initialize({ startOnLoad: false, theme: 'default' });
      mermaid.run();
    };
    script.onerror = function() {
      console.error('mermaid: failed to load from CDN');
    };
    document.head.appendChild(script);
  });
</script>
]]

local function browser_cache_dir()
  local dir = config.browser_cache_dir or (vim.fn.stdpath("cache") .. "/md-harpoon")
  vim.fn.mkdir(dir, "p")
  return dir
end

-- Stable per-source path. Same source ID → same URL, so reopening a
-- render in the same browser tab works. Filename uses the basename for
-- human readability plus an 8-char SHA suffix for collision avoidance.
local function browser_html_path(source_ident)
  local basename = vim.fn.fnamemodify(source_ident, ":t:r")
  if basename == "" then basename = "buffer" end
  local hash = vim.fn.sha256(source_ident):sub(1, 8)
  return browser_cache_dir() .. "/" .. basename .. "-" .. hash .. ".html"
end

-- Lazy-write the default stylesheet to a fixed path so pandoc can pick
-- it up via --include-in-header. Skipped when the user supplies their own.
local function ensure_default_css_file()
  local p = browser_cache_dir() .. "/style-default.html"
  if vim.fn.filereadable(p) ~= 1 then
    local f = io.open(p, "w")
    if not f then return nil end
    f:write(DEFAULT_CSS)
    f:close()
  end
  return p
end

-- Lazy-write the mermaid loader to a fixed path. Same caching pattern as
-- the default CSS — written once, picked up by --include-in-header.
local function ensure_mermaid_header_file()
  local p = browser_cache_dir() .. "/mermaid-header.html"
  if vim.fn.filereadable(p) ~= 1 then
    local f = io.open(p, "w")
    if not f then return nil end
    f:write(MERMAID_HEADER)
    f:close()
  end
  return p
end

-- Cheap pre-pandoc scan for fenced ```mermaid (or ~~~mermaid) blocks.
-- Used by browser_mermaid = "auto" to skip the loader injection on
-- documents that don't need it.
local function source_has_mermaid(md)
  return md:match("```%s*mermaid") ~= nil or md:match("~~~%s*mermaid") ~= nil
end

-- Rewrite Obsidian-style links so the resulting HTML is sensible:
--   ![[image.png]]      → ![](image.png)
--   ![[image.png|alt]]  → ![alt](image.png)
--   [[page|alt]]        → [alt](page.html)
--   [[page]]            → [page](page.html)
-- Cross-page <a href="page.html"> links assume the user will render the
-- linked pages too; otherwise they 404. That's a deliberate tradeoff —
-- it preserves navigability when multiple sources land in the same
-- cache dir.
local function resolve_wikilinks(content)
  content = content:gsub("!%[%[([^%]|]+)|([^%]]+)%]%]", "![%2](%1)")
  content = content:gsub("!%[%[([^%]]+)%]%]", "![](%1)")
  content = content:gsub("%[%[([^%]|]+)|([^%]]+)%]%]", function(target, alt)
    local href = target:gsub("%.md$", "") .. ".html"
    return ("[%s](%s)"):format(alt, href)
  end)
  content = content:gsub("%[%[([^%]]+)%]%]", function(target)
    local href = target:gsub("%.md$", "") .. ".html"
    return ("[%s](%s)"):format(target, href)
  end)
  return content
end

-- Returns: (source_ident, source_lines, source_dir) or all nil on failure.
-- source_ident is the absolute path for real files, "buf:<n>" for unnamed
-- buffers (used only for hash stability). source_dir feeds pandoc's
-- --resource-path so relative image references resolve.
local function browser_resolve_source(opts)
  -- Explicit slot.
  if opts.slot then
    local s = State[opts.slot]
    if not s or not s.source_path then
      require("md-harpoon.log").warn("browser",
        "slot " .. opts.slot .. " has no remembered source")
      return nil, nil, nil
    end
    -- Prefer the live buffer (may have unsaved edits) over the on-disk file.
    if s.source_bufnr and vim.api.nvim_buf_is_valid(s.source_bufnr) then
      local lines = vim.api.nvim_buf_get_lines(s.source_bufnr, 0, -1, false)
      return s.source_path, lines, vim.fn.fnamemodify(s.source_path, ":h")
    end
    if vim.fn.filereadable(s.source_path) ~= 1 then
      require("md-harpoon.log").warn("browser",
        "slot source file not readable: " .. s.source_path)
      return nil, nil, nil
    end
    return s.source_path, vim.fn.readfile(s.source_path), vim.fn.fnamemodify(s.source_path, ":h")
  end

  -- Explicit path.
  if opts.path then
    local resolved = vim.fn.expand(opts.path)
    if vim.fn.filereadable(resolved) ~= 1 then
      require("md-harpoon.log").warn("browser", "file not readable: " .. resolved)
      return nil, nil, nil
    end
    return resolved, vim.fn.readfile(resolved), vim.fn.fnamemodify(resolved, ":h")
  end

  -- Explicit buffer.
  local bufnr = opts.buf
  if bufnr then
    if not vim.api.nvim_buf_is_valid(bufnr) then
      require("md-harpoon.log").warn("browser", "invalid buffer")
      return nil, nil, nil
    end
  else
    -- Default: if the focused window is a slot float, use that slot's
    -- source. Otherwise use the current buffer. Lets `<leader>mb` mean
    -- "render whatever I'm looking at" without an extra arg.
    local cur_win = vim.api.nvim_get_current_win()
    for _, slot in ipairs(M.SLOTS) do
      local s = State[slot]
      if s and s.float_win and s.float_win.win == cur_win then
        return browser_resolve_source({ slot = slot })
      end
    end
    bufnr = vim.api.nvim_get_current_buf()
  end

  if not is_markdown(bufnr) then
    require("md-harpoon.log").warn("browser", "buffer is not markdown")
    return nil, nil, nil
  end

  local path = source_id(bufnr)
  local ident = path or ("buf:" .. bufnr)
  local dir = path and vim.fn.fnamemodify(path, ":h") or vim.fn.getcwd()
  return ident, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), dir
end

local function open_in_browser(path)
  if vim.ui and vim.ui.open then
    vim.ui.open(path)
    return
  end
  -- Fallback for nvim < 0.10.
  local opener
  if vim.fn.has("macunix") == 1 then
    opener = "open"
  elseif vim.fn.has("unix") == 1 then
    opener = "xdg-open"
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    opener = "explorer"
  end
  if not opener then
    require("md-harpoon.log").error("browser",
      "no browser opener for this OS; upgrade nvim or set one manually")
    return
  end
  vim.fn.jobstart({ opener, path }, { detach = true })
end

--- Convert a markdown source to standalone HTML and open it in the
--- default browser. Source resolution mirrors the rest of the plugin:
--- explicit `slot` / `path` / `buf` if given; otherwise the focused slot
--- float (if any); otherwise the current buffer.
---
--- Pandoc is required (or whichever converter is configured). Wikilinks
--- are preprocessed by default — `[[page]]` becomes
--- `[page](page.html)` and `![[asset]]` becomes `![](asset)` — so the
--- same file renders cleanly in both Obsidian and a browser.
---
---@param opts? { slot?: "1"|"2"|"3"|"a"|"s"|"d", path?: string, buf?: integer, css?: string, resolve_wikilinks?: boolean }
function M.browser_open(opts)
  opts = opts or {}

  if vim.fn.executable(config.browser_converter) ~= 1 then
    require("md-harpoon.log").error("browser",
      ("%s not found on PATH (required for browser export)")
        :format(config.browser_converter))
    return
  end

  local source_ident, lines, source_dir = browser_resolve_source(opts)
  if not source_ident then return end

  local md = table.concat(lines, "\n")

  local resolve = opts.resolve_wikilinks
  if resolve == nil then resolve = config.browser_resolve_wikilinks end
  if resolve then md = resolve_wikilinks(md) end

  local args = {
    config.browser_converter,
    "--from=markdown",
    "--to=html5",
    "--standalone",
    "--embed-resources",
    "--resource-path=" .. source_dir,
  }

  local css = opts.css or config.browser_css
  if css then
    if css:match("%.css$") then
      table.insert(args, "--css=" .. css)
    else
      table.insert(args, "--include-in-header=" .. css)
    end
  else
    local default = ensure_default_css_file()
    if default then
      table.insert(args, "--include-in-header=" .. default)
    end
  end

  -- Inject mermaid loader when needed. Modes: "auto" → only if source
  -- has mermaid blocks; "on" → always; "off"/anything else → never.
  local mermaid_mode = config.browser_mermaid or "auto"
  local include_mermaid = mermaid_mode == "on"
    or (mermaid_mode == "auto" and source_has_mermaid(md))
  if include_mermaid then
    local mh = ensure_mermaid_header_file()
    if mh then
      table.insert(args, "--include-in-header=" .. mh)
    end
  end

  local result = vim.fn.system(args, md)
  if vim.v.shell_error ~= 0 then
    require("md-harpoon.log").error("browser", "pandoc failed:\n" .. result)
    return
  end

  local html_path = browser_html_path(source_ident)
  local f = io.open(html_path, "w")
  if not f then
    require("md-harpoon.log").error("browser", "could not write " .. html_path)
    return
  end
  f:write(result)
  f:close()

  open_in_browser(html_path)
end

local function prompt_panel_and_render(path)
  vim.ui.select(M.SLOTS, {
    prompt = ("Render %q into panel:"):format(vim.fn.fnamemodify(path, ":t")),
    format_item = function(slot) return SLOT_LABELS[slot] or slot end,
  }, function(slot)
    if slot then M.render_path(slot, path) end
  end)
end

--- Fuzzy-find a markdown file under `cwd` (or current working dir), then
--- prompt for a panel to render it into. Uses `Snacks.picker.files` when
--- available; falls back to a `vim.fn.glob` + `vim.ui.select` list
--- otherwise (no fuzzy match in fallback — install snacks.nvim for the
--- real experience).
---@param opts? { cwd?: string, picker?: table }
function M.find(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()

  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    -- Read the canonical file-filter prefs from auto-core.files.
    -- Snacks's `hidden` opt covers dotfiles (`.foo`); `ignored`
    -- covers gitignored. Both default to TRUE in auto-core (show
    -- everything by default — KB notes typically live under dot
    -- dirs, dotfiles need to be reachable). Soft-dep: when
    -- auto-core isn't installed, fall back to showing both (the
    -- prior behavior of bare snacks defaults).
    local auto_show_hidden, auto_show_dotfiles = true, true
    local ok_core, core = pcall(require, "auto-core")
    if ok_core and core and core.files then
      auto_show_hidden   = core.files.get_show_hidden()
      auto_show_dotfiles = core.files.get_show_dotfiles()
    end
    -- Layered opts: auto-core canonical prefs at the bottom; user's
    -- per-call `opts.picker` overrides on top; non-overridable
    -- final defaults (cwd / ft / title / confirm) last.
    local picker_opts = vim.tbl_deep_extend("force",
      { hidden = auto_show_dotfiles, ignored = auto_show_hidden },
      opts.picker or {},
      {
        cwd = cwd,
        ft = "md",
        title = "Markdown files",
        confirm = function(picker, item)
          picker:close()
          if item and item.file then
            vim.schedule(function() prompt_panel_and_render(item.file) end)
          end
        end,
      })
    snacks.picker.files(picker_opts)
    return
  end

  -- Fallback: glob + vim.ui.select. Recursive **, case-insensitive on the
  -- common .md / .markdown extensions.
  local files = {}
  for _, ext in ipairs({ "md", "markdown" }) do
    for _, f in ipairs(vim.fn.glob(cwd .. "/**/*." .. ext, false, true)) do
      table.insert(files, f)
    end
  end
  if #files == 0 then
    require("md-harpoon.log").warn("find", "no markdown files under " .. cwd)
    return
  end
  vim.ui.select(files, {
    prompt = "Markdown:",
    format_item = function(p) return vim.fn.fnamemodify(p, ":.") end,
  }, function(choice)
    if choice then prompt_panel_and_render(choice) end
  end)
end

return M
