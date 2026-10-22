-- tools/smoke_stub.lua - closed stand-in for the Pika Engine, driven by tools/smoke.py.
--
-- Every global table is built from contract/api.json: reading a name the engine
-- does not register is reported and yields nil, as on the robot; calling it fails. Calls that matter for correctness are simulated
-- with the engine's real rules (pools, font faces, transform gate, hidden-until-
-- placed sprites, one sound channel + cooldown, frame strips, integer coords,
-- the body board's voice session, one playing Anim, hooks bound once, handles
-- collected when unreferenced). Registered calls the stub does not model return
-- a neutral value and are listed in the report as "not simulated". Nothing is drawn or played.
--
-- Host contract (set by smoke.py before loading this file):
--   HOST.api, HOST.lim, HOST.manifest   decoded JSON tables
--   HOST.file_size(rel) -> bytes | nil  HOST.png_size(rel) -> w, h, has_alpha | nil
--   HOST.sound_ms(rel) -> ms            HOST.read(rel) -> text | nil
--   HOST.anim_ms(rel) -> ms | nil       one pass of a GIF or MJPEG (nil: unknown, never ends)
--   HOST.anim_ok(rel) -> bool           the file opens as its codec (GIF / JPEG header)
--   HOST.report(kind, code, msg)        kind: "error" | "warn" | "info"

local H = HOST
local API, LIM, MAN = H.api, H.lim, H.manifest
local S = {}          -- session state, reset by new_session()
-- Objects handed to game code are empty proxies; their state lives here, out of reach,
-- so reading spr.x fails in the game exactly as it does on the robot.
local D = setmetatable({}, { __mode = "k" })

local function report(kind, code, msg) H.report(kind, code, msg) end
local warned = {}
local function once(kind, code, msg)
  local k = code .. msg
  if not warned[k] then warned[k] = true; report(kind, code, msg) end
end
local function warn_once(code, msg) once("warn", code, msg) end
local function error_once(code, msg) once("error", code, msg) end

-- The robot's Lua has 32-bit integers (PC-INT); lupa has 64-bit ones.
local INT_MAX = (1 << (LIM.lua_int_bits - 1)) - 1
local INT_MIN = -INT_MAX - 1

local function int_arg(v, fname, i)
  if type(v) == "number" and v == math.floor(v) and (v > INT_MAX or v < INT_MIN) then
    warn_once("INT32", ("%s argument #%d = %s is outside the robot's %d-bit integers: it wraps there; keep values below 2^%d")
      :format(fname, i, tostring(v), LIM.lua_int_bits, LIM.lua_int_bits - 1))
  end
  if math.type(v) == "integer" then return v end
  if type(v) == "number" and v == math.floor(v) then return math.tointeger(v) end
  error(("bad argument #%d to '%s' (number has no integer representation)"):format(i, fname), 3)
end

-- Creation site of a handle: the first caller frame that belongs to the pack
-- (game chunks are loaded as "@<rel path>", the stub is not).
local function site()
  for lvl = 3, 12 do
    local info = debug.getinfo(lvl, "Sl")
    if not info then break end
    if info.source:sub(1, 1) == "@" then return info.short_src .. ":" .. tostring(info.currentline) end
  end
  return "?"
end

-- Session id: handles of an ended session are freed by the engine, not by GC.
local SID = 0

local function safe_rel(p)
  if type(p) ~= "string" or p == "" then return false end
  if p:sub(1, 1) == "/" or p:find("\\", 1, true) or p:find("%c") then return false end
  for seg in (p .. "/"):gmatch("(.-)/") do
    if seg == "" or seg == "." or seg == ".." then return false end
  end
  return #p < LIM.sandbox_path_max
end

-- luaL_checkstring: a number is converted, anything else raises.
local function str_arg(v, fname, i)
  if type(v) == "number" then return tostring(v) end
  if type(v) ~= "string" then error(("bad argument #%d to '%s' (string expected, got %s)"):format(i, fname, type(v)), 3) end
  return v
end

local function check_path(p, fname)
  p = str_arg(p, fname, 1)
  if not safe_rel(p) then error(("unsafe path: %s"):format(p), 3) end
  return p
end

-- lua_isnumber: a number or a numeric string.
local function num_of(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) end
  return nil
end

-- ------------------------------------------------------------------ closed tables
local function closed(gname, impl, methods_of)
  local spec = API.globals[gname] or { functions = {}, methods = {}, constants = {} }
  local known = {}
  for _, n in ipairs(spec.functions) do known[n] = true end
  for _, n in ipairs(spec.constants) do known[n] = true end
  local t = {}
  for n in pairs(known) do
    if impl[n] ~= nil then t[n] = impl[n]
    else
      t[n] = function() warn_once("NOT-SIMULATED", gname .. "." .. n .. " is real but not simulated by smoke") end
    end
  end
  for n in pairs(impl) do
    if not known[n] then error("stub bug: " .. gname .. "." .. n .. " is not in contract/api.json") end
  end
  return setmetatable(t, {
    -- Engine globals are plain tables: an unknown key reads as nil (feature detection
    -- works); calling it raises Lua's own "attempt to call a nil value".
    __index = function(_, k)
      warn_once("MISSING-API", ("%s.%s is not an engine API: reads nil on the robot"):format(gname, tostring(k)))
      return nil
    end,
    __newindex = function(_, k) error(("cannot assign %s.%s"):format(gname, tostring(k)), 2) end,
  })
end

-- close: the engine registers __close (Text, Shape), so a <close> local destroys it.
local function method_table(gname, impl, on_gc, close)
  local known = {}
  for _, n in ipairs((API.globals[gname] or {}).methods or {}) do known[n] = true end
  local meta = {}
  local tname = "pika." .. gname:lower()
  local mt = {}
  for n in pairs(known) do
    local f = impl[n]
    if f then
      -- luaL_checkudata: every method raises when self is not this kind of handle.
      mt[n] = function(o, ...)
        if getmetatable(o) ~= meta then
          error(("bad argument #1 to '%s' (%s expected, got %s)"):format(n, tname, type(o)), 2)
        end
        return f(o, ...)
      end
    else
      mt[n] = function() warn_once("NOT-SIMULATED", gname .. ":" .. n .. " is real but not simulated by smoke") end
    end
  end
  for n in pairs(impl) do
    if not known[n] then error("stub bug: " .. gname .. ":" .. n .. " is not in contract/api.json") end
  end
  meta.__index = function(_, k)
    local f = mt[k]
    if f then return f end
    warn_once("MISSING-API", ("%s object has no field '%s': reads nil on the robot"):format(gname, tostring(k)))
    return nil
  end
  meta.__name = tname
  -- On the robot an unreferenced handle is collected and its object freed.
  meta.__gc = function(o)
    local r = D[o]
    if not r or not r.alive or r.sid ~= SID then return end
    warn_once("HANDLE-GC", ("%s created at %s was garbage-collected while alive: on the robot it disappears; keep a reference (or destroy it)")
      :format(gname, r.site or "?"))
    if on_gc then on_gc(o) end
  end
  if close then
    meta.__close = function(o) local r = D[o]; if r and r.alive and on_gc then on_gc(o) end end
  end
  return meta
end

-- ------------------------------------------------------------------ Sprite
local SPR_MT
local function sprite_free(o)
  local r = D[o]
  r.alive = false; S.sprites[o] = nil; S.sprite_n = S.sprite_n - 1; S.psram = S.psram - r.bytes
end

local function new_sprite(path, w, h, bpp)
  if w > LIM.img_max_w or h > LIM.img_max_h then return nil, "too_big" end
  local o = setmetatable({}, SPR_MT)
  -- flip = recorded flip state (what the engine believes); shown = orientation of
  -- the pixels actually on screen. They differ after set_frame (KI-FLIP-FRAME).
  D[o] = { path = path, w = w, h = h, bytes = w * h * bpp, x = 0, y = 0, pending = true, alive = true,
           fh = false, fv = false, sh = false, sv = false, sid = SID, site = site() }
  S.sprites[o] = true
  S.sprite_n = S.sprite_n + 1
  S.psram = S.psram + D[o].bytes
  if S.sprite_n > S.peak.sprites then S.peak.sprites = S.sprite_n end
  if S.psram > S.peak.psram then S.peak.psram = S.psram end
  return o
end

local function live(o) return D[o].alive end

local function xform(o, what)
  local r = D[o]
  if r.w > LIM.transform_max_px or r.h > LIM.transform_max_px then
    error_once("XFORM", ("%s refused: %s is %dx%d > %d px (returns false on the robot): use art at most %d px per side")
      :format(what, r.path, r.w, r.h, LIM.transform_max_px, LIM.transform_max_px))
    return false
  end
  return true
end

-- A destroyed sprite has a NULL renderer handle: getters read 0, 0 and every
-- call that returns a boolean returns false (lvgl_renderer.c).
SPR_MT = method_table("Sprite", {
  set_pos = function(o, x, y)
    x, y = int_arg(x, "set_pos", 1), int_arg(y, "set_pos", 2)
    if live(o) then D[o].x, D[o].y, D[o].pending = x, y, false end
  end,
  get_pos = function(o) if not live(o) then return 0, 0 end; return D[o].x, D[o].y end,
  get_size = function(o) if not live(o) then return 0, 0 end; return D[o].w, D[o].h end,
  set_visible = function(o) if live(o) then D[o].pending = false end end,
  set_frame = function(o, path, idx)
    path = check_path(path, "set_frame")
    idx = int_arg(idx, "set_frame", 2)
    if not live(o) then return false end
    S.frame_calls = S.frame_calls + 1
    local r = D[o]
    if path:match("%.[pP][nN][gG]$") then
      report("error", "FRAME-FMT", "set_frame reads raw frames, never a PNG: " .. path)
      return false
    end
    if r.bytes ~= r.w * r.h * 2 then
      report("error", "FRAME-FMT", "set_frame on " .. r.path .. ", a PNG sprite with alpha: strips are RGB565 only")
      return false
    end
    local size = H.file_size(path)
    if not size then warn_once("FRAME", "set_frame: " .. path .. " not found"); return false end
    if idx < 0 or (idx + 1) * r.bytes > size then
      warn_once("FRAME", ("set_frame(%s, %d): strip holds %d frame(s) of %d bytes"):format(path, idx, size // r.bytes, r.bytes))
      return false
    end
    if r.fh or r.fv then
      warn_once("KI-FLIP-FRAME", ("set_frame on %s, which is flipped: the frame loads unflipped but the flip stays recorded; ship pre-flipped frames")
        :format(r.path))
    end
    r.sh, r.sv = false, false
    return true
  end,
  set_scale = function(o, v)
    int_arg(v, "set_scale", 1)
    if not live(o) then return false end
    return xform(o, "set_scale")
  end,
  set_rotation = function(o, v)
    int_arg(v, "set_rotation", 1)
    if not live(o) then return false end
    return xform(o, "set_rotation")
  end,
  -- Bounded like Shape coordinates; out of range returns false (bind_sprite.c).
  set_pivot = function(o, x, y)
    x, y = int_arg(x, "set_pivot", 1), int_arg(y, "set_pivot", 2)
    if x < -LIM.img_max_w or x > 2 * LIM.img_max_w or y < -LIM.img_max_h or y > 2 * LIM.img_max_h then return false end
    return live(o)
  end,
  set_flip = function(o, h, v)
    if not live(o) then return false end
    S.frame_calls = S.frame_calls + 1
    local r = D[o]
    h, v = not not h, not not v
    -- The engine rewrites only the axes where the request differs from the recorded state.
    local dh, dv = h ~= r.fh, v ~= r.fv
    if not dh and not dv and (r.sh ~= h or r.sv ~= v) then
      warn_once("KI-FLIP-FRAME", ("set_flip on %s after set_frame is a no-op (same state as recorded): the frame stays unflipped; ship pre-flipped frames")
        :format(r.path))
    end
    if dh then r.sh = not r.sh end
    if dv then r.sv = not r.sv end
    r.fh, r.fv = h, v
    return true
  end,
  set_opacity = function(_, v)
    if num_of(v) == nil then error("bad argument #1 to 'set_opacity' (number expected, got " .. type(v) .. ")", 3) end
  end,
  set_z = function(_, z) int_arg(z, "set_z", 1) end,
  to_front = function() end, to_back = function() end,
  hit_test = function(o, qx, qy)
    qx, qy = int_arg(qx, "hit_test", 1), int_arg(qy, "hit_test", 2)
    local x, y = SPR_MT.__index(o, "get_pos")(o)
    local w, h = SPR_MT.__index(o, "get_size")(o)
    return qx >= x and qx < x + w and qy >= y and qy < y + h
  end,
  intersects = function(o, b)
    if getmetatable(b) ~= SPR_MT then error("bad argument #1 to 'intersects' (pika.sprite expected, got " .. type(b) .. ")", 3) end
    local ax, ay = SPR_MT.__index(o, "get_pos")(o)
    local aw, ah = SPR_MT.__index(o, "get_size")(o)
    local bx, by = SPR_MT.__index(b, "get_pos")(b)
    local bw, bh = SPR_MT.__index(b, "get_size")(b)
    return not (ax + aw <= bx or bx + bw <= ax or ay + ah <= by or by + bh <= ay)
  end,
  destroy = function(o) if D[o].alive then sprite_free(o) end end,
}, sprite_free)

local Sprite = closed("Sprite", {
  image = function(path)
    path = check_path(path, "Sprite.image")
    local w, h, alpha = H.png_size(path)
    if not w then return nil, "image load failed: " .. path end
    -- Same rule as asset_loader.c png_has_alpha: RGB565A8 when the PNG can carry alpha.
    return new_sprite(path, w, h, alpha and 3 or 2)
  end,
  new = function(path, w, h)
    path = check_path(path, "Sprite.new")
    w, h = int_arg(w, "Sprite.new", 2), int_arg(h, "Sprite.new", 3)
    if w <= 0 or h <= 0 then return nil, "load failed: " .. path end   -- asset_loader.c: INVALID_ARG
    local size = H.file_size(path)
    if not size or size < w * h * 2 then return nil, "load failed: " .. path end
    return new_sprite(path, w, h, 2)
  end,
  solid = function(w, h, rgb)
    w, h = int_arg(w, "Sprite.solid", 1), int_arg(h, "Sprite.solid", 2)
    int_arg(rgb, "Sprite.solid", 3)
    if w <= 0 or h <= 0 or w > LIM.img_max_w or h > LIM.img_max_h then error("Sprite.solid: size out of range", 2) end
    return new_sprite("solid", w, h, 2)
  end,
})

-- ------------------------------------------------------------------ Text + fonts
local TXT_MT
local function face_release(t)
  if D[t].face then S.faces[D[t].face] = S.faces[D[t].face] - 1; D[t].face = nil end
end
local function text_free(t)
  D[t].alive = false; face_release(t); S.texts[D[t].slot] = nil; S.text_n = S.text_n - 1
end
-- Arg types are strict (luaL_check*); on a destroyed label set/move/set_color/show
-- are no-ops and align/set_font return nil, msg (bind_engine.c).
TXT_MT = method_table("Text", {
  set = function(t, s) s = str_arg(s, "set", 1); if D[t].alive then D[t].str = s end end,
  move = function(t, x, y) int_arg(x, "move", 1); int_arg(y, "move", 2) end,
  align = function(t, where, dx, dy)
    where = str_arg(where, "align", 1)
    if dx ~= nil then int_arg(dx, "align", 2) end
    if dy ~= nil then int_arg(dy, "align", 3) end
    local ok = { center = 1, top = 1, bottom = 1, left = 1, right = 1, top_left = 1, top_right = 1, bottom_left = 1, bottom_right = 1 }
    if not ok[where] then return nil, "unknown Text align: " .. where end
    if not D[t].alive then return nil, "stale_text" end
  end,
  set_font = function(t, path, size)
    path = str_arg(path, "set_font", 1)
    if size ~= nil then size = int_arg(size, "set_font", 2) end
    if not safe_rel(path) then return nil, "unsafe font path: " .. path end
    size = size or LIM.font_px_default
    if not D[t].alive then return nil, "set_font failed (" .. path .. "): stale label" end
    if not H.file_size(path) then return nil, "set_font failed (" .. path .. "): not found" end
    local key = path .. "@" .. size
    if not S.faces[key] then
      local n, evict = 0, nil
      for k, refs in pairs(S.faces) do n = n + 1; if refs == 0 then evict = k end end
      if n >= LIM.font_slots then
        if not evict then return nil, "set_font failed (" .. path .. "): font cache full" end
        S.faces[evict] = nil
      end
      S.faces[key] = 0
      S.font_seen[key] = true
    end
    face_release(t)
    D[t].face = key; S.faces[key] = S.faces[key] + 1
    local n = 0; for _ in pairs(S.faces) do n = n + 1 end
    if n > S.peak.fonts then S.peak.fonts = n end
  end,
  set_color = function(_, rgb) int_arg(rgb, "set_color", 1) end,
  show = function() end,
  destroy = function(t) if D[t].alive then text_free(t) end end,
}, text_free, true)
local Text = closed("Text", {
  new = function(str, x, y)
    str = str_arg(str, "Text.new", 1)
    int_arg(x, "Text.new", 2); int_arg(y, "Text.new", 3)
    for slot = 1, LIM.text_slots do
      if not S.texts[slot] then
        local t = setmetatable({}, TXT_MT)
        D[t] = { slot = slot, str = tostring(str), alive = true, sid = SID, site = site() }
        S.texts[slot] = true; S.text_n = S.text_n + 1
        if S.text_n > S.peak.texts then S.peak.texts = S.text_n end
        return t
      end
    end
    error_once("TEXT", ("Text.new #%d at %s: pool_full (returns nil on the robot): reuse labels with :set, at most %d live")
      :format(LIM.text_slots + 1, site(), LIM.text_slots))
    return nil, "pool_full"
  end,
})

-- ------------------------------------------------------------------ Shape, Anim
-- Shape: bind_engine.c (arg checks) + lvgl_renderer.c line_rebuild (bbox, budget).
local LINE_PAD, LINE_BPP = 4, 3

local function shape_coord(v, fname, i, panel)
  v = int_arg(v, fname, i)
  if v < -panel or v > 2 * panel then error(("bad argument #%d to '%s' (coordinate out of range)"):format(i, fname), 4) end
  return v
end

local function shape_points(fname, base, x1, y1, x2, y2)
  return shape_coord(x1, fname, base, LIM.img_max_w), shape_coord(y1, fname, base + 1, LIM.img_max_h),
         shape_coord(x2, fname, base + 2, LIM.img_max_w), shape_coord(y2, fname, base + 3, LIM.img_max_h)
end

-- A malformed field raises; width is clamped. Omitted fields take the defaults.
local function shape_style(st, fname, i)
  local s = { width = 2, color = 0xFFFFFF, dash_on = 0, dash_off = 0, cap = "butt" }
  if st == nil then return s end
  if type(st) ~= "table" then error(("bad argument #%d to '%s' (table expected, got %s)"):format(i, fname, type(st)), 3) end
  if st.width ~= nil then
    local w = int_arg(st.width, fname, i)
    s.width = math.max(1, math.min(LIM.line_width_max, w))
  end
  if st.color ~= nil then s.color = int_arg(st.color, fname, i) end
  if st.dash ~= nil then
    local d = st.dash
    if type(d) ~= "table" then error(("bad argument #%d to '%s' (dash must be a table {on, off})"):format(i, fname), 3) end
    if rawlen(d) ~= 2 then error(("bad argument #%d to '%s' (dash must hold exactly two numbers {on, off})"):format(i, fname), 3) end
    local on, off = int_arg(rawget(d, 1), fname, i), int_arg(rawget(d, 2), fname, i)
    if on < 0 or on > LIM.img_max_w or off < 0 or off > LIM.img_max_w then
      error(("bad argument #%d to '%s' (dash value out of range)"):format(i, fname), 3)
    end
    s.dash_on, s.dash_off = on, off
  end
  if st.cap ~= nil then
    local c = str_arg(st.cap, fname, i)
    if c ~= "butt" and c ~= "round" then
      error(("bad argument #%d to '%s' (cap must be \"butt\" or \"round\")"):format(i, fname), 3)
    end
    s.cap = c
  end
  return s
end

-- Raster bytes of a line, or nil, reason when it cannot be built.
local function shape_bytes(r, x1, y1, x2, y2, width)
  local pad = LINE_PAD + (width + 1) // 2
  local w = math.abs(x2 - x1) + 2 * pad
  local h = math.abs(y2 - y1) + 2 * pad
  if w > LIM.img_max_w or h > LIM.img_max_h then return nil, "bbox_too_large" end
  local want = w * h * LINE_BPP
  if S.line_bytes - (r and r.bytes or 0) + want > LIM.line_pool_max_bytes then return nil, "no_mem" end
  return want
end

local function shape_free(s)
  local r = D[s]
  r.alive = false; S.shapes = S.shapes - 1; S.line_bytes = S.line_bytes - r.bytes
end

local SHP_MT = method_table("Shape", {
  set_points = function(s, x1, y1, x2, y2)
    x1, y1, x2, y2 = shape_points("set_points", 1, x1, y1, x2, y2)
    local r = D[s]
    if not r.alive then return end
    local bytes, why = shape_bytes(r, x1, y1, x2, y2, r.style.width)
    if not bytes then return nil, why end
    S.line_bytes = S.line_bytes - r.bytes + bytes
    r.bytes, r.pts = bytes, { x1, y1, x2, y2 }
  end,
  set_style = function(s, st)
    if st == nil then error("bad argument #1 to 'set_style' (table expected, got nil)", 3) end
    st = shape_style(st, "set_style", 1)
    local r = D[s]
    if not r.alive then return end
    local p = r.pts
    local bytes, why = shape_bytes(r, p[1], p[2], p[3], p[4], st.width)
    if not bytes then return nil, why end
    S.line_bytes = S.line_bytes - r.bytes + bytes
    r.bytes, r.style = bytes, st
  end,
  set_opacity = function(_, v) int_arg(v, "set_opacity", 1) end,
  set_z = function(_, z) int_arg(z, "set_z", 1) end,
  set_visible = function() end,
  destroy = function(s) if D[s].alive then shape_free(s) end end,
}, shape_free, true)

local Shape = closed("Shape", {
  line = function(x1, y1, x2, y2, st)
    x1, y1, x2, y2 = shape_points("Shape.line", 1, x1, y1, x2, y2)
    st = shape_style(st, "Shape.line", 5)
    if S.shapes >= LIM.line_slots then return nil, "pool_full" end
    local bytes, why = shape_bytes(nil, x1, y1, x2, y2, st.width)
    if not bytes then return nil, why end
    S.shapes = S.shapes + 1
    S.line_bytes = S.line_bytes + bytes
    local o = setmetatable({}, SHP_MT)
    D[o] = { alive = true, sid = SID, site = site(), bytes = bytes, pts = { x1, y1, x2, y2 }, style = st }
    return o
  end,
})

-- Mirrors anim.c: one active Anim; play() stops (and rewinds) the other one and
-- rewinds itself only if it had ended; a one-shot ends after one pass.
local function anim_stop(r)
  r.playing, r.ended, r.pos = false, true, 0
  if S.anim == r then S.anim = nil end
end
local function anim_free(a)
  local r = D[a]
  r.alive = false
  if S.anim == r then S.anim = nil end
end
local ANM_MT = method_table("Anim", {
  play = function(a, opt)
    local r = D[a]
    if not r.alive then return false end
    if S.anim and S.anim ~= r then anim_stop(S.anim) end
    if r.ended then r.pos = 0 end
    -- Only a boolean or {loop = ...} is read: play(1) is a one-shot (bind_anim.c).
    if type(opt) == "table" then r.loop = not not opt.loop
    elseif type(opt) == "boolean" then r.loop = opt
    else r.loop = false end
    r.ended, r.playing = false, true
    S.anim = r
    return true
  end,
  pause = function(a) D[a].playing = false end,
  resume = function(a)
    local r = D[a]
    if not r.alive or r.ended then return end
    if S.anim and S.anim ~= r then anim_stop(S.anim) end
    r.playing = true; S.anim = r
  end,
  stop = function(a) if D[a].alive then anim_stop(D[a]) end end,
  is_playing = function(a) return D[a].alive and D[a].playing end,
  set_pos = function(_, x, y) int_arg(x, "set_pos", 1); int_arg(y, "set_pos", 2) end,
  set_visible = function() end,
  destroy = function(a) if D[a].alive then anim_free(a) end end,
}, anim_free)
local Anim = closed("Anim", {
  new = function(path)
    -- Extension first, then the sandbox path; both raise (bind_anim.c).
    path = str_arg(path, "Anim.new", 1)
    local lower = path:lower()
    if not lower:match("%.gif$") and not lower:match("%.mjpeg$") and not lower:match("%.mjpg$") then
      error("unknown anim type (want .gif/.mjpeg): " .. path, 2)
    end
    if not safe_rel(path) then error("unsafe anim path: " .. path, 2) end
    local size = H.file_size(path)
    if not size then return nil, "anim load failed: " .. path end
    if size > LIM.anim_max_file_bytes then return nil, "anim load failed: " .. path end
    -- The codec opens the file: a .gif that is not a GIF fails here (anim.c).
    if not H.anim_ok(path) then return nil, "anim load failed: " .. path end
    local o = setmetatable({}, ANM_MT)
    D[o] = { path = path, alive = true, playing = false, ended = false, loop = false, pos = 0,
             dur = H.anim_ms(path), sid = SID, site = site() }
    return o
  end,
})

-- ------------------------------------------------------------------ Speaker
local sounds = (MAN.audio or {}).sounds or {}
local Speaker = closed("Speaker", {
  REASON_COMPLETED = 0, REASON_STOPPED = 1, REASON_PREEMPTED = 2, REASON_ERROR = 3,
  play = function(alias)
    local def = sounds[alias]
    if not def then warn_once("SOUND", "Speaker.play('" .. tostring(alias) .. "'): alias not in manifest"); return false end
    if def.remote == true and not S.urls[alias] then
      warn_once("SOUND", "Speaker.play('" .. alias .. "'): remote alias has no URL yet (returns false): call Speaker.set_url first")
      return false
    end
    if S.now - S.last_play < LIM.sound_cooldown_ms then
      report("warn", "COOLDOWN", ("Speaker.play('%s') at %d ms refused: inside %d ms cooldown"):format(alias, S.now, LIM.sound_cooldown_ms))
      S.snd.cooldown = S.snd.cooldown + 1
      return false
    end
    S.last_play = S.now
    S.snd.played = S.snd.played + 1
    if S.cur then S.events[#S.events + 1] = { "sound_end", S.cur.alias, 2 } end
    S.cur = { alias = alias, len = def.path and H.sound_ms(def.path) or 1000, loop = def.loop == true }
    S.cur.ends = S.now + S.cur.len
    S.played[alias] = (S.played[alias] or 0) + 1
    return true
  end,
  -- REASON_STOPPED is queued and delivered at the start of the next frame (sound.c).
  stop = function(alias)
    if not (S.cur and S.cur.alias == alias) then return false end
    S.events[#S.events + 1] = { "sound_end", alias, 1 }; S.cur = nil
    return true
  end,
  stop_all = function()
    if S.cur then S.events[#S.events + 1] = { "sound_end", S.cur.alias, 1 }; S.cur = nil end
    return true
  end,
  is_playing = function(alias) return S.cur ~= nil and S.cur.alias == alias end,
  is_busy = function() return S.cur ~= nil end,
  -- Clamped 0..100 and rounded; a non-number is a no-op (bind_speaker.c).
  set_volume = function(v)
    local n = num_of(v)
    if n == nil then return end
    S.volume = n >= 100 and 100 or (n <= 0 and 0 or math.floor(n + 0.5))
  end,
  get_volume = function() return S.volume end,
  set_url = function(alias, url)
    local def = sounds[alias]
    if not def or not (def.remote == true or type(def.url) == "string") then return false end
    if type(url) ~= "string" or not (url:match("^http://") or url:match("^https://"))
       or url:find("[^\33-\126]") or #url > LIM.sound_url_len_max - 1 then
      return false
    end
    S.urls[alias] = url
    return true
  end,
  -- Nothing is decoded on the PC: error, drop, hookup and abandon counters stay 0.
  stats = function()
    return { played_total = S.snd.played, finish_dropped = 0, error_count = 0, cooldown_reject = S.snd.cooldown,
             no_hookup = 0, speaker_abandoned_current = 0, speaker_abandoned_peak = 0 }
  end,
})

-- ------------------------------------------------------------------ Input
local actions, by_button = {}, {}
local man_actions = (MAN.input or {}).actions
if type(man_actions) ~= "table" then
  -- Same defaults as the engine (input.c seed_defaults).
  man_actions = { confirm = { "button:enter" }, left = { "button:left" }, right = { "button:right" } }
end
for name, srcs in pairs(man_actions) do
  actions[name] = true
  for _, s in ipairs(srcs) do by_button[s] = by_button[s] or name end
end
local function act_arg(a, fname)
  if a == nil then error("bad argument #1 to '" .. fname .. "' (action expected)", 3) end
  if not actions[a] then warn_once("ACTION", fname .. "('" .. tostring(a) .. "'): action not in manifest.input.actions") end
  return a
end
local Input = closed("Input", {
  PRESS = 0, RELEASE = 1, REPEAT = 2,
  is_down = function(a) return S.down[act_arg(a, "Input.is_down")] ~= nil end,
  just_pressed = function(a) return S.just[act_arg(a, "Input.just_pressed")] == 0 end,
  just_released = function(a) return S.just[act_arg(a, "Input.just_released")] == 1 end,
  -- The robot reports the hold carried by the last event: 0 after PRESS until the first
  -- REPEAT, and the release value after RELEASE (input.c apply_input_event).
  hold_ms = function(a) return S.hold[act_arg(a, "Input.hold_ms")] or 0 end,
  actions = function() local l = {}; for n in pairs(actions) do l[#l + 1] = n end; table.sort(l); return l end,
  stats = function() return { events_total = 0, events_delta = 0, dropped_total = 0, seq_gaps = 0 } end,
})

-- ------------------------------------------------------------------ the rest
-- Led: bind_led.c + led_pump.c. Bad arguments return false, never raise.
-- Commands queue in an 8-slot ring drained after every frame; a set() merges
-- into a set() still waiting in the ring.
local LED_RING = 8
local function led_push(op)
  local L = S.led
  L.pushed = L.pushed + 1
  if op == "rgb" and L.rgb_pos then L.coalesced = L.coalesced + 1; return true end
  if #L.q >= LED_RING then L.dropped = L.dropped + 1; return false end
  L.q[#L.q + 1] = op
  if op == "rgb" then L.rgb_pos = #L.q end
  return true
end
local function led_nums(...)
  for i = 1, select("#", ...) do if num_of((select(i, ...))) == nil then return false end end
  return true
end
local LED_PRESETS = { user_talk = 1, conv_processing = 1, robot_talking = 1, warm_white = 1, light_blue = 1, dark_blue = 1 }
local Led = closed("Led", {
  set = function(r, g, b) if not led_nums(r, g, b) then return false end; return led_push("rgb") end,
  off = function() return led_push("off") end,
  preset = function(n)
    if type(n) ~= "string" or not LED_PRESETS[n] then warn_once("LED", "Led.preset('" .. tostring(n) .. "'): unknown preset"); return false end
    return led_push("preset")
  end,
  blink = function(r, g, b, p)
    if not led_nums(r, g, b, p) then return false end
    p = num_of(p)
    if p < LIM.led_blink_min_ms or p > LIM.led_blink_max_ms then report("error", "LED", "Led.blink period " .. tostring(p) .. " ms rejected"); return false end
    return led_push("blink")
  end,
  pulse = function(r, g, b, d)
    if not led_nums(r, g, b, d) then return false end
    d = num_of(d)
    if d < LIM.led_pulse_min_ms or d > LIM.led_pulse_max_ms then report("error", "LED", "Led.pulse duration " .. tostring(d) .. " ms rejected"); return false end
    return led_push("pulse")
  end,
  -- 0..100, rejected outside (not clamped), rounded; the mirror moves only on a queued push.
  set_brightness = function(p)
    local n = num_of(p)
    if n == nil or n ~= n or n < 0 or n > 100 then return false end
    if not led_push("bright") then return false end
    S.led.bright = math.floor(n + 0.5)
    return true
  end,
  get_brightness = function() return S.led.bright end,
  is_available = function() return S.phase == "run" end,
  stats = function()
    local L = S.led
    return { pushed_total = L.pushed, coalesced_total = L.coalesced, dropped_total = L.dropped,
             sent_total = L.sent, send_fail_total = 0, brightness_pct = L.bright }
  end,
})

-- Servo: bind_servo.c + servo.c. Bad arguments return false, never raise. A
-- 32-slot ring drained after every frame; a plain move merges into the move
-- still waiting for the same joint. is_busy is a prediction stamped at push.
-- Back-side rejects (duty limit, validation) need the body board: always 0 here.
local SERVO_RING = 32
local SERVO_JOINTS = { "head", "base", "left", "right" }
local servos, poses = MAN.servos or {}, MAN.poses or {}
local function servo_joint(alias)
  if type(alias) ~= "string" then return nil end
  local v = servos[alias]
  if v == nil then return nil end
  -- The manifest maps an alias to a joint; "body" drives the base (servo.c).
  local j = type(v) == "table" and (v.servo or v.joint or v.hw) or v
  if j == "body" then j = "base" end
  return j
end
local function servo_push(joint, kind, dur)
  local V = S.servo
  V.pushed = V.pushed + 1
  if kind == "move" and V.pending[joint] then
    V.coalesced = V.coalesced + 1
    V.busy_until[joint] = S.now + dur
    return true
  end
  if #V.q >= SERVO_RING then V.dropped = V.dropped + 1; return false end
  V.q[#V.q + 1] = kind
  if kind == "move" then V.pending[joint] = true end
  V.busy_until[joint] = S.now + dur
  return true
end
local SERVO_EASING = { linear = true, in_out = true, bounce = true }
local Servo = closed("Servo", {
  pose = function(a)
    if type(a) ~= "string" or not poses[a] then warn_once("SERVO", "Servo.pose('" .. tostring(a) .. "'): pose not in manifest"); return false end
    for _, j in ipairs(SERVO_JOINTS) do S.servo.busy_until[j] = S.now + LIM.servo_pose_busy_ms end
    return servo_push("head", "pose", LIM.servo_pose_busy_ms)
  end,
  move = function(a, angle, dur, easing)
    local j = servo_joint(a)
    if not j then warn_once("SERVO", "Servo.move('" .. tostring(a) .. "'): servo not in manifest"); return false end
    if num_of(angle) == nil or num_of(dur) == nil then return false end
    if easing ~= nil and (type(easing) ~= "string" or not SERVO_EASING[easing]) then return false end
    local d = num_of(dur)
    d = d > 65535 and 65535 or (d < 0 and 0 or math.floor(d))
    return servo_push(j, "move", d)
  end,
  stop = function(a)
    if a == nil then
      local ok = true
      for _, j in ipairs(SERVO_JOINTS) do ok = servo_push(j, "stop", 0) and ok end
      return ok
    end
    local j = servo_joint(a)
    if not j then return false end
    return servo_push(j, "stop", 0)
  end,
  is_busy = function(a)
    local j = servo_joint(a)
    return j ~= nil and S.now < (S.servo.busy_until[j] or 0)
  end,
  stats = function()
    local V = S.servo
    return { pushed_total = V.pushed, coalesced_total = V.coalesced, dropped_total = V.dropped,
             sent_total = V.sent, send_fail_total = 0, back_reject_throttle = 0, back_reject_validation = 0,
             back_reject_priority = 0, back_reject_queue_full = 0, last_reject_ms = 0, drain_max_us = 0 }
  end,
  -- alias -> joint name and alias -> gesture name, as the engine reports them.
  list = function()
    local sv, ps = {}, {}
    for alias in pairs(servos) do sv[alias] = servo_joint(alias) end
    for alias, g in pairs(poses) do ps[alias] = type(g) == "table" and (g.gesture or g.pose) or g end
    return { servos = sv, poses = ps }
  end,
})
-- Voice follows the body board (game_voice.cpp): the session exists only after
-- game_start returns; set_keywords sends the list and starts listening; a second
-- set_keywords while active is refused with error/busy; Voice.start only reports
-- no_keywords when idle. Refusals arrive as on_voice_event next frame.
local function voice_event(code, message)
  S.voice_q[#S.voice_q + 1] = { type = "error", code = code, message = message }
end
local function voice_early(fname)
  if S.phase == "run" then return false end
  error_once("VOICE-EARLY", ("%s at %s during %s: dropped on the robot: the voice session starts after game_start returns; send keywords from on_tick")
    :format(fname, site(), S.phase == "load" and "the top-level chunk" or "game_start"))
  return true
end
local Voice = closed("Voice", {
  -- Mirrors bind_voice.c: pure array, count cap, then the exact wire JSON
  -- {"type":"game_command_keywords","keywords":[...],"sensitivity":n} against the byte cap.
  set_keywords = function(list, sens)
    if type(list) ~= "table" then error("bad argument #1 to 'set_keywords' (table expected)", 2) end
    if sens ~= nil and type(sens) ~= "number" then error("bad argument #2 to 'set_keywords' (number expected)", 2) end
    local n, cnt = #list, 0
    for _ in pairs(list) do cnt = cnt + 1 end
    if cnt ~= n or n == 0 then return nil, "keywords_not_array" end
    if n > LIM.voice_keywords_max then return nil, "too_many_keywords" end
    local len = #'{"type":"game_command_keywords","keywords":[]}' + math.max(n - 1, 0)
    for i = 1, n do
      local k = list[i]
      if type(k) ~= "string" then return nil, "encode_failed" end
      len = len + #k + 2 + select(2, k:gsub('[%c"\\]', ""))   -- escaped chars cost one byte more
    end
    if sens ~= nil then len = len + #(',"sensitivity":' .. tostring(math.tointeger(sens) or sens)) end
    if len + 1 > LIM.voice_start_json_max_bytes then return nil, "payload_too_big" end
    if voice_early("Voice.set_keywords") then return true end
    if S.voice ~= "idle" then
      voice_event("busy", "game_voice already active")
      return true
    end
    S.keywords = list; S.voice = "listening"
    return true
  end,
  start = function()
    if voice_early("Voice.start") then return true end
    if S.voice == "idle" then voice_event("no_keywords", "Voice.set_keywords must precede Voice.start") end
    return true
  end,
  stop = function() S.voice = "idle"; return true end,
  is_available = function() return S.phase == "run" end,
})
local Ranking = closed("Ranking", {
  -- score: a number or a numeric string (bind_ranking.c lua_isnumber).
  report = function(t) if type(t) ~= "table" or num_of(t.score) == nil then return false end; return true end,
  get_result = function() return nil end,
})
local Engine = closed("Engine", {
  exit = function(reason)
    if reason ~= nil then reason = str_arg(reason, "exit", 1) end
    S.exit = reason or "lua"
  end,
  -- A non-table raises; event is a string (or number) of 1..255 bytes (bind_engine.c).
  report_result = function(t)
    if type(t) ~= "table" then error("bad argument #1 to 'report_result' (table expected, got " .. type(t) .. ")", 2) end
    local ev = t.event
    if type(ev) == "number" then ev = tostring(ev) end
    if type(ev) ~= "string" or #ev == 0 or #ev > LIM.report_event_max_len - 1 then return nil, "bad_event" end
    return true
  end,
  -- engine_core.c engine_show_request: hold only before the screen is up, release once.
  show = function(visible)
    local V = S.show
    if visible ~= nil and not visible then
      if V.entered or V.held then return false end
      V.held = true
      return true
    end
    if not V.held or V.requested then return false end
    V.requested = true
    return true
  end,
})
local Timer = closed("Timer", { millis = function() return S.now end })
-- Pack data store: no body board on the PC, so nothing is ever published.
local Pack = closed("Pack", {
  data = function(key)
    if type(key) ~= "string" then error("bad argument #1 to 'data' (string expected)", 2) end
    return nil
  end,
})

-- Telemetry.event: the rules of core/game_tel.c, checked against the same
-- contract/telemetry_vectors.json (tools/check_telemetry.py). No JSON is built;
-- S.tel.last says what the robot would do: "sent", "held" or the reject reason.
local TEL_RESERVED = { id = true, trigger = true, t_ms = true, pv = true, ev = true,
  key = true, level = true, data = true }
local TEL_LEVELS = { info = true, warn = true, error = true }

local function tel_state()
  if not S.tel then
    S.tel = { ts = {}, sent = 0, dropped = 0, pending = 0, opt_unknown = 0, closed = false, last = nil }
  end
  return S.tel
end

local function tel_round(v)   -- C round(): half away from zero
  if v >= 0 then return math.floor(v + 0.5) end
  return math.ceil(v - 0.5)
end

-- First error wins, in the robot's order: name, then opts, then fields.
local function tel_check(name, fields, opts)
  if type(name) ~= "string" or #name == 0 or #name > LIM.tel_name_max or not name:match("^[a-z0-9_.]+$")
     or name:sub(1, 7) == "engine." or name:sub(1, 4) == "sys." then
    return "name"
  end
  local unknown = false
  if opts ~= nil then
    if type(opts) ~= "table" then return "opt_value" end
    for k, v in next, opts do
      if k == "key" then
        if type(v) ~= "string" then return "opt_value" end
        if #v == 0 or #v > LIM.tel_key_max or not v:match("^[a-z0-9_.]+$") or v:sub(1, 1) == "." or v:sub(-1) == "." then
          return "key"
        end
      elseif k == "level" then
        if type(v) ~= "string" or not TEL_LEVELS[v] then return "opt_value" end
      else
        unknown = true
      end
    end
  end
  if fields ~= nil then
    if type(fields) ~= "table" then return "bad_type" end
    local n, bytes, seen = 0, 0, {}
    for k, v in next, fields do
      if type(k) ~= "string" then return "field_name" end
      n = n + 1
      if n > LIM.tel_fields_max then return "too_many" end
      if #k == 0 or #k > LIM.tel_field_name_max or not k:match("^[a-z0-9_]+$") or TEL_RESERVED[k] or seen[k] then
        return "field_name"
      end
      seen[k] = true
      local enc
      local tv = type(v)
      if tv == "number" then
        local iv = v
        if math.type(v) ~= "integer" then
          if v ~= v or v == math.huge or v == -math.huge then return "bad_type" end
          iv = tel_round(v)
        end
        if iv < -2147483648 or iv > 2147483647 then return "bad_type" end
        enc = #tostring(math.tointeger(iv))
      elseif tv == "boolean" then
        enc = 1
      elseif tv == "string" then
        if #v > LIM.tel_str_max then return "str_long" end
        enc = #v + 2
      else
        return "bad_type"
      end
      bytes = bytes + #k + 4 + enc            -- ,"k":<value>
      if bytes > LIM.tel_fields_max_bytes then return "too_big" end
    end
  end
  return nil, unknown
end

local function tel_reject(T, name, why)
  T.last = why
  if why ~= "closed" then
    T.dropped = T.dropped + 1
    warn_once("TELEMETRY", ("Telemetry.event rejected (%s), e.g. ev=%s: returns false on the robot")
      :format(why, tostring(name)))
  end
  return false
end

local Telemetry = closed("Telemetry", {
  event = function(name, fields, opts)
    local T = tel_state()
    if T.closed then return tel_reject(T, name, "closed") end
    local why, unknown = tel_check(name, fields, opts)
    if why then return tel_reject(T, name, why) end
    local held = S.phase ~= "run"           -- top level and game_start: before game.start
    if held and T.pending >= LIM.tel_rate_max then return tel_reject(T, name, "pending") end
    local ts = T.ts
    -- & 0xffffffff: the robot's clock is a uint32 of milliseconds and wraps.
    if #ts >= LIM.tel_rate_max and ((S.now - ts[#ts - LIM.tel_rate_max + 1]) & 0xffffffff) < LIM.tel_rate_window_ms then
      return tel_reject(T, name, "rate")
    end
    ts[#ts + 1] = S.now
    if unknown then
      T.opt_unknown = T.opt_unknown + 1
      warn_once("TELEMETRY-OPT", "Telemetry.event opts has a key this engine does not know: ignored, event sent")
    end
    if held then T.pending = T.pending + 1; T.last = "held"
    else T.sent = T.sent + 1; T.last = "sent" end
    return true
  end,
  caps = function()
    return { rate_max = LIM.tel_rate_max, rate_window_ms = LIM.tel_rate_window_ms,
      name_max = LIM.tel_name_max, key_max = LIM.tel_key_max, fields_max = LIM.tel_fields_max,
      field_name_max = LIM.tel_field_name_max, str_max = LIM.tel_str_max,
      fields_max_bytes = LIM.tel_fields_max_bytes, opts = { key = true, level = true } }
  end,
})

-- game.start: held events go out (counted as sent).
local function tel_started()
  local T = tel_state()
  if T.closed then return end
  T.sent = T.sent + T.pending
  T.pending = 0
end

-- ------------------------------------------------------------------ sandbox + require
local ALLOWED_BASE = { "assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawlen",
  "rawset", "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type", "xpcall",
  "collectgarbage", "warn", "_VERSION" }

local function make_env()
  local env = {}
  for _, n in ipairs(ALLOWED_BASE) do env[n] = _G[n] end
  env.table, env.string, env.math, env.utf8 = table, string, math, utf8
  env.print = function(...) local p = {}; for i = 1, select("#", ...) do p[i] = tostring(select(i, ...)) end; H.print(table.concat(p, "\t")) end
  env.pika = {}
  env.Sprite, env.Text, env.Shape, env.Anim, env.Speaker, env.Input = Sprite, Text, Shape, Anim, Speaker, Input
  env.Led, env.Servo, env.Voice, env.Ranking, env.Engine, env.Timer = Led, Servo, Voice, Ranking, Engine, Timer
  env.Pack = Pack
  env.Telemetry = Telemetry
  env._G = env
  local cache = {}
  env.require = function(name)
    if type(name) ~= "string" or name:sub(1, 5) ~= "libs/" then error("require: only libs/<module> allowed, got: " .. tostring(name), 2) end
    if not safe_rel(name) then error("require: unsafe module path: " .. name, 2) end
    if cache[name] ~= nil then return cache[name] end
    local src = H.read(name .. ".lua")
    if not src then error("require: cannot load '" .. name .. "': not found", 2) end
    local chunk, err = load(src, "@" .. name .. ".lua", "t", env)
    if not chunk then error("require: cannot load '" .. name .. "': " .. err, 2) end
    local r = chunk()
    cache[name] = r == nil and true or r
    return cache[name]
  end
  return env
end

-- ------------------------------------------------------------------ session driver (called by smoke.py)
local M = {}
local GC_EVERY_TICKS = 30        -- collect often enough that a dropped handle shows up within a second
local FRAME_HOOKS = { on_tick = true, on_input = true }

function M.new_session(entry_src, entry_name)
  SID = SID + 1
  -- Handles are weak here so an unreferenced one can be collected (HANDLE-GC).
  S = { tick = 0, now = 0, sprites = setmetatable({}, { __mode = "k" }), sprite_n = 0, psram = 0, texts = {}, text_n = 0,
        faces = {}, font_seen = S.font_seen or {}, shapes = 0, line_bytes = 0, anim = nil, cur = nil, last_play = -1000000,
        volume = 80, snd = { played = 0, cooldown = 0 },
        led = { pushed = 0, coalesced = 0, dropped = 0, sent = 0, q = {}, rgb_pos = nil, bright = 100 },
        servo = { pushed = 0, coalesced = 0, dropped = 0, sent = 0, q = {}, pending = {}, busy_until = {} },
        show = { held = false, requested = false, entered = false },
        urls = {}, events = {}, down = {}, just = {}, hold = {}, played = S.played or {}, frame_calls = 0, exit = nil,
        phase = "load", voice = "idle", voice_q = {}, bound = {},
        peak = S.peak or { sprites = 0, texts = 0, psram = 0, fonts = 0 } }
  S.env = make_env()
  local chunk, err = load(entry_src, "@" .. entry_name, "t", S.env)
  if not chunk then return false, err end
  local ok, e = pcall(chunk)
  if not ok then return false, e end
  -- lua_vm_bind_frame_hooks: on_tick/on_input are resolved once, here.
  for n in pairs(FRAME_HOOKS) do S.bound[n] = rawget(S.env, n) end
  S.phase = "start"
  return true, nil
end

function M.hook(name, ...)
  local f
  if FRAME_HOOKS[name] then
    f = S.bound[name]
    if rawget(S.env, name) ~= f then
      error_once("HOOK-REBIND", ("%s was reassigned after load: robot keeps calling the function defined at load; switch on state inside one %s")
        :format(name, name))
    end
  else
    f = rawget(S.env, name)
  end
  -- The robot closes telemetry before game.stop; game_end runs after it.
  if name == "game_end" then tel_state().closed = true end
  if type(f) ~= "function" then
    if name == "game_start" then S.phase = "run"; S.show.entered = true; tel_started() end
    return true, nil, false
  end
  local ok, r = xpcall(f, debug.traceback, ...)
  if name == "game_start" then
    S.phase = "run"
    if not S.show.held then S.show.entered = true end
    -- A raising game_start fails the launch: no game.start, held events dropped.
    if ok then tel_started() else tel_state().pending = 0; tel_state().closed = true end
  end
  return ok, r, true
end

-- Telemetry state for tools/check_telemetry.py (vectors).
function M.tel() return tel_state() end
function M.tel_abort() local T = tel_state(); T.pending = 0; T.closed = true end

function M.has(name) return type(rawget(S.env, name)) == "function" end
function M.state() return S end
function M.button_action(hw) return by_button[hw] end
function M.voice_listening() return S.voice == "listening" end

function M.press(action, down, hold)
  if down then S.down[action] = S.now; S.just[action] = 0 else S.down[action] = nil; S.just[action] = 1 end
  S.hold[action] = hold or 0
end

function M.repeat_event(action, hold) S.hold[action] = hold end

function M.pop_events()
  local c = S.cur
  if c and S.now >= c.ends then
    if c.loop then
      -- A loop restarts on completion without REASON_COMPLETED; the restart counts as a play.
      c.ends = S.now + c.len; S.last_play = S.now
      S.played[c.alias] = (S.played[c.alias] or 0) + 1
      S.snd.played = S.snd.played + 1
    else
      S.events[#S.events + 1] = { "sound_end", c.alias, 0 }; S.cur = nil
    end
  end
  local ev = S.events; S.events = {}
  return ev
end

function M.pop_voice()
  local q = S.voice_q; S.voice_q = {}
  return q
end

function M.advance(ms)
  -- After the frame the engine sends what the LED and servo rings hold.
  local L, V = S.led, S.servo
  L.sent = L.sent + #L.q; L.q = {}; L.rgb_pos = nil
  V.sent = V.sent + #V.q; V.q = {}; V.pending = {}
  if S.show.requested then S.show.entered = true end
  S.now = S.now + ms; S.tick = S.tick + 1
  local a = S.anim
  if a and a.playing and a.dur then
    a.pos = a.pos + ms
    if a.pos >= a.dur then
      if a.loop then a.pos = a.pos % a.dur
      else a.playing, a.ended = false, true; S.anim = nil end
    end
  end
  if S.tick % GC_EVERY_TICKS == 0 then collectgarbage() end
end
function M.clear_just() S.just = {} end

function M.finish_report()
  collectgarbage()
  for o in pairs(S.sprites) do
    if D[o].pending then warn_once("HIDDEN", D[o].path .. " created but never set_pos/set_visible: invisible on the robot") end
  end
end

return M
