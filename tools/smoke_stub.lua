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
--   HOST.anim_ms(rel) -> ms | nil       one pass of a GIF (nil: unknown, never ends)
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

local function check_path(p, fname)
  if type(p) ~= "string" then error(("bad argument #1 to '%s' (string expected)"):format(fname), 3) end
  if not safe_rel(p) then error(("unsafe path: %s"):format(p), 3) end
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

local function method_table(gname, impl, on_gc)
  local known = {}
  for _, n in ipairs((API.globals[gname] or {}).methods or {}) do known[n] = true end
  local mt = {}
  for n in pairs(known) do
    mt[n] = impl[n] or function() warn_once("NOT-SIMULATED", gname .. ":" .. n .. " is real but not simulated by smoke") end
  end
  for n in pairs(impl) do
    if not known[n] then error("stub bug: " .. gname .. ":" .. n .. " is not in contract/api.json") end
  end
  return {
    __index = function(_, k)
      local f = mt[k]
      if f then return f end
      warn_once("MISSING-API", ("%s object has no field '%s': reads nil on the robot"):format(gname, tostring(k)))
      return nil
    end,
    __name = "pika." .. gname:lower(),
    -- On the robot an unreferenced handle is collected and its object freed.
    __gc = function(o)
      local r = D[o]
      if not r or not r.alive or r.sid ~= SID then return end
      warn_once("HANDLE-GC", ("%s created at %s was garbage-collected while alive: on the robot it disappears; keep a reference (or destroy it)")
        :format(gname, r.site or "?"))
      if on_gc then on_gc(o) end
    end,
  }
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

SPR_MT = method_table("Sprite", {
  set_pos = function(o, x, y)
    x, y = int_arg(x, "set_pos", 1), int_arg(y, "set_pos", 2)
    if live(o) then D[o].x, D[o].y, D[o].pending = x, y, false end
  end,
  get_pos = function(o) return D[o].x, D[o].y end,
  get_size = function(o) return D[o].w, D[o].h end,
  set_visible = function(o) if live(o) then D[o].pending = false end end,
  set_frame = function(o, path, idx)
    check_path(path, "set_frame")
    idx = int_arg(idx, "set_frame", 2)
    S.frame_calls = S.frame_calls + 1
    local r = D[o]
    if path:match("%.[pP][nN][gG]$") then
      report("error", "FRAME-FMT", "set_frame reads raw frames, never a PNG: " .. path)
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
  set_scale = function(o) return xform(o, "set_scale") end,
  set_rotation = function(o) return xform(o, "set_rotation") end,
  set_pivot = function() return true end,
  set_flip = function(o, h, v)
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
  set_opacity = function() end, set_z = function() end, to_front = function() end, to_back = function() end,
  hit_test = function(o, qx, qy) return qx >= D[o].x and qx < D[o].x + D[o].w and qy >= D[o].y and qy < D[o].y + D[o].h end,
  intersects = function(o, b) return D[o].x < D[b].x + D[b].w and D[b].x < D[o].x + D[o].w and D[o].y < D[b].y + D[b].h and D[b].y < D[o].y + D[o].h end,
  destroy = function(o) if D[o].alive then sprite_free(o) end end,
}, sprite_free)

local Sprite = closed("Sprite", {
  image = function(path)
    check_path(path, "Sprite.image")
    local w, h, alpha = H.png_size(path)
    if not w then return nil, "load failed: " .. path end
    -- Same rule as asset_loader.c png_has_alpha: RGB565A8 when the PNG can carry alpha.
    return new_sprite(path, w, h, alpha and 3 or 2)
  end,
  new = function(path, w, h)
    check_path(path, "Sprite.new")
    w, h = int_arg(w, "Sprite.new", 2), int_arg(h, "Sprite.new", 3)
    local size = H.file_size(path)
    if not size or size < w * h * 2 then return nil, "load failed: " .. path end
    return new_sprite(path, w, h, 2)
  end,
  solid = function(w, h)
    w, h = int_arg(w, "Sprite.solid", 1), int_arg(h, "Sprite.solid", 2)
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
TXT_MT = method_table("Text", {
  set = function(t, s) if type(s) ~= "string" and type(s) ~= "number" then error("bad argument #1 to 'set'", 2) end; D[t].str = tostring(s) end,
  move = function(t, x, y) int_arg(x, "move", 1); int_arg(y, "move", 2) end,
  align = function(t, where)
    local ok = { center = 1, top = 1, bottom = 1, left = 1, right = 1, top_left = 1, top_right = 1, bottom_left = 1, bottom_right = 1 }
    if not ok[where] then return nil, "bad align: " .. tostring(where) end
  end,
  set_font = function(t, path, size)
    if not safe_rel(path) then return nil, "unsafe font path: " .. tostring(path) end
    size = size or LIM.font_px_default
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
  set_color = function() end, show = function() end,
  destroy = function(t) if D[t].alive then text_free(t) end end,
}, text_free)
local Text = closed("Text", {
  new = function(str, x, y)
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
local function shape_free(s) D[s].alive = false; S.shapes = S.shapes - 1 end
local SHP_MT = method_table("Shape", {
  set_points = function() return 0 end, set_style = function() return 0 end,
  set_opacity = function() end, set_z = function() end, set_visible = function() end,
  destroy = function(s) if D[s].alive then shape_free(s) end end,
}, shape_free)
local Shape = closed("Shape", {
  line = function()
    if S.shapes >= LIM.line_slots then return nil, "pool_full" end
    S.shapes = S.shapes + 1
    local o = setmetatable({}, SHP_MT); D[o] = { alive = true, sid = SID, site = site() }; return o
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
    if type(opt) == "table" then r.loop = not not opt.loop else r.loop = not not opt end
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
  stop = function(a) anim_stop(D[a]) end,
  is_playing = function(a) return D[a].playing end,
  set_pos = function() end, set_visible = function() end,
  destroy = function(a) if D[a].alive then anim_free(a) end end,
}, anim_free)
local Anim = closed("Anim", {
  new = function(path)
    check_path(path, "Anim.new")
    if not path:lower():match("%.gif$") and not path:lower():match("%.mjpe?g$") then error("Anim.new: unsupported extension " .. path, 2) end
    local size = H.file_size(path)
    if not size then return nil, "load failed: " .. path end
    if size > LIM.anim_max_file_bytes then return nil, "too_big" end
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
      return false
    end
    S.last_play = S.now
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
  set_volume = function() end, get_volume = function() return 80 end,
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
  stats = function() return { played_total = 0, finish_dropped = 0, error_count = 0, cooldown_reject = 0 } end,
})

-- ------------------------------------------------------------------ Input
local actions, by_button = {}, {}
for name, srcs in pairs((MAN.input or {}).actions or {}) do
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
local function range(v, lo, hi) return type(v) == "number" and v >= lo and v <= hi end
local Led = closed("Led", {
  set = function() return true end, off = function() return true end,
  preset = function(n)
    local ok = { user_talk = 1, conv_processing = 1, robot_talking = 1, warm_white = 1, light_blue = 1, dark_blue = 1 }
    if not ok[n] then warn_once("LED", "Led.preset('" .. tostring(n) .. "'): unknown preset"); return false end
    return true
  end,
  blink = function(_, _, _, p)
    if not range(p, LIM.led_blink_min_ms, LIM.led_blink_max_ms) then report("error", "LED", "Led.blink period " .. tostring(p) .. " ms rejected"); return false end
    return true
  end,
  pulse = function(_, _, _, d)
    if not range(d, LIM.led_pulse_min_ms, LIM.led_pulse_max_ms) then report("error", "LED", "Led.pulse duration " .. tostring(d) .. " ms rejected"); return false end
    return true
  end,
  set_brightness = function(p) return range(p, 0, 100) end,
  get_brightness = function() return 100 end, is_available = function() return true end,
})
local servos, poses = MAN.servos or {}, MAN.poses or {}
local Servo = closed("Servo", {
  pose = function(a) if not poses[a] then warn_once("SERVO", "Servo.pose('" .. tostring(a) .. "'): pose not in manifest"); return false end; return true end,
  move = function(a) if not servos[a] then warn_once("SERVO", "Servo.move('" .. tostring(a) .. "'): servo not in manifest"); return false end; return true end,
  stop = function() return true end, is_busy = function() return false end,
  list = function() return { servos = servos, poses = poses } end,
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
  report = function(t) if type(t) ~= "table" or type(t.score) ~= "number" then return false end; return true end,
  get_result = function() return nil end,
})
local Engine = closed("Engine", {
  exit = function(reason) S.exit = reason or "lua" end,
  report_result = function(t) if type(t) ~= "table" or type(t.event) ~= "string" then return nil, "bad_event" end; return true end,
})
local Timer = closed("Timer", { millis = function() return S.now end })

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
        faces = {}, font_seen = S.font_seen or {}, shapes = 0, anim = nil, cur = nil, last_play = -1000000,
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
  if type(f) ~= "function" then
    if name == "game_start" then S.phase = "run" end
    return true, nil, false
  end
  local ok, r = xpcall(f, debug.traceback, ...)
  if name == "game_start" then S.phase = "run" end
  return ok, r, true
end

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
