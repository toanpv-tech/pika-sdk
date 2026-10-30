-- test_game_a2a: the talk-flow (A2A) game channel between a Lua pack and the conversation
-- server: Pack.send limits, Speaker.set_file path rules, Pack.data("game") + params.preload,
-- on_pack_cmd{op="preload"} pushes, Pack.preload_state, agent speech (AGENT_AUDIO ready ->
-- Speaker.play_stream -> end) with the Voice.stop / Voice.start mic mute around it, and a
-- "hello" upstream with exponential backoff. Finding ids (A1, C2, C4, D1 ...) name the
-- review item each row covers.
--
-- Runs on the real backend and on a bench mock of the conversation server:
--   * params.params.scn (or Pack.data("game").scn) names the mock scenario; the pack asks for
--     it with Pack.send("scn", {id = scn}). "none", "preload" or no scn send nothing.
--   * talk-flow: RUN SUITE starts AUTO_START_MS after game_start (params.params.auto = false
--     keeps the list idle). Menu: ENTER on row 01.
--   * scn l1_stop | voice_toggle | send_spam runs a driver instead of the suite; scn exit_soon
--     exits EXIT_SOON_MS after the auto start; GAME_DATA op="exit" exits at once.
--   * Pack.data("game").phase runs the phase driver (one launch per agent checkpoint).
--   * every wait has a deadline (shown on screen) and ends in SKIP or FAIL, never hangs.
-- UART: testkit rows "a2a [NN/NN] PASS|FAIL|SKIP group :: case :: detail" plus one
-- "a2a: <event>" line per event. Bench scorers parse "a2a: start ..." and "a2a: phase ..."
-- verbatim: keep those formats.
-- Pack.send is read as Pack["send"]: an older head has none, and every send row SKIPs.

-- ── Timing and limits ───────────────────────────────────────────────
local AUTO_START_MS    = 2500
local HELLO_DELAYS     = { 3000, 6000, 12000 }  -- wait after hello n; HELLO_CAP_MS after that
local HELLO_CAP_MS     = 30000
local HELLO_MAX        = 5
local HELLO_FIRST_MS   = 1000
local OUTBOX_MAX       = 64
local OUTBOX_RETRY_MS  = 250
local OUTBOX_TRIES     = 12       -- a frame refused this often is dropped
local PRELOAD_SEEN_MS  = 1000     -- at most one "preload_seen" frame per second
local DATA_Q_MAX       = 16
local RATE_QUIET_MS    = 1100     -- empty Pack.send window before a burst
local RATE_REOPEN_MS   = 1050     -- the window frees 1000 ms after the burst
local DATA_WAIT_MS     = 15000
local PRELOAD_WAIT_MS  = 25000    -- background files; PRELOAD_QUIET_MS without a push = done
local PRELOAD_QUIET_MS = 4000
local READY_WAIT_MS    = 30000    -- agent audio once the suite reached the audio rows
local END_GRACE_MS     = 3000     -- "end arrives within clip + 3 s" (C4)
local END_MIN_MS       = 5000
local END_MAX_MS       = 45000
local EMPTY_END_MS     = 3000     -- play_stream on an empty ring
local BYTES_PER_MS     = 2.5      -- OPUS 16 kHz ~20 kbit/s: bytes / 2.5 = clip ms (upper bound)
local EXIT_SOON_MS     = 3000
local L1_LOST_MS       = 4000
local TOGGLE_CHANGES   = 20       -- voice_toggle: 10 x (stop, start)
local TOGGLE_GAP_MS    = 400
local DRIVER_START_MS  = 1500
local SPAM_QUIET_MS    = 1200     -- send_spam: empty window before the 5 s rate phase
local SPAM_RATE_MS     = 5000
local SPAM_GAP_MS      = 100
local ARGS_MAX         = 2048     -- Pack.send limits under test
local KEYS_MAX         = 32
local OP_MAX           = 31
local PLAN_MAX         = 24

local fmt, rep, concat = string.format, string.rep, table.concat
local clock_ms = Timer.millis
local pack_send = Pack["send"]          -- nil on a head without the talk-flow data channel
local preload_state = Pack["preload_state"]
local Speaker_play_stream, Speaker_set_file = Speaker.play_stream, Speaker.set_file
local Speaker_play, Speaker_is_playing = Speaker.play, Speaker.is_playing
local Voice_stop, Voice_start = Voice.stop, Voice.start
local EMPTY = {}

-- ── Session state ───────────────────────────────────────────────────
local st = {
    params = nil, is_a2a = false, scn = nil, auto = true,
    data = nil,                     -- Pack.data("game") read in game_start
    preload = nil,                  -- params.preload
    t_start = 0,
}
local C = { data = 0, ack = 0, preload = 0, preload_ok = 0, preload_fail = 0, hello = 0,
            voice = 0, ready = 0, ended = 0, raw = 0, out_sent = 0, out_dropped = 0 }
local preload_paths, preload_last_ms = {}, 0     -- path -> "ok" | "fail" from the pushes
local preload_dirty, preload_report_ms = false, 0
local ready_q = {}             -- AGENT_AUDIO ready events not consumed yet
local end_ev = nil             -- last AGENT_AUDIO end
local data_q = {}              -- last GAME_DATA frames
local exit_req = false         -- GAME_DATA op="exit"
local ph, drv = nil, nil       -- phase driver / scenario driver (one at most)
local auto_fired, exit_at = false, nil
local ui                       -- screen state, defined with the screen below

-- ── Event log: one UART line, and the last EV_MAX on screen ─────────
local EV_MAX = 3
local ev_ring, ev_head = {}, 0

local function log(line)
    print("a2a: " .. line)
    ev_head = ev_head % EV_MAX + 1
    ev_ring[ev_head] = fmt("%5.1f %s", (clock_ms() - st.t_start) / 1000, line)
    if ui then ui.ev_dirty = true end
end

local function clear(t) for i = #t, 1, -1 do t[i] = nil end end

-- ── Outbox: Pack.send allows 5 per second, so frames queue and drain in on_tick ──
local outbox, out_next_ms, out_paused = {}, 0, false

-- Talk-flow only: outside it Pack.send refuses every frame (not_talk_flow).
local function queue_send(op, args)
    if not pack_send or not st.is_a2a then return false end
    if #outbox >= OUTBOX_MAX then
        table.remove(outbox, 1)
        C.out_dropped = C.out_dropped + 1
    end
    outbox[#outbox + 1] = { op = op, args = args, tries = 0 }
    return true
end

local function drain_outbox(now)
    if out_paused or #outbox == 0 or now < out_next_ms then return end
    local item = outbox[1]
    if pack_send(item.op, item.args) then
        table.remove(outbox, 1)
        C.out_sent = C.out_sent + 1
        if ui then ui.ev_dirty = true end
        return
    end
    item.tries = item.tries + 1
    if item.tries >= OUTBOX_TRIES then
        table.remove(outbox, 1)
        C.out_dropped = C.out_dropped + 1
        log(fmt("outbox drop op=%s tries=%d", item.op, item.tries))
    end
    out_next_ms = now + OUTBOX_RETRY_MS
end

-- ── Hello with exponential backoff (reset by any GAME_DATA) ─────────
local hello = { n = 0, next_ms = 0 }

local function hello_reset(now) hello.n, hello.next_ms = 0, now + HELLO_FIRST_MS end

local function hello_tick(now)
    if not pack_send or not st.is_a2a or hello.n >= HELLO_MAX or now < hello.next_ms then return end
    hello.n = hello.n + 1
    local delay = HELLO_DELAYS[hello.n] or HELLO_CAP_MS
    hello.next_ms = now + delay
    C.hello = C.hello + 1
    queue_send("hello", { n = hello.n, t = now - st.t_start, next_ms = delay })
    log(fmt("hello n=%d next_ms=%d", hello.n, delay))
end

-- ── Agent stream: one accepted play_stream waits for its AGENT_AUDIO end ──
-- stream_poll(start_ms, deadline_ms, now) -> nil while playing, else ended, reason, ms, took;
-- ended = false and reason "lost" once the deadline passed without an end.
local function stream_poll(t0, limit, now)
    if end_ev and end_ev.t >= t0 then return true, end_ev.reason, end_ev.ms, now - t0 end
    if now - t0 >= limit then return false, "lost", -1, now - t0 end
    return nil
end

local function clip_deadline(bytes)
    local ms = bytes / BYTES_PER_MS + END_GRACE_MS
    if ms < END_MIN_MS then ms = END_MIN_MS end
    if ms > END_MAX_MS then ms = END_MAX_MS end
    return math.floor(ms)
end

-- ── Engine hooks fed by the server ──────────────────────────────────
function on_pack_cmd(cmd)
    local now = clock_ms()
    if type(cmd) ~= "table" then
        C.raw = C.raw + 1
        log("raw-string on_pack_cmd: " .. tostring(cmd):sub(1, 80))
        return
    end
    if cmd.op == "preload" then
        -- firmware push: one per background file, after it was committed
        C.preload = C.preload + 1
        if cmd.ok then C.preload_ok = C.preload_ok + 1 else C.preload_fail = C.preload_fail + 1 end
        preload_paths[tostring(cmd.path)] = cmd.ok and "ok" or "fail"
        preload_last_ms, preload_dirty = now, true
        log(fmt("preload path=%s ok=%s n=%d", tostring(cmd.path), tostring(cmd.ok), C.preload))
        return
    end
    if cmd.op == "exit" then
        exit_req = true
        log("exit requested by server data")
        return
    end
    -- GAME_DATA: count, ack by seq, reset the hello backoff
    C.data = C.data + 1
    if #data_q >= DATA_Q_MAX then table.remove(data_q, 1) end
    data_q[#data_q + 1] = { op = cmd.op, seq = cmd.seq, t = now, args = cmd.args }
    hello_reset(now)
    C.ack = C.ack + 1
    queue_send("ack", { seq = cmd.seq, op = cmd.op })
    log(fmt("data op=%s seq=%s n=%d", tostring(cmd.op), tostring(cmd.seq), C.data))
end

function on_voice_event(e)
    local now = clock_ms()
    if type(e) ~= "table" then
        C.raw = C.raw + 1
        log("raw-string on_voice_event: " .. tostring(e):sub(1, 80))
        return
    end
    local d = type(e.data) == "table" and e.data or EMPTY
    if e.type == "AGENT_AUDIO" then
        if d.event == "ready" then
            C.ready = C.ready + 1
            ready_q[#ready_q + 1] = { bytes = tonumber(d.bytes) or 0, t = now }
            log(fmt("agent_audio ready bytes=%s n=%d", tostring(d.bytes), C.ready))
        elseif d.event == "end" then
            C.ended = C.ended + 1
            end_ev = { ms = tonumber(d.ms) or -1, reason = d.reason, t = now }
            log(fmt("agent_audio end ms=%s reason=%s", tostring(d.ms), tostring(d.reason)))
        else
            log("agent_audio event=" .. tostring(d.event))
        end
    elseif e.type == "VOICE_COMMAND" then
        C.voice = C.voice + 1
        queue_send("voice", { keyword = d.keyword, status = d.status })
        log(fmt("voice keyword=%s status=%s", tostring(d.keyword), tostring(d.status)))
    elseif e.type == "error" then
        log("voice error code=" .. tostring(e.code))
    else
        log("voice event type=" .. tostring(e.type))
    end
end

-- ── Suite ───────────────────────────────────────────────────────────
local tk = require("libs/testkit")
local FONT = "fonts/nunito-regular.ttf"

local S = tk.suite({
    tag = "a2a", title = "GAME A2A TEST", font = FONT, font_px = 14,
    groups = {
        send    = { label = "SEND",    what = "send limits (op, args, depth, rate)" },
        file    = { label = "FILE",    what = "Speaker.set_file path rules" },
        data    = { label = "DATA",    what = "Pack.data(game), params.preload, GAME_DATA" },
        preload = { label = "PRELOAD", what = "preload pushes and Pack.preload_state" },
        audio   = { label = "AUDIO",   what = "AGENT_AUDIO ready -> play_stream -> end" },
        voice   = { label = "VOICE",   what = "Voice.stop / Voice.start in talk-flow" },
        stress  = { label = "STRESS",  what = "manual rows (may starve PSRAM)" },
    },
    on_abort = function() out_paused = false end,
})

-- Return conventions (testkit): sync fn() -> pass, detail; async step -> done, pass, detail;
-- pass may be "skip". A nil return from the engine means "not implemented here".
local function expect_false(r, what)
    if r == nil then return "skip", what .. ": returned nil (not available on this engine)" end
    return r == false, what .. " returned " .. tostring(r)
end

-- Pack.send refuses everything outside talk-flow (not_talk_flow, C11) except bad_op.
local function send_gate(menu_ok)
    if not pack_send then return "no send API on this head" end
    if not menu_ok and not st.is_a2a then return "menu launch: send is talk-flow only (C11)" end
    return nil
end

local function send_case(name, fn, o, group)
    S:sync(group or "send", name, function()
        local why = send_gate()
        if why then return "skip", why end
        return fn()
    end, o)
end

-- Async rows: arm() returns {skip = why} or a state; wait_on() puts the current wait and its
-- deadline on screen (late = what the row reports when the deadline passes).
local function wait_on(t, label, ms, late, t0)
    t.wl, t.wms, t.wlate, t.wt0 = label, ms, late or "SKIP", t0 or clock_ms()
    return t
end

local function async_case(group, name, arm, step, o)
    S:async(group, name, arm, function(t)
        if t.skip then return true, "skip", t.skip end
        return step(t, clock_ms())
    end, o)
end

-- ── SEND: Pack.send rules (C2, C12, C14) ────────────────────────────
S:sync("send", "send API exists (feature detect)", function()
    return pack_send ~= nil and true or "skip", "send=" .. tostring(pack_send ~= nil)
end)

S:sync("send", 'op "" -> false (bad_op, also from the menu)', function()
    local why = send_gate(true)
    if why then return "skip", why end
    return expect_false(pack_send("", { a = 1 }), 'send("")')   -- bad_op precedes the talk-flow gate
end)

send_case("op 32 chars -> false, 31 ok (bad_op)", function()
    local long = pack_send(rep("o", OP_MAX + 1), { a = 1 })
    local okay = pack_send(rep("o", OP_MAX), { a = 1 })
    return long == false and okay == true, fmt("32=%s 31=%s", tostring(long), tostring(okay))
end)

send_case("op nil raises, op 5 is coerced (C14)", function()
    local ok = pcall(pack_send, nil, {})
    local num = pack_send(5, { a = 1 })
    return (not ok) and num == true, fmt("nil raised=%s number=%s", tostring(not ok), tostring(num))
end)

send_case("args > 2048 B -> false (args_too_big)", function()
    return expect_false(pack_send("big", { blob = rep("x", ARGS_MAX + 60) }), "2.1 KB args")
end)

send_case("object 33 keys -> false, 32 ok (too_many_keys)", function()
    local t33, t32 = {}, {}
    for i = 1, KEYS_MAX + 1 do t33["k" .. i] = i end
    for i = 1, KEYS_MAX do t32["k" .. i] = i end
    local r33, r32 = pack_send("keys", t33), pack_send("keys", t32)
    return r33 == false and r32 == true, fmt("33=%s 32=%s", tostring(r33), tostring(r32))
end)

send_case("function inside args -> false (encode_failed)", function()
    return expect_false(pack_send("fn", { f = function() end, a = 1 }), "args with a function")
end)

send_case("depth 4 ok, depth 5 -> false (too_deep)", function()
    local d4 = pack_send("deep", { a = { b = { c = { d = 1 } } } })
    local d5 = pack_send("deep", { a = { b = { c = { d = { e = 1 } } } } })
    return d4 == true and d5 == false, fmt("depth4=%s depth5=%s", tostring(d4), tostring(d5))
end)

send_case("array and scalar args, nil args", function()
    local arr = pack_send("arr", { 1, 2, 3 })
    local sca = pack_send("num", 42)
    local non = pack_send("none")
    return arr == true and sca == true and non == true,
           fmt("array=%s scalar=%s nil=%s", tostring(arr), tostring(sca), tostring(non))
end)

-- The outbox pauses so the rows own the 1 s window; seq 1..n without gaps is the mock's gate.
local function rate_arm()
    local why = send_gate()
    if why then return { skip = why } end
    out_paused = true
    return wait_on({ phase = "quiet" }, "empty send window", RATE_QUIET_MS, "run")
end

async_case("send", "10 calls in one tick -> 5 true, 5 false (rate)", rate_arm,
    function(t, now)
        if now - t.wt0 < RATE_QUIET_MS then return false end
        local res = {}
        for i = 1, 10 do res[i] = pack_send("rate", { i = i }) and "T" or "F" end
        out_paused = false
        local got = concat(res)
        return true, got == "TTTTTFFFFF", "pattern=" .. got
    end)

async_case("send", "1.0 s after the burst a send succeeds again", rate_arm,
    function(t, now)
        if t.phase == "quiet" then
            if now - t.wt0 < RATE_QUIET_MS then return false end
            for i = 1, 5 do pack_send("rate2", { i = i }) end
            t.phase = "reopen"
            wait_on(t, "window reopens", RATE_REOPEN_MS, "run", now)
            return false
        end
        if now - t.wt0 < RATE_REOPEN_MS then return false end
        local r = pack_send("rate2", { i = 6 })
        out_paused = false
        return true, r == true, fmt("after %d ms -> %s", now - t.wt0, tostring(r))
    end)

-- ── FILE: Speaker.set_file path rules ───────────────────────────────
local BAD_PATHS = { "preload/../x.wav", "/x.wav", "preload//x.wav", "preload/./x.wav", "preload/" }
for _, p in ipairs(BAD_PATHS) do
    S:sync("file", fmt('set_file("agent_clip", "%s") -> false', p), function()
        return expect_false(Speaker_set_file("agent_clip", p), "unsafe path")
    end)
end

S:sync("file", "set_file missing preload file -> false", function()
    return expect_false(Speaker_set_file("agent_clip", "preload/no_such_file.wav"), "missing file")
end)

S:sync("file", "set_file non-string / undeclared / sd alias -> false", function()
    local a = Speaker_set_file("agent_clip", 42)
    local b = Speaker_set_file("nope", "assets/audio/sfx.wav")
    local c = Speaker_set_file("sd_only", "assets/audio/sfx.wav")
    if a == nil then return "skip", "set_file not available on this engine" end
    return a == false and b == false and c == false,
           fmt("non_string=%s undeclared=%s sd_alias=%s", tostring(a), tostring(b), tostring(c))
end)

S:sync("file", "set_file to a file inside the pack -> true, then play", function()
    local r = Speaker_set_file("agent_clip", "assets/audio/sfx.wav")
    if r == nil then return "skip", "set_file not available on this engine" end
    if r ~= true then return false, "set_file returned " .. tostring(r) end
    local p = Speaker_play("agent_clip")
    return p == true, "set_file=true play=" .. tostring(p)
end)

S:sync("file", "set_file preload/ding.wav -> true when preloaded", function()
    local path = "preload/ding.wav"
    local r = Speaker_set_file("agent_clip", path)
    if r == nil then return "skip", "set_file not available on this engine" end
    local state = preload_state and preload_state(path)
    if state then
        if state ~= "ready" then
            return "skip", fmt("preload_state=%s, set_file=%s (only a ready file must load)", state, tostring(r))
        end
    elseif r == false and not st.preload then
        return "skip", "no preload plan in this session (returned false as expected for a missing file)"
    end
    return r == true, fmt("returned %s preload_state=%s", tostring(r), tostring(state))
end)

-- ── DATA: Pack.data("game"), params.preload, GAME_DATA ──────────────
S:sync("data", "params is a table with is_a2a / language", function()
    local p = st.params
    return type(p) == "table" and type(p.is_a2a) == "boolean" and type(p.language) == "string",
           fmt("is_a2a=%s language=%s scn=%s", tostring(p and p.is_a2a), tostring(p and p.language), tostring(st.scn))
end)

S:sync("data", 'Pack.data("game") present in game_start (C9)', function()
    if not st.is_a2a then return "skip", "menu launch: no game data" end
    if st.data == nil then
        return "skip", "Pack.data(game) was nil in game_start (no data in GAME_START, or ACK timeout -> data_ok=false)"
    end
    local keys = {}
    for k in pairs(st.data) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local same = Pack.data("game") == st.data
    return type(st.data) == "table" and same,
           fmt("keys=%s same_table=%s scn=%s", concat(keys, ","), tostring(same), tostring(st.data.scn))
end)

S:sync("data", 'Pack.data("game") matches this launch (C9 stale check)', function()
    if not st.is_a2a or st.data == nil then return "skip", "no game data in this session" end
    if st.scn == nil then return "skip", "GAME_START params carry no scn to compare" end
    local ds = st.data.scn
    if ds == nil then return "skip", "data has no scn field" end
    return ds == st.scn, fmt("params.scn=%s data.scn=%s", tostring(st.scn), tostring(ds))
end)

S:sync("data", "params.preload shape {ready, failed, pending} (C8)", function()
    local p = st.preload
    if p == nil then
        return "skip", st.is_a2a and "params.preload is nil (no plan bound, or TODO launch: C8)" or "menu launch"
    end
    local function arr(t) return type(t) == "table" and #t <= PLAN_MAX end
    local ok = arr(p.ready) and arr(p.failed) and arr(p.pending)
    return ok, fmt("ready=%d failed=%d pending=%d", #(p.ready or EMPTY), #(p.failed or EMPTY), #(p.pending or EMPTY))
end)

async_case("data", "GAME_DATA reaches on_pack_cmd as a table (ack by seq)",
    function() return wait_on({ n0 = C.data }, "a GAME_DATA frame", DATA_WAIT_MS) end,
    function(t, now)
        if C.data > t.n0 then
            local d = data_q[#data_q]
            return true, type(d.op) == "string" and d.seq ~= nil,
                   fmt("op=%s seq=%s args=%s", tostring(d.op), tostring(d.seq), type(d.args))
        end
        if now - t.wt0 >= DATA_WAIT_MS then
            return true, "skip", fmt("no GAME_DATA within %d s (server sent none)", DATA_WAIT_MS // 1000)
        end
        return false
    end,
    { prompt = "the server sends GAME_DATA (mock: data_burst, ping)" })

-- ── PRELOAD: pushes (B9) and Pack.preload_state ─────────────────────
S:sync("preload", 'preload_state: unsafe path, bare "preload/" -> "none"', function()
    if not preload_state then return "skip", "no Pack.preload_state on this head" end
    local bad = {}
    local function probe(p)
        local r = preload_state(p)
        if r ~= "none" then bad[#bad + 1] = fmt("%s=%s", tostring(p), tostring(r)) end
    end
    for _, p in ipairs(BAD_PATHS) do probe(p) end
    probe("assets/audio/sfx.wav")       -- inside the pack, not under preload/
    probe(5)                            -- a number is coerced to "5"
    local raised = not pcall(preload_state, {})
    return #bad == 0 and raised,
           fmt("checked=%d not_none=%d table_raised=%s%s", #BAD_PATHS + 2, #bad, tostring(raised),
               #bad > 0 and (" " .. concat(bad, " ")) or "")
end)

async_case("preload", "every pending file reports op=preload exactly once",
    function()
        if not st.preload then return { skip = "no params.preload in this session" } end
        return wait_on({}, "preload pushes", PRELOAD_WAIT_MS)
    end,
    function(t, now)
        local pending = st.preload.pending or EMPTY
        local missing = 0
        for _, path in ipairs(pending) do
            if preload_paths[path] == nil then missing = missing + 1 end
        end
        local quiet = preload_last_ms > 0 and (now - preload_last_ms) >= PRELOAD_QUIET_MS
        if not (missing == 0 or quiet or now - t.wt0 >= PRELOAD_WAIT_MS) then return false end
        local in_plan = {}
        for _, p in ipairs(pending) do in_plan[p] = true end
        local extra = 0
        for path in pairs(preload_paths) do
            if not in_plan[path] then extra = extra + 1 end
        end
        local dup = C.preload - (#pending - missing) - extra
        local detail = fmt("pending=%d notified=%d ok=%d fail=%d missing=%d extra=%d dup=%d",
                           #pending, C.preload, C.preload_ok, C.preload_fail, missing, extra, dup)
        if #pending == 0 then return true, "skip", detail .. " (nothing pending at start)" end
        return true, missing == 0 and dup == 0, detail
    end,
    { prompt = "background files arrive (quiet 4 s = done)", settle_ms = 500 })

-- params.preload is the state at start; the pull is authoritative afterwards: a ready or failed
-- file keeps its state, a pending one may have finished, a pushed one must match its push.
S:sync("preload", "preload_state agrees with params.preload and the pushes", function()
    if not preload_state then return "skip", "no Pack.preload_state on this head" end
    local p = st.preload
    if p == nil then
        local r = preload_state("preload/ding.wav")
        return r == "none", fmt("no plan (%s): preload/ding.wav -> %s", st.is_a2a and "talk-flow" or "menu", tostring(r))
    end
    local bad, n = {}, 0
    local function check(list, ok_fn)
        for _, path in ipairs(list or EMPTY) do
            n = n + 1
            local r = preload_state(path)
            if not ok_fn(r, path) then bad[#bad + 1] = fmt("%s=%s", path, tostring(r)) end
        end
    end
    check(p.ready, function(r) return r == "ready" end)
    check(p.failed, function(r) return r == "failed" end)
    check(p.pending, function(r, path)
        local push = preload_paths[path]
        if push == "ok" then return r == "ready" end
        if push == "fail" then return r == "failed" end
        return r == "pending" or r == "ready" or r == "failed"
    end)
    -- a file outside the plan is "none"; "pending" while the plan is not parsed yet (all lists empty)
    local outside = preload_state("preload/zz_not_in_plan.wav")
    local outside_ok = outside == "none" or (n == 0 and outside == "pending")
    if not outside_ok then bad[#bad + 1] = "outside=" .. tostring(outside) end
    return #bad == 0, fmt("checked=%d outside=%s mismatch=%d %s", n, tostring(outside), #bad,
                          concat(bad, " ", 1, math.min(#bad, 3)))
end)

-- ── AUDIO: AGENT_AUDIO ready -> play_stream -> end (C4, C5, D1, D4) ─
async_case("audio", "ready -> Voice.stop, play_stream, end within clip+3 s",
    function()
        if not st.is_a2a then return { skip = "menu launch: no agent audio" } end
        if Speaker_play_stream == nil then return { skip = "no Speaker.play_stream on this engine" } end
        return wait_on({ phase = "ready" }, "AGENT_AUDIO ready", READY_WAIT_MS)
    end,
    function(t, now)
        if t.phase == "ready" then
            if #ready_q == 0 then
                if now - t.wt0 >= READY_WAIT_MS then
                    return true, "skip", fmt("no AGENT_AUDIO ready within %d s (agent silent)", READY_WAIT_MS // 1000)
                end
                return false
            end
            t.bytes = table.remove(ready_q, 1).bytes
            t.vstop = Voice_stop()
            end_ev = nil
            t.p1 = Speaker_play_stream()
            if t.p1 == nil then
                Voice_start()                            -- undo the mute, or the mic stays off
                return true, "skip", "play_stream returned nil (not simulated)"
            end
            t.p2 = Speaker_play_stream()                 -- C4: a second call before end -> false
            t.sfx = Speaker_play("sfx")                  -- D4/C5: play refused while the stream plays
            t.phase = "end"
            wait_on(t, "AGENT_AUDIO end", clip_deadline(t.bytes), "FAIL", now)
            queue_send("audio_play", { bytes = t.bytes, ok = t.p1 })
            return false
        end
        local ended, reason, ms, took = stream_poll(t.wt0, t.wms, now)
        if ended == nil then return false end
        local head = fmt("bytes=%d play1=%s play2=%s sfx=%s", t.bytes, tostring(t.p1), tostring(t.p2), tostring(t.sfx))
        if not ended then
            Voice_start()
            queue_send("audio_end", { ms = -1, reason = "lost", took = took, bytes = t.bytes })
            return true, false, fmt("no AGENT_AUDIO end within %d ms (C4 lost end) %s", t.wms, head)
        end
        local vstart = Voice_start()
        queue_send("audio_end", { ms = ms, reason = reason, took = took, bytes = t.bytes })
        -- C4: end carries drained|stale|stopped|leave; an uncut clip must say "drained"
        local reason_ok = reason == nil or reason == "drained"
        local ok = t.p1 == true and t.p2 == false and t.sfx == false and took <= t.wms and reason_ok
        return true, ok, fmt("%s end_ms=%s reason=%s took=%d limit=%d vstop=%s vstart=%s", head, tostring(ms),
                             tostring(reason), took, t.wms, tostring(t.vstop), tostring(vstart))
    end,
    { prompt = "the agent speaks (mock: reply_then_response_complete)" })

async_case("audio", "play_stream on an empty ring -> end in <= 3 s",
    function()
        if not st.is_a2a then return { skip = "menu launch" } end
        if #ready_q > 0 then return { skip = "a clip is pending; the row above plays it" } end
        end_ev = nil
        local p = Speaker_play_stream()
        if p == nil then return { skip = "play_stream returned nil (not simulated)" } end
        return wait_on({ p = p }, "AGENT_AUDIO end (empty ring)", EMPTY_END_MS, "FAIL")
    end,
    function(t, now)
        local ended, reason, ms, took = stream_poll(t.wt0, t.wms, now)
        if ended == nil then return false end
        if not ended then return true, false, fmt("play=%s but no end within %d ms", tostring(t.p), t.wms) end
        return true, t.p == true, fmt("play=%s end_ms=%s reason=%s after %d ms",
                                      tostring(t.p), tostring(ms), tostring(reason), took)
    end)

S:sync("audio", "Speaker.play works when no stream plays", function()
    if end_ev == nil and C.ready > C.ended then return "skip", "a stream is still playing" end
    local r = Speaker_play("sfx")
    return r == true, "play(sfx)=" .. tostring(r) .. " is_playing=" .. tostring(Speaker_is_playing("sfx"))
end)

-- ── VOICE: mic mute around the stream ───────────────────────────────
S:sync("voice", "Voice.stop() -> true, Voice.start() -> true", function()
    -- menu: start without keywords reports error/no_keywords next frame; the return is still true
    local a, b = Voice_stop(), Voice_start()
    return a == true and b == true,
           fmt("%s stop=%s start=%s", st.is_a2a and "talk-flow" or "menu", tostring(a), tostring(b))
end)

S:sync("voice", "Voice.is_available() true while running", function()
    local r = Voice.is_available()
    return r == true, "is_available=" .. tostring(r)
end)

-- ── STRESS: manual rows (RUN SUITE skips them) ──────────────────────
send_case("C2: 3000 x 1 KB shared strings -> false, no crash", function()
    local chunk = rep("x", 1024)
    local t = {}
    for i = 1, 3000 do t[i] = chunk end
    local t0 = clock_ms()
    local r = pack_send("c2", t)
    return r == false, fmt("returned %s in %d ms (watch psram= in game.running)", tostring(r), clock_ms() - t0)
end, { manual = true }, "stress")

S:sync("stress", "exit with a reported result (Engine.exit)", function()
    Engine.report_result({ event = "win" })
    Engine.exit("manual")
    return true, "exiting"
end, { manual = true })

-- ── Phase driver: Pack.data("game") of a real agent bot, one launch per checkpoint ──
-- data.phase              id: Pack.send("phase", {id}) once, "a2a: phase id=" on UART
-- data.suite              true = also run the suite (then exit when it ends); default false
-- data.result             "win" (default) | "quit" | "none" (exit without Engine.report_result)
-- data.end_after_ms       exit this long after game_start
-- data.streams            exit once this many agent clips ended
-- data.stream             "auto" (default) | "hold:<ms>" (wait after the first ready) | "never"
-- data.sfx_before_stream  play "sfx" right before play_stream (codec muted by the cut, D1)
-- data.sfx_during_stream  try Speaker.play while the stream plays (must be false)
-- Without end_after_ms, streams and suite the pack never exits: the agent's timeout_s decides.
local function phase_setup(d)
    if type(d) ~= "table" or d.phase == nil then return nil end
    local p = {
        id = tostring(d.phase), suite = d.suite == true, result = d.result or "win",
        end_after_ms = tonumber(d.end_after_ms), streams = tonumber(d.streams),
        stream = tostring(d.stream or "auto"), hold_ms = 0,
        sfx_before = d.sfx_before_stream == true, sfx_during = d.sfx_during_stream == true,
        played = 0, ended = 0, playing = nil, hold_from = nil, suite_ran = false, done = false,
    }
    local hold = p.stream:match("^hold:(%d+)$")
    if hold then p.stream, p.hold_ms = "hold", tonumber(hold) end
    log(fmt("phase id=%s suite=%s result=%s end_after_ms=%s streams=%s stream=%s hold_ms=%d sfx_before=%s sfx_during=%s",
            p.id, tostring(p.suite), p.result, tostring(p.end_after_ms), tostring(p.streams), p.stream,
            p.hold_ms, tostring(p.sfx_before), tostring(p.sfx_during)))
    queue_send("phase", { id = p.id })
    return p
end

local function phase_exit(why)
    if ph.done then return end
    ph.done = true
    log(fmt("phase end id=%s why=%s result=%s played=%d ended=%d data=%d preload=%d/%d",
            ph.id, why, ph.result, ph.played, ph.ended, C.data, C.preload_ok, C.preload))
    if ph.result == "win" then
        Engine.report_result({ event = "win", s = 1, n = 1 })
    elseif ph.result == "quit" then
        Engine.report_result({ event = "quit", q = 1, s = 0, n = 1 })
    end
    Engine.exit("phase_" .. why)
end

local function phase_stream(now)
    if ph.stream == "never" or Speaker_play_stream == nil then return end
    local cur = ph.playing
    if cur then
        local ended, reason, ms, took = stream_poll(cur.t, cur.deadline, now)
        if ended == nil then return end
        ph.ended, ph.playing = ph.ended + 1, nil
        local vstart = Voice_start()
        if ended then
            log(fmt("phase stream end n=%d reason=%s ms=%s took=%d bytes=%d vstart=%s",
                    ph.ended, tostring(reason), tostring(ms), took, cur.bytes, tostring(vstart)))
        else
            log(fmt("phase stream end n=%d reason=lost took=%d bytes=%d", ph.ended, took, cur.bytes))
        end
        queue_send("stream_end", { n = ph.ended, reason = reason, took = took })
        return
    end
    if #ready_q == 0 then return end
    if ph.stream == "hold" then
        ph.hold_from = ph.hold_from or now
        if now - ph.hold_from < ph.hold_ms then return end
        ph.hold_from = nil
    end
    -- one play_stream drains every clip already in the ring, so all queued readies go together
    local bytes, clips = 0, #ready_q
    for _, r in ipairs(ready_q) do bytes = bytes + r.bytes end
    clear(ready_q)
    local sfx_pre, sfx_mid = nil, nil
    if ph.sfx_before then sfx_pre = Speaker_play("sfx") end
    local vstop = Voice_stop()
    end_ev = nil
    local ok = Speaker_play_stream()
    if ph.sfx_during then sfx_mid = Speaker_play("sfx") end
    ph.played = ph.played + 1
    ph.playing = { t = now, bytes = bytes, deadline = clips * END_MAX_MS }
    log(fmt("phase stream play n=%d clips=%d bytes=%d ok=%s vstop=%s sfx_before=%s sfx_during=%s",
            ph.played, clips, bytes, tostring(ok), tostring(vstop), tostring(sfx_pre), tostring(sfx_mid)))
    queue_send("stream_play", { n = ph.played, clips = clips, bytes = bytes, ok = ok })
end

local function phase_tick(now)
    if ph.done then return end
    if not ph.suite then phase_stream(now) end
    if ph.suite and S.in_suite then ph.suite_ran = true end
    if ph.suite and ph.suite_ran and not S.in_suite then return phase_exit("suite_done") end
    if ph.streams and ph.ended >= ph.streams and not ph.playing then return phase_exit("streams") end
    if ph.end_after_ms and now - st.t_start >= ph.end_after_ms and not ph.playing then
        return phase_exit("end_after")
    end
end

-- ── Scenario drivers (params.params.scn; the mock runs the scenario of the same name) ──
-- l1_stop       each AGENT_AUDIO ready: play_stream() then Speaker.stop_all() in the same tick
--               (odd n plain, even n Speaker.play("sfx") first so a game channel is active);
--               one "a2a: l1 ..." line and Pack.send l1_end per clip.
-- voice_toggle  10 x (Voice.stop x2, 400 ms, Voice.start x2, 400 ms): one game_voice per change.
-- send_spam     cyclic table, op with NUL, 3 KB args, then 10 sends per second for 5 s.
local function drv_l1(now)
    local cur = drv.playing
    if cur then
        local ended, reason, ms, took = stream_poll(cur.t, L1_LOST_MS, now)
        if ended == nil then return end
        drv.playing = nil
        if ended then
            log(fmt("l1 n=%d mode=%s play=%s stop=%s reason=%s end_ms=%s took=%d",
                    cur.n, cur.mode, tostring(cur.p), tostring(cur.s), tostring(reason), tostring(ms), took))
        else
            log(fmt("l1 n=%d mode=%s play=%s stop=%s reason=lost took=%d",
                    cur.n, cur.mode, tostring(cur.p), tostring(cur.s), took))
        end
        queue_send("l1_end", { n = cur.n, mode = cur.mode, reason = reason, took = took })
        return
    end
    if #ready_q == 0 then return end
    clear(ready_q)
    drv.n = drv.n + 1
    local mode = (drv.n % 2 == 0) and "sfx" or "plain"
    if mode == "sfx" then Speaker_play("sfx") end
    end_ev = nil
    local p = Speaker_play_stream()
    local s = Speaker.stop_all()
    drv.playing = { n = drv.n, mode = mode, p = p, s = s, t = now }
end

local function drv_voice(now)
    if drv.done or now < drv.next_ms then return end
    drv.i = drv.i + 1
    if drv.i > TOGGLE_CHANGES then
        drv.done = true
        log(fmt("voice_toggle done calls=%d", drv.calls))
        queue_send("voice_toggle_done", { calls = drv.calls, changes = TOGGLE_CHANGES })
        return
    end
    local stop = (drv.i % 2 == 1)
    local fn = stop and Voice_stop or Voice_start
    local a, b = fn(), fn()
    drv.calls = drv.calls + 2
    log(fmt("voice_toggle i=%d %s r=%s,%s", drv.i, stop and "stop" or "start", tostring(a), tostring(b)))
    drv.next_ms = now + TOGGLE_GAP_MS
end

local function drv_spam(now)
    if not pack_send or drv.done or now < drv.next_ms then return end
    if drv.phase == "limits" then
        local cyc = { a = 1 }
        cyc.self = cyc
        local r_cyc = pack_send("cyc", cyc)
        local r_nul = pack_send("a\0b", { a = 1 })
        local r_big = pack_send("big3k", { blob = rep("x", 3072) })
        log(fmt("spam limits cyclic=%s nul_op=%s args3k=%s", tostring(r_cyc), tostring(r_nul), tostring(r_big)))
        drv.phase, drv.next_ms, drv.t0 = "rate", now + SPAM_QUIET_MS, now + SPAM_QUIET_MS
        return
    end
    if now - drv.t0 >= SPAM_RATE_MS then
        drv.done = true
        out_paused = false
        log(fmt("spam rate sent=%d ok=%d refused=%d", drv.sent, drv.ok, drv.sent - drv.ok))
        queue_send("spam_done", { sent = drv.sent, ok = drv.ok })
        return
    end
    out_paused = true            -- the outbox must not take window slots meanwhile
    drv.sent = drv.sent + 1
    if pack_send("spam", { i = drv.sent }) then drv.ok = drv.ok + 1 end
    drv.next_ms = now + SPAM_GAP_MS
end

local DRIVERS = { l1_stop = drv_l1, voice_toggle = drv_voice, send_spam = drv_spam }

local function drv_setup(scn)
    if not DRIVERS[scn] then return nil end
    log("driver scn=" .. scn)
    return { name = scn, fn = DRIVERS[scn], n = 0, i = 0, calls = 0, next_ms = clock_ms() + DRIVER_START_MS,
             phase = "limits", sent = 0, ok = 0, t0 = 0, done = false, playing = nil }
end

-- One line of driver progress for the screen, or nil.
local function driver_status(now)
    if ph then
        local s = fmt("PHASE %s played %d ended %d", ph.id, ph.played, ph.ended)
        if ph.playing then
            return fmt("%s  end %d/%d s", s, (now - ph.playing.t) // 1000, ph.playing.deadline // 1000)
        elseif ph.end_after_ms then
            return fmt("%s  exit at %d/%d s", s, (now - st.t_start) // 1000, ph.end_after_ms // 1000)
        end
        return s
    end
    if drv then
        if drv.name == "l1_stop" then
            local cur = drv.playing
            return cur and fmt("DRV l1_stop n=%d %s  end %d/%d s", cur.n, cur.mode, (now - cur.t) // 1000, L1_LOST_MS // 1000)
                       or fmt("DRV l1_stop n=%d  waiting for AGENT_AUDIO ready", drv.n)
        elseif drv.name == "voice_toggle" then
            return fmt("DRV voice_toggle %d/%d calls=%d%s", math.min(drv.i, TOGGLE_CHANGES), TOGGLE_CHANGES,
                       drv.calls, drv.done and " done" or "")
        end
        return fmt("DRV send_spam %s sent=%d ok=%d%s", drv.phase, drv.sent, drv.ok, drv.done and " done" or "")
    end
    if exit_at then return fmt("EXIT_SOON in %d s", (exit_at - now + 999) // 1000) end
    return nil
end

-- ── Screen (480 x 320) ──────────────────────────────────────────────
-- testkit's single HUD label cannot colour rows, so the pack destroys it after S:start() and
-- draws from the suite's own state (tests, results, cursor, mode, active, st). Its hud_dirty
-- flag still says when the list changed. Eight labels = the whole Text pool.
-- Nunito line height = trunc(1.364 * px): 21 px at 16, 19 px at 14 (lv_tiny_ttf, no line space).
--   y   0  header   pack, is_a2a, scn, driver | row n/N, group i/n, PASS FAIL SKIP   16 px
--   y  44  deadline bar of the current wait
--   y  48  NOW      current row | WAIT label elapsed/limit s | result or prompt     14 px
--   y 109  rows     5 rows: status column (green/red/amber) + "NN GROUP case"       16 px
--   y 219  events   counters | driver | last events (time s, UART text)           14 px
--   y 300  hints    buttons for the current mode                                    14 px
local W = 480
local ROWS, ROW_H, ROW_Y = 5, 21, 109
local COL_STATUS, COL_NAME = 6, 56
local BAR_Y, BAR_H = 44, 3
local NOW_Y, EV_Y, HINT_Y = 48, 219, 300
local ROW_CHARS, LINE_CHARS = 51, 64
local RENDER_MS, EV_RENDER_MS = 100, 250
local RGB = { white = 0xFFFFFF, head = 0xFFFFFF, head_fail = 0xFF6060, pass = 0x40E070, fail = 0xFF5050,
              skip = 0xF0C040, run = 0xFFD060, row = 0xE8E8E8, ev = 0x9CC8FF, hint = 0xB0B0B0 }
local STATUS_RGB = { PASS = RGB.pass, FAIL = RGB.fail, SKIP = RGB.skip }
local C565 = { line = 0x39E7, track = 0x2945, fill = 0x055B, cursor = 0x114A, run = 0xFD20 }
local GROUP_TAG = { runner = "SUITE", send = "SEND", file = "FILE", data = "DATA", preload = "PRELOAD",
                    audio = "AUDIO", voice = "VOICE", stress = "STRESS" }
local LABELS = {   -- key, x, y, px, colour (creation order = stacking order)
    { "head", 6, 0, 16, RGB.head }, { "now", 6, NOW_Y, 14, RGB.white },
    { "pass", COL_STATUS, ROW_Y, 16, RGB.pass }, { "fail", COL_STATUS, ROW_Y, 16, RGB.fail },
    { "skip", COL_STATUS, ROW_Y, 16, RGB.skip }, { "rows", COL_NAME, ROW_Y, 16, RGB.row },
    { "ev", 6, EV_Y, 14, RGB.ev }, { "hint", 6, HINT_Y, 14, RGB.hint },
}
local HINT_SINGLE = "ENTER run row    LEFT / RIGHT move    row 01 = RUN SUITE"
local HINT_SUITE  = "RUN SUITE: rows run by themselves    LEFT = abort"
local HINT_CASE   = "case running    LEFT = abort it"

ui = { t = {}, last = {}, col = {}, ready = false, titles = {}, rowtxt = {},
       bar_on = false, bar_x = nil, wkey = -2, wl = nil, now_dirty = true, row_ms = 0,
       ev_dirty = true, ev_ms = 0, dkey = -2, hkey = -2, head1 = "",
       b_rows = {}, b_pass = {}, b_fail = {}, b_skip = {}, b_ev = {} }

local function clip(s, n)
    if #s > n then return s:sub(1, n - 1) .. "~" end
    return s
end

local function set_text(k, s, rgb)
    local h = ui.t[k]
    if not h then return end
    if ui.last[k] ~= s then ui.last[k] = s; h:set(s) end
    if rgb and ui.col[k] ~= rgb then ui.col[k] = rgb; h:set_color(rgb) end
end

local function solid(w, h, c565, x, y, visible)
    local s, err = Sprite.solid(w, h, c565)
    if not s then print("a2a: ui Sprite.solid failed: " .. tostring(err)); return nil end
    s:set_pos(x, y)
    if not visible then s:set_visible(false) end
    return s
end

local function ui_init()
    if S.hud then S.hud:destroy(); S.hud = nil end     -- free testkit's label: the pack draws
    ui.s_line1  = solid(W, 1, C565.line, 0, BAR_Y - 1, true)
    ui.s_track  = solid(W, BAR_H, C565.track, 0, BAR_Y, true)
    ui.s_fill   = solid(W, BAR_H, C565.fill, -W, BAR_Y, false)
    ui.s_line2  = solid(W, 1, C565.line, 0, ROW_Y - 3, true)
    ui.s_cursor = solid(W, ROW_H, C565.cursor, 0, ROW_Y - 1, true)
    ui.s_run    = solid(4, ROW_H, C565.run, 0, ROW_Y - 1, false)
    ui.s_line3  = solid(W, 1, C565.line, 0, EV_Y - 3, true)
    ui.s_line4  = solid(W, 1, C565.line, 0, HINT_Y - 2, true)
    for _, l in ipairs(LABELS) do
        local t, err = Text.new("", l[2], l[3])
        if t then
            local ok, ferr = t:set_font(FONT, l[4])
            if ok == nil and ferr then print("a2a: ui set_font failed: " .. tostring(ferr)) end
            t:set_color(l[5])
            ui.col[l[1]] = l[5]
        else
            print("a2a: ui Text.new failed: " .. tostring(err))
        end
        ui.t[l[1]] = t
    end
    -- static per-row strings: "NN GROUP case" and the NOW title with group i/n
    local n = #S.tests
    local gsize, gpos = {}, {}
    for i, t in ipairs(S.tests) do
        gsize[t.group] = (gsize[t.group] or 0) + 1
        gpos[i] = gsize[t.group]
    end
    for i, t in ipairs(S.tests) do
        local g = GROUP_TAG[t.group] or t.group
        ui.rowtxt[i] = clip(fmt("%02d %-7s %s", i, g, t.name), ROW_CHARS)
        ui.titles[i] = clip(fmt("%02d/%02d %s %d/%d :: %s", i, n, g, gpos[i], gsize[t.group], t.name), LINE_CHARS)
    end
    ui.gpos, ui.gsize = gpos, gsize
    local mode = ph and (" phase=" .. ph.id) or (drv and " driver") or ""
    ui.head1 = clip(fmt("GAME A2A TEST  is_a2a=%s  scn=%s%s", tostring(st.is_a2a), tostring(st.scn), mode), 54)
    ui.ready = true
end

local function draw_rows()
    local n, cur = #S.tests, S.cursor
    local top = cur - 2
    if top > n - ROWS + 1 then top = n - ROWS + 1 end
    if top < 1 then top = 1 end
    local br, bp, bf, bs = ui.b_rows, ui.b_pass, ui.b_fail, ui.b_skip
    local k = 0
    for i = top, math.min(n, top + ROWS - 1) do
        k = k + 1
        local r = S.results[i]
        local status = r and r.status
        br[k] = ui.rowtxt[i]
        bp[k] = status == "PASS" and "PASS" or ""
        bf[k] = status == "FAIL" and "FAIL" or ""
        bs[k] = (S.active == i and "RUN") or (status == "SKIP" and "SKIP") or ""
    end
    set_text("rows", concat(br, "\n", 1, k))
    set_text("pass", concat(bp, "\n", 1, k))
    set_text("fail", concat(bf, "\n", 1, k))
    set_text("skip", concat(bs, "\n", 1, k))
    local y = ROW_Y + (cur - top) * ROW_H - 1
    if ui.s_cursor then ui.s_cursor:set_pos(0, y) end
    if ui.s_run then
        ui.s_run:set_pos(0, y)
        ui.s_run:set_visible(S.active ~= nil)
    end
    local p, f, s = S:counts()
    local t = S.tests[cur]
    local line2 = fmt("%02d/%02d  %s %d/%d    PASS %d  FAIL %d  SKIP %d", cur, n, GROUP_TAG[t.group] or t.group,
                      ui.gpos[cur], ui.gsize[t.group], p, f, s)
    set_text("head", ui.head1 .. "\n" .. line2, f > 0 and RGB.head_fail or RGB.head)
end

local function draw_now(now, t)
    local i = S.active or S.cursor
    local l2, l3, rgb
    if t then
        rgb = RGB.run
        if t.wl then
            l2 = fmt("WAIT %s  %d / %d s  (then %s)", t.wl, (now - t.wt0) // 1000, (t.wms + 999) // 1000, t.wlate)
        else
            l2 = "running"
        end
        local p = S.tests[i].prompt
        l3 = type(p) == "string" and p or ""
    elseif S.mode == "between" then
        rgb, l2, l3 = RGB.white, "RUN SUITE: starting this row", ""
    else
        local r = S.results[i]
        if r then
            local m = r.status .. "  " .. r.msg
            rgb, l2, l3 = STATUS_RGB[r.status], m:sub(1, LINE_CHARS), clip(m:sub(LINE_CHARS + 1), LINE_CHARS)
        else
            rgb, l3 = RGB.white, ""
            l2 = S.tests[i].manual and "not run (manual row: RUN SUITE skips it)" or "not run"
        end
    end
    set_text("now", ui.titles[i] .. "\n" .. clip(l2, LINE_CHARS) .. "\n" .. l3, rgb)
end

local function draw_events(now)
    local b, n = ui.b_ev, 1
    b[1] = fmt("data %d ack %d pre %d/%d hello %d rdy %d end %d voice %d out %d/%d",
               C.data, C.ack, C.preload_ok, C.preload, C.hello, C.ready, C.ended, C.voice, C.out_sent, C.out_dropped)
    local d = driver_status(now)
    local shown = EV_MAX
    if d then n = 2; b[2] = clip(d, LINE_CHARS); shown = EV_MAX - 1 end
    for k = shown - 1, 0, -1 do           -- oldest first, newest on the last line
        n = n + 1
        b[n] = clip(ev_ring[(ev_head - 1 - k) % EV_MAX + 1] or "", LINE_CHARS)
    end
    set_text("ev", concat(b, "\n", 1, n))
end

local function draw_hint(now)
    local key, s
    if st.is_a2a and st.auto and not auto_fired and st.scn ~= "exit_soon" and S.mode == "single" then
        key = 100 + (st.t_start + AUTO_START_MS - now) // 1000
        if key == ui.hkey then return end
        s = fmt("RUN SUITE starts in %d s    ENTER = now    LEFT / RIGHT move", key - 99)
    else
        key = (S.mode == "single") and 1 or (S.in_suite and 2 or 3)
        if key == ui.hkey then return end
        s = (key == 1 and HINT_SINGLE) or (key == 2 and HINT_SUITE) or HINT_CASE
    end
    ui.hkey = key
    set_text("hint", s)
end

-- Called every tick; builds strings only when something shown changed (rows on the testkit
-- dirty flag, the wait line once per second, events at most every EV_RENDER_MS).
local function ui_tick(now)
    if not ui.ready then return end
    local t = (S.mode == "running") and S.st or nil
    local wkey = -1
    if t and t.wms then
        local el = now - t.wt0
        if el < 0 then el = 0 elseif el > t.wms then el = t.wms end
        local x = (W * el) // t.wms - W
        if ui.s_fill and x ~= ui.bar_x then
            ui.bar_x = x
            ui.s_fill:set_pos(x, BAR_Y)
            if not ui.bar_on then ui.bar_on = true; ui.s_fill:set_visible(true) end
        end
        wkey = el // 1000
    elseif ui.bar_on then
        ui.bar_on, ui.bar_x = false, nil
        ui.s_fill:set_visible(false)
    end
    if S.hud_dirty and now - ui.row_ms >= RENDER_MS then
        S.hud_dirty, ui.row_ms, ui.now_dirty = false, now, true
        draw_rows()
    end
    local wl = t and t.wl
    if ui.now_dirty or wkey ~= ui.wkey or wl ~= ui.wl then
        ui.now_dirty, ui.wkey, ui.wl = false, wkey, wl
        draw_now(now, t)
    end
    local dkey = (ph or drv or exit_at) and (now - st.t_start) // 1000 or -1
    if dkey ~= ui.dkey or (ui.ev_dirty and now - ui.ev_ms >= EV_RENDER_MS) then
        ui.dkey, ui.ev_dirty, ui.ev_ms = dkey, false, now
        draw_events(now)
    end
    draw_hint(now)
end

-- ── Engine hooks ────────────────────────────────────────────────────
function game_start(params)
    st.t_start = clock_ms()
    st.params = type(params) == "table" and params or {}
    st.is_a2a = st.params.is_a2a == true
    st.preload = type(st.params.preload) == "table" and st.params.preload or nil
    local pp = type(st.params.params) == "table" and st.params.params or EMPTY
    local ok, d = pcall(Pack.data, "game")
    st.data = ok and d or nil
    if not ok then log("Pack.data(game) raised: " .. tostring(d)) end
    st.scn = pp.scn or (type(st.data) == "table" and st.data.scn) or nil
    if pp.auto == false then st.auto = false end
    log(fmt("start is_a2a=%s lang=%s scn=%s data=%s preload=%s send=%s",
            tostring(st.is_a2a), tostring(st.params.language), tostring(st.scn),
            type(st.data), tostring(st.preload ~= nil), tostring(pack_send ~= nil)))
    if st.is_a2a then ph = phase_setup(st.data) end
    if ph and not ph.suite then st.auto = false end
    if st.is_a2a and not ph then drv = drv_setup(st.scn) end
    if drv then st.auto = false end
    S:start()
    ui_init()
    hello_reset(st.t_start)
    if st.scn and st.scn ~= "none" and st.scn ~= "preload" then
        queue_send("scn", { id = st.scn })
    end
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

local function exit_with(reason)
    Engine.report_result({ event = "win" })
    Engine.exit(reason)
end

function on_tick(_dt)
    local now = clock_ms()
    drain_outbox(now)
    hello_tick(now)
    if preload_dirty and now - preload_report_ms >= PRELOAD_SEEN_MS then
        preload_dirty, preload_report_ms = false, now
        queue_send("preload_seen", { n = C.preload, ok = C.preload_ok, fail = C.preload_fail })
    end
    if st.is_a2a and st.auto and not auto_fired and now - st.t_start >= AUTO_START_MS then
        auto_fired = true
        if st.scn == "exit_soon" then
            exit_at = now + EXIT_SOON_MS
        elseif S.mode == "single" and S.cursor == 1 then
            S:input(S.fire, Input.PRESS, 0)        -- row 01 = RUN SUITE
        end
    end
    if exit_at and now >= exit_at then
        exit_at = nil
        exit_with("exit_soon")
    end
    if exit_req then
        exit_req = false
        exit_with("server_exit")
    end
    if ph then phase_tick(now) end
    if drv then drv.fn(now) end
    S:tick()
    ui_tick(now)
end

function game_end()
    S:summary(fmt("data=%d ack=%d preload=%d/%d hello=%d ready=%d end=%d voice=%d raw=%d out_sent=%d out_dropped=%d",
                  C.data, C.ack, C.preload_ok, C.preload, C.hello, C.ready, C.ended, C.voice, C.raw,
                  C.out_sent, C.out_dropped))
end
