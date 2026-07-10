-- button: input-pipeline stress + invariant suite for the engine's
-- action-mapped Input surface (bind_input.c + input_pump.c).
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
--          = the SPSC ring overflowed or an event was lost on the
--          back->head IPC/forward path)
--      Faults are counted, ring-logged, and printed as they happen.
--
--   2. Guided CAPTURE TESTS that prompt the operator ("Tap ENTER once",
--      "MASH all three", "Hold LEFT+RIGHT") and auto-validate the window.
--      Each test FAILS if any protocol fault fires during it.
--
-- Layout:
--   row 1   = "RUN SUITE (guided)" - walks every test (operator acts on cue)
--   row 2   = "Reset results + monitor"
--   row 3+  = probe / pairing / idle / hold / combo / stress / diag tests
--
-- Controls (MENU/single mode only):
--   LEFT/RIGHT : navigate   ENTER : fire highlighted row
-- During a capture test the buttons feed the test (nav is suspended); each
-- test self-terminates on its goal or a bounded timeout, so nothing hangs.
--
-- Pass criteria (head-side contract):
--   * Every Input.* call returns the documented type/value.
--   * Zero protocol faults across the session.
--   * Under mashing: dropped_total == 0 AND seq_gaps == 0.
--   * Cadence/hold values are reported (operator/OTD confirms timing).
--
-- Reference: pika_engine_old SD/games/input_test (basic counter); this is
-- the worldclass re-do matching the new led/servo stress-suite house style.

-- ── Localize hot upvalues ────────────────────────────────────────────
local Input_is_down       = Input.is_down
local Input_just_pressed  = Input.just_pressed
local Input_just_released = Input.just_released
local Input_hold_ms       = Input.hold_ms
local Input_stats         = Input.stats
local Input_actions       = Input.actions
-- One Text label, created lazily (Text.new needs the game screen).
local hud_lbl
local function HUD_set_label(s)
  if not Text then return end
  if hud_lbl then hud_lbl:set(s) else hud_lbl = Text.new(s, 4, 4) end
end
local PRESS, RELEASE, REPEAT = Input.PRESS, Input.RELEASE, Input.REPEAT
local pcall, ipairs, pairs = pcall, ipairs, pairs
local fmt    = string.format
local concat = table.concat
local huge   = math.huge
local floor  = math.floor

local clock_ms = (Engine and Engine.now_ms) or (Timer and Timer.millis)
                 or function() return 0 end

-- ── Constants (mirror engine internals; drift => a test FAILs) ────────
-- PIKA_INPUT_RING_SZ in input_internal.h. The mash tests must never push
-- more than this many events between two engine_task drains, or
-- dropped_total climbs - which is exactly the failure we watch for.
local RING_SZ         = 32
-- Back-side auto-repeat timing (back_esp32 button.h). Head only OBSERVES
-- the forwarded REPEAT stream; exact cadence is hardware/IPC-dependent so
-- these are expectation hints, not hard gates.
local REPEAT_DELAY_MS = 400        -- GAME_REPEAT_DELAY_MS: hold before 1st REPEAT
local REPEAT_RATE_MS  = 80         -- GAME_REPEAT_RATE_MS: nominal gap between REPEATs
local REP_DT_LO       = 40         -- soft lower bound for observed repeat dt
local REP_DT_HI       = 300        -- soft upper bound (frame + IPC jitter headroom)
local PRESS_HOLD_TOL  = 60         -- a PRESS should arrive with hold_ms ~0
local TAP_SETTLE_MS   = 400        -- quiet gap that ends a "single tap" capture

-- The three manifest-declared actions (1:1 with the physical buttons).
-- ENTER acts as fire/confirm and LEFT/RIGHT as nav while in MENU mode.
local ACTIONS = {"enter", "left", "right"}

local R_PASS, R_FAIL, R_SKIP = "PASS", "FAIL", "SKIP"

-- ── Protocol monitor ─────────────────────────────────────────────────
local mon = {
    events      = 0,          -- session cumulative event count
    fault_count = 0,          -- session cumulative faults
    faults      = {},         -- ring of recent fault strings (cap 12)
    last_event_ms = 0,
    drop_seen   = 0,          -- last dropped_total we reported on (fault gate)
    gap_seen    = 0,          -- last seq_gaps we reported on
    win = { faults = 0, events = 0, drop_base = 0, gap_base = 0 },
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
    print("button " .. line)
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
              fmt("seq_gaps %d->%d (event lost on back->head IPC path)",
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

-- ── Test registry ────────────────────────────────────────────────────
-- Descriptor shapes:
--   { group, name, kind = "meta", action }
--   { group, name, sync = fn() -> (ok, msg) }
--   { group, name, prompt, cap = { window_ms, done, validate } }
-- A capture test's done(view, elapsed, scratch) -> bool early-finish, and
-- validate(view, elapsed, scratch) -> (ok, msg). `view` is win_view();
-- per-action window counters are read directly off mon.st[...]. `scratch`
-- is a per-arm table for tests that must remember cross-tick facts.
local TESTS = {}

local function reg_meta(group, name, action)
    TESTS[#TESTS + 1] = { group = group, name = name, kind = "meta", action = action }
end
local function reg_sync(group, name, fn)
    TESTS[#TESTS + 1] = { group = group, name = name, sync = fn }
end
local function reg_cap(group, name, prompt, window_ms, done, validate)
    TESTS[#TESTS + 1] = { group = group, name = name, prompt = prompt,
        cap = { window_ms = window_ms, done = done, validate = validate } }
    TESTS[#TESTS].settle_ms = 700
end

-- ── Meta rows ────────────────────────────────────────────────────────
reg_meta("runner", "RUN SUITE (guided)",       "suite")
reg_meta("runner", "Reset results + monitor",  "reset")

-- ── Group A: Probe / introspection (sync) ────────────────────────────
reg_sync("probe", "Input.actions() shape", function()
    local A = Input_actions()
    if type(A) ~= "table" then return false, "actions() not a table" end
    local seen = {}
    for _, v in ipairs(A) do seen[v] = true end
    for _, name in ipairs(ACTIONS) do
        if not seen[name] then return false, fmt("missing action '%s'", name) end
    end
    return true, fmt("%d actions: %s", #A, concat(A, ","))
end)

reg_sync("probe", "Input.stats() shape", function()
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

reg_cap("pair", "Tap ENTER once", "Tap ENTER once (quick press + release)",
        6000, done_tap("enter"), val_tap("enter"))
reg_cap("pair", "Tap LEFT once", "Tap LEFT once (quick press + release)",
        6000, done_tap("left"), val_tap("left"))
reg_cap("pair", "Tap RIGHT once", "Tap RIGHT once (quick press + release)",
        6000, done_tap("right"), val_tap("right"))

-- ── Group C: Idle / neutral (capture) ────────────────────────────────
reg_cap("idle", "Release all -> idle clean",
        "Release ALL buttons and DON'T touch them", 1500, nil,
        function(d, _el, _sc)
            for _, name in ipairs(ACTIONS) do
                if Input_is_down(name) then
                    return false, fmt("%s still down", name)
                end
                if Input_just_pressed(name) or Input_just_released(name) then
                    return false, fmt("%s edge flag stuck high", name)
                end
                if Input_hold_ms(name) ~= 0 then
                    return false, fmt("%s hold_ms=%d (expected 0)", name, Input_hold_ms(name))
                end
            end
            if d.events > 0 then
                return false, fmt("%d events during idle window", d.events)
            end
            return true, "idle neutral: down/edges/hold all clear"
        end)

-- ── Group D: Hold / auto-repeat (capture) ────────────────────────────
reg_cap("hold", "Hold ENTER ~2s",
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

reg_cap("hold", "Repeat cadence (hold ENTER 3s)",
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
            -- back-timed over IPC, so it is OTD-confirmed, not hard-gated).
            return true, fmt("reps=%d dt avg=%d min=%d max=%dms (~%dms nominal, %s)",
                             a.w_x, avg, lo, a.w_rep_dt_max, REPEAT_RATE_MS, note)
        end)

-- ── Group E: Concurrency (capture) ───────────────────────────────────
reg_cap("combo", "Hold LEFT + RIGHT together",
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
reg_cap("stress", "Mash ENTER fast (5s)",
        "MASH ENTER as fast as you can!", 5000, nil,
        function(d, el, _sc)
            local a = mon.st.enter
            local secs = (el > 0) and (el / 1000) or 1
            local eps  = a.w_p / secs
            if a.w_p < 5 then
                return false, fmt("only %d presses in %ds - mash harder", a.w_p, floor(secs))
            end
            if d.dropped > 0 then
                return false, fmt("dropped=%d (SPSC ring overflow!)", d.dropped)
            end
            if d.gaps > 0 then
                return false, fmt("seq_gaps=%d (events lost on IPC path)", d.gaps)
            end
            if a.w_p ~= a.w_r then
                return false, fmt("unbalanced after mash p=%d r=%d", a.w_p, a.w_r)
            end
            return true, fmt("%d presses, %.1f/s, 0 drop, 0 gap, balanced", a.w_p, eps)
        end)

reg_cap("stress", "Mash ALL three (5s)",
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

reg_cap("stress", "Alternate LEFT/RIGHT (5s)",
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
reg_sync("diag", "monitor dump + DIAG hints", function()
    local s = Input_stats()
    print(fmt("button monitor: events=%d faults=%d drop=%d gaps=%d",
              mon.events, mon.fault_count, s.dropped_total, s.seq_gaps))
    for _, name in ipairs(ACTIONS) do
        local a = mon.st[name]
        print(fmt("button   %-5s p=%d r=%d x=%d max_hold=%dms down=%s",
                  name, a.p, a.r, a.x, a.max_hold, tostring(a.down)))
    end
    if mon.fault_count > 0 then
        print("button recent faults:")
        for _, line in ipairs(mon.faults) do print("button   " .. line) end
    end

    if mon.events == 0 then
        print("button DIAG: events=0 -> on_input never fired (game session "
              .. "inactive? back not forwarding GAME_INPUT? STATE_GAME gate? "
              .. "engine_level<6 or manifest input.actions missing?)")
    end
    if s.dropped_total > 0 then
        print("button DIAG: dropped>0 -> head SPSC ring (" .. RING_SZ
              .. " slots) overflowed faster than engine_task drained "
              .. "(frame stall, or flood exceeded ring depth).")
    end
    if s.seq_gaps > 0 then
        print("button DIAG: seq_gaps>0 -> event sequence skipped (lost on the "
              .. "back->head IPC/forward path before reaching the ring).")
    end
    if mon.fault_count > 0 then
        print("button DIAG: faults>0 -> protocol invariant broken; the FAULT "
              .. "lines name the action + kind (double-press/orphan-release/"
              .. "poll-mismatch/edge-* = pump or back edge-logic bug).")
    end

    return true, fmt("events=%d faults=%d drop=%d gaps=%d (see DIAG/faults above)",
                     mon.events, mon.fault_count, s.dropped_total, s.seq_gaps)
end)

-- ── Group H: Session ─────────────────────────────────────────────────
reg_sync("session", "Engine.exit", function()
    Engine.exit("button_done")
    return true, "exit posted; session ends, input reset on back"
end)

-- ── Runner state ─────────────────────────────────────────────────────
local N_TESTS      = #TESTS
local cursor       = 1
local mode         = "single"     -- "single" | "between" | "running_cap"
local in_suite     = false
local active       = nil           -- index of in-flight capture test, or nil
local cap_rt       = nil           -- capture runtime { phase, t_arm, t0, t_end, scratch }
local active_prompt = nil
local settle_until = 0

local results = {}
local total_pass, total_fail, total_skip = 0, 0, 0

local hud_dirty    = true
local hud_last_ms  = 0
local hud_buf      = {}
local hud_last_str = ""
local RENDER_MIN_MS = 80
local SETTLE_MS     = 900

local function dirty() hud_dirty = true end

local function record(idx, status, msg)
    if results[idx] then
        if     results[idx].status == R_PASS then total_pass = total_pass - 1
        elseif results[idx].status == R_FAIL then total_fail = total_fail - 1
        elseif results[idx].status == R_SKIP then total_skip = total_skip - 1
        end
    end
    results[idx] = { status = status, msg = msg, t_ms = clock_ms() }
    if     status == R_PASS then total_pass = total_pass + 1
    elseif status == R_FAIL then total_fail = total_fail + 1
    elseif status == R_SKIP then total_skip = total_skip + 1
    end
end

local meta_dispatch  -- forward decl

local function log_begin(idx, t)
    print(fmt("button [%02d/%02d] BEGIN  %-7s :: %s", idx, N_TESTS, t.group, t.name))
end
local function log_end(idx, t, status, msg)
    if msg == nil or msg == "" then msg = "(no detail)" end
    print(fmt("button [%02d/%02d] %-4s   %-7s :: %s :: %s",
              idx, N_TESTS, status, t.group, t.name, msg))
end

local function fire(idx)
    local t = TESTS[idx]
    if not t then return "sync_done" end

    if t.kind == "meta" then
        meta_dispatch(t.action)
        return "meta_done"
    end

    log_begin(idx, t)

    if t.sync then
        local ok, a, b = pcall(t.sync)
        local pass, msg
        if not ok then pass, msg = false, "lua error: " .. tostring(a)
        else           pass, msg = a, b or "" end
        local status = pass and R_PASS or R_FAIL
        record(idx, status, msg)
        log_end(idx, t, status, msg)
        dirty()
        return "sync_done"
    end

    -- capture test: enter "clear" phase (wait for all-up + brief settle so
    -- the button that fired/advanced this test is not counted in the window).
    active        = idx
    cap_rt        = { phase = "clear", t_arm = clock_ms(), scratch = {} }
    active_prompt = t.prompt
    mode          = "running_cap"
    dirty()
    return "cap_armed"
end

local function cap_step()
    local t  = TESTS[active]
    local c  = t.cap
    local rt = cap_rt
    local now = clock_ms()

    if rt.phase == "clear" then
        -- Begin once buttons are released (operator let go of the trigger),
        -- or force-start after 3s so a stuck button can't wedge the suite.
        if (all_up() and (now - rt.t_arm) > 150) or (now - rt.t_arm > 3000) then
            mon_window_begin()
            rt.phase = "collect"
            rt.t0    = now
            rt.t_end = now + c.window_ms
        end
        return
    end

    -- collect
    local d = win_view()
    local elapsed  = now - rt.t0
    local finished = elapsed >= c.window_ms
    if not finished and c.done and c.done(d, elapsed, rt.scratch) then
        finished = true
    end
    if not finished then return end

    local ok, msg = c.validate(d, elapsed, rt.scratch)
    if d.faults > 0 then
        ok  = false
        msg = fmt("%d protocol fault(s); %s", d.faults, msg or "")
    end
    local status = ok and R_PASS or R_FAIL
    record(active, status, msg or "")
    log_end(active, t, status, msg or "")
    active, cap_rt, active_prompt = nil, nil, nil
    mode = "single"
    dirty()
end

-- ── Suite walker ─────────────────────────────────────────────────────
local FIRST_TEST_IDX = 1
do
    for i, t in ipairs(TESTS) do
        if t.kind ~= "meta" then FIRST_TEST_IDX = i; break end
    end
end

local function suite_step(settle_override_ms)
    while cursor <= N_TESTS and TESTS[cursor].kind == "meta" do
        cursor = cursor + 1
    end
    if cursor > N_TESTS then
        in_suite = false
        mode = "single"
        cursor = N_TESTS
        print("button ============================================")
        print(fmt("button SUITE END :: PASS=%d  FAIL=%d  SKIP=%d  (of %d total)",
                  total_pass, total_fail, total_skip,
                  N_TESTS - (FIRST_TEST_IDX - 1)))
        print("button ============================================")
        dirty()
        return
    end
    settle_until = clock_ms() + (settle_override_ms or SETTLE_MS)
    mode = "between"
    dirty()
end

local function suite_start()
    cursor = FIRST_TEST_IDX
    total_pass, total_fail, total_skip = 0, 0, 0
    for k in pairs(results) do results[k] = nil end
    in_suite = true
    print("button ============================================")
    print(fmt("button SUITE BEGIN :: %d tests queued (act on each prompt)",
              N_TESTS - (FIRST_TEST_IDX - 1)))
    print("button ============================================")
    suite_step()
end

local function reset_results()
    total_pass, total_fail, total_skip = 0, 0, 0
    for k in pairs(results) do results[k] = nil end
    mon.events, mon.fault_count = 0, 0
    for i = #mon.faults, 1, -1 do mon.faults[i] = nil end
    for _, name in ipairs(ACTIONS) do
        local a = mon.st[name]
        a.p, a.r, a.x, a.max_hold = 0, 0, 0, 0
    end
    local s = Input_stats()
    mon.drop_seen, mon.gap_seen = s.dropped_total, s.seq_gaps
    print("button: results + monitor reset")
    dirty()
end

meta_dispatch = function(action)
    if     action == "suite" then suite_start()
    elseif action == "reset" then reset_results()
    end
end

-- ── HUD ──────────────────────────────────────────────────────────────
-- Structured panel: a fixed-width rule sets the block width, every line
-- left-aligns to it, indentation gives hierarchy, and each row carries a
-- plain-language group label + "what it tests" so the screen reads as
-- features, not internal code names. Capture rows show the action prompt
-- in place of the result while the operator is acting.
local ssub    = string.sub
local PANEL_W = 40
local RULE    = string.rep("-", PANEL_W)

local GROUP_INFO = {
    runner = { label = "SUITE CONTROL", what = "guided run / reset monitor" },
    probe  = { label = "STATE PROBE",   what = "actions() + stats() shape" },
    pair   = { label = "SINGLE TAP",    what = "tap each button once" },
    idle   = { label = "IDLE",          what = "release all -> clean idle" },
    hold   = { label = "HOLD",          what = "long-press + repeat cadence" },
    combo  = { label = "COMBO",         what = "two buttons together" },
    stress = { label = "STRESS",        what = "mash + alternate fast" },
    diag   = { label = "DIAGNOSTICS",   what = "monitor dump + hints" },
    session= { label = "CLEANUP",       what = "exit session" },
}
local GROUP_FALLBACK = { label = "TEST", what = "" }
local function group_info(g) return GROUP_INFO[g] or GROUP_FALLBACK end
local function clip_w(s)
    if #s > PANEL_W then return ssub(s, 1, PANEL_W - 1) .. "~" end
    return s
end

local function format_hud()
    local n  = 0
    local t  = TESTS[cursor]
    local gi = group_info(t.group)

    n = n + 1; hud_buf[n] = fmt("BUTTON TEST           %02d/%02d", cursor, N_TESTS)
    n = n + 1; hud_buf[n] = fmt("mode %-7s  PASS %d  FAIL %d  SKIP %d",
        mode, total_pass, total_fail, total_skip)
    n = n + 1; hud_buf[n] = RULE

    n = n + 1; hud_buf[n] = clip_w("NOW  > " .. gi.label)
    if gi.what ~= "" then
        n = n + 1; hud_buf[n] = clip_w("     " .. gi.what)
    end
    n = n + 1; hud_buf[n] = clip_w("     case: " .. t.name)
    n = n + 1; hud_buf[n] = RULE

    if mode == "running_cap" and active_prompt then
        n = n + 1; hud_buf[n] = clip_w("ACTION  " .. active_prompt)
        if cap_rt and cap_rt.phase == "clear" then
            n = n + 1; hud_buf[n] = "        (release all buttons first)"
        end
    else
        local r = results[cursor]
        if r then
            n = n + 1; hud_buf[n] = fmt("RESULT  %s", r.status)
            if r.msg and r.msg ~= "" then
                n = n + 1; hud_buf[n] = clip_w("        " .. r.msg)
            end
        else
            n = n + 1; hud_buf[n] = "RESULT  (not run)"
        end
    end
    n = n + 1; hud_buf[n] = RULE

    -- Live input state + monitor health.
    local s = Input_stats()
    n = n + 1; hud_buf[n] = fmt("keys E:%s  L:%s  R:%s",
        Input_is_down("enter") and "DN" or "up",
        Input_is_down("left")  and "DN" or "up",
        Input_is_down("right") and "DN" or "up")
    n = n + 1; hud_buf[n] = clip_w(fmt("hold %d / %d / %d ms  (E/L/R)",
        Input_hold_ms("enter"), Input_hold_ms("left"), Input_hold_ms("right")))
    n = n + 1; hud_buf[n] = clip_w(fmt("mon  ev=%d flt=%d drop=%d gap=%d",
        mon.events, mon.fault_count, s.dropped_total, s.seq_gaps))

    n = n + 1; hud_buf[n] = in_suite
        and "SUITE running   act on each prompt"
        or  "ENTER=fire   LEFT/RIGHT=nav   row1=suite"

    for i = n + 1, #hud_buf do hud_buf[i] = nil end
    return concat(hud_buf, "\n", 1, n)
end

local function render_if_dirty()
    if not hud_dirty then return end
    local now = clock_ms()
    if (now - hud_last_ms) < RENDER_MIN_MS then return end
    local str = format_hud()
    if str ~= hud_last_str then
        HUD_set_label(str)
        hud_last_str = str
    end
    hud_last_ms = now
    hud_dirty = false
end

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    local ev = (Engine and Engine.version and Engine.version()) or "?"
    print(fmt("button: game_start engine=%s tests=%d",
              tostring(ev), N_TESTS))
    local A = Input_actions()
    print("button: actions = " .. concat(A, ","))
    -- Baseline the drop/gap watermark so pre-existing counters from earlier
    -- sessions don't trip a fault on the first tick.
    local s = Input_stats()
    mon.drop_seen, mon.gap_seen = s.dropped_total, s.seq_gaps
    dirty()
end

function on_input(action, phase, hold_ms)
    protocol_check(action, phase, hold_ms)   -- ALWAYS - this is the contract

    if mode == "running_cap" then
        return  -- buttons feed the active test; the monitor already logged it
    end

    if phase ~= PRESS then return end
    if mode ~= "single" then return end       -- ignore input during "between"

    if action == "left" then
        cursor = (cursor > 1) and (cursor - 1) or N_TESTS
        dirty()
    elseif action == "right" then
        cursor = (cursor < N_TESTS) and (cursor + 1) or 1
        dirty()
    elseif action == "enter" then
        fire(cursor)
    end
end

function on_input_lost(count)
    fault("-", "engine-lost",
          fmt("on_input_lost(+%d) - engine dropped events (ring overflow)", count))
end

function on_tick(_dt)
    mon_tick()   -- runs first: validate this frame's edges + pipeline health

    if mode == "between" and clock_ms() >= settle_until then
        local r = fire(cursor)
        if r == "sync_done" or r == "meta_done" then
            if in_suite then
                local finished_settle = TESTS[cursor].settle_ms
                cursor = cursor + 1
                suite_step(finished_settle)
            else
                mode = "single"
            end
        end

    elseif mode == "running_cap" then
        cap_step()
        if not active and in_suite then
            local finished_settle = TESTS[cursor].settle_ms
            cursor = cursor + 1
            suite_step(finished_settle)
        end
    end

    dirty()           -- live HUD feedback (down-state/hold); throttled below
    render_if_dirty()
end

function game_end()
    print("button ============================================")
    print(fmt("button SUMMARY :: PASS=%d  FAIL=%d  SKIP=%d  total=%d",
              total_pass, total_fail, total_skip, N_TESTS))
    print("button ============================================")
    for i, t in ipairs(TESTS) do
        if t.kind ~= "meta" then
            local r = results[i]
            if r then
                print(fmt("button [%02d/%02d] %-4s   %-7s :: %s :: %s",
                          i, N_TESTS, r.status, t.group, t.name, r.msg))
            else
                print(fmt("button [%02d/%02d] ----   %-7s :: %s :: not run",
                          i, N_TESTS, t.group, t.name))
            end
        end
    end
    print("button ============================================")
    local s = Input_stats()
    print(fmt("button FINAL monitor events=%d faults=%d drop=%d gaps=%d",
              mon.events, mon.fault_count, s.dropped_total, s.seq_gaps))
    for _, name in ipairs(ACTIONS) do
        local a = mon.st[name]
        print(fmt("button   %-5s p=%d r=%d x=%d max_hold=%dms",
                  name, a.p, a.r, a.x, a.max_hold))
    end
end
