-- test_telemetry: the Telemetry API (Telemetry.event, Telemetry.caps) on a robot.
--
-- Groups (suite order):
--   probe  : Telemetry.caps() shape, limits = contract/constraints.json tel_*,
--            a new table on every call
--   guard  : every bad argument returns false and never raises. Each batch
--            first waits for a free window slot and ends with one valid
--            control call that must return true, so the falses come from the
--            argument rules and not from the rate window.
--   start  : calls made in game_start are held until game.start: 3 return
--            true, the 4th false (hold buffer full). The held calls fill the
--            rate window, so the first on_tick call returns false (recorded
--            at boot, reported here).
--   valid  : accepted payloads: value types, float rounding, strings, 8 fields
--            of 296 encoded bytes, opts.key / opts.level, name edges, nil
--            holes and extra arguments, metatables ignored, unknown opts key
--   rate   : window edges at the exact millisecond, a call every frame,
--            paced calls that must all pass
--   vector : contract/telemetry_vectors.json replayed one vector at a time
--            (libs/tel_vectors.lua, generated from that file)
--   diag   : session counters = what game.stop must report
--   manual : rows RUN SUITE skips: a 10 min soak (network unplug check),
--            Engine.exit (game_end calls are refused), error() after an event
--
-- Lua only sees true/false, never the reason. Every call goes through
-- invoke(): it pcalls (a raise is a FAIL), keeps a model of the
-- 3-per-5000-ms window fed with real call times and prints, for every
-- accepted call, the data the server must receive:
--   telemetry sent ev=<name> key=game.tel[.<key>] level=<INFO|WARN|ERROR> data=<json>
-- The events reach the server (MQTT game.tel, then Datadog) only on a robot
-- with network: compare those lines with Datadog there. Smoke and Pika Studio
-- send nothing. game_end prints the game.stop tel=<sent>/<drop> this session
-- must show. RUN SUITE runs unattended; only the manual rows need a person.
--
-- Docs: docs/reference/api.md#telemetry (the call), docs/reference/telemetry.md
-- and contract/pages/telemetry.md (game.stop tel=, the reject / opt_unknown
-- log lines).

-- ── Constants ────────────────────────────────────────────────────────
-- contract/constraints.json limits
local RATE_MAX       = 3      -- tel_rate_max
local WINDOW_MS      = 5000   -- tel_rate_window_ms
local NAME_MAX       = 24     -- tel_name_max
local KEY_MAX        = 24     -- tel_key_max
local FIELDS_MAX     = 8      -- tel_fields_max
local FIELD_NAME_MAX = 16     -- tel_field_name_max
local STR_MAX        = 40     -- tel_str_max
local FIELDS_BYTES   = 300    -- tel_fields_max_bytes

local CAPS_WANT = {
    rate_max = RATE_MAX, rate_window_ms = WINDOW_MS, name_max = NAME_MAX,
    key_max = KEY_MAX, fields_max = FIELDS_MAX, field_name_max = FIELD_NAME_MAX,
    str_max = STR_MAX, fields_max_bytes = FIELDS_BYTES,
}

local SLOT_MARGIN_MS  = 2       -- wait past the window edge before a must-pass call
local MAX_CALLS_TICK  = 24      -- calls one async step may make in one frame
-- The exact-ms window edge cannot be hit at ~33 ms frames, so the edge steps
-- spin up to EDGE_SPIN_MS (far below the 1500 ms hook watchdog). The spin is
-- also bounded by a count: in smoke Timer.millis does not move inside a hook.
local EDGE_SPIN_MS    = 40
local EDGE_SPIN_MAX   = 200000
local TEST_TIMEOUT_MS = 60000
local SPAM_MS         = 6000    -- a call every frame for this long
local PACE_MS         = 1700    -- 3 calls per 5100 ms: never over the window
local PACE_FOR_MS     = 10300
local SOAK_MS         = 600000

local TAG = "telemetry"
local fmt, concat, sort = string.format, table.concat, table.sort
local now = Timer.millis

local T  = Telemetry
local EV = T and T.event
local V  = require("libs/tel_vectors")

-- ── Session model ────────────────────────────────────────────────────
-- sess.ok / sess.bad count results before game_end: they must equal
-- game.stop tel=<sent>/<drop> (calls after the game ended are not counted).
local sess = { started = false, closed = false, held = 0,
               ok = 0, bad = 0, raised = 0, opt_unknown = 0 }
-- Last RATE_MAX accepted calls, oldest first: the binding read the clock
-- somewhere in [lo, hi] (Timer.millis before and after the call).
local acc_lo, acc_hi, acc_n = {}, {}, 0

local function take(lo, hi)
    if acc_n < RATE_MAX then
        acc_n = acc_n + 1
    else
        for i = 1, RATE_MAX - 1 do
            acc_lo[i], acc_hi[i] = acc_lo[i + 1], acc_hi[i + 1]
        end
    end
    acc_lo[acc_n], acc_hi[acc_n] = lo, hi
end

-- "send" / "reject" / "either" for a valid call made between t0 and t1.
local function predict(t0, t1)
    if sess.closed then return "reject" end
    if not sess.started and sess.held >= RATE_MAX then return "reject" end
    if acc_n < RATE_MAX then return "send" end
    if t0 - acc_hi[1] >= WINDOW_MS then return "send" end
    if t1 - acc_lo[1] < WINDOW_MS then return "reject" end
    return "either"
end

-- ms until one more call is certain to pass.
local function slot_in()
    if acc_n < RATE_MAX then return 0 end
    local d = acc_hi[1] + WINDOW_MS + SLOT_MARGIN_MS - now()
    return d > 0 and d or 0
end

-- ms until the window is empty (RATE_MAX calls in a row are certain to pass).
local function clear_in()
    if acc_n == 0 then return 0 end
    local d = acc_hi[acc_n] + WINDOW_MS + SLOT_MARGIN_MS - now()
    return d > 0 and d or 0
end

local function in_window()
    local n, t = 0, now()
    for i = 1, acc_n do
        if t - acc_hi[i] < WINDOW_MS then n = n + 1 end
    end
    return n
end

-- ── Expected server data ─────────────────────────────────────────────
-- Same transforms as the engine: bool -> 0/1, float -> round half away from
-- zero, '"' '\' control bytes and DEL -> '_'. Read with next/rawget: the
-- engine ignores metamethods, so the printer must too.
local function clean(s) return (s:gsub('[%z\1-\31"\\\127]', "_")) end

local function json_value(v)
    local mt = math.type(v)
    if mt == "integer" then return tostring(v) end
    if mt == "float" then
        local r = (v >= 0) and math.floor(v + 0.5) or -math.floor(-v + 0.5)
        return fmt("%d", math.tointeger(r) or 0)
    end
    if type(v) == "boolean" then return v and "1" or "0" end
    return '"' .. clean(v) .. '"'
end

local function data_json(data)
    if type(data) ~= "table" then return "{}" end
    local keys = {}
    for k in next, data do keys[#keys + 1] = k end
    sort(keys)
    local parts = {}
    for i, k in ipairs(keys) do parts[i] = '"' .. k .. '":' .. json_value(rawget(data, k)) end
    return "{" .. concat(parts, ",") .. "}"
end

local LEVEL = { info = "INFO", warn = "WARN", error = "ERROR" }

local function print_sent(name, fields, opts, data)
    local key, level = "game.tel", "INFO"
    if type(opts) == "table" then
        local k, l = rawget(opts, "key"), rawget(opts, "level")
        if type(k) == "string" then key = key .. "." .. k end
        level = LEVEL[l] or level
    end
    if data == nil then data = fields end
    print(fmt("%s sent ev=%s key=%s level=%s data=%s", TAG, tostring(name), key, level,
              data_json(data)))
end

-- ── The one call path ────────────────────────────────────────────────
-- want: "reject" = invalid by the rules, must be false whatever the window;
--       "model"  = valid, must match the window model;
--       "send"   = valid, the caller waited for a slot: must be true.
-- raw: an argument list passed as is ({ n = <count>, ... }).
-- Returns got (boolean), pred, fail (string or nil).
local function invoke(want, name, fields, opts, raw, data)
    if not EV then return false, "reject", "no Telemetry.event on this head" end
    local t0 = now()
    local ok, got
    if raw then ok, got = pcall(EV, table.unpack(raw, 1, raw.n))
    else ok, got = pcall(EV, name, fields, opts) end
    local t1 = now()

    local pred = (want == "reject") and "reject" or predict(t0, t1)
    local fail
    if not ok then
        fail = "raised: " .. tostring(got)
        got = false
        if not sess.closed then sess.raised = sess.raised + 1 end
    elseif type(got) ~= "boolean" then
        fail = "returned a " .. type(got) .. ", not a boolean"
        got = false
    end
    if got then
        take(t0, t1)
        if not sess.started then sess.held = sess.held + 1 end
    end
    if not sess.closed then
        if got then sess.ok = sess.ok + 1 else sess.bad = sess.bad + 1 end
    end

    local label = type(name) == "string" and clean(name) or ("<" .. type(name) .. ">")
    if not fail then
        if pred == "reject" and got then
            fail = (want == "reject") and ("accepted an invalid call ev=" .. label)
                or ("accepted over the rate window ev=" .. label)
        elseif pred == "send" and not got then
            fail = "refused a valid call with room in the window ev=" .. label
        end
    end
    if got and not sess.closed then
        local o = raw and raw[3] or opts
        if type(o) == "table" then
            for k in next, o do
                if k ~= "key" and k ~= "level" then sess.opt_unknown = sess.opt_unknown + 1; break end
            end
        end
        print_sent(raw and raw[1] or name, raw and raw[2] or fields, o, data)
    end
    return got, pred, fail
end

-- ── Scripted async tests ─────────────────────────────────────────────
-- A step is one call: { name, fields, opts, raw, data, want, ... } plus
--   clear = true   wait until the window is empty, then start a block (base)
--   slot = true    wait until one call is certain to pass
--   at = ms        not before block base + ms
--   edge = ms      exactly ms after the oldest call in the window
--   for_ms, every_ms  repeat the call every every_ms (0 = every frame) for
--                  for_ms; all_true = every repeat must return true
--   expect         the contract vector's expected result (counted as exact)
local function new_run(steps)
    return { steps = steps, i = 1, base = now(), cleared = false,
             calls = 0, trues = 0, falses = 0, either = 0, exact = 0, expects = 0,
             nfail = 0, first = nil, wait = nil, rep_end = nil, rep_next = 0,
             edge_hit = 0, edge_miss = 0 }
end

local function one_call(st, s)
    local got, pred, fail = invoke(s.want, s.name, s.fields, s.opts, s.raw, s.data)
    st.calls = st.calls + 1
    if got then st.trues = st.trues + 1 else st.falses = st.falses + 1 end
    if pred == "either" then st.either = st.either + 1 end
    if s.all_true and not got and not fail then fail = "paced call refused ev=" .. tostring(s.name) end
    if s.expect then
        st.expects = st.expects + 1
        if (s.expect == "send") == got then st.exact = st.exact + 1 end
    end
    if fail then
        st.nfail = st.nfail + 1
        if not st.first then st.first = fmt("step %d: %s", st.i, fail) end
        print(fmt("%s fail step=%d %s", TAG, st.i, fail))
    end
end

local function next_step(st)
    st.i = st.i + 1
    st.cleared = false
    st.rep_end = nil
end

-- Returns true when every step ran.
local function run_steps(st)
    local steps = st.steps
    local calls = 0
    while st.i <= #steps do
        local s = steps[st.i]
        local t = now()
        st.wait = nil
        if s.clear and not st.cleared then
            local d = clear_in()
            if d > 0 then st.wait = fmt("window empties in %d ms", d); return false end
            st.cleared = true
            st.base = t
        end
        if (s.slot or s.want == "send") and slot_in() > 0 then
            st.wait = fmt("free slot in %d ms", slot_in())
            return false
        end
        if s.at and t < st.base + s.at then
            st.wait = fmt("at +%d ms", s.at)
            return false
        end
        if s.edge then
            if acc_n == 0 then
                st.nfail = st.nfail + 1
                st.first = st.first or "edge step with an empty window"
                next_step(st)
                return false
            end
            local target = acc_hi[1] + s.edge
            if target - now() > EDGE_SPIN_MS then st.wait = "edge +" .. s.edge; return false end
            local n = 0
            while now() < target and n < EDGE_SPIN_MAX do n = n + 1 end
            -- Never early: if the spin ran out (smoke), call on a later frame.
            if now() < target then st.wait = "edge +" .. s.edge; return false end
            if now() == target and acc_lo[1] == acc_hi[1] then st.edge_hit = st.edge_hit + 1
            else st.edge_miss = st.edge_miss + 1 end
        end
        if s.for_ms then
            if not st.rep_end then st.rep_end, st.rep_next = t + s.for_ms, t end
            if t >= st.rep_end then next_step(st); return false end
            if t >= st.rep_next then
                one_call(st, s)
                st.rep_next = (s.every_ms > 0) and (st.rep_next + s.every_ms) or t
            end
            st.wait = fmt("repeating, %d s left", (st.rep_end - t) // 1000)
            return false
        end
        one_call(st, s)
        next_step(st)
        calls = calls + 1
        if calls >= MAX_CALLS_TICK then return false end
    end
    return true
end

local function run_msg(st)
    local m = fmt("calls=%d true=%d false=%d", st.calls, st.trues, st.falses)
    if st.either > 0 then m = m .. fmt(" either=%d", st.either) end
    if st.expects > 0 then m = m .. fmt(" as_vector=%d/%d", st.exact, st.expects) end
    if st.edge_hit + st.edge_miss > 0 then
        m = m .. fmt(" edge_exact=%d/%d", st.edge_hit, st.edge_hit + st.edge_miss)
    end
    if st.first then m = st.first .. "; " .. m end
    return m
end

local function run_prompt(st)
    if not st or not st.steps then return "" end
    return fmt("step %d/%d  %s", math.min(st.i, #st.steps), #st.steps, st.wait or "calling")
end

local tk = require("libs/testkit")

local raise_next = false   -- manual row: error() in the next on_tick

local S = tk.suite({
    tag = "telemetry", title = "TELEMETRY TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    groups = {
        probe  = { label = "CAPS",       what = "Telemetry.caps() shape and limits" },
        start  = { label = "HELD",       what = "calls in game_start wait for game.start" },
        guard  = { label = "GUARDS",     what = "bad arguments: false, never raise" },
        valid  = { label = "PAYLOADS",   what = "valid calls return true" },
        rate   = { label = "RATE LIMIT", what = "3 per 5000 ms, false over it" },
        vector = { label = "VECTORS",    what = "contract/telemetry_vectors.json" },
        diag   = { label = "SESSION",    what = "what game.stop must report" },
        manual = { label = "MANUAL",     what = "long or game-ending rows" },
    },
    status = function()
        return fmt("tel true=%d false=%d raised=%d\nwindow %d/%d  slot in %d ms",
                   sess.ok, sess.bad, sess.raised, in_window(), RATE_MAX, slot_in())
    end,
    on_abort = function() raise_next = false end,
})

-- steps: a list, or a function building it at arm time (keeps large test
-- tables out of the heap between runs).
local function script(group, name, steps, o)
    o = o or {}
    local timeout = o.timeout_ms or TEST_TIMEOUT_MS
    S:async(group, name,
        function()
            if not EV then return { skip = true } end
            local list = steps
            if type(list) == "function" then list = list() end
            local st = new_run(list)
            st.t_end = now() + timeout
            return st
        end,
        function(st)
            if st.skip then return true, "skip", "no Telemetry API on this head" end
            if not run_steps(st) then
                if now() >= st.t_end then
                    return true, false, fmt("timed out at step %d; %s", st.i, run_msg(st))
                end
                return false
            end
            return true, st.nfail == 0, run_msg(st)
        end,
        { prompt = run_prompt, manual = o.manual, settle_ms = o.settle_ms })
end

local function no_api() return "skip", "no Telemetry API on this head" end

-- ── Group: probe ─────────────────────────────────────────────────────
S:sync("probe", "Telemetry.event and caps are functions", function()
    if not T then return no_api() end
    return type(T.event) == "function" and type(T.caps) == "function",
           fmt("event=%s caps=%s", type(T.event), type(T.caps))
end)

S:sync("probe", "caps() limits = constraints.json tel_*", function()
    if not (T and T.caps) then return no_api() end
    local c = T.caps()
    if type(c) ~= "table" then return false, "caps() returned " .. type(c) end
    local bad = {}
    for k, v in pairs(CAPS_WANT) do
        if c[k] ~= v or math.type(c[k]) ~= "integer" then
            bad[#bad + 1] = fmt("%s=%s (want %d)", k, tostring(c[k]), v)
        end
    end
    sort(bad)
    if #bad > 0 then return false, concat(bad, ", ") end
    return true, fmt("rate %d/%d ms, fields %d / %d B, str %d", c.rate_max, c.rate_window_ms,
                     c.fields_max, c.fields_max_bytes, c.str_max)
end)

S:sync("probe", "caps().opts lists key and level", function()
    if not (T and T.caps) then return no_api() end
    local o = T.caps().opts
    return type(o) == "table" and o.key == true and o.level == true,
           fmt("opts.key=%s opts.level=%s", tostring(o and o.key), tostring(o and o.level))
end)

S:sync("probe", "caps() returns a new table each call", function()
    if not (T and T.caps) then return no_api() end
    local a = T.caps()
    a.rate_max = 99
    if type(a.opts) == "table" then a.opts.key = false end
    local b = T.caps()
    return a ~= b and b.rate_max == RATE_MAX and b.opts.key == true,
           fmt("after editing the first: rate_max=%s opts.key=%s",
               tostring(b.rate_max), tostring(b.opts and b.opts.key))
end)

-- ── Group: guard ─────────────────────────────────────────────────────
-- One ev name ("guard") for every non-name case: the log then shows one
-- reject line per reason.
local CONTROL = { want = "send", name = "guard.control", fields = { n = 1 } }

local function batch(cases)
    local steps = {}
    for i, c in ipairs(cases) do
        local s = { want = "reject", name = c[1], fields = c[2], opts = c[3], raw = c.raw }
        if i == 1 then s.slot = true end
        steps[i] = s
    end
    steps[#steps + 1] = CONTROL
    return steps
end

local function many_fields(n, name_len, val_len)
    local f = {}
    for i = 1, n do
        f[fmt("f%0" .. (name_len - 1) .. "d", i)] = string.rep(string.char(97 + i % 26), val_len)
    end
    return f
end

script("guard", "event name: 14 bad names -> false", function()
    return batch({
        { raw = { n = 0 } },                     -- no argument at all
        { nil }, { 5 }, { true }, { {} }, { "" }, { "Answer" }, { "a b" }, { "a-b" },
        { "engine.x" }, { "sys.y" }, { string.rep("a", NAME_MAX + 1) },
        { "\195\164" }, { "a\0b" },
    })
end)

script("guard", "opts: not a table, bad key, bad level -> false", function()
    return batch({
        { "guard", nil, 5 }, { "guard", nil, "x" }, { "guard", nil, true },
        { "guard", nil, { key = 5 } }, { "guard", nil, { key = "" } },
        { "guard", nil, { key = ".q" } }, { "guard", nil, { key = "q." } },
        { "guard", nil, { key = "Q" } }, { "guard", nil, { key = "a b" } },
        { "guard", nil, { key = string.rep("k", KEY_MAX + 1) } },
        { "guard", nil, { level = "fatal" } }, { "guard", nil, { level = "INFO" } },
        { "guard", nil, { level = 1 } }, { "guard", nil, { level = "" } },
    })
end)

script("guard", "fields: not a flat table of names -> false", function()
    return batch({
        { "guard", "x" }, { "guard", 5 }, { "guard", true },
        { "guard", { 1 } }, { "guard", { [1.5] = 1 } }, { "guard", { [true] = 1 } },
        { "guard", { Q = 1 } }, { "guard", { ["a.b"] = 1 } }, { "guard", { ["a-b"] = 1 } },
        { "guard", { [""] = 1 } }, { "guard", { [string.rep("a", FIELD_NAME_MAX + 1)] = 1 } },
    })
end)

script("guard", "8 reserved field names -> false", function()
    local cases = {}
    for _, r in ipairs({ "id", "trigger", "t_ms", "pv", "ev", "key", "level", "data" }) do
        cases[#cases + 1] = { "guard", { [r] = 1 } }
    end
    return batch(cases)
end)

script("guard", "values: type, int32, NaN/inf, long string -> false", function()
    return batch({
        { "guard", { a = {} } }, { "guard", { a = print } },
        { "guard", { a = 2147483648 } }, { "guard", { a = -2147483649 } },
        { "guard", { a = 2147483647.5 } }, { "guard", { a = -2147483648.6 } },
        { "guard", { a = 0 / 0 } }, { "guard", { a = math.huge } }, { "guard", { a = -math.huge } },
        { "guard", { s = string.rep("x", STR_MAX + 1) } },
        { "guard", { s = string.rep("x", 100000) } },
    })
end)

script("guard", "size: 9 fields, 1000 fields, 304 B -> false", function()
    return batch({
        { "guard", many_fields(FIELDS_MAX + 1, 2, 1) },
        { "guard", many_fields(1000, 5, 1) },
        -- 8 x (16-char name + 16-byte string) = 8 x 38 = 304 B encoded
        { "guard", many_fields(FIELDS_MAX, FIELD_NAME_MAX, 16) },
    })
end)

script("guard", "every rule broken at once -> false, nothing sent", function()
    return batch({
        { "Bad", { level = 1, Q = {} }, { key = ".x", level = 3 } },
        { "ok", { level = 1 }, { key = ".x" } },
    })
end)

-- ── Group: start (calls made in game_start and the first on_tick) ────
local boot = { t = nil, got = {}, pred = {}, fail = nil,
               tick_got = nil, tick_pred = nil, tick_dt = nil }

S:sync("start", "3 calls in game_start -> true (held)", function()
    if not EV then return no_api() end
    local g = boot.got
    if boot.fail then return false, boot.fail end
    return g[1] == true and g[2] == true and g[3] == true,
           fmt("got %s,%s,%s", tostring(g[1]), tostring(g[2]), tostring(g[3]))
end)

S:sync("start", "4th call in game_start -> false (hold full)", function()
    if not EV then return no_api() end
    return boot.got[4] == false, "got " .. tostring(boot.got[4])
end)

S:sync("start", "first on_tick call -> false (window full)", function()
    if not EV then return no_api() end
    if boot.tick_got == nil then return false, "no on_tick call recorded" end
    if boot.tick_pred ~= "reject" then
        return "skip", fmt("first tick came %d ms after game_start: window already open", boot.tick_dt)
    end
    return boot.tick_got == false,
           fmt("got %s, %d ms after the held calls", tostring(boot.tick_got), boot.tick_dt)
end)

-- ── Group: valid ─────────────────────────────────────────────────────
local function sends(list)
    local steps = {}
    for i, c in ipairs(list) do
        steps[i] = { want = "send", name = c[1], fields = c[2], opts = c[3], raw = c.raw,
                     data = c.data }
    end
    return steps
end

script("valid", "int, bool, string, int32 edges -> true", sends({
    { "v.types", { i = 42, neg = -7, imax = 2147483647, imin = -2147483648,
                   bt = true, bf = false, s = "abc", z = 0 } },
}))

-- Half away from zero; -0.0 -> 0; int32 edges after rounding.
script("valid", "floats rounded half away from zero -> true", sends({
    { "v.floats", { half = 2.5, nhalf = -2.5, low = 0.49, nlow = -0.5,
                    big = 2147483647.4, two = 2.0, negz = -0.0, nbig = -2147483648.4 } },
}))

-- 40 bytes is the cap; UTF-8 passes; '"', '\' and control bytes become '_'.
script("valid", "strings: 40 B, UTF-8, escaped bytes -> true", sends({
    { "v.str", { s40 = string.rep("x", STR_MAX), utf = "Ti\225\186\191ng Vi\225\187\135t",
                 q = 'a"b\\c', ctl = "a\nb\tc", nul = "a\0b", empty = "", sp = "a b" } },
}))

-- 8 x (16-char name + 15-byte string) = 8 x 37 = 296 B, under the 300 B cap.
script("valid", "8 fields, 296 B encoded -> true", function()
    return sends({ { "v.max", many_fields(FIELDS_MAX, FIELD_NAME_MAX, 15) } })
end)

script("valid", "opts.key, opts.level, both, 24-char key -> true", sends({
    { "v.key", nil, { key = "quiz" } },
    { "v.level", nil, { level = "warn" } },
    { "v.both", { q = 1 }, { key = "quiz.v2", level = "error" } },
    { "v.key24", nil, { key = string.rep("k", KEY_MAX) } },
    { "v.info", nil, { level = "info" } },
}))

-- The name rule is charset + length + reserved prefix only; the leading and
-- trailing dot rule belongs to opts.key.
script("valid", "names: 24 chars, digits, dots anywhere -> true", sends({
    { "abcdefghijklmnopqrstuvwx" }, { "stage_2.end.x9" },
    { "v.a..b" }, { ".v.lead" }, { "v.trail." },
}))

script("valid", "no fields, empty tables, nil holes, extra args", sends({
    { "v.bare" },
    { "v.empty", {}, {} },
    { "v.nil_fields", raw = { "v.nil_fields", nil, { level = "warn" }, n = 3 } },
    { "v.extra", raw = { "v.extra", nil, nil, 1, "x", {}, n = 6 } },
    { "v.nil_value", { a = nil, b = 1 } },
}))

-- The engine reads arguments raw: __index/__pairs never run (an __index
-- that raises proves it), options behind __index are not seen.
script("valid", "metatables ignored (fields and opts) -> true", function()
    local boom = function() error("metamethod called") end
    return sends({
        { "v.mt_index", setmetatable({}, { __index = boom }), data = {} },
        { "v.mt_pairs", setmetatable({ a = 1 }, { __pairs = boom }), data = { a = 1 } },
        { "v.opts_mt", nil, setmetatable({}, { __index = { key = "quiz", level = "error" } }) },
    })
end)

-- A newer pack's option on this head: dropped, the event still goes out
-- (one "telemetry opt_unknown" log line per session).
script("valid", "unknown opts key: event still sent -> true", sends({
    { "v.opt_sample", nil, { sample = 1 } },
    { "v.opt_mixed", { n = 1 }, { foo = "bar", key = "quiz" } },
    { "v.opt_numkey", nil, { [1] = "x", level = "warn" } },
}))

-- ── Group: rate ──────────────────────────────────────────────────────
-- 3 at t, then +4950 and +4999 must be refused, +5000 accepted; two more at
-- that ms pass (the oldest left is still t), the next one is refused.
script("rate", "window edges: 3 at t, then +4950/+4999/+5000", {
    { clear = true, want = "model", name = "rate.edge" },
    { want = "model", name = "rate.edge" }, { want = "model", name = "rate.edge" },
    { want = "model", name = "rate.edge" },
    { at = 4950, want = "model", name = "rate.edge" },
    { edge = WINDOW_MS - 1, want = "model", name = "rate.edge" },
    { edge = WINDOW_MS, want = "model", name = "rate.edge" },
    { want = "model", name = "rate.edge" }, { want = "model", name = "rate.edge" },
    { want = "model", name = "rate.edge" },
})

local SPAM_FIELDS = { n = 1 }
script("rate", "a call every frame for 6 s: false over 3/5 s", {
    { clear = true, want = "model", name = "rate.spam", fields = SPAM_FIELDS,
      for_ms = SPAM_MS, every_ms = 0 },
}, { timeout_ms = SPAM_MS + WINDOW_MS + 5000 })

script("rate", "paced 1 per 1.7 s for 10 s: all true", {
    { clear = true, want = "model", name = "rate.paced", for_ms = PACE_FOR_MS,
      every_ms = PACE_MS, all_true = true },
}, { timeout_ms = PACE_FOR_MS + WINDOW_MS + 5000 })

-- ── Group: vector ────────────────────────────────────────────────────
for _, vec in ipairs(V.list) do
    script("vector", vec.name, function()
        local steps = {}
        for i, s in ipairs(vec.steps) do
            local fields = s.fields
            if type(fields) == "table" then
                local f = {}
                for _, p in ipairs(fields) do f[p[1]] = p[2] end
                fields = f
            end
            -- Rule rejects hold at any time; rate outcomes come from real times.
            local want = (s.expect == "reject" and s.why ~= "rate") and "reject" or "model"
            steps[i] = { clear = (i == 1), at = s.at, name = s.name, fields = fields,
                         opts = s.opts, want = want, expect = s.expect }
        end
        return steps
    end, { timeout_ms = 20000 })
end

-- ── Group: diag ──────────────────────────────────────────────────────
S:sync("diag", "session counters (game.stop tel=)", function()
    if not EV then return no_api() end
    local skipped = {}
    for i, s in ipairs(V.skipped) do skipped[i] = s.name end
    print(fmt("%s vectors not replayed: %s", TAG, concat(skipped, ",")))
    return sess.raised == 0,
           fmt("so far tel=%d/%d raised=%d opt_unknown=%d", sess.ok, sess.bad, sess.raised,
               sess.opt_unknown)
end)

-- ── Group: manual ────────────────────────────────────────────────────
-- Long: 10 min at the full rate. Unplug the network mid-way and plug it back:
-- Lua must keep getting true (messages are lost downstream while offline,
-- which Datadog shows as a gap, not the pack).
script("manual", "soak 10 min, 1 per 1.7 s (unplug network)", {
    { clear = true, want = "model", name = "soak.tick", fields = SPAM_FIELDS,
      for_ms = SOAK_MS, every_ms = PACE_MS, all_true = true },
}, { manual = true, timeout_ms = SOAK_MS + WINDOW_MS + 10000 })

-- Ends the game: game_end then calls twice and must get false (the session
-- closed before game.stop); see the FINAL line.
S:sync("manual", "Engine.exit: game_end calls -> false", function()
    Engine.exit("telemetry_exit")
    return true, "exit posted; see the FINAL line"
end, { manual = true })

-- Ends the game with game.error: the event must still reach the server.
S:sync("manual", "event, then error() in on_tick", function()
    if not EV then return no_api() end
    if slot_in() > 0 then return "skip", fmt("window full, retry in %d ms", slot_in()) end
    local got, _, fail = invoke("send", "manual.before_error", { n = 1 })
    if not got then return false, fail or "event refused" end
    raise_next = true
    return true, "event sent; the next frame raises (game.error phase=on_tick)"
end, { manual = true })

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start(_params)
    boot.t = now()
    if EV then
        for i = 1, RATE_MAX + 1 do
            local got, _, fail = invoke("model", "boot.held", { i = i })
            boot.got[i] = got
            if fail and not boot.fail then boot.fail = fail end
        end
    end
    print(fmt("%s: game_start held=%s,%s,%s 4th=%s", TAG, tostring(boot.got[1]),
              tostring(boot.got[2]), tostring(boot.got[3]), tostring(boot.got[4])))
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    if not sess.started then
        -- game.start is out: the held calls went with it and still fill the window.
        sess.started = true
        if EV then
            boot.tick_got, boot.tick_pred = invoke("model", "boot.first_tick")
            boot.tick_dt = now() - boot.t
        end
    end
    if raise_next then
        raise_next = false
        -- game_end may not run after an error teardown: print the expectation now.
        print(fmt("%s FINAL before error() | expect game.stop tel=%d/%d | raised=%d",
                  TAG, sess.ok, sess.bad, sess.raised))
        error("test_telemetry: deliberate error after one event")
    end
    S:tick()
end

function game_end()
    -- game.stop is already out: both calls must be refused and not counted.
    local tel, drop = sess.ok, sess.bad
    sess.closed = true
    local a = invoke("reject", "end.in_game_end")
    local b = invoke("reject", "end.in_game_end", { n = 1 })
    S:summary(fmt("game_end calls -> %s,%s (want false,false) | expect game.stop tel=%d/%d"
                  .. " | raised=%d opt_unknown=%d", tostring(a), tostring(b), tel, drop,
                  sess.raised, sess.opt_unknown))
end
