-- libs/settings — pre-game settings screen, 3-button, push-only.
-- Resolve: require("libs/settings")
--
-- SIMPLE / STATIC, full-screen (480x320), no firmware, no animation, no neon.
-- All chrome (background, focus bar, start-button plate, volume bars) is drawn
-- with Sprite.solid at runtime — no PNG, so it cannot fail to load. The ONLY
-- baked assets are the Vietnamese text labels (a single Text label can't do a
-- positioned layout and Sprite has no text API). If even those are missing the
-- lib degrades to a single multi-line Text label.
--
-- Built lazily on the FIRST render(); the game MUST call menu:destroy() when it
-- leaves SETTINGS (e.g. SETTINGS->PLAY) to free PSRAM and again in game_end().
--
-- 3-button model (LEFT / RIGHT / ENTER) — two modes:
--   NAVIGATE (default): LEFT/RIGHT scroll the cursor through the items, wrapping
--                over [start button, row1, row2, ...]. ENTER selects — the start
--                button (first, default focus) fires on_start(cfg); a value row
--                opens it to edit.
--   EDIT (a value row selected): LEFT/RIGHT change that row's value (choice
--                clamps, range steps with live on_change). ENTER confirms and
--                returns to NAVIGATE. The focus bar lightens to mark edit mode.
--
-- HOME is host-driven (NOT a menu action); the game wires on_home.
--
-- spec = { rows, start_label, on_start (REQUIRED), actions?, kit?, title?,
--          has_save?, on_resume?, resume? }
-- choice row = { kind="choice", key=, label=, options={...}, default=<idx>,
--                label_img=, option_imgs={...} }   -> cfg[key] = index
-- range  row = { kind="range", key=, label=, min=, max=, step=, default=,
--                unit=, on_change=, label_img= }    -> cfg[key] = number
--
-- Resume affordance (optional, opt-in): when spec.has_save is truthy the lib
-- prepends a leading Continue/New-game choice. The lib ONLY drives the choice +
-- dispatch; the GAME owns persistence — it passes spec.has_save (e.g.
-- State.has_save()) and spec.on_resume (REQUIRED when has_save; loads + restores
-- its own save). The resume row is a direct launcher: LEFT/RIGHT flip Continue<->
-- New (scrolling away at the ends), ENTER launches on the spot — Continue fires
-- on_resume, New fires on_start(cfg). The start button launches the same way.
-- spec.resume = { continue_label=, new_label=, label_img=, option_imgs={...} }
-- customises the labels/art (text shows only in the no-kit fallback; sprite mode
-- needs option_imgs to be visible, like any choice row).

local M = {}
local Menu = {}
Menu.__index = Menu

local PRESS = (Input and Input.PRESS) or "press"

-- Shared text label for the no-kit fallback (and to clear it in kit mode).
-- Created lazily; pinned top-left. "" hides it (kit mode draws its own chrome).
local text_lbl           -- Text handle
local function set_text(s)
  if not Text then return end
  if s == "" then
    if text_lbl then text_lbl:show(false) end
    return
  end
  if text_lbl then text_lbl:set(s); text_lbl:show(true)
  else text_lbl = Text.new(s, 4, 4) end
end

-- Layout geometry (480x320), full screen.
local L = {
  SCREEN_W = 480, SCREEN_H = 320,
  BTN_W = 220, BTN_H = 52, BTN_CY = 86,
  ROW_Y0 = 170, ROW_PITCH = 72,           -- value rows: 170, 242
  LABEL_X = 72, VAL_CX = 336,
  HL_W = 360, HL_H = 52,
  SEG_W = 18, SEG_H = 30, SEG_PITCH = 26, -- volume bars
}
local L_HL_X = (L.SCREEN_W - L.HL_W) // 2
local L_BTN_X = (L.SCREEN_W - L.BTN_W) // 2

-- Muted palette (RGB565) — brightness-based focus, no loud colours.
local C = {
  BG          = 0x10A2,
  BTN         = 0x4A8A,   -- start plate (navigate)
  BTN_FOCUS   = 0x9CF3,   -- start plate (focused)
  HL          = 0x39E7,   -- value-row focus bar (navigate)
  HL_EDIT     = 0x6B4D,   -- value-row focus bar (edit)
  VOL_ON      = 0xC618,
  VOL_OFF     = 0x39E7,
}

local function bar(v, lo, hi)
  local cells, span = 5, hi - lo
  local n = (span > 0) and math.floor((v - lo) / span * cells + 0.5) or 0
  if n < 0 then n = 0 elseif n > cells then n = cells end
  return string.rep("#", n) .. string.rep("-", cells - n)
end

function M.new(spec)
  assert(type(spec) == "table", "settings.new: spec table required")
  assert(type(spec.on_start) == "function", "settings.new: spec.on_start required")
  -- Optional resume choice, prepended as the first value row. Built into a fresh
  -- list so the caller's spec.rows is never mutated. Tracked in _resume_row so
  -- the start action can branch on it without scanning by key.
  local rows = spec.rows or {}
  local resume_row
  if spec.has_save then
    assert(type(spec.on_resume) == "function",
           "settings.new: spec.on_resume required when has_save")
    local rz = spec.resume or {}
    resume_row = {
      kind = "choice", key = "__resume",
      options = { rz.continue_label or "Tiep tuc", rz.new_label or "Choi moi" },
      default = 1,                       -- default focus = Continue
      label_img = rz.label_img, option_imgs = rz.option_imgs,
    }
    local merged = { resume_row }
    for _, r in ipairs(rows) do merged[#merged + 1] = r end
    rows = merged
  end
  local self = setmetatable({
    title       = spec.title,
    rows        = rows,
    start_label = spec.start_label or "Start",
    on_start    = spec.on_start,
    on_resume   = spec.on_resume,
    _resume_row = resume_row,
    kit         = spec.kit or "images/settings",
    cursor      = 1,      -- 1 = start button ; 2..#rows+1 = value rows
    editing     = false,
    a_left      = (spec.actions and spec.actions.left)  or "left",
    a_right     = (spec.actions and spec.actions.right) or "right",
    a_enter     = (spec.actions and spec.actions.enter) or "fire",
    _built      = false,
    _no_kit     = false,
    _spr        = {},
    _last       = {},
    -- Value-row geometry. 2 rows keep the original 170/72 layout byte-for-byte;
    -- a 3rd row (e.g. the resume choice) compresses so the last row stays fully
    -- on the 320px screen instead of clipping off the bottom.
    _row_y0     = (#rows >= 3) and 150 or L.ROW_Y0,
    _pitch      = (#rows >= 3) and 60  or L.ROW_PITCH,
  }, Menu)
  for _, r in ipairs(self.rows) do
    if r.kind == "choice" then
      local i = r.default or 1
      if i < 1 then i = 1 elseif i > #r.options then i = #r.options end
      r._idx = i
    elseif r.kind == "range" then
      r._val = r.default or r.min or 0
    end
  end
  return self
end

local function on_start_pos(self) return self.cursor == 1 end
local function row_cy(self, i) return self._row_y0 + (i - 1) * self._pitch end

function Menu:_adjust(dir)
  local r = self.rows[self.cursor - 1]
  if not r then return end
  if r.kind == "choice" then
    local i = r._idx + dir
    if i < 1 then i = 1 elseif i > #r.options then i = #r.options end
    r._idx = i
  elseif r.kind == "range" then
    local v = r._val + dir * (r.step or 1)
    if v < r.min then v = r.min elseif v > r.max then v = r.max end
    if v ~= r._val then
      r._val = v
      if r.on_change then pcall(r.on_change, v) end
    end
  end
end

function Menu:_collect()
  local cfg = {}
  for _, r in ipairs(self.rows) do
    if r.kind == "choice" then cfg[r.key] = r._idx
    elseif r.kind == "range" then cfg[r.key] = r._val end
  end
  return cfg
end

-- Fire the chosen start action: Continue -> on_resume, otherwise on_start(cfg)
-- with the internal __resume key stripped. Shared by the start button and the
-- resume row so either one launches.
function Menu:_launch()
  if self._resume_row and self._resume_row._idx == 1 then
    self.on_resume()
  else
    local cfg = self:_collect(); cfg.__resume = nil
    self.on_start(cfg)
  end
end

function Menu:_scroll(dir)
  local n = #self.rows + 1
  self.cursor = self.cursor + dir
  if self.cursor < 1 then self.cursor = n
  elseif self.cursor > n then self.cursor = 1 end
end

function Menu:input(action, phase)
  if phase ~= PRESS then return false end
  if self.editing then
    if action == self.a_left then self:_adjust(-1); return true
    elseif action == self.a_right then self:_adjust(1); return true
    elseif action == self.a_enter then self.editing = false; return true end
    return false
  end
  -- The resume row is a direct action selector (NOT an editable value): LEFT/
  -- RIGHT flip Continue<->New and fall through to scrolling at the ends, ENTER
  -- launches immediately. This is what a returning player expects from pressing
  -- the highlighted "Continue" item.
  local frow = self.rows[self.cursor - 1]
  if frow and frow == self._resume_row then
    if action == self.a_left then
      if frow._idx > 1 then frow._idx = frow._idx - 1 else self:_scroll(-1) end
      return true
    elseif action == self.a_right then
      if frow._idx < #frow.options then frow._idx = frow._idx + 1 else self:_scroll(1) end
      return true
    elseif action == self.a_enter then
      self:_launch(); return true
    end
    return false
  end
  if action == self.a_left then self:_scroll(-1); return true
  elseif action == self.a_right then self:_scroll(1); return true
  elseif action == self.a_enter then
    if on_start_pos(self) then self:_launch()
    else self.editing = true end
    return true
  end
  return false
end

----------------------------------------------------------------------
-- Sprites
----------------------------------------------------------------------
local function load_img(path)
  if not (Sprite and Sprite.image) then return nil end
  local ok, s = pcall(Sprite.image, path)
  if ok and s then return s end
  print("settings: asset MISSING/invalid -> " .. tostring(path))
  return nil
end

local function solid(w, h, color)
  if not (Sprite and Sprite.solid) then return nil end
  local ok, s = pcall(Sprite.solid, w, h, color)
  if ok and s then return s end
  return nil
end

local function chrome_path(self, name) return self.kit .. "/chrome/" .. name end
local function place(s, x, y) if s then s:set_pos(x, y) end end
local function show(s, v) if s then s:set_visible(v) end end
local function front(s) if s then s:to_front() end end

local function label_img_path(self, r)
  return r.label_img or (self.kit .. "/lbl_" .. tostring(r.key) .. ".png")
end
local function option_img_path(self, r, i)
  if r.option_imgs and r.option_imgs[i] then return r.option_imgs[i] end
  return self.kit .. "/" .. tostring(r.key) .. "/" .. i .. ".png"
end

local function row_sprites(r)
  local t = {}
  local function add(s) if s then t[#t + 1] = s end end
  add(r._label)
  if r._opts then for _, o in ipairs(r._opts) do add(o) end end
  if r._seg_off then for _, o in ipairs(r._seg_off) do add(o) end end
  if r._seg_on then for _, o in ipairs(r._seg_on) do add(o) end end
  return t
end

function Menu:_build()
  self._built = true
  local sp = self._spr

  sp.bg = solid(L.SCREEN_W, L.SCREEN_H, C.BG)
  if not sp.bg then self._no_kit = true; return end  -- no Sprite.solid -> text fallback
  place(sp.bg, 0, 0)
  set_text("")   -- kit mode draws its own chrome; hide the text fallback

  -- focus bars (value rows) + start plate
  sp.hl       = solid(L.HL_W, L.HL_H, C.HL)
  sp.hl_edit  = solid(L.HL_W, L.HL_H, C.HL_EDIT)
  sp.btn      = solid(L.BTN_W, L.BTN_H, C.BTN)
  sp.btn_focus= solid(L.BTN_W, L.BTN_H, C.BTN_FOCUS)
  show(sp.hl, false); show(sp.hl_edit, false)
  place(sp.btn, L_BTN_X, L.BTN_CY - L.BTN_H // 2)
  place(sp.btn_focus, L_BTN_X, L.BTN_CY - L.BTN_H // 2)
  sp.btn_text = load_img(chrome_path(self, "btn_start.png"))
  if sp.btn_text then
    local tw, th = sp.btn_text:get_size()
    place(sp.btn_text, L_BTN_X + (L.BTN_W - tw) // 2, L.BTN_CY - th // 2)
  end

  for i, r in ipairs(self.rows) do
    local cy = row_cy(self, i)
    r._label = load_img(label_img_path(self, r))
    if r._label then
      local _, lh = r._label:get_size()
      place(r._label, L.LABEL_X, cy - lh // 2)
    end
    if r.kind == "choice" then
      r._opts = {}
      for k = 1, #r.options do
        local o = load_img(option_img_path(self, r, k))
        if o then
          local ow, oh = o:get_size()
          o:set_pos(L.VAL_CX - ow // 2, cy - oh // 2)
          o:set_visible(false)
        end
        r._opts[k] = o
      end
    elseif r.kind == "range" then
      local nseg = math.max(1, math.floor((r.max - r.min) / (r.step or 1) + 0.5))
      r._nseg, r._seg_off, r._seg_on = nseg, {}, {}
      local total = (nseg - 1) * L.SEG_PITCH + L.SEG_W
      local x0 = L.VAL_CX - total // 2
      for k = 1, nseg do
        local x = x0 + (k - 1) * L.SEG_PITCH
        local off = solid(L.SEG_W, L.SEG_H, C.VOL_OFF)
        local on  = solid(L.SEG_W, L.SEG_H, C.VOL_ON)
        place(off, x, cy - L.SEG_H // 2)
        place(on,  x, cy - L.SEG_H // 2); show(on, false)
        r._seg_off[k], r._seg_on[k] = off, on
      end
    end
  end

  -- z order: bg, focus bars, then row content, then start plate + its text
  front(sp.bg); front(sp.hl); front(sp.hl_edit)
  for _, r in ipairs(self.rows) do for _, s in ipairs(row_sprites(r)) do front(s) end end
  front(sp.btn); front(sp.btn_focus); front(sp.btn_text)
end

function Menu:destroy()
  local function kill(s) if s then pcall(function() s:destroy() end) end end
  local sp = self._spr
  kill(sp.bg); kill(sp.hl); kill(sp.hl_edit); kill(sp.btn); kill(sp.btn_focus); kill(sp.btn_text)
  for _, r in ipairs(self.rows) do
    for _, s in ipairs(row_sprites(r)) do kill(s) end
    r._label, r._opts, r._seg_off, r._seg_on = nil
  end
  self._spr, self._last = {}, {}
  self._built, self._no_kit, self.editing = false, false, false
end

-- Text fallback (no Sprite.solid / kit missing): single multi-line label.
function Menu:_render_text()
  local lines = {}
  if self.title then lines[#lines + 1] = self.title; lines[#lines + 1] = "" end
  lines[#lines + 1] = ((self.cursor == 1) and "> " or "  ") .. self.start_label
  for i, r in ipairs(self.rows) do
    local focused = (self.cursor == i + 1)
    local mark = focused and (self.editing and ">>" or "> ") or "  "
    local val = ""
    if r.kind == "choice" then
      val = "< " .. tostring(r.options[r._idx]) .. " >"
    elseif r.kind == "range" then
      val = "< " .. bar(r._val, r.min, r.max) .. " " .. tostring(r._val) .. (r.unit or "") .. " >"
    end
    lines[#lines + 1] = string.format("%s%-10s %s", mark, r.label or r.key, val)
  end
  set_text(table.concat(lines, "\n"))
end

function Menu:render()
  if not self._built then self:_build() end
  if self._no_kit then self:_render_text(); return self end
  local sp, last = self._spr, self._last
  local on_start, editing = on_start_pos(self), self.editing

  if last.cursor ~= self.cursor or last.editing ~= editing then
    last.cursor, last.editing = self.cursor, editing
    if on_start then
      show(sp.hl, false); show(sp.hl_edit, false)
    else
      local y = row_cy(self, self.cursor - 1) - L.HL_H // 2
      place(sp.hl, L_HL_X, y); place(sp.hl_edit, L_HL_X, y)
      show(sp.hl, not editing); show(sp.hl_edit, editing)
    end
    show(sp.btn, not on_start); show(sp.btn_focus, on_start)
  end

  for i, r in ipairs(self.rows) do
    if r.kind == "choice" then
      if last["idx" .. i] ~= r._idx then
        for k, o in ipairs(r._opts) do show(o, k == r._idx) end
        last["idx" .. i] = r._idx
      end
    elseif r.kind == "range" then
      if last["val" .. i] ~= r._val then
        local lit = math.floor((r._val - r.min) / (r.step or 1) + 0.5)
        for k = 1, (r._nseg or 0) do show(r._seg_on[k], k <= lit) end
        last["val" .. i] = r._val
      end
    end
  end
  return self
end

return M
