-- test_input: input-pipeline stress + invariant suite for the engine's
-- action-mapped Input API and on_input_lost.
--
-- Unlike led/servo (where Lua DRIVES output and reads stats), input is
-- an INBOUND stream: Lua cannot synthesise button presses, so the stress
-- here is operator-in-the-loop. Two layers do the work:
--
--   1. A passive PROTOCOL MONITOR that runs on every on_input event and
--      every tick, in every mode. It validates the pipeline invariants
--      that a real bug would violate:
--        * PRESS/RELEASE pairing (no double-press, no orphan release)
--        * REPEAT only while down, hold_ms monotonic non-decreasing
--        * is_down() (poll) agrees with the PRESS/RELEASE callbacks
--        * just_pressed/just_released true for EXACTLY one tick
--        * Input.stats().dropped_total / seq_gaps never grow (any growth
--          = the engine's input ring overflowed or an event was lost
--          between the buttons and the engine)
--      Faults are counted, ring-logged, and printed as they happen.
--
--   2. Guided CAPTURE TESTS that prompt the operator ("Tap ENTER once",
--      "MASH all three", "Hold LEFT+RIGHT") and auto-validate the window.
--      Each test FAILS if any protocol fault fires during it.
--
-- Runner: libs/testkit. LEFT/RIGHT move, ENTER runs the highlighted row
-- (row 1 = guided RUN SUITE). During a capture test the buttons feed the
-- test and navigation is suspended; each test ends on its goal or a
-- bounded timeout, so nothing hangs. LEFT does not abort the suite here:
-- the operator's own presses would cut it short.
--
-- Pass criteria (head-side contract):
--   * Every Input.* call returns the documented type/value.
--   * Zero protocol faults across the session.
--   * Under mashing: dropped_total == 0 AND seq_gaps == 0.
--   * Cadence/hold values are reported (the operator confirms timing).
--

-- ── Localize hot upvalues ────────────────────────────────────────────
local Input_is_down       = Input.is_down
local Input_just_pressed  = Input.just_pressed
local Input_just_released = Input.just_released
local Input_hold_ms       = Input.hold_ms
local Input_stats         = Input.stats
local Input_actions       = Input.actions
local PRESS, RELEASE, REPEAT = Input.PRESS, Input.RELEASE, Input.REPEAT
local ipairs = ipairs
local fmt    = string.format
local concat = table.concat
local huge   = math.huge
local floor  = math.floor

local clock_ms = Timer.millis

-- ── Constants (mirror contract/constraints.json; drift => a test FAILs) ──
-- Input ring depth (input_ring_slots in contract/constraints.json). The mash tests must never push
-- more than this many events between two engine frames, or
-- dropped_total climbs - which is exactly the failure we watch for.
local RING_SZ         = 32
-- Button auto-repeat timing (button_repeat_delay_ms / button_repeat_rate_ms in
-- contract/constraints.json). The game only OBSERVES the REPEAT stream; the
-- exact cadence depends on the hardware path, so
-- these are expectation hints, not hard gates.
local REPEAT_DELAY_MS = 400        -- hold before 1st REPEAT
local REPEAT_RATE_MS  = 80         -- nominal gap between REPEATs
local REP_DT_LO       = 40         -- soft lower bound for observed repeat dt
local REP_DT_HI       = 300        -- soft upper bound (frame + transport jitter headroom)
local PRESS_HOLD_TOL  = 60         -- a PRESS should arrive with hold_ms ~0
local TAP_SETTLE_MS   = 400        -- quiet gap that ends a "single tap" capture

-- The three manifest-declared actions (1:1 with the physical buttons).
-- ENTER acts as fire/confirm and LEFT/RIGHT as nav while in MENU mode.
local ACTIONS = {"enter", "left", "right"}

-- ── Protocol monitor ─────────────────────────────────────────────────
local mon = {
    events      = 0,          -- session cumulative event count
    fault_count = 0,          -- session cumulative faults
    faults      = {},         -- ring of recent fault strings (cap 12)
    last_event_ms = 0,
    drop_seen   = 0,          -- last dropped_total we reported on (fault gate)
    gap_seen    = 0,          -- last seq_gaps we reported on
    win = { faults = 0, events = 0, drop_base = 0, gap_base = 0, hold0 = {} },
    st  = {},                 -- per-action state, keyed by action name
}

for _, name in ipairs(ACTIONS) do
    mon.st[name] = {
        down = false, prev_hold = 0,
        -- one-tick edge expectation (set in callback, checked in mon_tick)
        e_press = false, e_release = false,
        -- session cumulative
        p = 0, r = 0, x = 0, max_hold = 0,
        -- window (reset by mon_window_begin)
        w_p = 0, w_r = 0, w_x = 0, w_max_hold = 0,
        w_rep_n = 0, w_rep_dt_sum = 0,
        w_rep_dt_min = huge, w_rep_dt_max = 0, w_last_rep = 0,
    }
end

local function fault(action, kind, detail)
    mon.fault_count = mon.fault_count + 1
    mon.win.faults  = mon.win.faults + 1
    local line = fmt("FAULT %-5s %-16s %s", action or "-", kind, detail or "")
    local f = mon.faults
    f[#f + 1] = line
    if #f > 12 then table.remove(f, 1) end
    print("input " .. line)
end

-- Called for EVERY on_input event, in every mode. This is the contract
-- the whole game exists to verify.
local function protocol_check(action, phase, hold_ms)
    local now = clock_ms()
    mon.events     = mon.events + 1
    mon.win.events = mon.win.events + 1
    mon.last_event_ms = now
    hold_ms = hold_ms or 0

    local a = mon.st[action]
    if not a then
        fault(action, "unknown-action", "engine delivered action not in manifest")
        return
    end

    if hold_ms > a.max_hold   then a.max_hold   = hold_ms end
    if hold_ms > a.w_max_hold then a.w_max_hold = hold_ms end

    if phase == PRESS then
        a.e_press = true
        if a.down then
            fault(action, "double-press", "PRESS while already down (missing RELEASE)")
        end
        a.down = true
        a.p = a.p + 1; a.w_p = a.w_p + 1
        a.w_last_rep = 0
        if hold_ms > PRESS_HOLD_TOL then
            fault(action, "press-hold", fmt("PRESS hold_ms=%d (expected ~0)", hold_ms))
        end
        a.prev_hold = hold_ms

    elseif phase == REPEAT then
        if not a.down then
            fault(action, "repeat-not-down", "REPEAT while not down")
        end
        a.x = a.x + 1; a.w_x = a.w_x + 1
        if hold_ms < a.prev_hold then
            fault(action, "hold-regress",
                  fmt("REPEAT hold_ms=%d < prev %d", hold_ms, a.prev_hold))
        end
        if a.w_last_rep > 0 then
            local dt = now - a.w_last_rep
            a.w_rep_n     = a.w_rep_n + 1
            a.w_rep_dt_sum = a.w_rep_dt_sum + dt
            if dt < a.w_rep_dt_min then a.w_rep_dt_min = dt end
            if dt > a.w_rep_dt_max then a.w_rep_dt_max = dt end
        end
        a.w_last_rep = now
        a.prev_hold  = hold_ms

    elseif phase == RELEASE then
        a.e_release = true
        if not a.down then
            fault(action, "orphan-release", "RELEASE while not down")
        end
        a.down = false
        a.r = a.r + 1; a.w_r = a.w_r + 1
        if hold_ms < a.prev_hold then
            fault(action, "hold-regress-rel",
                  fmt("RELEASE hold_ms=%d < prev %d", hold_ms, a.prev_hold))
        end
        a.w_last_rep = 0
        a.prev_hold  = 0
    else
        fault(action, "bad-phase", fmt("unknown phase=%s", tostring(phase)))
    end
end

-- Reset window accumulators + snapshot stat baselines. Called when a
-- capture test transitions from "clear" (waiting all-up) to "collect".
local function mon_window_begin()
    local s = Input_stats()
    mon.win.faults    = 0
    mon.win.events    = 0
    mon.win.drop_base = s.dropped_total
    mon.win.gap_base  = s.seq_gaps
    for _, name in ipairs(ACTIONS) do
        mon.win.hold0[name] = Input_hold_ms(name)
        local a = mon.st[name]
        a.w_p, a.w_r, a.w_x, a.w_max_hold = 0, 0, 0, 0
        a.w_rep_n, a.w_rep_dt_sum = 0, 0
        a.w_rep_dt_min, a.w_rep_dt_max = huge, 0
        a.w_last_rep = 0
    end
end

local function win_view()
    local s = Input_stats()
    return {
        faults  = mon.win.faults,
        events  = mon.win.events,
        dropped = s.dropped_total - mon.win.drop_base,
        gaps    = s.seq_gaps      - mon.win.gap_base,
    }
end

-- Always-on per-tick invariant checks: pipeline integrity + poll/edge
-- consistency. Runs after the drain (so e_press/e_release reflect this
-- frame's events) and clears the one-tick edge flags at the end.
local function mon_tick()
    local s = Input_stats()
    if s.dropped_total > mon.drop_seen then
        fault("-", "pipeline-drop",
              fmt("dropped_total %d->%d (SPSC ring of %d overflowed)",
                  mon.drop_seen, s.dropped_total, RING_SZ))
        mon.drop_seen = s.dropped_total
    end
    if s.seq_gaps > mon.gap_seen then
        fault("-", "seq-gap",
              fmt("seq_gaps %d->%d (event lost before reaching the engine)",
                  mon.gap_seen, s.seq_gaps))
        mon.gap_seen = s.seq_gaps
    end
    for _, name in ipairs(ACTIONS) do
        local a = mon.st[name]
        if Input_is_down(name) ~= a.down then
            fault(name, "poll-mismatch",
                  fmt("is_down=%s but callback down=%s",
                      tostring(Input_is_down(name)), tostring(a.down)))
        end
        if Input_just_pressed(name) ~= a.e_press then
            fault(name, "edge-press",
                  fmt("just_pressed=%s but PRESS-this-tick=%s",
                      tostring(Input_just_pressed(name)), tostring(a.e_press)))
        end
        if Input_just_released(name) ~= a.e_release then
            fault(name, "edge-release",
                  fmt("just_released=%s but RELEASE-this-tick=%s",
                      tostring(Input_just_released(name)), tostring(a.e_release)))
        end
        a.e_press   = false
        a.e_release = false
    end
end

local function all_up()
    for _, name in ipairs(ACTIONS) do
        if Input_is_down(name) then return false end
    end
    return true
end

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "input", title = "INPUT TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    prev = "left", next = "right", fire = "enter",
    abortable = false, live = true,
    groups = {
        probe   = { label = "STATE PROBE",  what = "actions() + stats() shape" },
        pair    = { label = "SINGLE TAP",   what = "tap each button once" },
        idle    = { label = "IDLE",         what = "release all -> clean idle" },
        hold    = { label = "HOLD",         what = "long-press + repeat cadence" },
        combo   = { label = "COMBO",        what = "two buttons together" },
        stress  = { label = "STRESS",       what = "mash + alternate fast" },
        diag    = { label = "DIAGNOSTICS",  what = "monitor dump + hints" },
        session = { label = "CLEANUP",      what = "exit session" },
    },
    status = function()
        local s = Input_stats()
        return fmt("keys E:%s  L:%s  R:%s   hold %d/%d/%d ms\nmon  ev=%d flt=%d drop=%d gap=%d",
            Input_is_down("enter") and "DN" or "up",
            Input_is_down("left")  and "DN" or "up",
            Input_is_down("right") and "DN" or "up",
            Input_hold_ms("enter"), Input_hold_ms("left"), Input_hold_ms("right"),
            mon.events, mon.fault_count, s.dropped_total, s.seq_gaps)
    end,
    on_reset = function()
        mon.events, mon.fault_count = 0, 0
        for i = #mon.faults, 1, -1 do mon.faults[i] = nil end
        for _, name in ipairs(ACTIONS) do
            local a = mon.st[name]
            a.p, a.r, a.x, a.max_hold = 0, 0, 0, 0
        end
        local s = Input_stats()
        mon.drop_seen, mon.gap_seen = s.dropped_total, s.seq_gaps
    end,
})

-- Capture test: wait until every button is up (the press that started the
-- test must not count), then collect for window_ms. done(view, elapsed,
-- scratch) may end it early; validate(view, elapsed, scratch) -> ok, msg.
-- Any protocol fault inside the window fails it.
local function cap(group, name, prompt, window_ms, done, validate)
    S:async(group, name,
        function()
            return { phase = "clear", t_arm = clock_ms(), scratch = {} }
        end,
        function(rt)
            local now = clock_ms()
            if rt.phase == "clear" then
                -- force-start after 3 s so a stuck button cannot wedge the suite
                if (all_up() and (now - rt.t_arm) > 150) or (now - rt.t_arm > 3000) then
                    mon_window_begin()
                    rt.phase = "collect"
                    rt.t0    = now
                end
                return false
            end
            local d = win_view()
            local elapsed  = now - rt.t0
            local finished = elapsed >= window_ms
            if not finished and done and done(d, elapsed, rt.scratch) then
                finished = true
            end
            if not finished then return false end
            local ok, msg = validate(d, elapsed, rt.scratch)
            if d.faults > 0 then
                ok  = false
                msg = fmt("%d protocol fault(s); %s", d.faults, msg or "")
            end
            return true, ok, msg
        end,
        {
            settle_ms = 700,
            input = function() end,   -- protocol_check already counted it
            prompt = function(rt)
                if rt.phase == "clear" then return prompt .. "  (release all first)" end
                return prompt
            end,
        })
end

-- ── Group A: Probe / introspection (sync) ────────────────────────────
S:sync("probe", "Input.actions() shape", function()
    local A = Input_actions()
    if type(A) ~= "table" then return false, "actions() not a table" end
    local seen = {}
    for _, v in ipairs(A) do seen[v] = true end
    for _, name in ipairs(ACTIONS) do
        if not seen[name] then return false, fmt("missing action '%s'", name) end
    end
    return true, fmt("%d actions: %s", #A, concat(A, ","))
end)

S:sync("probe", "Input.stats() shape", function()
    local s = Input_stats()
    for _, k in ipairs({"events_total", "events_delta", "dropped_total", "seq_gaps"}) do
        if type(s[k]) ~= "number" then
            return false, fmt("stats.%s missing/not a number", k)
        end
    end
    return true, fmt("events=%d delta=%d drop=%d gaps=%d",
                     s.events_total, s.events_delta, s.dropped_total, s.seq_gaps)
end)

-- ── Group B: Pairing / reachability (capture) ────────────────────────
local function done_tap(name)
    return function(_d, _el, _sc)
        local a = mon.st[name]
        -- finish once a release is seen AND the input went quiet (so a
        -- fumbled double-tap lands inside this window and gets flagged).
        return a.w_r >= 1 and (clock_ms() - mon.last_event_ms) > TAP_SETTLE_MS
    end
end

local function val_tap(name)
    return function(_d, _el, _sc)
        for _, o in ipairs(ACTIONS) do
            if o ~= name and mon.st[o].w_p > 0 then
                return false, fmt("stray %s input - press only %s", o, name)
            end
        end
        local a = mon.st[name]
        if a.w_p == 0 then return false, "no PRESS seen (timed out)" end
        if a.w_p ~= a.w_r then
            return false, fmt("unbalanced p=%d r=%d", a.w_p, a.w_r)
        end
        if a.w_p ~= 1 then
            return false, fmt("expected 1 tap, got %d (retry: one clean tap)", a.w_p)
        end
        if a.w_x > 0 then
            return false, fmt("held too long -> %d REPEAT (tap = quick press)", a.w_x)
        end
        if a.w_max_hold == 0 then
            return false, "RELEASE carried hold_ms=0 (expected >0)"
        end
        return true, fmt("clean tap, release hold=%dms", a.w_max_hold)
    end
end

cap("pair", "Tap ENTER once", "Tap ENTER once (quick press + release)",
        6000, done_tap("enter"), val_tap("enter"))
cap("pair", "Tap LEFT once", "Tap LEFT once (quick press + release)",
        6000, done_tap("left"), val_tap("left"))
cap("pair", "Tap RIGHT once", "Tap RIGHT once (quick press + release)",
        6000, done_tap("right"), val_tap("right"))

-- ── Group C: Idle / neutral (capture) ────────────────────────────────
cap("idle", "Release all -> idle clean",
        "Release ALL buttons and DON'T touch them", 1500, nil,
        function(d, _el, _sc)
            for _, name in ipairs(ACTIONS) do
                if Input_is_down(name) then
                    return false, fmt("%s still down", name)
                end
                if Input_just_pressed(name) or Input_just_released(name) then
                    return false, fmt("%s edge flag stuck high", name)
                end
                -- hold_ms keeps the last event's value (0 after PRESS, the
                -- release hold after RELEASE); with no events it must not move.
                if Input_hold_ms(name) ~= mon.win.hold0[name] then
                    return false, fmt("%s hold_ms %d -> %d with no event", name,
                                      mon.win.hold0[name], Input_hold_ms(name))
                end
            end
            if d.events > 0 then
                return false, fmt("%d events during idle window", d.events)
            end
            return true, "idle neutral: down/edges clear, hold_ms stable"
        end)

-- ── Group D: Hold / auto-repeat (capture) ────────────────────────────
cap("hold", "Hold ENTER ~2s",
        "Press & HOLD ENTER ~2s, then release", 5000,
        function(_d, _el, _sc)
            local a = mon.st.enter
            return a.w_r >= 1 and (clock_ms() - mon.last_event_ms) > 250
        end,
        function(_d, el, _sc)
            local a = mon.st.enter
            if a.w_p == 0 then return false, "no PRESS (timed out)" end
            if a.w_x < 1 then
                return false, fmt("no REPEAT in %dms (hold > %dms)", el, REPEAT_DELAY_MS)
            end
            if a.w_p ~= a.w_r then
                return false, fmt("unbalanced p=%d r=%d", a.w_p, a.w_r)
            end
            return true, fmt("hold ok: %d repeat(s), peak hold=%dms", a.w_x, a.w_max_hold)
        end)

cap("hold", "Repeat cadence (hold ENTER 3s)",
        "HOLD ENTER the WHOLE time (measuring rate)", 3500, nil,
        function(_d, _el, _sc)
            local a = mon.st.enter
            if a.w_x < 3 then
                return false, fmt("only %d repeats - hold ENTER for the full 3s", a.w_x)
            end
            local avg = (a.w_rep_n > 0) and (a.w_rep_dt_sum // a.w_rep_n) or 0
            local lo  = (a.w_rep_dt_min == huge) and 0 or a.w_rep_dt_min
            local note = (avg >= REP_DT_LO and avg <= REP_DT_HI) and "in-band"
                         or fmt("OUT of [%d,%d]", REP_DT_LO, REP_DT_HI)
            -- Cadence active is the pass gate; exact dt is reported (it is
            -- timed outside the engine, so it is reported, not hard-gated).
            return true, fmt("reps=%d dt avg=%d min=%d max=%dms (~%dms nominal, %s)",
                             a.w_x, avg, lo, a.w_rep_dt_max, REPEAT_RATE_MS, note)
        end)

-- ── Group E: Concurrency (capture) ───────────────────────────────────
cap("combo", "Hold LEFT + RIGHT together",
        "Press & HOLD both LEFT and RIGHT at once", 6000,
        function(_d, _el, sc)
            if Input_is_down("left") and Input_is_down("right") then sc.both = true end
            return sc.both and all_up()
        end,
        function(_d, _el, sc)
            if not sc.both then
                return false, "never saw LEFT and RIGHT down simultaneously"
            end
            return true, "concurrent LEFT+RIGHT held (per-source state independent)"
        end)

-- ── Group F: Stress (capture) ────────────────────────────────────────
-- The mash tests are the heart of the suite: they flood the SPSC ring and
-- the back->head forward path. The contract is zero dropped_total and zero
-- seq_gaps growth (plus zero protocol faults, enforced by cap_step).
cap("stress", "Mash ENTER fast (5s)",
        "MASH ENTER as fast as you can!", 5000, nil,
        function(d, el, _sc)
            local a = mon.st.enter
            local secs = (el > 0) and (el / 1000) or 1
            local eps  = a.w_p / secs
            if a.w_p < 5 then
                return false, fmt("only %d presses in %ds - mash harder", a.w_p, floor(secs))
            end
            if d.dropped > 0 then
                return false, fmt("dropped=%d (input ring overflow!)", d.dropped)
            end
            if d.gaps > 0 then
                return false, fmt("seq_gaps=%d (events lost before reaching the engine)", d.gaps)
            end
            if a.w_p ~= a.w_r then
                return false, fmt("unbalanced after mash p=%d r=%d", a.w_p, a.w_r)
            end
            return true, fmt("%d presses, %.1f/s, 0 drop, 0 gap, balanced", a.w_p, eps)
        end)

cap("stress", "Mash ALL three (5s)",
        "MASH all THREE buttons randomly!", 5000, nil,
        function(d, el, _sc)
            local tp = 0
            for _, name in ipairs(ACTIONS) do tp = tp + mon.st[name].w_p end
            if tp < 9 then
                return false, fmt("only %d total presses - hit all three hard", tp)
            end
            if d.dropped > 0 then return false, fmt("dropped=%d", d.dropped) end
            if d.gaps > 0 then return false, fmt("seq_gaps=%d", d.gaps) end
            for _, name in ipairs(ACTIONS) do
                local a = mon.st[name]
                if a.w_p ~= a.w_r then
                    return false, fmt("%s unbalanced p=%d r=%d", name, a.w_p, a.w_r)
                end
            end
            local secs = (el > 0) and (el / 1000) or 1
            return true, fmt("%d events, %d/s, 0 drop/gap, all balanced",
                             d.events, floor(d.events / secs))
        end)

cap("stress", "Alternate LEFT/RIGHT (5s)",
        "Rapidly ALTERNATE LEFT then RIGHT", 5000, nil,
        function(d, _el, _sc)
            local l, r = mon.st.left, mon.st.right
            if l.w_p < 3 or r.w_p < 3 then
                return false, fmt("need both rapid: L=%d R=%d", l.w_p, r.w_p)
            end
            if d.dropped > 0 then return false, fmt("dropped=%d", d.dropped) end
            if d.gaps > 0 then return false, fmt("seq_gaps=%d", d.gaps) end
            if l.w_p ~= l.w_r or r.w_p ~= r.w_r then
                return false, fmt("unbalanced L p/r=%d/%d R p/r=%d/%d",
                                  l.w_p, l.w_r, r.w_p, r.w_r)
            end
            return true, fmt("L=%d R=%d presses, 0 drop/gap, balanced", l.w_p, r.w_p)
        end)

-- ── Group G: Diagnostics (sync) ──────────────────────────────────────
S:sync("diag", "monitor dump + DIAG hints", function()
    local s = Input_stats()
    print(fmt("input monitor: events=%d faults=%d drop=%d gaps=%d",
              mon.events, mon.fault_count, s.dropped_total, s.seq_gaps))
    for _, name in ipairs(ACTIONS) do
        local a = mon.st[name]
        print(fmt("input   %-5s p=%d r=%d x=%d max_hold=%dms down=%s",
                  name, a.p, a.r, a.x, a.max_hold, tostring(a.down)))
    end
    if mon.fault_count > 0 then
        print("input recent faults:")
        for _, line in ipairs(mon.faults) do print("input   " .. line) end
    end

    if mon.events == 0 then
        print("input DIAG: events=0 -> on_input never fired (no action bound "
              .. "to the buttons in manifest input.actions, or button events do "
              .. "not reach the engine)")
    end
    if s.dropped_total > 0 then
        print("input DIAG: dropped>0 -> the engine's input queue (" .. RING_SZ
              .. " events) overflowed between two frames (a long frame, or a "
              .. "flood deeper than the queue); on_input_lost reports it too.")
    end
    if s.seq_gaps > 0 then
        print("input DIAG: seq_gaps>0 -> event sequence skipped (lost on the "
              .. "way from the buttons to the engine's input ring).")
    end
    if mon.fault_count > 0 then
        print("input DIAG: faults>0 -> protocol invariant broken; the FAULT "
              .. "lines name the action + kind (double-press/orphan-release/"
              .. "poll-mismatch/edge-* = an engine input bug worth reporting).")
    end

    return true, fmt("events=%d faults=%d drop=%d gaps=%d (see DIAG/faults above)",
                     mon.events, mon.fault_count, s.dropped_total, s.seq_gaps)
end)

-- ── Group H: Session ─────────────────────────────────────────────────
S:sync("session", "Engine.exit", function()
    Engine.exit("input_done")
    return true, "exit posted; the session ends"
end, { manual = true })

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    print("input: actions = " .. concat(Input_actions(), ","))
    -- Baseline the drop/gap watermark so counters from earlier sessions
    -- don't trip a fault on the first tick.
    local s = Input_stats()
    mon.drop_seen, mon.gap_seen = s.dropped_total, s.seq_gaps
    S:start()
end

function on_input(action, phase, hold_ms)
    protocol_check(action, phase, hold_ms)   -- every event, in every mode
    S:input(action, phase, hold_ms)
end

function on_input_lost(count)
    fault("-", "engine-lost",
          fmt("on_input_lost(+%d) - engine dropped events (ring overflow)", count))
end

function on_tick(_dt)
    mon_tick()   -- first: validate this frame's edges + pipeline health
    S:tick()
end

function game_end()
    local s = Input_stats()
    S:summary(fmt("monitor events=%d faults=%d drop=%d gaps=%d",
                  mon.events, mon.fault_count, s.dropped_total, s.seq_gaps))
    for _, name in ipairs(ACTIONS) do
        local a = mon.st[name]
        print(fmt("input   %-5s p=%d r=%d x=%d max_hold=%dms",
                  name, a.p, a.r, a.x, a.max_hold))
    end
end
