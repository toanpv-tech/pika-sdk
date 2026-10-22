-- test_timer: Timer.millis, the only real clock, on a robot.
--
-- Groups (suite order):
--   probe : the value is an integer; two back-to-back calls never go back
--   tick  : sampled once per frame over SAMPLE_TICKS frames: differences are
--           never negative, on_tick's dt is the nominal DT_MS every frame,
--           and the real frame period sits near TICK_PERIOD_MS (KI-DT-NOMINAL:
--           dt is 33 while frames are 30 ms apart, so summing dt runs fast)
--   cost  : COST_CALLS calls in one frame stay monotonic and cheap
--
-- Only differences are compared (now - t0): the value turns negative after
-- about 24.8 days of uptime, so absolute values mean nothing. Timing numbers
-- are only meaningful on the robot; smoke.py advances a simulated clock.

local DT_MS          = 33     -- derived.dt_ms in contract/constraints.json (1000 // target_fps)
local TICK_PERIOD_MS = 30     -- derived.tick_period_ms in contract/constraints.json
local SAMPLE_TICKS   = 90     -- about 3 s of frames
local PERIOD_MIN_MS  = 24     -- 0.8 x period: the loop never runs faster than its RTOS tick
local PERIOD_MAX_MS  = 120    -- 4 x period: generous, frames run late under load (not measured)
local COST_CALLS     = 2000
local COST_MAX_MS    = TICK_PERIOD_MS   -- not measured: 2000 calls must fit well inside one frame

local fmt = string.format
local mtype = math.type
local clock_ms = Timer.millis

-- testkit's step(st) gets no dt: on_tick stores it here before S:tick().
local frame = { dt = nil, ms = 0, n = 0 }

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "timer", title = "TIMER TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    groups = {
        probe = { label = "PROBE", what = "integer, never goes back" },
        tick  = { label = "TICKS", what = "per-frame differences vs dt" },
        cost  = { label = "COST",  what = "many calls in one frame" },
    },
    status = function()
        return fmt("frames=%d  dt=%s", frame.n, tostring(frame.dt))
    end,
})

-- ── Group: probe ─────────────────────────────────────────────────────
S:sync("probe", "millis() is an integer", function()
    local v = clock_ms()
    return mtype(v) == "integer", "math.type=" .. tostring(mtype(v))
end)

S:sync("probe", "two calls: difference >= 0", function()
    local a = clock_ms()
    local b = clock_ms()
    return b - a >= 0, fmt("difference %d ms", b - a)
end)

-- ── Group: tick ──────────────────────────────────────────────────────
-- One sampler shared by the tick rows; each row judges a different part.
local function arm_sampler()
    return { prev = nil, t0 = 0, k = 0, min_d = math.maxinteger, max_d = math.mininteger,
             sum_dt = 0, bad_dt = 0, last_bad_dt = nil }
end

-- Returns true once SAMPLE_TICKS frame differences are collected.
local function sample(st)
    local now = frame.ms
    if st.prev == nil then
        st.prev, st.t0 = now, now
        return false
    end
    local d = now - st.prev
    st.prev = now
    st.k = st.k + 1
    if d < st.min_d then st.min_d = d end
    if d > st.max_d then st.max_d = d end
    st.sum_dt = st.sum_dt + (frame.dt or 0)
    if frame.dt ~= DT_MS then st.bad_dt, st.last_bad_dt = st.bad_dt + 1, frame.dt end
    return st.k >= SAMPLE_TICKS
end

S:async("tick", "frame differences never negative", arm_sampler,
    function(st)
        if not sample(st) then return false end
        return true, st.min_d >= 0,
               fmt("%d frames: min %d ms, max %d ms", st.k, st.min_d, st.max_d)
    end)

S:async("tick", "on_tick dt is the nominal 33 ms", arm_sampler,
    function(st)
        if not sample(st) then return false end
        local elapsed = st.prev - st.t0
        local ratio = elapsed > 0 and (st.sum_dt / elapsed) or 0
        return true, st.bad_dt == 0,
               fmt("%d frames, %d with dt ~= %d (last %s); sum(dt)/real = %.2f",
                   st.k, st.bad_dt, DT_MS, tostring(st.last_bad_dt), ratio)
    end)

S:async("tick", "real frame period near 30 ms", arm_sampler,
    function(st)
        if not sample(st) then return false end
        local mean = (st.prev - st.t0) / st.k
        return true, mean >= PERIOD_MIN_MS and mean <= PERIOD_MAX_MS,
               fmt("mean %.1f ms over %d frames (want %d..%d, nominal %d)",
                   mean, st.k, PERIOD_MIN_MS, PERIOD_MAX_MS, TICK_PERIOD_MS)
    end)

-- ── Group: cost ──────────────────────────────────────────────────────
-- Integers only, no table or string per call: the loop allocates nothing.
S:sync("cost", "2000 calls in one frame: monotonic, cheap", function()
    local t0 = clock_ms()
    local prev, back = t0, 0
    for _ = 1, COST_CALLS do
        local v = clock_ms()
        if v - prev < 0 then back = back + 1 end
        prev = v
    end
    local spent = prev - t0
    return back == 0 and spent <= COST_MAX_MS,
           fmt("%d calls in %d ms (max %d), went back %d times", COST_CALLS, spent, COST_MAX_MS, back)
end)

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    print("timer: game_start")
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(dt)
    frame.dt, frame.ms, frame.n = dt, clock_ms(), frame.n + 1
    S:tick()
end

function game_end()
    S:summary(fmt("frames=%d", frame.n))
end
