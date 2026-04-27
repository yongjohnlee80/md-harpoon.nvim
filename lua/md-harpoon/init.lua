-- md-harpoon.nvim — six-slot floating Markdown previewer with cursor memory.
--
-- Wraps `delphinus/md-render.nvim` (which does the actual rendering) and adds
-- a slot manager that lets you keep up to six markdown files open as
-- coexisting floats laid out in a 2×3 grid: q/w/e on top, a/s/d on the
-- bottom. Each slot remembers the cursor position you left it at, so
-- focusing back into a slot drops you exactly where you were — not at line 1.
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
--   * Geometry is fixed to a left/middle/right × top/bottom grid (each panel
--     ~⅓ wide, ~½ tall) instead of one centered float.
--   * Cursor sync-back to source on close is intentionally dropped — with
--     six slots open against different sources, syncing them all back is
--     more confusing than helpful.
--   * Per-slot cursor memory: leaving a slot saves the cursor; reopening
--     the same source restores it. Loading a NEW document (uppercase
--     keymaps / `render_current` / file-picker) resets to the top.

local M = {}

-- Panel width bounds. Adjust here to change the per-slot floor/ceiling.
-- The float clamps to [MIN_PANEL_WIDTH, MAX_PANEL_WIDTH]; content wraps
-- at CONTENT_INTERIOR_WIDTH (= MAX_PANEL_WIDTH - 4 to leave room for the
-- rounded border + a 1-col right-edge margin).
local MIN_PANEL_WIDTH = 80
local MAX_PANEL_WIDTH = 120
local CONTENT_INTERIOR_WIDTH = MAX_PANEL_WIDTH - 4

local SLOT_POS = {
  q = { row = "top",    col = "left"   },
  w = { row = "top",    col = "middle" },
  e = { row = "top",    col = "right"  },
  a = { row = "bottom", col = "left"   },
  s = { row = "bottom", col = "middle" },
  d = { row = "bottom", col = "right"  },
}

M.SLOTS = { "q", "w", "e", "a", "s", "d" }

---@class MdHarpoonSlotState
---@field float_win MdRender.FloatWin
---@field source_bufnr integer? bufnr last rendered into this slot
---@field source_path string? absolute path of the source (stable across bufnr churn)
---@field last_cursor integer[]? {row, col} from the last time the user was in the float

---@type table<string, MdHarpoonSlotState>
local State = {}

local function ensure_slot(slot)
  assert(SLOT_POS[slot], "md-harpoon: unknown slot " .. tostring(slot))
  if not State[slot] then
    State[slot] = {
      float_win = require("md-render").FloatWin.new("md_harpoon_slot_" .. slot),
      source_bufnr = nil,
      source_path = nil,
      last_cursor = nil,
    }
  end
  return State[slot]
end

-- Width policy (panels, not content):
--   * Floor / ceiling from MIN_PANEL_WIDTH / MAX_PANEL_WIDTH. Hard bounds,
--     screen-size independent.
--   * Within those bounds, panels track their content's actual width.
--
-- Column placement uses a ⅓ grid for predictable left/middle/right
-- positioning. Three MAX_PANEL_WIDTH-wide panels overlap on screens narrower
-- than ~3 × MAX_PANEL_WIDTH; intentional ("a little overlap is okay since
-- we have focus features").
--
-- Row placement splits available height roughly in half — top row at
-- row=1, bottom row offset down by `top_height + 1` for a 1-line gap.
-- A/s/d sit slightly lower than they did in the 3-slot ancestor to make
-- room for q/w/e on top.
--
-- Returns (row, col, width, height).
local function geometry(slot, content_lines, content_max_width)
  local cols, lines = vim.o.columns, vim.o.lines
  local margin = 1
  local each_outer = math.floor((cols - 4 * margin) / 3) -- ⅓ slot incl. borders
  local width = math.max(MIN_PANEL_WIDTH, math.min(MAX_PANEL_WIDTH, content_max_width + 2))

  -- Reserve ~3 lines for cmdline + status; 1-line gap between rows.
  local usable = math.max(10, lines - 3)
  local row_height = math.floor((usable - 1) / 2)
  local height = math.min(content_lines, row_height)

  local pos = SLOT_POS[slot]
  local row = pos.row == "top" and 1 or (1 + row_height + 1)

  local col
  if pos.col == "left" then
    col = margin
  elseif pos.col == "middle" then
    col = margin + each_outer + margin
  else
    col = margin + 2 * (each_outer + margin)
  end
  -- Keep the float on screen on narrow terminals: if the right edge would
  -- fall off the visible area, slide left so it fits flush against the
  -- right margin. Mirrors the plugin's own clamp in
  -- display_utils.open_float_window.
  col = math.min(col, math.max(0, cols - width))
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
    vim.notify("md-harpoon: buffer is not markdown", vim.log.levels.WARN)
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
  local opts = {
    buf_dir = vim.fn.fnamemodify(source_name, ":h"),
    max_width = CONTENT_INTERIOR_WIDTH,
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

  -- auto_close = false so the float persists across WinEnter/CursorMoved.
  -- Required for slots to coexist while the user moves between sources.
  s.float_win:setup(win, { auto_close = false })
  s.source_bufnr = source_bufnr
  s.source_path = source_id(source_bufnr)

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
---@param slot "q"|"w"|"e"|"a"|"s"|"d"
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
---@param slot "q"|"w"|"e"|"a"|"s"|"d"
---@param path string absolute or `~`-prefixed path to a markdown file
function M.render_path(slot, path)
  local resolved = vim.fn.expand(path)
  if vim.fn.filereadable(resolved) ~= 1 then
    vim.notify("md-harpoon: file not readable: " .. resolved, vim.log.levels.WARN)
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
---      lowercase key "just works" the first time without making the user
---      remember the uppercase variant).
---@param slot "q"|"w"|"e"|"a"|"s"|"d"
function M.focus(slot)
  local s = ensure_slot(slot)
  local win = s.float_win.win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    return
  end
  if s.source_bufnr and vim.api.nvim_buf_is_valid(s.source_bufnr) then
    open_slot(slot, s.source_bufnr)
    return
  end
  open_slot(slot, vim.api.nvim_get_current_buf())
end

local function prompt_panel_and_render(path)
  vim.ui.select(M.SLOTS, {
    prompt = ("Render %q into panel:"):format(vim.fn.fnamemodify(path, ":t")),
  }, function(slot)
    if slot then M.render_path(slot, path) end
  end)
end

--- Fuzzy-find a markdown file under `cwd` (or current working dir), then
--- prompt for a panel to render it into. Uses `Snacks.picker.files` when
--- available; falls back to a `vim.fn.glob` + `vim.ui.select` list
--- otherwise (no fuzzy match in fallback — install snacks.nvim for the
--- real experience).
---@param opts? { cwd?: string }
function M.find(opts)
  opts = opts or {}
  local cwd = opts.cwd or vim.fn.getcwd()

  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    snacks.picker.files({
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
    vim.notify("md-harpoon: no markdown files under " .. cwd, vim.log.levels.WARN)
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
