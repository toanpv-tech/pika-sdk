-- test_anim: the Anim API (GIF and MJPEG playback).
--
-- Groups (suite order):
--   probe  : what Anim.new returns, state before play
--   guard  : bad arguments raise (unknown extension, unsafe path, non-anim
--            self, fractional position); runtime failures return nil, msg
--            (missing file, a file that is not a GIF); calls after destroy
--   state  : the play / pause / resume / stop state machine through
--            is_playing, and the one-playing-Anim rule (facts.anim_concurrent)
--   timing : async, on the clock: a one-shot ends on its own, a loop does
--            not, pause and play-after-pause continue from the current frame,
--            stop rewinds, MJPEG ends and loops
--   look   : the operator judges the screen: GIF and MJPEG motion, pause,
--            stop, hide/show, move, one Anim at a time, black canvas behind
--            transparent pixels, a one-shot holding its last frame.
--            ENTER = looks right, RIGHT = looks wrong.
--
-- Timing windows: count.gif is 12 frames x 150 ms (one pass about 1.8 s); the
-- engine advances at most one frame per engine frame (30 ms) and floors frame
-- delays at anim_min_frame_ms. MJPEG has no per-frame delay: one frame per
-- engine frame. The windows are wide on purpose: they separate "continued"
-- from "restarted", not milliseconds.
--
-- Every test destroys the Anims and sprites it made (free_all), also on
-- failure and on abort. Assets (assets/, ~26 KB): count.gif (128x96),
-- count.mjpeg (128x96, 10 frames), trans.gif (64x64, transparent background),
-- junk.gif (text with a .gif name).

-- anim_max_file_bytes and anim_min_frame_ms in contract/constraints.json:
-- every asset here is far below the first; count.gif delays are above the second.
local GIF, GIF_FRAMES, GIF_FRAME_MS = "assets/count.gif", 12, 150
local GIF_PASS_MS = GIF_FRAMES * GIF_FRAME_MS      -- 1800
local MJPEG, MJPEG_FRAMES = "assets/count.mjpeg", 10
local TRANS, JUNK = "assets/trans.gif", "assets/junk.gif"
local REGULAR = "fonts/nunito-regular.ttf"

-- Timing windows (ms).
local ONESHOT_MIN, ONESHOT_MAX = 1200, 4000        -- full GIF pass
local PAUSE_AT, PAUSE_FOR = 900, 1000              -- pause half-way, hold 1 s
local REST_MIN, REST_MAX = 300, 1350               -- rest of the pass after a continue
local LOOP_CHECK_MS = 2 * GIF_PASS_MS + 400        -- a loop still plays here
local MJPEG_MAX = 3000                             -- 10 frames, one per engine frame

local fmt = string.format
local clock_ms = Timer.millis
local TOP = 48                   -- below the two fullscreen HUD lines
local CX, CY = 176, 112          -- a 128x96 canvas centred on the screen

-- Objects made by the running test; free_all() destroys them. Keeping them
-- here also stops the GC from collecting them (HANDLE-GC).
local made = {}
-- Timed actions of the running look test: { at = ms, fn = f }.
local plan = {}

local function keep(o) made[#made + 1] = o; return o end

local function free_all()
    for i = #plan, 1, -1 do plan[i] = nil end
    for i = #made, 1, -1 do
        made[i]:destroy()
        made[i] = nil
    end
end

local function after(ms, fn) plan[#plan + 1] = { at = clock_ms() + ms, fn = fn } end

local function run_plan()
    if #plan == 0 then return end
    local now = clock_ms()
    local i = 1
    while i <= #plan do
        local p = plan[i]
        if now - p.at >= 0 then
            table.remove(plan, i)
            local ok, err = pcall(p.fn)
            if not ok then print("anim: plan error: " .. tostring(err)) end
        else
            i = i + 1
        end
    end
end

local function new_anim(path, x, y)
    local a, err = Anim.new(path)
    if not a then error("Anim.new(" .. path .. "): " .. tostring(err)) end
    keep(a)
    if x then a:set_pos(x, y) end
    return a
end

local function caption(str)
    local t, err = Text.new(str, 8, 290)
    if not t then error("Text.new: " .. tostring(err)) end
    keep(t)
    t:set_font(REGULAR, 14)
    return t
end

local function with_objs(fn)
    return function()
        local ok, pass, msg = pcall(fn)
        free_all()
        if not ok then error(pass, 0) end
        return pass, msg
    end
end

-- true when f(...) raises; a handle it returned instead is destroyed.
local function raises(f, ...)
    local ok, r = pcall(f, ...)
    if ok and type(r) ~= "nil" and type(r) ~= "boolean" then pcall(function() r:destroy() end) end
    return not ok, ok and "returned instead of raising" or "raised"
end

local function fails(what, a, err)
    if a then
        keep(a)
        return false, what .. " returned an anim"
    end
    return type(err) == "string", fmt("%s -> nil, %s", what, tostring(err))
end

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "anim", title = "ANIM TEST",
    font = REGULAR, font_px = 14,
    groups = {
        probe  = { label = "PROBE",   what = "Anim.new result, state before play" },
        guard  = { label = "GUARDS",  what = "bad args raise, failures nil/false" },
        state  = { label = "STATE",   what = "play/pause/resume/stop, one at a time" },
        timing = { label = "TIMING",  what = "one-shot ends, loop, continue, rewind" },
        look   = { label = "LOOK",    what = "operator checks the screen" },
    },
    status = function() return fmt("objects held by this test: %d", #made) end,
    on_abort = free_all,
})

-- ── Group: probe ─────────────────────────────────────────────────────
S:sync("probe", "Anim.new(gif) -> anim, not playing", with_objs(function()
    local a = new_anim(GIF)
    local p = a:is_playing()
    return p == false, "is_playing -> " .. tostring(p)
end))

S:sync("probe", "Anim.new(mjpeg) -> anim, not playing", with_objs(function()
    local a = new_anim(MJPEG)
    local p = a:is_playing()
    return p == false, "is_playing -> " .. tostring(p)
end))

S:sync("probe", "handle has every method", with_objs(function()
    local a = new_anim(GIF)
    for _, m in ipairs({ "play", "pause", "resume", "stop", "is_playing", "set_pos", "set_visible", "destroy" }) do
        if type(a[m]) ~= "function" then return false, m .. " is " .. type(a[m]) end
    end
    return true, "8 methods"
end))

-- ── Group: guard ─────────────────────────────────────────────────────
-- Non-string probes pass a table: luaL_checkstring converts a number.
S:sync("guard", "Anim.new(table) raises", function()
    return raises(Anim.new, {})
end)

S:sync("guard", "unknown extension raises", function()
    for _, p in ipairs({ "assets/count.bmp", "assets/count", "assets/count.gif.txt", "assets/count.png" }) do
        if not raises(Anim.new, p) then return false, p .. " did not raise" end
    end
    return true, ".bmp, none, .gif.txt, .png raised"
end)

S:sync("guard", "unsafe path raises", function()
    for _, p in ipairs({ "../count.gif", "/sd/count.gif", "assets//count.gif", "assets/./count.gif" }) do
        if not raises(Anim.new, p) then return false, p .. " did not raise" end
    end
    return true, "../, absolute, //, ./ raised"
end)

S:sync("guard", "missing file -> nil, msg", with_objs(function()
    return fails("missing.gif", Anim.new("assets/missing.gif"))
end))

S:sync("guard", "extension is case-insensitive (.GIF .MJPG .Mjpeg)", with_objs(function()
    for _, p in ipairs({ "assets/missing.GIF", "assets/missing.MJPG", "assets/missing.Mjpeg" }) do
        local ok, a, err = pcall(Anim.new, p)
        if not ok then return false, p .. " raised: " .. tostring(a) end
        if a then keep(a); return false, p .. " returned an anim" end
        if type(err) ~= "string" then return false, p .. " -> nil without a message" end
    end
    return true, "3 spellings accepted, missing file -> nil, msg"
end))

-- The codec opens the file in Anim.new (anim.c anim_create -> codec open), so
-- a file that is not a GIF fails there, not at play.
S:sync("guard", "a .gif that is not a GIF -> nil, msg", with_objs(function()
    return fails("junk.gif", Anim.new(JUNK))
end))

-- Methods are called through a real handle's metatable with a table as self.
local function non_anim_self(methods)
    return with_objs(function()
        local a = new_anim(GIF)
        for _, m in ipairs(methods) do
            if not raises(a[m], {}, 0, 0) then return false, m .. "({}) did not raise" end
        end
        return true, table.concat(methods, ", ") .. " raised"
    end)
end

S:sync("guard", "play / pause / resume / stop / is_playing on a non-anim raise",
    non_anim_self({ "play", "pause", "resume", "stop", "is_playing" }))

S:sync("guard", "set_pos / set_visible on a non-anim raise",
    non_anim_self({ "set_pos", "set_visible" }))

S:sync("guard", "set_pos fractional raises", with_objs(function()
    local a = new_anim(GIF)
    return raises(a.set_pos, a, 10.5, 0)
end))

S:sync("guard", "destroy twice: no raise", function()
    local a, err = Anim.new(GIF)
    if not a then return false, "Anim.new: " .. tostring(err) end
    a:destroy()
    local ok = pcall(a.destroy, a)
    return ok, ok and "second destroy ok" or "second destroy raised"
end)

S:sync("guard", "after destroy: play -> false, others no-op", function()
    local a, err = Anim.new(GIF)
    if not a then return false, "Anim.new: " .. tostring(err) end
    a:destroy()
    local p = a:play(true)
    local ip = a:is_playing()
    for _, c in ipairs({ { "pause" }, { "resume" }, { "stop" }, { "set_pos", 1, 2 }, { "set_visible", true } }) do
        local ok, e = pcall(a[c[1]], a, c[2], c[3])
        if not ok then return false, c[1] .. " raised: " .. tostring(e) end
    end
    return p == false and ip == false, fmt("play -> %s, is_playing -> %s", tostring(p), tostring(ip))
end)

-- ── Group: state (sync) ──────────────────────────────────────────────
S:sync("state", "play() -> true, playing; stop -> not playing", with_objs(function()
    local a = new_anim(GIF, CX, CY)
    local r = a:play()
    local p1 = a:is_playing()
    a:stop()
    local p2 = a:is_playing()
    return r == true and p1 == true and p2 == false,
           fmt("play -> %s, playing %s, after stop %s", tostring(r), tostring(p1), tostring(p2))
end))

S:sync("state", "play(true), play{loop=true}, play{}, play(false) -> true", with_objs(function()
    local a = new_anim(GIF, CX, CY)
    local forms = { { true }, { { loop = true } }, { {} }, { false } }
    for i, f in ipairs(forms) do
        a:stop()
        local r = a:play(f[1])
        if r ~= true or not a:is_playing() then return false, fmt("form %d -> %s", i, tostring(r)) end
    end
    return true, "4 forms play"
end))

S:sync("state", "pause -> not playing, resume -> playing", with_objs(function()
    local a = new_anim(GIF, CX, CY)
    a:play(true)
    a:pause()
    local p1 = a:is_playing()
    a:resume()
    local p2 = a:is_playing()
    return p1 == false and p2 == true, fmt("paused %s, resumed %s", tostring(p1), tostring(p2))
end))

S:sync("state", "pause / stop before any play: no raise, not playing", with_objs(function()
    local a = new_anim(GIF, CX, CY)
    a:pause()
    a:stop()
    local p = a:is_playing()
    return p == false, "is_playing -> " .. tostring(p)
end))

-- resume continues a pause only; after stop the Anim has ended (anim.c anim_resume).
S:sync("state", "stop then resume: stays stopped", with_objs(function()
    local a = new_anim(GIF, CX, CY)
    a:play(true)
    a:stop()
    a:resume()
    local p = a:is_playing()
    return p == false, "is_playing after stop + resume -> " .. tostring(p)
end))

S:sync("state", "B:play stops A (one playing Anim)", with_objs(function()
    local a = new_anim(GIF, 40, CY)
    local b = new_anim(MJPEG, 300, CY)
    a:play(true)
    b:play(true)
    local pa, pb = a:is_playing(), b:is_playing()
    return pa == false and pb == true, fmt("A %s, B %s", tostring(pa), tostring(pb))
end))

S:sync("state", "B:stop does not restart A", with_objs(function()
    local a = new_anim(GIF, 40, CY)
    local b = new_anim(MJPEG, 300, CY)
    a:play(true)
    b:play(true)
    b:stop()
    local pa, pb = a:is_playing(), b:is_playing()
    return pa == false and pb == false, fmt("A %s, B %s", tostring(pa), tostring(pb))
end))

-- A paused A is still the active Anim, so B:play stops (rewinds) it and a
-- later A:resume does nothing (anim.c anim_play -> anim_stop(s_active)).
S:sync("state", "paused A is stopped by B:play; A:resume no-op", with_objs(function()
    local a = new_anim(GIF, 40, CY)
    local b = new_anim(MJPEG, 300, CY)
    a:play(true)
    a:pause()
    b:play(true)
    a:resume()
    local pa, pb = a:is_playing(), b:is_playing()
    return pa == false and pb == true, fmt("A %s, B %s", tostring(pa), tostring(pb))
end))

S:sync("state", "Anim.new stops nothing", with_objs(function()
    local a = new_anim(GIF, CX, CY)
    a:play(true)
    new_anim(MJPEG)
    local p = a:is_playing()
    return p == true, "A playing after another Anim.new -> " .. tostring(p)
end))

S:sync("state", "destroy the playing Anim, then play another", with_objs(function()
    local a = new_anim(GIF, 40, CY)
    local b = new_anim(MJPEG, 300, CY)
    a:play(true)
    a:destroy()
    local pa = a:is_playing()
    local r = b:play(true)
    local pb = b:is_playing()
    return pa == false and r == true and pb == true,
           fmt("destroyed A playing %s; B play -> %s, playing %s", tostring(pa), tostring(r), tostring(pb))
end))

-- ── Group: timing (async) ────────────────────────────────────────────
-- arm() builds and starts; step(st, elapsed_ms) -> done, pass, msg.
-- Objects are freed when the test ends or raises.
local function timed(name, arm, step)
    S:async("timing", name,
        function()
            local ok, st = pcall(arm)
            if not ok then free_all(); error(st, 0) end
            st.t0 = clock_ms()
            return st
        end,
        function(st)
            local ok, done, pass, msg = pcall(step, st, clock_ms() - st.t0)
            if not ok then free_all(); error(done, 0) end
            if done then free_all() end
            return done, pass, msg
        end)
end

local function play_gif(loop)
    local a = new_anim(GIF, CX, CY)
    return { a = a, ok = a:play(loop) }
end

timed("GIF one-shot ends on its own",
    function() return play_gif(false) end,
    function(st, el)
        if not st.ok then return true, false, "play() -> false" end
        if not st.a:is_playing() then
            return true, el >= ONESHOT_MIN and el <= ONESHOT_MAX,
                   fmt("ended after %d ms (window %d..%d)", el, ONESHOT_MIN, ONESHOT_MAX)
        end
        if el > ONESHOT_MAX then return true, false, fmt("still playing after %d ms", el) end
        return false
    end)

timed("GIF loop keeps playing past two passes",
    function() return play_gif(true) end,
    function(st, el)
        if not st.ok then return true, false, "play(true) -> false" end
        if not st.a:is_playing() then return true, false, fmt("stopped after %d ms", el) end
        if el < LOOP_CHECK_MS then return false end
        st.a:stop()
        return true, not st.a:is_playing(), fmt("still playing at %d ms, then stopped", el)
    end)

-- Pause half-way, hold, continue with cont(a); the rest of the pass must be
-- shorter than a full one.
local function continue_test(name, cont)
    timed(name,
        function() local st = play_gif(false); st.phase = "run"; return st end,
        function(st, el)
            local a = st.a
            if not st.ok then return true, false, "play() -> false" end
            if st.phase == "run" then
                if not a:is_playing() then return true, false, fmt("ended at %d ms before the pause", el) end
                if el < PAUSE_AT then return false end
                a:pause()
                st.phase, st.mark = "paused", el
                return false
            elseif st.phase == "paused" then
                if el - st.mark < PAUSE_FOR then return false end
                if a:is_playing() then return true, false, "is_playing while paused" end
                cont(a)
                if not a:is_playing() then return true, false, "not playing after continue" end
                st.phase, st.mark = "rest", el
                return false
            end
            local rest = el - st.mark
            if not a:is_playing() then
                return true, rest >= REST_MIN and rest <= REST_MAX,
                       fmt("rest of the pass %d ms (window %d..%d; a restart is ~%d)",
                           rest, REST_MIN, REST_MAX, GIF_PASS_MS)
            end
            if rest > ONESHOT_MAX then return true, false, fmt("still playing %d ms after continue", rest) end
            return false
        end)
end

continue_test("pause + resume continues from the frame", function(a) a:resume() end)
continue_test("pause + play() continues from the frame", function(a) a:play() end)

timed("stop + play restarts from frame 0",
    function() local st = play_gif(false); st.phase = "run"; return st end,
    function(st, el)
        local a = st.a
        if not st.ok then return true, false, "play() -> false" end
        if st.phase == "run" then
            if el < PAUSE_AT then return false end
            a:stop()
            if a:play() ~= true then return true, false, "second play() -> false" end
            st.phase, st.mark = "again", el
            return false
        end
        local rest = el - st.mark
        if not a:is_playing() then
            return true, rest > REST_MAX and rest <= ONESHOT_MAX,
                   fmt("second pass %d ms (want a full pass, > %d)", rest, REST_MAX)
        end
        if rest > ONESHOT_MAX then return true, false, fmt("still playing %d ms after restart", rest) end
        return false
    end)

timed("MJPEG one-shot ends on its own",
    function()
        local a = new_anim(MJPEG, CX, CY)
        return { a = a, ok = a:play() }
    end,
    function(st, el)
        if not st.ok then return true, false, "play() -> false" end
        if not st.a:is_playing() then
            return true, true, fmt("%d frames ended after %d ms", MJPEG_FRAMES, el)
        end
        if el > MJPEG_MAX then return true, false, fmt("still playing after %d ms", el) end
        return false
    end)

timed("MJPEG loop keeps playing",
    function()
        local a = new_anim(MJPEG, CX, CY)
        return { a = a, ok = a:play(true) }
    end,
    function(st, el)
        if not st.ok then return true, false, "play(true) -> false" end
        if not st.a:is_playing() then return true, false, fmt("stopped after %d ms", el) end
        if el < MJPEG_MAX then return false end
        st.a:stop()
        return true, true, fmt("still playing at %d ms", el)
    end)

-- ── Group: look (operator) ───────────────────────────────────────────
local function look(name, show, question)
    S:look("look", name, function()
        local ok, err = pcall(show)
        if not ok then free_all(); error(err, 0) end
        return free_all
    end, question)
end

look("GIF loop", function()
    if not new_anim(GIF, CX, CY):play(true) then error("play") end
    caption("counts 0 to 11, yellow bar grows, then repeats")
end, "Counts and repeats?")

look("MJPEG loop", function()
    if not new_anim(MJPEG, CX, CY):play(true) then error("play") end
    caption("counts 0 to 9 quickly, then repeats")
end, "Counts and repeats?")

look("pause freezes, resume continues", function()
    local a = new_anim(GIF, CX, CY)
    a:play(true)
    after(1500, function() a:pause() end)
    after(3500, function() a:resume() end)
    caption("runs, freezes 2 s, continues from the same number")
end, "Froze, then continued?")

look("stop keeps the last frame", function()
    local a = new_anim(GIF, CX, CY)
    a:play(true)
    after(1500, function() a:stop() end)
    caption("runs 1.5 s, stops; the picture stays on screen")
end, "Stopped, picture stays?")

look("set_visible hides and shows", function()
    local a = new_anim(GIF, CX, CY)
    a:play(true)
    after(1500, function() a:set_visible(false) end)
    after(3000, function() a:set_visible(true) end)
    caption("runs, gone for 1.5 s, back again")
end, "Hid, then came back?")

look("set_pos moves while playing", function()
    local a = new_anim(GIF, 20, CY)
    a:play(true)
    after(1500, function() a:set_pos(330, CY) end)
    caption("starts on the left, jumps right, keeps counting")
end, "Jumped right, still runs?")

look("one Anim at a time", function()
    local a = new_anim(GIF, 20, CY)
    local b = new_anim(MJPEG, 330, CY)
    a:play(true)
    after(1500, function() b:play(true) end)
    caption("left runs; when right starts, left freezes")
end, "Left froze at right start?")

-- The canvas is opaque RGB565: transparent GIF pixels show black, not the
-- green sprite behind the Anim. The transparent palette entry is magenta, so
-- magenta (or noise) on the robot means transparency is drawn as a colour.
look("transparent GIF pixels show black", function()
    local bg, err = Sprite.solid(200, 140, 0x07E0)
    if not bg then error("Sprite.solid: " .. tostring(err)) end
    keep(bg)
    bg:set_pos(140, TOP + 40)
    local a = new_anim(TRANS, 208, TOP + 78)
    a:play(true)
    caption("disc in a black square (not magenta) on green")
end, "Black square around disc?")

look("one-shot holds its last frame", function()
    if not new_anim(GIF, CX, CY):play() then error("play") end
    caption("counts 0 to 11 once and stays on 11")
end, "Stopped on 11?")

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    print(fmt("anim: count.gif %d frames x %d ms, count.mjpeg %d frames",
              GIF_FRAMES, GIF_FRAME_MS, MJPEG_FRAMES))
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    run_plan()
    S:tick()
end

function game_end()
    free_all()
    S:summary()
end
