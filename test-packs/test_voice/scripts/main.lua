-- test_voice: keyword spotting through the Voice API and on_voice_event.
--
-- Model: keyword spotting (NOT conversation/STT). The game sends an English
-- keyword list; the child speaks a short command; the voice server matches it
-- and the robot delivers VOICE_COMMAND{data.keyword}. Reference:
-- docs/reference/api.md#voice in the Pika SDK.
--
-- Voice rules these tests check (the robot enforces them):
--   * Voice.set_keywords sends the list AND starts listening. The session
--     exists only after game_start returned, so every test starts from a
--     button press; Voice.is_available() is false during game_start.
--   * A second set_keywords while a session is active is refused with an
--     error/busy event and the old list stays. Swap = Voice.stop, then
--     set_keywords again.
--   * Voice.start when idle reports error/no_keywords.
--
-- Groups:
--   guard   : argument and size checks, local, no network (after-flash check)
--   session : real sessions; needs a voice server (Pika Studio: Configure
--             Voice ASR Server) or a robot. The "listen" test waits for the
--             operator to say a keyword and reports the latency from
--             set_keywords to the first command.
-- In talk-flow (params.is_a2a) the busy / no_keywords rules do not apply, so
-- those tests report SKIP.
--
-- on_voice_event(e) arrives as a TABLE. A raw-string fallback (parse fail or
-- depth cap) is counted and shown, never dropped silently.

-- Keywords this test listens for. English only: other languages and
-- out-of-vocabulary phrases never trigger.
local KEYWORDS    = { "go left", "go right", "jump", "stop" }
local SENSITIVITY = 5
-- voice_keywords_max and voice_start_json_max_bytes in contract/constraints.json.
local KEYWORDS_MAX   = 64
local LISTEN_MS      = 20000   -- operator has this long to say a keyword
local REPLY_MS       = 3000    -- an error event arrives well within this
local OPEN_MS        = 1500    -- let a new session open before probing it

local Voice_set_keywords = Voice.set_keywords
local Voice_stop         = Voice.stop
local Voice_start        = Voice.start
local Voice_is_available = Voice.is_available
local fmt, concat, rep   = string.format, table.concat, string.rep
local clock_ms           = Timer.millis

local is_a2a          = false
local avail_at_start  = nil

-- ── Event capture ────────────────────────────────────────────────────
-- Tests drain ev.q from the index they saved at arm; the queue is bounded.
local Q_MAX = 16
local ev = { q = {}, seq = 0, dropped = 0, raw = 0, commands = 0,
             last = "-", lat_n = 0, lat_sum = 0, lat_best = nil, lat_worst = nil }

local function push(e)
    if #ev.q >= Q_MAX then table.remove(ev.q, 1); ev.dropped = ev.dropped + 1 end
    ev.seq = ev.seq + 1
    e.seq = ev.seq
    ev.q[#ev.q + 1] = e
end

-- Events newer than seq, oldest first.
local function events_after(seq)
    local out = {}
    for _, e in ipairs(ev.q) do
        if e.seq > seq then out[#out + 1] = e end
    end
    return out
end

function on_voice_event(e)
    if type(e) ~= "table" then
        ev.raw = ev.raw + 1
        ev.last = "raw string"
        print("voice: raw-string event fallback: " .. tostring(e))
        return
    end
    if e.type == "error" then
        push({ kind = "error", code = e.code, message = e.message })
        ev.last = "error " .. tostring(e.code)
        print(fmt("voice ERROR code=%s msg=%s", tostring(e.code), tostring(e.message)))
    elseif e.type == "VOICE_COMMAND" then
        local data = e.data
        if type(data) == "table" and data.keyword then
            ev.commands = ev.commands + 1
            push({ kind = "command", keyword = data.keyword, t = clock_ms() })
            ev.last = "heard " .. tostring(data.keyword)
            print("voice CMD: " .. tostring(data.keyword))
        elseif type(data) == "table" and data.status == "unavailable" then
            push({ kind = "unavailable" })
            ev.last = "unavailable"
            print("voice: keyword spotting unavailable (game keeps playing)")
        else
            ev.last = "command without keyword"
            print("voice: VOICE_COMMAND with no keyword/status")
        end
    else
        ev.last = "unknown " .. tostring(e.type)
        print("voice: unknown event type=" .. tostring(e.type))
    end
end

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "voice", title = "VOICE TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    groups = {
        guard   = { label = "GUARDS",  what = "bad arguments, size caps (local)" },
        session = { label = "SESSION", what = "listen / busy / restart (server)" },
    },
    status = function()
        local lat = "--"
        if ev.lat_n > 0 then
            lat = fmt("n=%d min=%d avg=%d max=%d ms", ev.lat_n, ev.lat_best,
                      ev.lat_sum // ev.lat_n, ev.lat_worst)
        end
        return fmt("%s  avail=%s  cmds=%d raw=%d\nlast %s\nlatency %s",
                   is_a2a and "talk-flow" or "menu", tostring(Voice_is_available()),
                   ev.commands, ev.raw, ev.last, lat)
    end,
    on_abort = function() Voice_stop() end,
})

-- ── Group: guards (sync, no network) ─────────────────────────────────
local function expect_raise(fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return false, "expected a raise, got a return" end
    return true, "raised: " .. tostring(err)
end

local function expect_reason(list, want)
    local ok, reason = Voice_set_keywords(list)
    if ok ~= nil then return false, fmt("expected nil, got %s", tostring(ok)) end
    if reason ~= want then return false, fmt("reason=%s (want %s)", tostring(reason), want) end
    return true, "reason=" .. want
end

S:sync("guard", "set_keywords(nil) raises", function()
    return expect_raise(Voice_set_keywords, nil)
end)
S:sync("guard", "set_keywords(string) raises", function()
    return expect_raise(Voice_set_keywords, "not_a_table")
end)
S:sync("guard", "sensitivity=string raises", function()
    return expect_raise(Voice_set_keywords, { "jump" }, "loud")
end)
S:sync("guard", "map table -> keywords_not_array", function()
    return expect_reason({ go_left = true, jump = true }, "keywords_not_array")
end)
S:sync("guard", "empty table -> keywords_not_array", function()
    return expect_reason({}, "keywords_not_array")
end)
S:sync("guard", "65 keywords -> too_many_keywords", function()
    local t = {}
    for i = 1, KEYWORDS_MAX + 1 do t[i] = "kw" .. i end
    return expect_reason(t, "too_many_keywords")
end)
S:sync("guard", "12 x 200 chars -> payload_too_big", function()
    -- under the keyword cap, over the 2048-byte body cap
    local t = {}
    for i = 1, 12 do t[i] = rep("X", 200) end
    return expect_reason(t, "payload_too_big")
end)
S:sync("guard", "Voice.stop() idle -> true", function()
    local r = Voice_stop()
    return r == true, fmt("returned %s", tostring(r))
end)
S:sync("guard", "is_available: false in game_start, true now", function()
    local now = Voice_is_available()
    return avail_at_start == false and now == true,
           fmt("game_start=%s now=%s", tostring(avail_at_start), tostring(now))
end)

-- ── Group: session (async, needs a voice server) ─────────────────────
-- Opens a fresh session. Returns st or a failure message.
local function open_session(list)
    Voice_stop()
    local seq = ev.seq
    local ok, reason = Voice_set_keywords(list or KEYWORDS, SENSITIVITY)
    if ok == nil then return nil, "set_keywords -> nil, " .. tostring(reason) end
    return { seq = seq, t0 = clock_ms() }
end

S:async("session", "listen: say a keyword",
    function()
        local st, err = open_session()
        return st or { err = err }
    end,
    function(st)
        if st.err then return true, false, st.err end
        for _, e in ipairs(events_after(st.seq)) do
            if e.kind == "command" then
                local dt = e.t - st.t0
                ev.lat_n, ev.lat_sum = ev.lat_n + 1, ev.lat_sum + dt
                if not ev.lat_best or dt < ev.lat_best then ev.lat_best = dt end
                if not ev.lat_worst or dt > ev.lat_worst then ev.lat_worst = dt end
                Voice_stop()
                return true, true, fmt("heard '%s' %d ms after set_keywords", e.keyword, dt)
            elseif e.kind == "unavailable" then
                Voice_stop()
                return true, "skip", "voice service reports unavailable"
            elseif e.kind == "error" and e.code ~= "busy" then
                return true, false, "session error: " .. tostring(e.code)
            end
        end
        if clock_ms() - st.t0 >= LISTEN_MS then
            Voice_stop()
            return true, false, fmt("no keyword heard in %d s", LISTEN_MS // 1000)
        end
        return false
    end,
    { prompt = "Say: " .. concat(KEYWORDS, " / "), settle_ms = 2000 })

S:async("session", "second set_keywords -> error busy",
    function()
        if is_a2a then return { skip = true } end
        local st, err = open_session()
        if not st then return { err = err } end
        st.phase = "open"
        return st
    end,
    function(st)
        if st.skip then return true, "skip", "talk-flow forwards every list (no busy)" end
        if st.err then return true, false, st.err end
        if st.phase == "open" then
            if clock_ms() - st.t0 < OPEN_MS then return false end
            st.seq = ev.seq
            local ok = Voice_set_keywords({ "jump" })
            if ok ~= true then
                Voice_stop()
                return true, false, "second set_keywords returned " .. tostring(ok)
            end
            st.phase, st.t1 = "await", clock_ms()
            return false
        end
        for _, e in ipairs(events_after(st.seq)) do
            if e.kind == "error" then
                Voice_stop()
                return true, e.code == "busy", "error code=" .. tostring(e.code)
            end
        end
        if clock_ms() - st.t1 >= REPLY_MS then
            Voice_stop()
            return true, false, fmt("no busy error within %d ms", REPLY_MS)
        end
        return false
    end,
    { settle_ms = 2000 })

S:async("session", "Voice.start idle -> error no_keywords",
    function()
        if is_a2a then return { skip = true } end
        Voice_stop()
        local seq = ev.seq
        local ok = Voice_start()
        return { seq = seq, ok = ok, t0 = clock_ms() }
    end,
    function(st)
        if st.skip then return true, "skip", "Voice.start does nothing in talk-flow" end
        if st.ok ~= true then return true, false, "Voice.start returned " .. tostring(st.ok) end
        for _, e in ipairs(events_after(st.seq)) do
            if e.kind == "error" then
                return true, e.code == "no_keywords", "error code=" .. tostring(e.code)
            end
        end
        if clock_ms() - st.t0 >= REPLY_MS then
            return true, false, fmt("no no_keywords error within %d ms", REPLY_MS)
        end
        return false
    end)

S:async("session", "stop + set_keywords reopens cleanly",
    function()
        local st, err = open_session()
        return st or { err = err }
    end,
    function(st)
        if st.err then return true, false, st.err end
        for _, e in ipairs(events_after(st.seq)) do
            if e.kind == "error" then
                Voice_stop()
                return true, false, "error code=" .. tostring(e.code)
            end
        end
        if clock_ms() - st.t0 < REPLY_MS then return false end
        Voice_stop()
        return true, true, fmt("no error within %d ms of reopening", REPLY_MS)
    end,
    { settle_ms = 2000 })

-- ── Lua engine hooks ─────────────────────────────────────────────────
-- params is always a table; is_a2a / language are added by the engine.
function game_start(params)
    is_a2a = type(params) == "table" and params.is_a2a == true
    avail_at_start = Voice_is_available()
    print(fmt("voice: lang=%s mode=%s available=%s",
              tostring(type(params) == "table" and params.language or "?"),
              is_a2a and "talk-flow" or "menu", tostring(avail_at_start)))
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    S:tick()
end

function game_end()
    Voice_stop()
    S:summary(fmt("commands=%d raw=%d queue_dropped=%d latency_samples=%d",
                  ev.commands, ev.raw, ev.dropped, ev.lat_n))
end
