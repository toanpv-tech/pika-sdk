-- test_servo: the Servo API (move, pose, stop, is_busy, list, stats) on the robot.
--
-- Runner: libs/testkit (RUN SUITE + Reset rows, then the tests below).
--
-- Groups (suite order):
--   probe  : Servo.list() against manifest.json, Servo.stats() shape, is_busy type
--   guard  : bad arguments return false and never raise; nothing is queued
--   accept : valid calls return true; out-of-range angle / duration are
--            saturated, not refused; two moves of one joint in a frame merge
--   busy   : is_busy predictions (async, bounded): move duration, the
--            requested (unclamped) duration, stop, stop(), pose ~1.5 s
--   stats  : commands reach the robot (sent, no reject), a refused gesture
--            counts in back_reject_validation, the duty limit (8 s of motion
--            per 10 s) counts in back_reject_throttle and lifts after 5 s
--   look   : the operator watches the robot: right joint, both ways, back to
--            rest; easings; stop returns to rest; poses. ENTER = looks right,
--            RIGHT = looks wrong.
--   diag   : stats dump with hints
--   manual : ring overflow, Engine.exit mid-move (RUN SUITE skips them)
--
-- Needs the robot (the back board drives the joints and sends the reject
-- counters) and an operator for the look rows. Motions are small (at most
-- ~25 degrees around rest). Every test ends with Servo.stop() (every joint
-- back to its rest angle), also on failure, on abort and in game_end.

-- ── Locals ───────────────────────────────────────────────────────────
local Servo_move    = Servo.move
local Servo_pose    = Servo.pose
local Servo_stop    = Servo.stop
local Servo_is_busy = Servo.is_busy
local Servo_list    = Servo.list
local Servo_stats   = Servo.stats
local fmt, unpack   = string.format, table.unpack
local clock_ms      = Timer.millis

-- ── Constants ────────────────────────────────────────────────────────
-- Rest angle per joint: where Servo.stop() drives it (back_esp32 configs.h
-- SERVO_*_START; not in constraints.json). Small moves are offsets from it.
local REST = { head = 100, base = 90, body = 90, left = 120, right = 120 }
local JOINTS = { "head", "base", "left", "right" }     -- one alias per joint
-- manifest.json servos / poses, and what Servo.list() must report for them.
-- "body" is the documented friendly name of the base joint.
local WANT_SERVOS = { head = "head", base = "base", body = "base",
                      left = "left", right = "right" }
local WANT_POSES  = { neutral = "default", hi = "say_hi", wave = "left_wave",
                      bad_system = "system_error" }

local POSE_BUSY_MS = 1500   -- servo_pose_busy_ms
local MOVE_MAX_MS  = 3000   -- servo_move_max_ms (robot clamp)
local DUTY_COOLDOWN_MS = 5000   -- servo_duty_cooldown_s
local RING_SLOTS   = 32     -- GAME_SERVO_RING_SZ (servo_internal.h), not in constraints.json
local BUSY_EARLY_MS = 250   -- is_busy may clear this early (frame clock vs push clock)
local BUSY_LATE_MS  = 300   -- or this late (one poll every frame)
local ACK_WAIT_MS   = 900   -- back flushes reject counters every 500 ms
local STATS_POLL_MS = 250   -- Servo.stats() allocates a table: poll, not every tick

local STAT_KEYS = {
    "pushed_total", "coalesced_total", "dropped_total", "sent_total",
    "send_fail_total", "back_reject_throttle", "back_reject_validation",
    "back_reject_priority", "back_reject_queue_full", "last_reject_ms",
    "drain_max_us",
}

-- ── Scripted motion ──────────────────────────────────────────────────
-- A plan is a static list of timed steps run from on_tick, so a look row can
-- move a joint out and back without the test owning the frame loop.
local plan, plan_i, plan_t0 = nil, 0, 0

local function plan_start(p) plan, plan_i, plan_t0 = p, 1, clock_ms() end
local function plan_clear() plan = nil end

local function plan_run()
    if not plan then return end
    local el = clock_ms() - plan_t0
    while plan_i <= #plan and el >= plan[plan_i].at do
        local s = plan[plan_i]
        plan_i = plan_i + 1
        if s.op == "move" then Servo_move(s.alias, s.angle, s.dur, s.easing)
        elseif s.op == "pose" then Servo_pose(s.alias)
        else Servo_stop(s.alias) end
    end
    if plan_i > #plan then plan = nil end
end

-- Every joint back to rest, scripted motion dropped.
local function halt()
    plan_clear()
    Servo_stop()
end

-- ── Helpers ──────────────────────────────────────────────────────────
-- Copies Servo.stats() into t (no new table per poll). false when stats()
-- did not return a table.
local function snap_into(t)
    local s = Servo_stats()
    if type(s) ~= "table" then return false end
    for i = 1, #STAT_KEYS do t[STAT_KEYS[i]] = s[STAT_KEYS[i]] end
    return true
end

local function delta(a, b, k) return (b[k] or 0) - (a[k] or 0) end

-- Sync test that moves joints: always ends with halt(), also on error.
local function with_halt(fn)
    return function()
        local ok, pass, msg = pcall(fn)
        halt()
        if not ok then error(pass, 0) end
        return pass, msg
    end
end

-- Async test whose arm/step may move joints: halt() when it ends or raises.
local function guarded(arm, step)
    local function a()
        local ok, st = pcall(arm)
        if not ok then halt(); error(st, 0) end
        return st
    end
    local function s(st)
        local ok, done, pass, msg = pcall(step, st)
        if not ok then halt(); error(done, 0) end
        if done then halt() end
        return done, pass, msg
    end
    return { a, s }
end

-- Look rows: start a plan; the operator's answer (or abort) halts.
local function show_plan(p)
    return function()
        local ok, err = pcall(plan_start, p)
        if not ok then halt(); error(err, 0) end
        return halt
    end
end

-- Runs a list of { label, fn, args... } that must each return false
-- without raising. Reports the first case that does not.
local function all_false(cases)
    return function()
        for i = 1, #cases do
            local c = cases[i]
            local ok, r = pcall(c[2], unpack(c, 3, c.n or #c))
            if not ok then return false, c[1] .. " raised: " .. tostring(r) end
            if r ~= false then return false, c[1] .. " -> " .. tostring(r) end
        end
        return true, fmt("%d calls -> false, none raised", #cases)
    end
end

-- Records the first time `alias` (or every joint when nil) reads idle.
local function track_idle(st, alias, el)
    if st.idle_at then return end
    local busy
    if alias then
        busy = Servo_is_busy(alias)
    else
        busy = false
        for i = 1, #JOINTS do busy = busy or Servo_is_busy(JOINTS[i]) end
    end
    if not busy then st.idle_at = el end
end

local function idle_in(st, lo, hi)
    return st.idle_at ~= nil and st.idle_at >= lo and st.idle_at <= hi
end

local stat_view = {}   -- HUD status snapshot

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "servo", title = "SERVO TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    groups = {
        probe  = { label = "STATE PROBE", what = "list / stats / is_busy shape" },
        guard  = { label = "ARG GUARDS",  what = "bad arguments -> false, no raise" },
        accept = { label = "ACCEPTED",    what = "valid calls -> true, saturation" },
        busy   = { label = "BUSY",        what = "is_busy predictions over time" },
        stats  = { label = "STATS",       what = "sent / reject counters" },
        look   = { label = "LOOK",        what = "operator watches the joints" },
        diag   = { label = "DIAGNOSTICS", what = "stats dump + hints" },
        manual = { label = "MANUAL",      what = "flood / exit (not in suite)" },
    },
    status = function()
        if not snap_into(stat_view) then return "stats: n/a" end
        local v = stat_view
        return fmt("sent %d fail %d drop %d coal %d\nrej thr %d val %d pri %d qf %d",
            v.sent_total, v.send_fail_total, v.dropped_total, v.coalesced_total,
            v.back_reject_throttle, v.back_reject_validation,
            v.back_reject_priority, v.back_reject_queue_full)
    end,
    on_abort = halt,
})

-- Registers an async test built by guarded().
local function async_g(group, name, pair, o)
    return S:async(group, name, pair[1], pair[2], o)
end

-- ── Group: probe (sync) ──────────────────────────────────────────────
-- Kept first and free of bad aliases: the default smoke run executes them.
S:sync("probe", "list() -> {servos = {}, poses = {}}", function()
    local L = Servo_list()
    local ok = type(L) == "table" and type(L.servos) == "table"
               and type(L.poses) == "table"
    return ok, ok and "both sub-tables present" or ("got " .. type(L))
end)

S:sync("probe", "list().servos: alias -> joint (body = base)", function()
    local got = Servo_list().servos
    local n = 0
    for alias, joint in pairs(got) do
        n = n + 1
        if WANT_SERVOS[alias] ~= joint then
            return false, fmt("%s -> %s, want %s", alias, tostring(joint),
                              tostring(WANT_SERVOS[alias]))
        end
    end
    return n == 5, fmt("%d aliases match the manifest", n)
end)

S:sync("probe", "list().poses: alias -> gesture", function()
    local got = Servo_list().poses
    local n = 0
    for alias, g in pairs(got) do
        n = n + 1
        if WANT_POSES[alias] ~= g then
            return false, fmt("%s -> %s, want %s", alias, tostring(g),
                              tostring(WANT_POSES[alias]))
        end
    end
    return n == 4, fmt("%d poses match the manifest", n)
end)

S:sync("probe", "stats(): 11 integer counters >= 0", function()
    local s = Servo_stats()
    if type(s) ~= "table" then return false, "stats() returned " .. type(s) end
    for i = 1, #STAT_KEYS do
        local v = s[STAT_KEYS[i]]
        if math.type(v) ~= "integer" or v < 0 then
            return false, STAT_KEYS[i] .. " = " .. tostring(v)
        end
    end
    return true, fmt("sent=%d rej_val=%d", s.sent_total, s.back_reject_validation)
end)

S:sync("probe", "is_busy(alias) returns a boolean", function()
    for alias in pairs(WANT_SERVOS) do
        local b = Servo_is_busy(alias)
        if type(b) ~= "boolean" then return false, alias .. " -> " .. type(b) end
    end
    return true, "5 aliases -> boolean"
end)

-- ── Group: guard (sync) ──────────────────────────────────────────────
-- Servo never raises: every bad argument returns false (bind_servo.c).
-- A numeric string is a number to Lua (move("head", "90", 300) is valid),
-- so the non-number probes use words and tables.
S:sync("guard", "move: bad alias -> false", all_false({
    { "move('nope')",  Servo_move, "nope", 90, 300 },
    { "move(42)",      Servo_move, 42, 90, 300 },
    { "move(nil)",     Servo_move, nil, 90, 300, n = 5 },
    { "move(pose alias 'hi')", Servo_move, "hi", 90, 300 },
}))

S:sync("guard", "move: bad angle / duration -> false", all_false({
    { "angle 'ninety'",   Servo_move, "head", "ninety", 300 },
    { "angle {}",         Servo_move, "head", {}, 300 },
    { "angle nil",        Servo_move, "head", nil, 300, n = 5 },
    { "duration 'long'",  Servo_move, "head", 100, "long" },
    { "duration missing", Servo_move, "head", 100 },
}))

S:sync("guard", "move: bad easing -> false", all_false({
    { "easing 'spring'", Servo_move, "head", 100, 300, "spring" },
    { "easing 'LINEAR'", Servo_move, "head", 100, 300, "LINEAR" },
    { "easing false",    Servo_move, "head", 100, 300, false },
    { "easing {}",       Servo_move, "head", 100, 300, {} },
}))

S:sync("guard", "pose: bad alias -> false", all_false({
    { "pose('nope')",    Servo_pose, "nope" },
    { "pose(42)",        Servo_pose, 42 },
    { "pose()",          Servo_pose },
    { "pose(servo alias 'head')", Servo_pose, "head" },
    { "pose(gesture name 'say_hi')", Servo_pose, "say_hi" },
}))

S:sync("guard", "stop: bad alias -> false", all_false({
    { "stop('nope')",   Servo_stop, "nope" },
    { "stop(42)",       Servo_stop, 42 },
    { "stop(false)",    Servo_stop, false },
    { "stop(pose alias 'hi')", Servo_stop, "hi" },
}))

S:sync("guard", "is_busy: bad alias -> false", all_false({
    { "is_busy('nope')", Servo_is_busy, "nope" },
    { "is_busy()",       Servo_is_busy },
    { "is_busy(42)",     Servo_is_busy, 42 },
    { "is_busy(pose alias 'neutral')", Servo_is_busy, "neutral" },
}))

S:sync("guard", "bad calls queue nothing (pushed_total)", function()
    local a, b = {}, {}
    if not snap_into(a) then return false, "stats() did not return a table" end
    Servo_move("nope", 90, 300)
    Servo_move("head", "ninety", 300)
    Servo_move("head", 100, 300, "spring")
    Servo_pose("nope")
    Servo_stop("nope")
    snap_into(b)
    local d = delta(a, b, "pushed_total")
    return d == 0, fmt("pushed +%d after 5 refused calls", d)
end)

S:sync("guard", "list(x) / stats(x) ignore arguments", function()
    local ok1, L = pcall(Servo_list, "x", 1)
    local ok2, s = pcall(Servo_stats, {})
    local pass = ok1 and type(L) == "table" and ok2 and type(s) == "table"
    return pass, fmt("list -> %s, stats -> %s", ok1 and type(L) or "raised",
                     ok2 and type(s) or "raised")
end)

-- ── Group: accept (sync) ─────────────────────────────────────────────
-- Moves target the rest angle, so the joints do not visibly move.
S:sync("accept", "move(alias, rest, 300) -> true, 5 aliases", with_halt(function()
    local a, b = {}, {}
    local have = snap_into(a)
    for alias, rest in pairs(REST) do
        local r = Servo_move(alias, rest, 300)
        if r ~= true then return false, alias .. " -> " .. tostring(r) end
    end
    if not have then return false, "returns ok; stats() did not return a table" end
    snap_into(b)
    local d = delta(a, b, "pushed_total")
    return d == 5, fmt("5 x true, pushed +%d", d)
end))

S:sync("accept", "easing nil / linear / in_out / bounce -> true", with_halt(function()
    local cases = { false, "linear", "in_out", "bounce" }
    for i = 1, #cases do
        local e = cases[i] or nil
        local r = Servo_move("head", REST.head, 300, e)
        if r ~= true then return false, tostring(e) .. " -> " .. tostring(r) end
    end
    return true, "4 x true"
end))

-- Angle and duration are saturated on the head and clamped by the robot, not
-- refused. The extreme moves are replaced in the same frame by a rest move
-- (same-frame merge), so the robot never receives them.
S:sync("accept", "out-of-range angle / duration -> true, merged", with_halt(function()
    local a, b = {}, {}
    local have = snap_into(a)
    local r1 = Servo_move("head", 1e9, 1e9)
    local r2 = Servo_move("head", -1e9, -5, "bounce")
    local r3 = Servo_move("head", REST.head, 300)
    if not (r1 == true and r2 == true and r3 == true) then
        return false, fmt("-> %s %s %s", tostring(r1), tostring(r2), tostring(r3))
    end
    if not have then return false, "returns ok; stats() did not return a table" end
    snap_into(b)
    local p, c = delta(a, b, "pushed_total"), delta(a, b, "coalesced_total")
    return p == 3 and c == 2, fmt("3 x true, pushed +%d coalesced +%d (want 3/2)", p, c)
end))

S:sync("accept", "stop(alias) and stop() -> true", with_halt(function()
    for i = 1, #JOINTS do
        local r = Servo_stop(JOINTS[i])
        if r ~= true then return false, JOINTS[i] .. " -> " .. tostring(r) end
    end
    local r = Servo_stop("body")
    if r ~= true then return false, "body -> " .. tostring(r) end
    r = Servo_stop()
    return r == true, "stop() -> " .. tostring(r)
end))

-- ── Group: busy (async) ──────────────────────────────────────────────
-- is_busy is a prediction stamped at push time from the requested duration.
async_g("busy", "move 800 ms: busy, then idle at ~800 ms", guarded(
    function()
        local st = { t0 = clock_ms() }
        st.ok = Servo_move("head", REST.head + 10, 800, "in_out")
        st.busy0 = Servo_is_busy("head")
        st.other = Servo_is_busy("left")
        return st
    end,
    function(st)
        local el = clock_ms() - st.t0
        track_idle(st, "head", el)
        if not st.idle_at and el < 800 + BUSY_LATE_MS then return false end
        local pass = st.ok and st.busy0 and not st.other
                     and idle_in(st, 800 - BUSY_EARLY_MS, 800 + BUSY_LATE_MS)
        return true, pass, fmt("move=%s busy@0=%s left busy=%s idle at %s ms",
            tostring(st.ok), tostring(st.busy0), tostring(st.other),
            tostring(st.idle_at))
    end))

async_g("busy", "busy follows the requested 5000 ms, not 3000", guarded(
    function()
        local st = { t0 = clock_ms() }
        st.ok = Servo_move("head", REST.head + 6, 5000, "linear")
        return st
    end,
    function(st)
        local el = clock_ms() - st.t0
        track_idle(st, "head", el)
        if not st.idle_at and el < 5000 + BUSY_LATE_MS then return false end
        local pass = st.ok and idle_in(st, 5000 - BUSY_EARLY_MS, 5000 + BUSY_LATE_MS)
        return true, pass, fmt("idle at %s ms (robot clamps motion to %d ms)",
                               tostring(st.idle_at), MOVE_MAX_MS)
    end), { settle_ms = 1500 })

async_g("busy", "stop(alias) mid-move: true, idle at once", guarded(
    function()
        local st = { t0 = clock_ms() }
        st.ok = Servo_move("left", REST.left - 20, 2000, "linear")
        return st
    end,
    function(st)
        if clock_ms() - st.t0 < 400 then return false end
        local before = Servo_is_busy("left")
        local r = Servo_stop("left")
        local after = Servo_is_busy("left")
        return true, st.ok and before and r == true and not after,
            fmt("busy before=%s stop=%s busy after=%s",
                tostring(before), tostring(r), tostring(after))
    end))

async_g("busy", "stop() mid-move: true, all four idle", guarded(
    function()
        local st = { t0 = clock_ms(), ok = true }
        for i = 1, #JOINTS do
            local j = JOINTS[i]
            st.ok = Servo_move(j, REST[j] - 8, 1500) and st.ok
        end
        return st
    end,
    function(st)
        if clock_ms() - st.t0 < 400 then return false end
        local before = Servo_is_busy("head") and Servo_is_busy("right")
        local r = Servo_stop()
        local any = false
        for i = 1, #JOINTS do any = any or Servo_is_busy(JOINTS[i]) end
        return true, st.ok and before and r == true and not any,
            fmt("moves=%s busy before=%s stop()=%s any busy after=%s",
                tostring(st.ok), tostring(before), tostring(r), tostring(any))
    end))

async_g("busy", "pose: all four busy ~1.5 s", guarded(
    function()
        local st = { t0 = clock_ms(), all0 = true }
        st.ok = Servo_pose("neutral")
        for i = 1, #JOINTS do st.all0 = st.all0 and Servo_is_busy(JOINTS[i]) end
        return st
    end,
    function(st)
        local el = clock_ms() - st.t0
        track_idle(st, nil, el)
        if not st.idle_at and el < POSE_BUSY_MS + BUSY_LATE_MS then return false end
        local pass = st.ok and st.all0
                     and idle_in(st, POSE_BUSY_MS - BUSY_EARLY_MS, POSE_BUSY_MS + BUSY_LATE_MS)
        return true, pass, fmt("pose=%s all busy@0=%s all idle at %s ms",
            tostring(st.ok), tostring(st.all0), tostring(st.idle_at))
    end), { settle_ms = 2500 })

-- Two moves of one joint in a frame merge: the later one replaces the
-- earlier, so the right arm only nudges 5 degrees and is idle after 400 ms.
async_g("busy", "same-frame moves merge, later one wins", guarded(
    function()
        local st = { t0 = clock_ms(), a = {}, b = {} }
        st.have = snap_into(st.a)
        st.ok1 = Servo_move("right", REST.right - 20, 3000)
        st.ok2 = Servo_move("right", REST.right - 5, 400)
        snap_into(st.b)
        return st
    end,
    function(st)
        local el = clock_ms() - st.t0
        track_idle(st, "right", el)
        if not st.idle_at and el < 400 + BUSY_LATE_MS then return false end
        local c = delta(st.a, st.b, "coalesced_total")
        local pass = st.ok1 and st.ok2 and st.have and c == 1
                     and idle_in(st, 400 - BUSY_EARLY_MS, 400 + BUSY_LATE_MS)
        return true, pass, fmt("coalesced +%d idle at %s ms (want +1, ~400)%s",
            c, tostring(st.idle_at), st.have and "" or " stats n/a")
    end))

-- ── Group: stats (async) ─────────────────────────────────────────────
async_g("stats", "small moves: sent, no fail, no reject", guarded(
    function()
        local st = { t0 = clock_ms(), a = {}, b = {}, ok = true }
        st.have = snap_into(st.a)
        for i = 1, #JOINTS do
            local j = JOINTS[i]
            st.ok = Servo_move(j, REST[j] - 4, 300) and st.ok
        end
        return st
    end,
    function(st)
        if clock_ms() - st.t0 < ACK_WAIT_MS then return false end
        if not st.have or not snap_into(st.b) then
            return true, false, "stats() did not return a table"
        end
        local a, b = st.a, st.b
        local sent, fail = delta(a, b, "sent_total"), delta(a, b, "send_fail_total")
        local rej = delta(a, b, "back_reject_throttle") + delta(a, b, "back_reject_validation")
                  + delta(a, b, "back_reject_priority") + delta(a, b, "back_reject_queue_full")
        local drop = delta(a, b, "dropped_total")
        return true, st.ok and sent >= 4 and fail == 0 and rej == 0 and drop == 0,
            fmt("sent +%d fail +%d drop +%d rej +%d", sent, fail, drop, rej)
    end))

-- system_error is accepted by the engine and refused by the robot. Fired
-- twice, 800 ms apart: the head takes the first reject report of a session
-- as its baseline (servo.c game_servo_handle_ack, ack_seeded), so a single
-- refusal can read +0 when it is the session's first.
async_g("stats", "refused gesture -> back_reject_validation", guarded(
    function()
        local st = { t0 = clock_ms(), a = {}, b = {}, next_poll = 0, second = false }
        st.have = snap_into(st.a)
        st.ok = Servo_pose("bad_system")
        return st
    end,
    function(st)
        local now = clock_ms()
        local el = now - st.t0
        if not st.have then return true, false, "stats() did not return a table" end
        if not st.second and el >= 800 then
            st.second = true
            Servo_pose("bad_system")
        end
        if now >= st.next_poll then
            st.next_poll = now + STATS_POLL_MS
            snap_into(st.b)
            local d = delta(st.a, st.b, "back_reject_validation")
            if d >= 1 and st.second then
                return true, st.ok == true and (st.b.last_reject_ms or 0) > 0,
                    fmt("pose=%s rej_val +%d last_reject_ms=%d after %d ms",
                        tostring(st.ok), d, st.b.last_reject_ms or 0, el)
            end
        end
        if el >= 800 + 2 * ACK_WAIT_MS then
            return true, false, fmt("pose=%s, no validation reject within %d ms",
                                    tostring(st.ok), el)
        end
        return false
    end), { settle_ms = 2000 })

-- Head swings +-5 degrees, 1000 ms moves back to back: past 8 s of motion
-- in 10 s the robot refuses moves for 5 s. Earlier head motion counts in
-- the same window, so the trip may come early; the swing count is not
-- asserted. Swings continue until a reject is reported (see the baseline
-- note above), then stop("head") (exempt from the limit) returns it to rest.
async_g("stats", "duty limit -> throttle, lifts after 5 s", guarded(
    function()
        local st = { t0 = clock_ms(), a = {}, b = {}, phase = "drive",
                     next_swing = 0, next_poll = 0, swings = 0 }
        st.have = snap_into(st.a)
        return st
    end,
    function(st)
        local now = clock_ms()
        if not st.have then return true, false, "stats() did not return a table" end
        if st.phase == "drive" then
            if now >= st.next_swing then
                st.swings = st.swings + 1
                Servo_move("head", REST.head + ((st.swings % 2 == 0) and -5 or 5), 1000)
                st.next_swing = now + 1000
            end
            if now >= st.next_poll then
                st.next_poll = now + STATS_POLL_MS
                snap_into(st.b)
                st.thr = delta(st.a, st.b, "back_reject_throttle")
                if st.thr > 0 then
                    Servo_stop("head")
                    st.phase, st.t_trip = "cooldown", now
                    st.trip_ms = now - st.t0
                end
            end
            if st.phase == "drive" and now - st.t0 >= 16000 then
                return true, false, fmt("%d swings, no throttle reject in 16 s", st.swings)
            end
            return false
        elseif st.phase == "cooldown" then
            if now - st.t_trip < DUTY_COOLDOWN_MS + 600 then return false end
            snap_into(st.a)
            st.ok_after = Servo_move("head", REST.head, 300)
            st.phase, st.t_v = "verify", now
            return false
        end
        if now - st.t_v < ACK_WAIT_MS then return false end
        snap_into(st.b)
        local again = delta(st.a, st.b, "back_reject_throttle")
        return true, st.ok_after == true and again == 0,
            fmt("trip after %d swings / %d ms (thr +%d); after cooldown move=%s thr +%d",
                st.swings, st.trip_ms, st.thr, tostring(st.ok_after), again)
    end), { settle_ms = 1500 })

-- ── Group: look (operator) ───────────────────────────────────────────
local function mv(at, alias, angle, dur, easing)
    return { at = at, op = "move", alias = alias, angle = angle, dur = dur, easing = easing }
end
local function stp(at, alias) return { at = at, op = "stop", alias = alias } end
local function pse(at, alias) return { at = at, op = "pose", alias = alias } end

local function both_ways(alias, d)
    local r = REST[alias]
    return { mv(0, alias, r + d, 500, "in_out"), mv(800, alias, r - d, 800, "in_out"),
             mv(1900, alias, r, 500, "in_out") }
end
-- Arms: a lower angle lifts the arm (raise_both drives both to 30).
local function lift(alias)
    local r = REST[alias]
    return { mv(0, alias, r - 25, 600, "in_out"), mv(1000, alias, r, 600, "in_out") }
end

S:look("look", "head: one way, other way, back", show_plan(both_ways("head", 15)),
    "HEAD only: one way, other, back?")
S:look("look", "base: one way, other way, back", show_plan(both_ways("base", 15)),
    "BODY only: one way, other, back?")
S:look("look", "left arm: lift and lower", show_plan(lift("left")),
    "LEFT arm only: lift, then lower?")
S:look("look", "right arm: lift and lower", show_plan(lift("right")),
    "RIGHT arm only: lift, then lower?")
S:look("look", "easings: linear / in_out / bounce", show_plan({
        mv(0, "left", 90, 700, "linear"),  mv(1000, "left", 120, 700, "linear"),
        mv(2000, "left", 90, 700, "in_out"), mv(3000, "left", 120, 700, "in_out"),
        mv(4000, "left", 90, 700, "bounce"), mv(5000, "left", 120, 700, "bounce"),
    }), "LEFT: steady, smooth, bouncy?")
S:look("look", "stop(alias) returns to rest", show_plan({
        mv(0, "left", 60, 3000, "linear"), stp(1000, "left"),
    }), "LEFT rose, then back to rest?")
S:look("look", "stop() returns all four to rest", show_plan({
        mv(0, "head", 108, 800), mv(0, "base", 98, 800),
        mv(0, "left", 100, 800), mv(0, "right", 100, 800), stp(1600, nil),
    }), "All four moved, then all to rest?")
S:look("look", "pose 'hi' (say_hi)", show_plan({ pse(0, "hi") }),
    "Say-hi gesture played?")
S:look("look", "pose 'wave' (left_wave)", show_plan({ pse(0, "wave") }),
    "Left-arm wave played?")

-- ── Group: diag ──────────────────────────────────────────────────────
S:sync("diag", "stats dump + DIAG hints", function()
    local s = Servo_stats()
    if type(s) ~= "table" then return false, "stats() did not return a table" end
    print(fmt("servo stats: pushed=%d coal=%d drop=%d sent=%d sfail=%d | "
              .. "rej thr=%d val=%d pri=%d qf=%d | last_rej=%d drain_max_us=%d",
        s.pushed_total, s.coalesced_total, s.dropped_total, s.sent_total,
        s.send_fail_total, s.back_reject_throttle, s.back_reject_validation,
        s.back_reject_priority, s.back_reject_queue_full, s.last_reject_ms,
        s.drain_max_us))
    if s.pushed_total == 0 then
        print("servo DIAG: pushed=0 -> no call was accepted (manifest servos/poses missing?)")
    end
    if s.send_fail_total > 0 then
        print("servo DIAG: send_fail>0 -> commands did not reach the body board")
    end
    if s.back_reject_priority > 0 then
        print("servo DIAG: priority rejects -> the robot had no game session for the servos")
    end
    if s.back_reject_validation > 0 then
        print("servo DIAG: validation rejects -> refused gesture (expected once per run "
              .. "from the 'refused gesture' test) or a bad command")
    end
    if s.back_reject_throttle > 0 then
        print("servo DIAG: throttle rejects -> duty limit hit (expected from the duty test)")
    end
    if s.back_reject_queue_full > 0 then
        print("servo DIAG: queue_full rejects -> the robot's gesture queue overflowed")
    end
    return true, fmt("sent=%d fail=%d drop=%d", s.sent_total, s.send_fail_total,
                     s.dropped_total)
end)

-- ── Group: manual ────────────────────────────────────────────────────
-- Manual: fills the 32-slot head queue in one frame, so 32 stop commands go
-- to the robot at once; its gesture queue overflows (queue_full rejects) and
-- the joints stay busy replaying stops for seconds, which would disturb the
-- tests that follow in RUN SUITE. Stops only: no joint leaves rest.
S:sync("manual", "full queue: 33rd call false, pose busy anyway", with_halt(function()
    local a, b = {}, {}
    if not snap_into(a) then return false, "stats() did not return a table" end
    local n = 0
    for _ = 1, RING_SLOTS do
        if Servo_stop("head") then n = n + 1 end
    end
    local r33 = Servo_stop("head")
    local rpose = Servo_pose("neutral")
    local busy = Servo_is_busy("left")
    local rall = Servo_stop()
    snap_into(b)
    local drop = delta(a, b, "dropped_total")
    -- 1 stop + 1 pose + 4 stop() pushes refused
    local pass = n == RING_SLOTS and r33 == false and rpose == false and busy
                 and rall == false and drop == 6
    return pass, fmt("queued %d, 33rd=%s pose=%s left busy=%s stop()=%s drop +%d",
        n, tostring(r33), tostring(rpose), tostring(busy), tostring(rall), drop)
end), { manual = true })

-- Manual: ends the game. The arm is sent first and the exit comes 600 ms
-- later, so it is visibly mid-travel; the operator checks it returns to rest
-- when the session ends (the robot's game stop does that). Not guarded: a
-- stop queued here would hide what the session end does.
S:async("manual", "Engine.exit mid-move: joints return to rest",
    function()
        return { t0 = clock_ms(), ok = Servo_move("left", REST.left - 25, 1500, "in_out") }
    end,
    function(st)
        if clock_ms() - st.t0 < 600 then return false end
        Engine.exit("servo_done")
        return true, st.ok == true,
            fmt("move=%s, exit posted; watch the LEFT arm return to rest", tostring(st.ok))
    end, { manual = true })

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    local L = Servo_list()
    local ns, np = 0, 0
    for _ in pairs(L.servos) do ns = ns + 1 end
    for _ in pairs(L.poses) do np = np + 1 end
    print(fmt("servo: servos=%d poses=%d", ns, np))
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    plan_run()
    S:tick()
end

function game_end()
    -- The queue is not sent after game_end (the session reset drops it);
    -- the robot's own game stop returns the joints to rest. Kept so a
    -- future engine that drains here also stops them.
    halt()
    local s = Servo_stats()
    if type(s) == "table" then
        S:summary(fmt("stats sent=%d fail=%d drop=%d rej thr=%d val=%d pri=%d qf=%d",
            s.sent_total, s.send_fail_total, s.dropped_total, s.back_reject_throttle,
            s.back_reject_validation, s.back_reject_priority, s.back_reject_queue_full))
    else
        S:summary("stats n/a")
    end
end
