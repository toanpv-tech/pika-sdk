-- test_led: the Led API (the light on the robot's back, driven by the body board).
--
-- Groups (suite order):
--   probe  : is_available in game_start and in a frame, the brightness default,
--            the shape of Led.stats() (automatic)
--   guard  : bad arguments return false and never raise; edge values are
--            accepted; out-of-range rgb is clamped (automatic)
--   mirror : get_brightness follows the last set_brightness that was queued,
--            rounded; a rejected call leaves it alone (automatic)
--   queue  : what Led.stats() counts: one push is sent after on_tick, SET_RGB
--            pushes in one frame merge into one slot, a 3 s set() storm and a
--            1.5 s flood of other ops lose nothing (automatic)
--   look   : the operator watches the LED on the robot's BACK and answers each
--            card: ENTER = looks right, RIGHT = looks wrong. Colours, presets,
--            blink, pulse, brightness steps.
--   diag   : stats dump with hints
--   limit  : MANUAL rows (RUN SUITE skips them). Rejected blink/pulse periods and
--            unknown presets, which smoke.py reports on purpose, and an 8-slot
--            queue overflow, which the robot logs as a drop.
--
-- Needs a robot for the LED itself and an operator for the look group. Calls
-- return a local result (queued or not), never a hardware acknowledgement, so
-- only the look group proves the light changed. When Led.is_available() is
-- false the behaviour tests SKIP. Every test leaves the LED off and the
-- brightness at 100, also on failure and on abort; so does game_end.

-- led_blink_min_ms / led_blink_max_ms, led_pulse_min_ms / led_pulse_max_ms in
-- contract/constraints.json.
local BLINK_MIN, BLINK_MAX = 333, 5000
local PULSE_MIN, PULSE_MAX = 100, 5000
-- Led.set_brightness range and default (contract/semantics.json).
local BRIGHT_MAX = 100
-- Commands queued per frame before a non-merging op is refused (no constraints
-- key; GAME_LED_RING_SZ in the engine's led_internal.h). SET_RGB pushes merge
-- into one slot; off/preset/blink/pulse/set_brightness each take one.
local QUEUE_SLOTS = 8

local REGULAR = "fonts/nunito-regular.ttf"
local CARD_PX = 18
local CARD_Y = 48            -- below the two fullscreen HUD lines
local WHERE = "Look at the LED on the robot's BACK\n(not the base light, not the screen)."

local fmt = string.format
local clock_ms = Timer.millis

-- Captured in game_start, checked by the probe group.
local start = { avail = nil, bright = nil }

-- ── Helpers ──────────────────────────────────────────────────────────

local function restore()
    Led.off()
    if Led.get_brightness() ~= BRIGHT_MAX then Led.set_brightness(BRIGHT_MAX) end
end

-- Result of f(...), or the string "raised" when it raised (Led never should).
local function try(f, ...)
    local ok, r = pcall(f, ...)
    if not ok then return "raised" end
    return r
end

-- Runs every probe in `cases` ({label, f, args...}) and expects `want` from each.
local function expect_all(want, cases)
    for _, c in ipairs(cases) do
        local r = try(c[2], table.unpack(c, 3))
        if r ~= want then return false, fmt("%s -> %s (want %s)", c[1], tostring(r), tostring(want)) end
    end
    return true, fmt("%d calls -> %s", #cases, tostring(want))
end

local function unavailable()
    if Led.is_available() then return nil end
    return "Led.is_available() = false"
end

-- Behaviour test wrapper: SKIP when the LED is not available, always restore.
local function led_test(fn)
    return function()
        local why = unavailable()
        if why then return "skip", why end
        local ok, pass, msg = pcall(fn)
        restore()
        if not ok then error(pass, 0) end
        return pass, msg
    end
end

-- Stats snapshot as plain numbers; nil when Led.stats() is not a table.
local function snap()
    local s = Led.stats()
    if type(s) ~= "table" then return nil end
    return { p = s.pushed_total, c = s.coalesced_total, d = s.dropped_total,
             s = s.sent_total, f = s.send_fail_total, b = s.brightness_pct }
end

local diff = { pushed = 0, coalesced = 0, dropped = 0, sent = 0, send_fail = 0 }
local function delta(before)
    local now = snap()
    if not before or not now then return nil end
    diff.pushed    = now.p - before.p
    diff.coalesced = now.c - before.c
    diff.dropped   = now.d - before.d
    diff.sent      = now.s - before.s
    diff.send_fail = now.f - before.f
    return diff
end

local function fmt_diff(d)
    return fmt("pushed=%d coal=%d drop=%d sent=%d sfail=%d",
               d.pushed, d.coalesced, d.dropped, d.sent, d.send_fail)
end

-- Every queued command leaves the head once per frame: sent or send-failed.
local function accounted(d)
    return d.sent + d.send_fail == d.pushed - d.coalesced - d.dropped
end

-- ── Look support: one Text card + a small LED driver advanced in on_tick ──
local card
local drv = { kind = nil, t0 = 0, i = 0 }
local RAMP = { 100, 60, 20, 0 }
local RAMP_STEP_MS = 700
local PULSE_EVERY_MS = 2000
local OFF_CYCLE_MS = 3000     -- white 1 s, off 2 s

local function drop_card()
    if card then card:destroy(); card = nil end
end

local function stop_look()
    drv.kind = nil
    drop_card()
    restore()
end

local function show_card(text)
    drop_card()
    local t, err = Text.new(WHERE .. "\n\n" .. text, 16, CARD_Y)
    if not t then error("Text.new: " .. tostring(err)) end
    card = t
    local _, ferr = t:set_font(REGULAR, CARD_PX)
    if ferr then error("set_font: " .. ferr) end
end

local function drive(now)
    local k = drv.kind
    if not k then return end
    local t = now - drv.t0
    if k == "ramp" then
        local i = (t // RAMP_STEP_MS) % #RAMP + 1
        if i ~= drv.i then drv.i = i; Led.set_brightness(RAMP[i]) end
    elseif k == "pulse" then
        local i = t // PULSE_EVERY_MS
        if i ~= drv.i then drv.i = i; Led.pulse(255, 0, 255, 800) end
    elseif k == "off" then
        local on = (t % OFF_CYCLE_MS) < 1000
        if on ~= drv.on then
            drv.on = on
            if on then Led.set(255, 255, 255) else Led.off() end
        end
    end
end

local function start_drive(kind)
    drv.kind, drv.t0, drv.i, drv.on = kind, clock_ms(), -1, nil
end

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "led", title = "LED TEST",
    font = REGULAR, font_px = 14,
    groups = {
        probe  = { label = "STATE PROBE", what = "availability, default, stats shape" },
        guard  = { label = "ARGUMENTS",   what = "bad args -> false, edges accepted" },
        mirror = { label = "BRIGHTNESS",  what = "get_brightness follows set" },
        queue  = { label = "QUEUE",       what = "push / merge / send counters" },
        look   = { label = "LOOK",        what = "operator watches the back LED" },
        diag   = { label = "DIAGNOSTICS", what = "stats dump + hints" },
        limit  = { label = "LIMITS",      what = "rejections smoke flags (manual)" },
    },
    status = function()
        local s = Led.stats()
        if type(s) ~= "table" then return "led stats: n/a" end
        return fmt("led push=%d coal=%d drop=%d sent=%d sfail=%d bright=%d",
                   s.pushed_total, s.coalesced_total, s.dropped_total,
                   s.sent_total, s.send_fail_total, s.brightness_pct)
    end,
    on_abort = stop_look,
})

-- ── Group: probe ─────────────────────────────────────────────────────
-- The engine marks the game running only after game_start returned.
S:sync("probe", "is_available() false in game_start", function()
    return start.avail == false, "game_start saw " .. tostring(start.avail)
end)

S:sync("probe", "is_available() true in a frame", function()
    local v = Led.is_available()
    return v == true, "on_tick sees " .. tostring(v)
end)

S:sync("probe", "get_brightness() = 100 at game start", function()
    return start.bright == BRIGHT_MAX and math.type(start.bright) == "integer",
           fmt("game_start saw %s (%s)", tostring(start.bright), tostring(math.type(start.bright)))
end)

S:sync("probe", "stats(): 6 integer fields >= 0", function()
    local s = Led.stats()
    if type(s) ~= "table" then return false, "stats() -> " .. tostring(s) end
    for _, k in ipairs({ "pushed_total", "coalesced_total", "dropped_total",
                         "sent_total", "send_fail_total", "brightness_pct" }) do
        local v = s[k]
        if math.type(v) ~= "integer" or v < 0 then
            return false, fmt("%s = %s", k, tostring(v))
        end
    end
    return true, fmt("pushed=%d sent=%d brightness_pct=%d",
                     s.pushed_total, s.sent_total, s.brightness_pct)
end)

S:sync("probe", "stats().brightness_pct = get_brightness()", function()
    local s, b = Led.stats(), Led.get_brightness()
    if type(s) ~= "table" then return false, "stats() -> " .. tostring(s) end
    return s.brightness_pct == b, fmt("stats=%s get=%s", tostring(s.brightness_pct), tostring(b))
end)

-- ── Group: guard ─────────────────────────────────────────────────────
-- Robot peripherals never raise. A numeric string is a number to the engine
-- (Led.set("10", 0, 0) is valid), so the bad values here are tables, booleans,
-- words and nil.
S:sync("guard", "set: non-number r/g/b -> false", led_test(function()
    return expect_all(false, {
        { "set('red', 0, 0)", Led.set, "red", 0, 0 },
        { "set(0, {}, 0)", Led.set, 0, {}, 0 },
        { "set(0, 0, true)", Led.set, 0, 0, true },
        { "set(0, 0)", Led.set, 0, 0 },
    })
end))

S:sync("guard", "set: out-of-range rgb clamps -> true", led_test(function()
    return expect_all(true, {
        { "set(9999, -50, 256)", Led.set, 9999, -50, 256 },
        { "set(127.6, 0.4, 0)", Led.set, 127.6, 0.4, 0 },
    })
end))

-- 6 presets + the restoring off() = 7 commands, inside the 8-slot frame queue.
S:sync("guard", "preset: all 6 names -> true", led_test(function()
    return expect_all(true, {
        { "user_talk", Led.preset, "user_talk" },
        { "conv_processing", Led.preset, "conv_processing" },
        { "robot_talking", Led.preset, "robot_talking" },
        { "warm_white", Led.preset, "warm_white" },
        { "light_blue", Led.preset, "light_blue" },
        { "dark_blue", Led.preset, "dark_blue" },
    })
end))

S:sync("guard", "blink: non-number r/g/b -> false", led_test(function()
    return expect_all(false, {
        { "blink('red', 0, 0, 500)", Led.blink, "red", 0, 0, 500 },
        { "blink(0, {}, 0, 500)", Led.blink, 0, {}, 0, 500 },
        { "blink(0, 0, nil, 500)", Led.blink, 0, 0, nil, 500 },
    })
end))

S:sync("guard", "blink: 333 and 5000 ms -> true", led_test(function()
    return expect_all(true, {
        { "blink(.., " .. BLINK_MIN .. ")", Led.blink, 255, 0, 0, BLINK_MIN },
        { "blink(.., " .. BLINK_MAX .. ")", Led.blink, 255, 0, 0, BLINK_MAX },
    })
end))

S:sync("guard", "pulse: non-number r/g/b -> false", led_test(function()
    return expect_all(false, {
        { "pulse('red', 0, 0, 500)", Led.pulse, "red", 0, 0, 500 },
        { "pulse(0, {}, 0, 500)", Led.pulse, 0, {}, 0, 500 },
        { "pulse(0, 0, nil, 500)", Led.pulse, 0, 0, nil, 500 },
    })
end))

S:sync("guard", "pulse: 100 and 5000 ms -> true", led_test(function()
    return expect_all(true, {
        { "pulse(.., " .. PULSE_MIN .. ")", Led.pulse, 0, 255, 0, PULSE_MIN },
        { "pulse(.., " .. PULSE_MAX .. ")", Led.pulse, 0, 255, 0, PULSE_MAX },
    })
end))

S:sync("guard", "set_brightness: 101/-1/'dim'/nil -> false", led_test(function()
    return expect_all(false, {
        { "set_brightness(101)", Led.set_brightness, BRIGHT_MAX + 1 },
        { "set_brightness(-1)", Led.set_brightness, -1 },
        { "set_brightness('dim')", Led.set_brightness, "dim" },
        { "set_brightness(nil)", Led.set_brightness, nil },
        { "set_brightness({})", Led.set_brightness, {} },
    })
end))

S:sync("guard", "set_brightness: 0 and 100 -> true", led_test(function()
    return expect_all(true, {
        { "set_brightness(0)", Led.set_brightness, 0 },
        { "set_brightness(100)", Led.set_brightness, BRIGHT_MAX },
    })
end))

-- NaN is not inside 0..100. The engine's range check compares with < and >,
-- which NaN passes, so this row shows whether the guard catches it.
S:sync("guard", "set_brightness(NaN) -> false", led_test(function()
    local r = try(Led.set_brightness, 0 / 0)
    return r == false, fmt("-> %s, get_brightness=%s", tostring(r), tostring(Led.get_brightness()))
end))

S:sync("guard", "off() -> true", led_test(function()
    local r = try(Led.off)
    return r == true, "-> " .. tostring(r)
end))

-- ── Group: mirror ────────────────────────────────────────────────────
S:sync("mirror", "set_brightness(50) -> get 50, stats 50", led_test(function()
    if Led.set_brightness(50) ~= true then return false, "set_brightness(50) -> false" end
    local b, s = Led.get_brightness(), Led.stats()
    local sb = type(s) == "table" and s.brightness_pct or nil
    return b == 50 and sb == 50, fmt("get=%s stats=%s", tostring(b), tostring(sb))
end))

S:sync("mirror", "fractions round: 33.6 -> 34, 33.4 -> 33", led_test(function()
    Led.set_brightness(33.6)
    local a = Led.get_brightness()
    Led.set_brightness(33.4)
    local b = Led.get_brightness()
    return a == 34 and b == 33, fmt("33.6 -> %s, 33.4 -> %s", tostring(a), tostring(b))
end))

S:sync("mirror", "rejected set keeps the last value", led_test(function()
    Led.set_brightness(40)
    local r = Led.set_brightness(BRIGHT_MAX + 1)
    local b = Led.get_brightness()
    return r == false and b == 40, fmt("set(101) -> %s, get=%s (want 40)", tostring(r), tostring(b))
end))

-- ── Group: queue ─────────────────────────────────────────────────────
-- Commands are queued during the frame and sent after on_tick, so the counters
-- move one frame later.
S:async("queue", "one set() is sent after on_tick",
    function()
        local why = unavailable()
        if why then return { skip = why } end
        local st = { before = snap() }
        st.ok = Led.set(0, 0, 64)
        return st
    end,
    function(st)
        if st.skip then return true, "skip", st.skip end
        local d = delta(st.before)
        restore()
        if not st.ok then return true, false, "set() -> false" end
        if not d then return true, false, "stats() -> " .. tostring((Led.stats())) end
        return true, d.pushed == 1 and d.sent + d.send_fail == 1 and d.send_fail == 0, fmt_diff(d)
    end)

S:sync("queue", "20 set() in one frame merge into 1 slot", led_test(function()
    local before = snap()
    for i = 1, 20 do Led.set(i * 10, 0, 0) end
    local d = delta(before)
    if not d then return false, "stats() -> " .. tostring((Led.stats())) end
    return d.pushed == 20 and d.coalesced == 19 and d.dropped == 0, fmt_diff(d)
end))

-- 12 set() per frame for 3 s on a slow blue triangle (no flashing). Only the
-- last set() of a frame is sent, the rest merge.
local STORM_MS, STORM_PER_TICK = 3000, 12
S:async("queue", "set() storm 12x/frame, 3 s",
    function()
        local why = unavailable()
        if why then return { skip = why } end
        return { before = snap(), t_end = clock_ms() + STORM_MS, ticks = 0, k = 0, phase = "drive" }
    end,
    function(st)
        if st.skip then return true, "skip", st.skip end
        if st.phase == "drive" then
            local k = st.k
            for _ = 1, STORM_PER_TICK do
                k = k + 1
                local v = k % 510
                if v > 255 then v = 510 - v end
                Led.set(0, 0, v)
            end
            st.k = k
            st.ticks = st.ticks + 1
            if clock_ms() >= st.t_end then st.phase = "check" end
            return false
        end
        local d = delta(st.before)
        restore()
        if not d then return true, false, "stats() -> " .. tostring((Led.stats())) end
        local pct = d.pushed > 0 and (d.coalesced * 100 // d.pushed) or 0
        local msg = fmt("ticks=%d %s merged=%d%%", st.ticks, fmt_diff(d), pct)
        if d.dropped > 0 or d.send_fail > 0 or d.sent == 0 then return true, false, msg end
        return true, accounted(d) and pct >= 70, msg
    end, { settle_ms = 1500 })

-- Two non-merging ops per frame for 1.5 s. preset warm_white + brightness 100
-- keep the light steady (alternating colours every frame would flash at 15 Hz).
local FLOOD_MS = 1500
S:async("queue", "preset + brightness flood 2/frame, 1.5 s",
    function()
        local why = unavailable()
        if why then return { skip = why } end
        return { before = snap(), t_end = clock_ms() + FLOOD_MS, ticks = 0, refused = 0 }
    end,
    function(st)
        if st.skip then return true, "skip", st.skip end
        if clock_ms() < st.t_end then
            if not Led.preset("warm_white") then st.refused = st.refused + 1 end
            if not Led.set_brightness(BRIGHT_MAX) then st.refused = st.refused + 1 end
            st.ticks = st.ticks + 1
            return false
        end
        local d = delta(st.before)
        restore()
        if not d then return true, false, "stats() -> " .. tostring((Led.stats())) end
        local msg = fmt("ticks=%d refused=%d %s", st.ticks, st.refused, fmt_diff(d))
        return true, st.refused == 0 and d.dropped == 0 and d.send_fail == 0
                     and d.coalesced == 0 and accounted(d), msg
    end, { settle_ms = 1500 })

-- ── Group: look (operator) ───────────────────────────────────────────
-- show() starts the light and returns stop_look, which testkit runs once the
-- operator answered. When the LED is unavailable show() sets the verdict to
-- "skip" itself: testkit's look step returns st.verdict and st.msg as given.
local function look(name, question, text, start_fn, o)
    S:look("look", name, function(st)
        local why = unavailable()
        if why then st.verdict, st.msg = "skip", why; return nil end
        show_card(text)
        start_fn()
        return stop_look
    end, question, o)
end

for _, c in ipairs({
    { "red",   255, 0, 0 },     { "green", 0, 255, 0 },
    { "blue",  0, 0, 255 },     { "white", 255, 255, 255 },
}) do
    local up = string.upper(c[1])
    look("set " .. c[1], "Back LED solid " .. up .. "?",
         fmt("Led.set(%d, %d, %d)\nExpected: solid %s, steady.", c[2], c[3], c[4], up),
         function() Led.set(c[2], c[3], c[4]) end)
end

look("set(9999, -50, 256) clamps", "Back LED solid MAGENTA?",
     "Led.set(9999, -50, 256) clamps to 255, 0, 255.\nExpected: solid magenta (pink-purple).",
     function() Led.set(9999, -50, 256) end)

look("off()", "White 1 s, then dark 2 s?",
     "Led.set(white), then Led.off() after 1 s.\nExpected: white 1 s, fully dark 2 s, repeating.",
     function() start_drive("off") end)

-- Colours of the game presets on the body board (led_ctrl.cpp kGamePresetRgb).
for _, p in ipairs({
    { "user_talk", "BLUE" }, { "conv_processing", "PURPLE (dim)" },
    { "robot_talking", "YELLOW" }, { "warm_white", "WARM WHITE" },
    { "light_blue", "LIGHT BLUE" }, { "dark_blue", "DARK BLUE" },
}) do
    look("preset " .. p[1], "Back LED " .. p[2] .. "?",
         fmt("Led.preset('%s')\nExpected: solid %s, steady.", p[1], string.lower(p[2])),
         function() Led.preset(p[1]) end)
end

-- The body board toggles every period_ms: 500 ms = 0.5 s on, 0.5 s off.
look("blink red 500 ms", "RED 0.5 s on / 0.5 s off?",
     "Led.blink(255, 0, 0, 500)\nExpected: red on 0.5 s, off 0.5 s, repeating.",
     function() Led.blink(255, 0, 0, 500) end)

look("blink green 1000 ms", "GREEN 1 s on / 1 s off?",
     "Led.blink(0, 255, 0, 1000)\nExpected: green on 1 s, off 1 s, repeating.",
     function() Led.blink(0, 255, 0, 1000) end)

look("pulse purple 800 ms", "PURPLE 0.8 s flash, every 2 s?",
     "Led.pulse(255, 0, 255, 800), sent every 2 s.\nExpected: purple for 0.8 s then dark,\nagain every 2 s.",
     function() start_drive("pulse") end)

look("brightness 100/60/20/0", "WHITE dims in steps to dark?",
     "Led.set(white) + set_brightness 100, 60, 20, 0,\n0.7 s each. Expected: white dimming in\nthree steps, then dark, repeating.",
     function() Led.set(255, 255, 255); start_drive("ramp") end)

-- ── Group: diag ──────────────────────────────────────────────────────
S:sync("diag", "stats dump + hints", function()
    local s = Led.stats()
    if type(s) ~= "table" then return false, "stats() -> " .. tostring(s) end
    print(fmt("led stats: pushed=%d coal=%d drop=%d sent=%d sfail=%d brightness=%d",
              s.pushed_total, s.coalesced_total, s.dropped_total,
              s.sent_total, s.send_fail_total, s.brightness_pct))
    if s.pushed_total == 0 then
        print("led DIAG: pushed=0 -> no Led call was queued this session")
    end
    if s.pushed_total > 0 and s.sent_total == 0 then
        print("led DIAG: pushed but never sent -> the link to the body board fails")
    end
    if s.send_fail_total > 0 then
        print("led DIAG: send_fail > 0 -> commands did not reach the body board (link busy or down)")
    end
    if s.dropped_total > 0 then
        print("led DIAG: dropped > 0 -> more than 8 non-merging commands in one frame")
    end
    return true, fmt("pushed=%d sent=%d drop=%d sfail=%d",
                     s.pushed_total, s.sent_total, s.dropped_total, s.send_fail_total)
end)

-- ── Group: limit (manual) ────────────────────────────────────────────
-- smoke.py reports a rejected blink/pulse period as an ERROR and an unknown
-- preset as a WARN (it flags them in games), so these contract checks stay out
-- of RUN SUITE and the smoke gate. Run them by hand on the robot.
S:sync("limit", "blink 332 / 5001 / 'fast' ms -> false", led_test(function()
    return expect_all(false, {
        { "blink(.., 332)", Led.blink, 255, 0, 0, BLINK_MIN - 1 },
        { "blink(.., 5001)", Led.blink, 255, 0, 0, BLINK_MAX + 1 },
        { "blink(.., 'fast')", Led.blink, 255, 0, 0, "fast" },
        { "blink(.., nil)", Led.blink, 255, 0, 0 },
    })
end), { manual = true })

S:sync("limit", "pulse 99 / 5001 / 'fast' ms -> false", led_test(function()
    return expect_all(false, {
        { "pulse(.., 99)", Led.pulse, 0, 255, 0, PULSE_MIN - 1 },
        { "pulse(.., 5001)", Led.pulse, 0, 255, 0, PULSE_MAX + 1 },
        { "pulse(.., 'fast')", Led.pulse, 0, 255, 0, "fast" },
        { "pulse(.., nil)", Led.pulse, 0, 255, 0 },
    })
end), { manual = true })

-- System-only states (firmware update, alarm, ...) have no preset name.
S:sync("limit", "preset unknown / number / system / case -> false", led_test(function()
    return expect_all(false, {
        { "preset('does_not_exist')", Led.preset, "does_not_exist" },
        { "preset(3)", Led.preset, 3 },
        { "preset('fw_updating')", Led.preset, "fw_updating" },
        { "preset('USER_TALK')", Led.preset, "USER_TALK" },
        { "preset(nil)", Led.preset, nil },
    })
end), { manual = true })

-- Manual: overflows the frame queue on purpose; the robot logs "led ring full"
-- and game.stop reports the drop. Nine off() leave the LED off either way.
S:sync("limit", "9 off() in one frame: 9th -> false, drop +1", led_test(function()
    local before = snap()
    local r = {}
    for i = 1, QUEUE_SLOTS + 1 do r[i] = Led.off() end
    local d = delta(before)
    for i = 1, QUEUE_SLOTS do
        if r[i] ~= true then return false, fmt("off() #%d -> %s", i, tostring(r[i])) end
    end
    if r[QUEUE_SLOTS + 1] ~= false then
        return false, fmt("off() #%d -> %s (want false)", QUEUE_SLOTS + 1, tostring(r[QUEUE_SLOTS + 1]))
    end
    if not d then return false, "stats() -> " .. tostring((Led.stats())) end
    return d.dropped == 1, fmt_diff(d)
end), { manual = true })

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start(_params)
    -- Read only: a command queued here would go out before the session is live.
    start.avail = Led.is_available()
    start.bright = Led.get_brightness()
    print(fmt("led: game_start is_available=%s brightness=%s",
              tostring(start.avail), tostring(start.bright)))
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    drive(clock_ms())
    S:tick()
end

function game_end()
    drv.kind = nil
    drop_card()
    restore()
    local s = Led.stats()
    if type(s) == "table" then
        S:summary(fmt("stats pushed=%d coal=%d drop=%d sent=%d sfail=%d brightness=%d",
                      s.pushed_total, s.coalesced_total, s.dropped_total,
                      s.sent_total, s.send_fail_total, s.brightness_pct))
    else
        S:summary("stats n/a")
    end
end
