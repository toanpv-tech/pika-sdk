-- test_shape: the Shape API (Shape.line and its six methods) on the robot.
--
-- Shape draws one primitive, a straight segment. Each line is rasterised once
-- into an anti-aliased RGB565A8 image over its bounding box, so geometry and
-- style changes cost a raster and three limits apply: 8 live lines
-- (line_slots), a bbox of at most 480 x 320 including the padding, and a
-- 256 KiB raster budget shared by every live line (line_pool_max_bytes).
--
-- Groups (suite order):
--   probe  : handle type, mutators return nothing, 8 free slots
--   guard  : bad arguments raise (coordinates, style fields, method args,
--            a non-Shape self); valid edge values do not
--   fail   : runtime refusals return nil, reason: pool_full, bbox_too_large,
--            no_mem, on Shape.line, set_points and set_style; a refusal costs
--            no slot and no budget
--   life   : destroy is idempotent, a dead handle is a no-op, a stale handle
--            cannot touch a recycled slot, <close> frees the line
--   cache  : the same points / style again cost no raster (timed, robot only)
--   stress : create/destroy churn, full-pool churn, refused-move churn,
--            8 lines re-rastered every frame for 1 s; all bounded
--   look   : the gallery. The operator answers each card: ENTER = looks
--            right, RIGHT = looks wrong. Every card destroys its lines.
--   diag   : pool census and a raster cost table printed to UART
--   manual : a dropped handle is collected (deliberately trips smoke's
--            HANDLE-GC warning, so RUN SUITE leaves it out)
--
-- Needs the robot for the cache timings and the raster costs (the PC has no
-- raster: smoke reports those as SKIP or 0 ms) and an operator for "look".
-- No test keeps a line: every line a test makes goes into `made` and is
-- destroyed when the test ends, also on failure and on abort.

-- ── Constants ────────────────────────────────────────────────────────
-- contract/constraints.json: line_slots, line_width_max, line_pool_max_bytes,
-- img_max_w / img_max_h (bbox cap and coordinate range).
local LINE_SLOTS     = 8
local LINE_WIDTH_MAX = 64
local LINE_POOL_BYTES = 262144
local IMG_W, IMG_H   = 480, 320
-- Coordinate range: x in -img_max_w..2*img_max_w, y in -img_max_h..2*img_max_h.
local X_MIN, X_MAX   = -IMG_W, 2 * IMG_W
local Y_MIN, Y_MAX   = -IMG_H, 2 * IMG_H
-- Padding around the stroke: 4 px plus half the width (api.md#shape), and
-- 3 bytes per raster pixel (RGB565 + A8).
local LINE_PAD       = 4
local BYTES_PER_PX   = 3

local fmt, abs = string.format, math.abs
local floor, sin, cos, pi = math.floor, math.sin, math.cos, math.pi
local clock_ms = Timer.millis

local RED, GREEN, BLUE   = 0xFF0000, 0x00FF00, 0x0000FF
local WHITE, GREY        = 0xFFFFFF, 0x8892A6

local TINY     = { width = 1 }
local TOP      = 56          -- below the two fullscreen HUD lines

-- Raster bytes, bbox width and height of one line, as the firmware computes
-- them (render/lvgl_renderer.c line_rebuild).
local function line_bytes(x1, y1, x2, y2, width)
    local w = width or 2
    if w < 1 then w = 1 elseif w > LINE_WIDTH_MAX then w = LINE_WIDTH_MAX end
    local pad = LINE_PAD + (w + 1) // 2
    local bw, bh = abs(x2 - x1) + 2 * pad, abs(y2 - y1) + 2 * pad
    return bw * bh * BYTES_PER_PX, bw, bh
end

-- ── Line registry ────────────────────────────────────────────────────
-- Every line a test makes (HANDLE-GC: the table keeps it referenced).
local made = {}

local function keep(s)
    if s then made[#made + 1] = s end
    return s
end

local function free_all()
    for i = #made, 1, -1 do
        made[i]:destroy()
        made[i] = nil
    end
end

-- Creates a line that must exist; raises with the reason otherwise.
local function need(x1, y1, x2, y2, style)
    local s, why = Shape.line(x1, y1, x2, y2, style)
    if not s then
        error(fmt("Shape.line(%d,%d,%d,%d) -> nil, %s", x1, y1, x2, y2, tostring(why)), 2)
    end
    return keep(s)
end

-- Free slots right now: takes up to LINE_SLOTS tiny lines and gives them back.
local census_buf = {}
local function free_slots()
    local n = 0
    for _ = 1, LINE_SLOTS do
        local s = Shape.line(0, 0, 4, 4, TINY)
        if not s then break end
        n = n + 1
        census_buf[n] = s
    end
    for i = n, 1, -1 do
        census_buf[i]:destroy()
        census_buf[i] = nil
    end
    return n
end

-- true when Shape.line raised; a handle it returned is registered.
local function line_raises(...)
    local ok, s = pcall(Shape.line, ...)
    if ok then keep(s) end
    return not ok
end

local function method_raises(s, name, ...)
    return not pcall(s[name], s, ...)
end

-- Sync test whose lines are always destroyed afterwards.
local function with_lines(fn)
    return function()
        local ok, pass, msg = pcall(fn)
        free_all()
        if not ok then error(pass, 0) end
        return pass, msg
    end
end

local function raised(ok_flag)
    return ok_flag, ok_flag and "raised" or "returned instead of raising"
end

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "shape", title = "SHAPE TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    groups = {
        probe  = { label = "PROBE",    what = "handle, returns, free slots" },
        guard  = { label = "GUARDS",   what = "bad arguments raise" },
        fail   = { label = "REFUSALS", what = "nil, reason: pool / bbox / budget" },
        life   = { label = "LIFETIME", what = "destroy, stale handles, <close>" },
        cache  = { label = "CACHE",    what = "unchanged value costs no raster" },
        stress = { label = "STRESS",   what = "bounded churn and per-frame moves" },
        look   = { label = "LOOK",     what = "operator checks the screen" },
        diag   = { label = "DIAG",     what = "pool census, raster cost table" },
        manual = { label = "MANUAL",   what = "trips a smoke warning on purpose" },
    },
    status = function()
        return fmt("lines held by tests: %d", #made)
    end,
    on_abort = free_all,
})

-- testkit does not clean up when step() raises, so every async test frees
-- its lines itself when it ends or fails.
local function async(group, name, arm, step, o)
    local function arm_w()
        local ok, st = pcall(arm)
        if not ok then free_all(); error(st, 0) end
        return st
    end
    local function step_w(st)
        local ok, done, pass, msg = pcall(step, st)
        if not ok then free_all(); error(done, 0) end
        if done then free_all() end
        return done, pass, msg
    end
    return S:async(group, name, arm_w, step_w, o)
end

-- Gallery card: build() draws with need(); a short page fails the card
-- instead of being shown half drawn.
local function look(name, build, question)
    S:look("look", name, function()
        local ok, err = pcall(build)
        if not ok then free_all(); error(err, 0) end
        return free_all
    end, question)
end

-- ── Group: probe ─────────────────────────────────────────────────────
S:sync("probe", "Shape.line returns a userdata handle", with_lines(function()
    local s = need(20, 200, 120, 200)
    return type(s) == "userdata", "type=" .. type(s)
end))

S:sync("probe", "mutators return nothing on success", with_lines(function()
    local s = need(20, 200, 120, 200)
    local n = {
        set_points  = select("#", s:set_points(20, 210, 120, 210)),
        set_style   = select("#", s:set_style({ width = 3 })),
        set_opacity = select("#", s:set_opacity(200)),
        set_z       = select("#", s:set_z(1000)),
        set_visible = select("#", s:set_visible(true)),
        destroy     = select("#", s:destroy()),
    }
    local bad = {}
    for _, m in ipairs({ "set_points", "set_style", "set_opacity", "set_z",
                         "set_visible", "destroy" }) do
        if n[m] ~= 0 then bad[#bad + 1] = fmt("%s=%d", m, n[m]) end
    end
    return #bad == 0, #bad == 0 and "0 values from all six"
                               or ("values returned: " .. table.concat(bad, " "))
end))

S:sync("probe", "8 free line slots", function()
    local n = free_slots()
    return n == LINE_SLOTS, fmt("%d/%d free", n, LINE_SLOTS)
end)

-- ── Group: guard ─────────────────────────────────────────────────────
S:sync("guard", "Shape.line(1.5, ...) raises", with_lines(function()
    return raised(line_raises(1.5, 0, 10, 10))
end))

S:sync("guard", "Shape.line(table, ...) raises", with_lines(function()
    return raised(line_raises({}, 0, 10, 10))
end))

S:sync("guard", "Shape.line missing y2 raises", with_lines(function()
    return raised(line_raises(0, 0, 10))
end))

S:sync("guard", "coords past -480..960 / -320..640 raise", with_lines(function()
    local cases = {
        { "x1=-481", X_MIN - 1, 0, 0, 0 }, { "x2=961", 950, 0, X_MAX + 1, 0 },
        { "y1=-321", 0, Y_MIN - 1, 0, 0 }, { "y2=641", 0, 630, 0, Y_MAX + 1 },
    }
    local missed = {}
    for _, c in ipairs(cases) do
        if not line_raises(c[2], c[3], c[4], c[5]) then missed[#missed + 1] = c[1] end
    end
    return #missed == 0, #missed == 0 and "4/4 raised"
                                   or ("accepted: " .. table.concat(missed, " "))
end))

-- Short segments at the edges: a long one would hit bbox_too_large instead.
S:sync("guard", "edge coords -480/-320 and 960/640 accepted", with_lines(function()
    local ok1, a, wa = pcall(Shape.line, X_MIN, Y_MIN, X_MIN + 10, Y_MIN + 10)
    if ok1 then keep(a) end
    local ok2, b, wb = pcall(Shape.line, X_MAX, Y_MAX, X_MAX - 10, Y_MAX - 10)
    if ok2 then keep(b) end
    return ok1 and ok2 and a ~= nil and b ~= nil,
           fmt("low edge -> %s, high edge -> %s",
               ok1 and (a and "line" or ("nil, " .. tostring(wa))) or "raised",
               ok2 and (b and "line" or ("nil, " .. tostring(wb))) or "raised")
end))

S:sync("guard", "style non-table raises", with_lines(function()
    return raised(line_raises(0, 0, 10, 10, "red"))
end))

local BAD_STYLES = {
    { "cap", { { cap = "square" }, { cap = "nope" } } },
    { "dash", { { dash = { 4 } }, { dash = { 4, 5, 1 } }, { dash = {} }, { dash = 4 },
                { dash = { -1, 4 } }, { dash = { 4, IMG_W + 1 } }, { dash = { 1.5, 2 } },
                { dash = { "a", 2 } } } },
    { "width", { { width = {} }, { width = 2.5 } } },
    { "color", { { color = "red" }, { color = 1.5 } } },
}
for _, f in ipairs(BAD_STYLES) do
    local field, list = f[1], f[2]
    S:sync("guard", fmt("style.%s: %d bad forms raise", field, #list), with_lines(function()
        local missed = {}
        for i, st in ipairs(list) do
            if not line_raises(10, 10, 60, 60, st) then missed[#missed + 1] = "#" .. i end
        end
        return #missed == 0, #missed == 0 and fmt("%d/%d raised", #list, #list)
                                       or ("accepted: " .. table.concat(missed, " "))
    end))
end

-- dash {0, n} draws solid; width outside 1..64 is clamped, never raised.
local GOOD_STYLES = {
    {}, { cap = "butt" }, { cap = "round" }, { dash = { 4, 4 } }, { dash = { 0, 4 } },
    { dash = { IMG_W, IMG_W } }, { color = 0x000000 }, { width = 0 }, { width = -5 },
    { width = LINE_WIDTH_MAX }, { width = 1000 },
}
S:sync("guard", "valid styles accepted (nil + 11 tables)", with_lines(function()
    local bad = {}
    local ok, s = pcall(Shape.line, 10, 10, 60, 60)
    if ok then keep(s) end
    if not (ok and s) then bad[#bad + 1] = "nil" end
    for i, st in ipairs(GOOD_STYLES) do
        local okc, sc, why = pcall(Shape.line, 10, 10, 60, 60, st)
        if okc then keep(sc) end
        if not (okc and sc) then
            bad[#bad + 1] = fmt("#%d:%s", i, okc and tostring(why) or "raised")
        end
        free_all()
    end
    return #bad == 0, #bad == 0 and "12/12 created"
                               or ("refused: " .. table.concat(bad, " "))
end))

S:sync("guard", "set_points: fractional / out of range / missing raise", with_lines(function()
    local s = need(20, 200, 120, 200)
    local r = {
        method_raises(s, "set_points", 1.5, 0, 10, 10),
        method_raises(s, "set_points", 0, 0, X_MAX + 1, 10),
        method_raises(s, "set_points", 0, 0, 10),
    }
    local n = (r[1] and 1 or 0) + (r[2] and 1 or 0) + (r[3] and 1 or 0)
    return n == 3, fmt("%d/3 raised (fractional=%s range=%s missing=%s)", n,
                       tostring(r[1]), tostring(r[2]), tostring(r[3]))
end))

S:sync("guard", "set_style: non-table / bad cap / none raise", with_lines(function()
    local s = need(20, 200, 120, 200)
    local r1 = method_raises(s, "set_style", "x")
    local r2 = method_raises(s, "set_style", { cap = "square" })
    local r3 = method_raises(s, "set_style")
    return r1 and r2 and r3, fmt("non-table=%s cap=%s none=%s",
                                 tostring(r1), tostring(r2), tostring(r3))
end))

S:sync("guard", "set_opacity: 1.5 / string / nil raise", with_lines(function()
    local s = need(20, 200, 120, 200)
    local r1 = method_raises(s, "set_opacity", 1.5)
    local r2 = method_raises(s, "set_opacity", "x")
    local r3 = method_raises(s, "set_opacity", nil)
    return r1 and r2 and r3, fmt("1.5=%s string=%s nil=%s",
                                 tostring(r1), tostring(r2), tostring(r3))
end))

S:sync("guard", "set_opacity -20 / 300 clamp, no raise", with_lines(function()
    local s = need(20, 200, 120, 200)
    local r1 = method_raises(s, "set_opacity", -20)
    local r2 = method_raises(s, "set_opacity", 300)
    return not r1 and not r2, fmt("-20 %s, 300 %s", r1 and "raised" or "ok",
                                  r2 and "raised" or "ok")
end))

S:sync("guard", "set_z: 1.5 / nil raise; -3 / 1000 clamp", with_lines(function()
    local s = need(20, 200, 120, 200)
    local r1 = method_raises(s, "set_z", 1.5)
    local r2 = method_raises(s, "set_z", nil)
    local r3 = method_raises(s, "set_z", -3)
    local r4 = method_raises(s, "set_z", 1000)
    return r1 and r2 and not r3 and not r4,
           fmt("1.5=%s nil=%s -3=%s 1000=%s", r1 and "raised" or "ok",
               r2 and "raised" or "ok", r3 and "raised" or "ok", r4 and "raised" or "ok")
end))

-- The methods check their self (luaL_checkudata): a plain table must raise.
S:sync("guard", "every method on a non-Shape self raises", with_lines(function()
    local s = need(20, 200, 120, 200)
    local fake = {}
    local calls = {
        { "set_points", 0, 0, 10, 10 }, { "set_style", TINY }, { "set_opacity", 100 },
        { "set_z", 1 }, { "set_visible", true }, { "destroy" },
    }
    local missed = {}
    for _, c in ipairs(calls) do
        if pcall(s[c[1]], fake, c[2], c[3], c[4], c[5]) then missed[#missed + 1] = c[1] end
    end
    return #missed == 0, #missed == 0 and "6/6 raised"
                                   or ("accepted: " .. table.concat(missed, " "))
end))

-- ── Group: fail (nil, reason) ────────────────────────────────────────
-- Smoke does not report a Shape pool overflow (unlike Text), so these run in
-- RUN SUITE.
S:sync("fail", "9th line -> nil, pool_full", with_lines(function()
    for i = 1, LINE_SLOTS do need(10, 40 + i * 20, 60, 40 + i * 20, TINY) end
    local s, why = Shape.line(10, 300, 60, 300, TINY)
    if s then keep(s); return false, "a 9th line was created" end
    return why == "pool_full", fmt("%d created, then -> nil, %s", LINE_SLOTS, tostring(why))
end))

S:sync("fail", "destroy frees a slot for a new line", with_lines(function()
    for i = 1, LINE_SLOTS do need(10, 40 + i * 20, 60, 40 + i * 20, TINY) end
    made[#made]:destroy()
    made[#made] = nil
    local s, why = Shape.line(10, 300, 60, 300, TINY)
    keep(s)
    return s ~= nil, s and "slot reused" or ("-> nil, " .. tostring(why))
end))

-- (0,10)-(479,10) width 2: bbox 489 px > 480.  (10,0)-(10,319): 329 px > 320.
S:sync("fail", "bbox past 480x320 -> nil, bbox_too_large", with_lines(function()
    local a, wa = Shape.line(0, 10, IMG_W - 1, 10)
    keep(a)
    local b, wb = Shape.line(10, 0, 10, IMG_H - 1)
    keep(b)
    local _, bw = line_bytes(0, 10, IMG_W - 1, 10, 2)
    local _, _, bh = line_bytes(10, 0, 10, IMG_H - 1, 2)
    return a == nil and wa == "bbox_too_large" and b == nil and wb == "bbox_too_large",
           fmt("wide %d px -> %s, %s; tall %d px -> %s, %s", bw, tostring(a), tostring(wa),
               bh, tostring(b), tostring(wb))
end))

-- 460 px fits at width 2 (bbox 470) but not at width 64 (pad 36 -> 532).
S:sync("fail", "width grows the bbox: 460 px w2 ok, w64 too large", with_lines(function()
    local a, wa = Shape.line(10, 100, 470, 100, { width = 2 })
    keep(a)
    local b, wb = Shape.line(10, 200, 470, 200, { width = LINE_WIDTH_MAX })
    keep(b)
    return a ~= nil and b == nil and wb == "bbox_too_large",
           fmt("w2 -> %s; w64 -> %s, %s", a and "line" or ("nil, " .. tostring(wa)),
               tostring(b), tostring(wb))
end))

-- Unclamped, width 1000 would give a 1400 px bbox; clamped to 64 it fits.
S:sync("fail", "width 1000 clamps to 64 (line created)", with_lines(function()
    local s, why = Shape.line(10, 160, 400, 160, { width = 1000 })
    keep(s)
    local _, bw, bh = line_bytes(10, 160, 400, 160, 1000)
    return s ~= nil, s and fmt("created, bbox %dx%d at width 64", bw, bh)
                         or ("-> nil, " .. tostring(why))
end))

S:sync("fail", "refused create costs no slot", with_lines(function()
    local s = Shape.line(0, 10, IMG_W - 1, 10)
    keep(s)
    free_all()
    local n = free_slots()
    return n == LINE_SLOTS, fmt("%d/%d free after a refused create", n, LINE_SLOTS)
end))

-- (0,0)-(200,100) width 2 costs 210*110*3 = 69300 B: 3 fit in 256 KiB.
S:sync("fail", "budget: 3 lines of 69300 B fit, 4th -> no_mem", with_lines(function()
    local per = line_bytes(0, 0, 200, 100, 2)
    local fit = LINE_POOL_BYTES // per
    for i = 1, fit do
        local s, why = Shape.line(0, 50 + i, 200, 150 + i)
        if not s then return false, fmt("line %d/%d -> nil, %s", i, fit, tostring(why)) end
        keep(s)
    end
    local s, why = Shape.line(0, 60, 200, 160)
    if s then keep(s); return false, fmt("line %d over the budget was created", fit + 1) end
    return why == "no_mem", fmt("%d x %d B fit, next -> nil, %s", fit, per, tostring(why))
end))

-- (0,0)-(300,200) width 2 costs 195300 B: a second one passes 256 KiB.
S:sync("fail", "no_mem, then destroy returns the budget", with_lines(function()
    local a = need(0, 60, 300, 260)
    local b, why = Shape.line(0, 60, 300, 260)
    if b then keep(b); return false, "second 195300 B line was created" end
    a:destroy()
    local c, why2 = Shape.line(0, 60, 300, 260)
    keep(c)
    return why == "no_mem" and c ~= nil,
           fmt("2nd -> nil, %s; after destroy -> %s", tostring(why),
               c and "line" or ("nil, " .. tostring(why2)))
end))

S:sync("fail", "set_points past the bbox -> nil, bbox_too_large", with_lines(function()
    local s = need(100, 100, 200, 100, { width = 16 })
    local r, why = s:set_points(0, 0, IMG_W - 1, IMG_H - 1)
    -- The old geometry is kept: putting it back is accepted.
    local _, why2 = s:set_points(100, 100, 200, 100)
    return r == nil and why == "bbox_too_large" and why2 == nil,
           fmt("-> %s, %s; old points again -> %s", tostring(r), tostring(why),
               why2 and ("nil, " .. why2) or "ok")
end))

S:sync("fail", "set_points over the budget -> nil, no_mem", with_lines(function()
    need(0, 60, 300, 260)
    local b = need(0, 300, 50, 300)
    local r, why = b:set_points(0, 60, 300, 260)
    return r == nil and why == "no_mem", fmt("-> %s, %s", tostring(r), tostring(why))
end))

-- (20,100)-(440,100): bbox 430 px wide at width 2, 492 px at width 64 (pad 36).
S:sync("fail", "set_style past the bbox -> nil, bbox_too_large", with_lines(function()
    local s = need(20, 100, 440, 100)
    local r, why = s:set_style({ width = LINE_WIDTH_MAX })
    local _, bw = line_bytes(20, 100, 440, 100, LINE_WIDTH_MAX)
    return r == nil and why == "bbox_too_large",
           fmt("width 64 -> bbox %d px -> %s, %s", bw, tostring(r), tostring(why))
end))

S:sync("fail", "set_style over the budget -> nil, no_mem", with_lines(function()
    need(0, 60, 300, 260)                        -- 195300 B
    local b = need(0, 300, 300, 300)             -- 9300 B
    local r, why = b:set_style({ width = LINE_WIDTH_MAX })   -- 80352 B
    return r == nil and why == "no_mem", fmt("-> %s, %s", tostring(r), tostring(why))
end))

-- ── Group: life ──────────────────────────────────────────────────────
S:sync("life", "destroy twice: no raise", function()
    local s = need(20, 200, 120, 200)
    s:destroy()
    local ok = pcall(s.destroy, s)
    free_all()
    return ok, ok and "second destroy ok" or "second destroy raised"
end)

S:sync("life", "dead handle: all 6 methods no-op, no reason", function()
    local s = need(20, 200, 120, 200)
    s:destroy()
    free_all()
    local bad = {}
    local ok1, r1, w1 = pcall(s.set_points, s, 0, 0, 10, 10)
    if not ok1 or r1 ~= nil or w1 ~= nil then bad[#bad + 1] = "set_points" end
    local ok2, r2, w2 = pcall(s.set_style, s, TINY)
    if not ok2 or r2 ~= nil or w2 ~= nil then bad[#bad + 1] = "set_style" end
    if not pcall(s.set_opacity, s, 100) then bad[#bad + 1] = "set_opacity" end
    if not pcall(s.set_z, s, 3) then bad[#bad + 1] = "set_z" end
    if not pcall(s.set_visible, s, true) then bad[#bad + 1] = "set_visible" end
    if not pcall(s.destroy, s) then bad[#bad + 1] = "destroy" end
    return #bad == 0, #bad == 0 and "6/6 no-op"
                               or ("raised or returned a value: " .. table.concat(bad, " "))
end)

-- A new line takes the freed slot; the old handle must not free it.
S:sync("life", "stale destroy does not free a recycled slot", with_lines(function()
    local victim = need(40, 200, 140, 200)
    victim:destroy()
    local reuse = need(40, 220, 140, 220)
    -- An oversize move through the stale handle must be a silent no-op; a
    -- bbox_too_large reply means it reached the recycled line.
    local _, stale_why = victim:set_points(0, 0, IMG_W - 1, IMG_H - 1)
    victim:destroy()
    local n = free_slots()
    local _, why = reuse:set_points(40, 230, 140, 230)
    return n == LINE_SLOTS - 1 and why == nil and stale_why == nil,
           fmt("stale oversize move %s; %d/%d free with the new line held (want %d); new line set_points %s",
               stale_why and ("-> " .. stale_why) or "no-op", n, LINE_SLOTS, LINE_SLOTS - 1,
               why and ("-> " .. why) or "ok")
end))

S:sync("life", "<close> destroys the line at scope exit", with_lines(function()
    local s = need(20, 200, 120, 200)
    do
        local c <close> = s
    end
    local n = free_slots()
    return n == LINE_SLOTS, fmt("%d/%d free after the <close> scope", n, LINE_SLOTS)
end))

-- ── Group: cache (async, robot timing) ───────────────────────────────
-- Re-asserting the current points or style must skip the raster: a layout
-- pass re-sends geometry every frame. Arms run in separate frames so one
-- frame never pays more than CACHE_REPS rebuilds (~50 ms each on the robot).
-- set_opacity never rasters and is the per-call floor.
local CACHE_REPS = 6
local CX1, CY1, CX2, CY2 = 40, 60, 300, 260     -- 175908 B at width 6
local STY_A = { width = 6, color = RED, cap = "round" }
local STY_B = { width = 6, color = GREEN, cap = "round" }

async("cache", "same points / style again cost no raster",
    function()
        return { phase = 1, line = need(CX1, CY1, CX2, CY2, { width = 6 }), why = nil }
    end,
    function(st)
        local s = st.line
        local t0 = clock_ms()
        if st.phase == 1 then
            s:set_points(CX1, CY1, CX2, CY2)
            t0 = clock_ms()
            for _ = 1, CACHE_REPS do s:set_points(CX1, CY1, CX2, CY2) end
            st.p_same = clock_ms() - t0
        elseif st.phase == 2 then
            for k = 1, CACHE_REPS do
                local _, why = s:set_points(CX1, CY1 + k % 2, CX2, CY2 + k % 2)
                st.why = st.why or why
            end
            st.p_moved = clock_ms() - t0
        elseif st.phase == 3 then
            for k = 1, CACHE_REPS do s:set_opacity(200 + k % 2) end
            st.ctrl = clock_ms() - t0
        elseif st.phase == 4 then
            s:set_style(STY_A)
            t0 = clock_ms()
            for _ = 1, CACHE_REPS do s:set_style(STY_A) end
            st.s_same = clock_ms() - t0
        else
            for k = 1, CACHE_REPS do
                local _, why = s:set_style(k % 2 == 0 and STY_A or STY_B)
                st.why = st.why or why
            end
            st.s_diff = clock_ms() - t0
            local msg = fmt("%d reps: points same %d / moved %d ms, style same %d / changed %d ms, opacity %d ms",
                            CACHE_REPS, st.p_same, st.p_moved, st.s_same, st.s_diff, st.ctrl)
            if st.why then return true, false, "a rebuild was refused: " .. st.why end
            if st.p_moved < 1 or st.s_diff < 1 then
                return true, "skip", "timer did not resolve the rebuilds (no raster here); " .. msg
            end
            local pass = st.p_same * 2 < st.p_moved and st.p_same <= st.ctrl + 1
                         and st.s_same * 2 < st.s_diff
            return true, pass, msg
        end
        st.phase = st.phase + 1
        return false
    end,
    { prompt = "timing set_points / set_style (5 frames)" })

-- ── Group: stress (async, bounded) ───────────────────────────────────
local CHURN_ROUNDS, CHURN_PER_TICK = 100, 20
local CHURN_STYLE = { width = 2 }
local STRESS_DEADLINE_MS = 10000

async("stress", "100 x create/destroy, then 8 free slots",
    function() return { done = 0, fail = nil, t_end = clock_ms() + STRESS_DEADLINE_MS } end,
    function(st)
        for _ = 1, CHURN_PER_TICK do
            if st.done >= CHURN_ROUNDS then break end
            st.done = st.done + 1
            local s, why = Shape.line(20, 60, 80, 120, CHURN_STYLE)
            if not s then
                st.fail = fmt("round %d -> nil, %s", st.done, tostring(why))
                break
            end
            s:destroy()
        end
        if st.fail then return true, false, st.fail end
        if st.done < CHURN_ROUNDS then
            if clock_ms() > st.t_end then return true, false, "deadline at round " .. st.done end
            return false
        end
        local n = free_slots()
        return true, n == LINE_SLOTS, fmt("%d rounds, %d/%d free after", st.done, n, LINE_SLOTS)
    end)

local POOL_ROUNDS = 10
async("stress", "10 x fill all 8 slots and free",
    function() return { round = 0 } end,
    function(st)
        st.round = st.round + 1
        for i = 1, LINE_SLOTS do
            local s, why = Shape.line(10 + i * 30, 60, 10 + i * 30, 180, TINY)
            if not s then
                return true, false, fmt("round %d line %d -> nil, %s", st.round, i, tostring(why))
            end
            keep(s)
        end
        free_all()
        if st.round < POOL_ROUNDS then return false end
        local n = free_slots()
        return true, n == LINE_SLOTS, fmt("%d x %d clean, %d/%d free after",
                                          POOL_ROUNDS, LINE_SLOTS, n, LINE_SLOTS)
    end)

-- A refused move must not cost its slot, or a pack driving set_points from
-- live data drains the pool.
local REFUSE_ROUNDS = 10
local WIDE16 = { width = 16 }
async("stress", "10 x refused set_points + destroy keep 8 slots",
    function() return { round = 0, odd = nil } end,
    function(st)
        st.round = st.round + 1
        local s = need(100, 100, 200, 100, WIDE16)
        local _, why = s:set_points(0, 0, IMG_W - 1, IMG_H - 1)
        if why ~= "bbox_too_large" then st.odd = st.odd or tostring(why) end
        free_all()
        if st.round < REFUSE_ROUNDS then return false end
        local n = free_slots()
        return true, n == LINE_SLOTS and st.odd == nil,
               fmt("%d refused moves, %d/%d free after%s", REFUSE_ROUNDS, n, LINE_SLOTS,
                   st.odd and (", a move returned " .. st.odd) or "")
    end)

-- What a per-frame layout costs: 8 lines of 100 px, every one moved by 1 px
-- each frame for MOVE_FRAMES frames.
local MOVE_FRAMES = 30
async("stress", "8 lines re-rastered every frame for 30 frames",
    function()
        for i = 1, LINE_SLOTS do need(60, TOP + i * 30, 160, TOP + i * 30) end
        return { frame = 0, worst = 0, total = 0, why = nil }
    end,
    function(st)
        st.frame = st.frame + 1
        local d = st.frame % 2
        local t0 = clock_ms()
        for i = 1, #made do
            local y = TOP + i * 30 + d
            local _, why = made[i]:set_points(60, y, 160, y)
            if why then st.why = st.why or why end
        end
        local dt = clock_ms() - t0
        st.total = st.total + dt
        if dt > st.worst then st.worst = dt end
        if st.frame < MOVE_FRAMES then return false end
        return true, st.why == nil,
               fmt("%d frames x %d rebuilds: worst %d ms, mean %d ms per frame%s",
                   MOVE_FRAMES, LINE_SLOTS, st.worst, st.total // MOVE_FRAMES,
                   st.why and (", refused: " .. st.why) or "")
    end,
    { fullscreen = true, prompt = "8 lines moving (1 s)" })

-- ── Group: look (operator) ───────────────────────────────────────────
look("width 1 / 2 / 4 / 8 / 16", function()
    local rows = { { 70, 1 }, { 110, 2 }, { 150, 4 }, { 200, 8 }, { 260, 16 } }
    for _, r in ipairs(rows) do need(60, r[1], 420, r[1], { width = r[2] }) end
end, "Five lines, each thicker than the one above?")

look("width clamp: 64 vs 1000", function()
    need(90, 120, 390, 120, { width = LINE_WIDTH_MAX, color = 0xFFC46B })
    need(90, 240, 390, 240, { width = 1000, color = 0xFFC46B })
end, "Two bars of the same thickness?")

look("cap: butt vs round", function()
    need(140, 60, 140, 300, { width = 1, color = GREY })
    need(340, 60, 340, 300, { width = 1, color = GREY })
    for i = 1, 3 do
        need(140, 50 + i * 30, 340, 50 + i * 30, { width = 4 * i, color = 0x7FD4FF })
        need(140, 170 + i * 30, 340, 170 + i * 30,
             { width = 4 * i, color = 0xFFC46B, cap = "round" })
    end
end, "Blue ends flush on the grey guides, orange ends rounded past them?")

look("dash: solid / 4,4 / 2,8 / 12,3 / 0,4", function()
    local dashes = { false, { 4, 4 }, { 2, 8 }, { 12, 3 }, { 0, 4 } }
    for i, d in ipairs(dashes) do
        need(50, 70 + (i - 1) * 48, 430, 70 + (i - 1) * 48,
             { width = 5, dash = d or nil, color = WHITE })
    end
end, "Lines 1 and 5 solid, 2-4 dashed with different gaps?")

look("colour", function()
    local cs = { RED, GREEN, BLUE, 0xFFFF00, WHITE, 0x00FFFF }
    for i, c in ipairs(cs) do
        need(60, 70 + (i - 1) * 42, 420, 70 + (i - 1) * 42, { width = 10, color = c })
    end
end, "Top to bottom: red, green, blue, yellow, white, cyan?")

look("opacity 300(clamp) / 192 / 128 / 64 / 32 / -20", function()
    local ops = { 300, 192, 128, 64, 32, -20 }
    for i, o in ipairs(ops) do
        local s = need(60, 66 + (i - 1) * 40, 420, 66 + (i - 1) * 40,
                       { width = 14, color = 0x6BE38A })
        s:set_opacity(o)
    end
end, "Five green bars fading downwards, no sixth bar?")

look("angles 0 / 30 / 45 / 60 / 90 / 135", function()
    local cx, cy, r = 240, 190, 80
    for _, d in ipairs({ 0, 30, 45, 60, 90, 135 }) do
        local a = d * pi / 180
        need(floor(cx - r * cos(a)), floor(cy - r * sin(a)),
             floor(cx + r * cos(a)), floor(cy + r * sin(a)),
             { width = 3, color = 0xFFD166, cap = "round" })
    end
end, "Six lines through one centre, smooth edges at every angle?")

look("set_z: right cross blue moved on top", function()
    need(40, 185, 200, 185, { width = 16, color = BLUE })
    need(120, 80, 120, 290, { width = 16, color = RED })
    local blue = need(280, 185, 440, 185, { width = 16, color = BLUE })
    need(360, 80, 360, 290, { width = 16, color = RED })
    blue:set_z(1000)
end, "Left cross red on top, right cross blue on top?")

look("set_visible: middle hidden", function()
    need(60, 100, 420, 100, { width = 10 })
    local mid = need(60, 180, 420, 180, { width = 10, color = RED })
    mid:set_visible(false)
    local bot = need(60, 260, 420, 260, { width = 10 })
    bot:set_visible(false)
    bot:set_visible(true)
end, "Top and bottom white lines only, nothing in the middle?")

look("set_style replaces the whole style", function()
    local dashed = { width = 12, color = RED, dash = { 10, 8 }, cap = "round" }
    local top = need(60, 110, 420, 110, dashed)
    local _, why = top:set_style({ width = 12 })
    if why then error("set_style -> " .. why) end
    need(60, 230, 420, 230, dashed)
end, "Top line white and solid, bottom line red and dashed?")

look("set_points: moved, and a refused move kept", function()
    local a = need(60, 90, 420, 90, { width = 8, color = 0x7FD4FF })
    local _, why = a:set_points(60, 170, 420, 170)
    if why then error("set_points -> " .. why) end
    local b = need(60, 260, 420, 260, { width = 8, color = 0xFFC46B })
    local _, why2 = b:set_points(0, 0, IMG_W - 1, IMG_H - 1)
    if why2 ~= "bbox_too_large" then error("oversize move -> " .. tostring(why2)) end
end, "Blue line in the middle, orange at the bottom, nothing at the top?")

local function poly(pts, style)
    local n = #pts // 2
    for i = 1, n do
        local j = i % n + 1
        need(pts[2 * i - 1], pts[2 * i], pts[2 * j - 1], pts[2 * j], style)
    end
end

look("triangle (3 lines) + rectangle (4 lines)", function()
    poly({ 125, 80, 220, 280, 30, 280 }, { width = 4, color = 0x7FD4FF, cap = "round" })
    poly({ 260, 90, 450, 90, 450, 270, 260, 270 }, { width = 4, color = 0xFFC46B })
end, "A closed triangle on the left, a closed rectangle on the right?")

look("five-point star (5 lines)", function()
    local cx, cy, r, p = 240, 190, 95, {}
    for i = 0, 4 do
        local a = -pi / 2 + i * 4 * pi / 5
        p[#p + 1] = floor(cx + r * cos(a))
        p[#p + 1] = floor(cy + r * sin(a))
    end
    poly(p, { width = 3, color = 0xFFD166, cap = "round" })
end, "A closed five-point star?")

look("zigzag (7 lines)", function()
    local st = { width = 5, color = 0xFF8FA3, cap = "round" }
    local x, y, up = 50, 260, true
    for _ = 1, 7 do
        local nx, ny = x + 55, up and 150 or 260
        need(x, y, nx, ny, st)
        x, y, up = nx, ny, not up
    end
end, "A zigzag of 7 strokes with round joins?")

-- There is no circle: 8 segments give an octagon.
look("dashed octagon (8 lines, no circle API)", function()
    local cx, cy, r, p = 240, 190, 100, {}
    for i = 0, 7 do
        p[#p + 1] = floor(cx + r * cos(i * pi / 4))
        p[#p + 1] = floor(cy + r * sin(i * pi / 4))
    end
    poly(p, { width = 3, color = GREY, dash = { 4, 4 } })
end, "A closed dashed octagon?")

-- ── Group: diag ──────────────────────────────────────────────────────
S:sync("diag", "pool clean: 8 free slots", function()
    local n = free_slots()
    return n == LINE_SLOTS, fmt("%d/%d free", n, LINE_SLOTS)
end)

-- One case per frame: n lines created, then COST_PASSES passes moving each
-- by 1 px. Prints ms per rebuild for the porting notes.
local COST_PASSES = 4
local COST_CASES = {
    { n = 1, x1 = 20, y1 = 80, x2 = 120, y2 = 80, w = 2 },
    { n = 8, x1 = 20, y1 = 80, x2 = 120, y2 = 80, w = 2 },
    { n = 8, x1 = 20, y1 = 80, x2 = 420, y2 = 80, w = 2 },
    { n = 1, x1 = 20, y1 = 60, x2 = 220, y2 = 210, w = 2 },
    { n = 2, x1 = 20, y1 = 60, x2 = 220, y2 = 210, w = 2 },
    { n = 1, x1 = 20, y1 = 60, x2 = 320, y2 = 260, w = 8 },
}
async("diag", "raster cost table (UART)",
    function() return { i = 0, out = {}, why = nil } end,
    function(st)
        st.i = st.i + 1
        local c = COST_CASES[st.i]
        local style = { width = c.w }
        for k = 1, c.n do
            local dy = (k - 1) * 28
            need(c.x1, c.y1 + dy, c.x2, c.y2 + dy, style)
        end
        local t0 = clock_ms()
        for p = 1, COST_PASSES do
            for k = 1, c.n do
                local dy = (k - 1) * 28 + p % 2
                local _, why = made[k]:set_points(c.x1, c.y1 + dy, c.x2, c.y2 + dy)
                st.why = st.why or why
            end
        end
        local dt = clock_ms() - t0
        free_all()
        local bytes, bw, bh = line_bytes(c.x1, c.y1, c.x2, c.y2, c.w)
        local rebuilds = COST_PASSES * c.n
        local line = fmt("n=%d bbox=%dx%d (%d B) w=%d: %d ms / %d rebuilds = %.2f ms each",
                         c.n, bw, bh, bytes, c.w, dt, rebuilds, dt / rebuilds)
        print("shape cost " .. line)
        st.out[#st.out + 1] = fmt("%.1f", dt / rebuilds)
        if st.i < #COST_CASES then return false end
        return true, st.why == nil,
               "ms/rebuild per case: " .. table.concat(st.out, " ")
               .. (st.why and (" refused: " .. st.why) or "")
    end,
    { fullscreen = true, prompt = "measuring raster cost" })

-- ── Group: manual ────────────────────────────────────────────────────
-- A line nobody references is destroyed at the next collection
-- (HANDLE-GC). Manual: dropping it on purpose makes smoke.py warn HANDLE-GC.
local function drop_a_line()
    Shape.line(20, 200, 120, 200)
end

S:sync("manual", "dropped handle frees its slot at collection", function()
    drop_a_line()
    collectgarbage("collect")
    collectgarbage("collect")
    local n = free_slots()
    return n == LINE_SLOTS, fmt("%d/%d free after collectgarbage", n, LINE_SLOTS)
end, { manual = true })

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    print(fmt("shape: %d slots, width max %d, budget %d B, bbox max %dx%d",
              LINE_SLOTS, LINE_WIDTH_MAX, LINE_POOL_BYTES, IMG_W, IMG_H))
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    S:tick()
end

function game_end()
    local held = #made
    free_all()
    S:summary(fmt("lines still held by tests: %d", held))
end
