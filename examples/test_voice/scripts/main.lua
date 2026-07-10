-- voice_probe: minimal pack for verifying the game-voice binding end-to-end.
--
-- Model: keyword spotting (NOT conversation/STT). The game ships an English
-- keyword list; the child speaks a short command; the backend matches a
-- pre-loaded keyword and returns VOICE_COMMAND{data.keyword}. See
-- VoiceRefactor/Binding.md.
--
-- Modes (LEFT/RIGHT cycles; ENTER fires the active mode):
--   LISTEN  : set_keywords + start. Spoken commands land as e.data.keyword and
--             count into the HUD. e.data.status=="unavailable" hides voice UI
--             but the mode keeps running. ENTER toggles the session.
--   ERRORS  : Local error-model probe — NO network. Asserts the P1 binding
--             guards row by row (raise-on-misuse + (nil,reason)-on-runtime), so
--             this mode is the after-flash sanity check.
--   LATENCY : Server round-trip probe. Stamps connect RTT (Voice.start ->
--             first ack we can observe) and the time to the FIRST VOICE_COMMAND
--             after ENTER. The operator must speak a keyword to fill the
--             command milestone; connect RTT lands speech-free.
--   RESULT  : A2A game_result probe. ENTER cycles a report value (win/lose/quit);
--             it calls Engine.report_result{event=...} then Engine.exit(). In an
--             A2A talk-flow game the backend uplinks game_result{event} and the
--             agent resumes; in offline mode report_result is ignored back-side
--             (logged) and exit just ends the game. Voice.mode() shows which.
--
-- on_voice_event(e) arrives as a TABLE (engine marshals the JSON frame). A
-- defensive raw-string fallback keeps the game alive if the engine ever falls
-- back (parse fail / depth-cap hit).

-- Keywords this probe listens for. English-only (backend is a zh-en model);
-- Vietnamese / out-of-vocab phrases are rejected server-side and never trigger.
local KEYWORDS    = { "go left", "go right", "jump", "stop" }
local SENSITIVITY = 5

-- ── Localize hot upvalues ─────────────────────────────────────────────
local Voice_set_keywords = Voice.set_keywords
local Voice_start        = Voice.start
local Voice_stop         = Voice.stop
local Voice_is_available = Voice.is_available
local Voice_mode         = Voice.mode
local Engine_report      = Engine.report_result
local Engine_exit        = Engine.exit
-- One Text label, created lazily (Text.new needs the game screen).
local hud_lbl
local function HUD_set_label(s)
  if not Text then return end
  if hud_lbl then hud_lbl:set(s) else hud_lbl = Text.new(s, 4, 4) end
end
local fmt, concat        = string.format, table.concat
local rep                = string.rep
local pcall, ipairs, type, tostring = pcall, ipairs, type, tostring

local clock_ms = (Engine and Engine.now_ms) or (Timer and Timer.millis)
                 or function() return 0 end

-- ── Mode state (small, kept module-local) ─────────────────────────────
local MAX_CMD_RING = 6

local listen = {
    started     = false,   -- true between Voice.start and Voice.stop
    available   = true,    -- flipped false on status=="unavailable"
    last_err    = nil,
    commands    = 0,
    ring        = {},      -- recent keywords heard
}

local errors = {
    results = {},
    ran     = false,
}

-- LATENCY: connect RTT + time-to-first-command, both measured from Voice.start.
local latency = {
    started    = false,
    t0         = 0,
    dt_first   = nil,   -- first VOICE_COMMAND after start
    last_err   = nil,
    n = 0, sum = 0, best = nil, worst = nil,   -- first-command aggregate
}

-- RESULT: cycle a report value; ENTER reports it then exits the game.
local RESULT_EVENTS = { "win", "lose", "quit" }
local result = {
    idx      = 1,          -- which RESULT_EVENTS entry ENTER will report
    last_err = nil,
}

-- ── P1 error-model probe builders ─────────────────────────────────────
-- VOICE_MAX_KEYWORDS = 16 in bind_voice.c. Build 20 to be safely past.
local function build_too_many_keywords()
    local t = {}
    for i = 1, 20 do t[i] = "kw" .. i end
    return t
end

-- Object/sparse table is not a pure array -> keywords_not_array.
local function build_not_array()
    return { go_left = true, jump = true }
end

-- JSON_MAX = 1024B (incl. NUL). A handful of long keywords blows past while
-- staying under the 16-count cap so payload_too_big is what trips.
local function build_payload_too_big()
    local t = {}
    for i = 1, 8 do t[i] = rep("X", 200) end
    return t
end

-- ── P1 test rows ──────────────────────────────────────────────────────
-- Each row asserts ONE contract: arg-type error is a raise (game bug);
-- runtime failures are (nil, reason) (Lua pcall-friendly).
local error_tests = {
    {
        name = "arg=nil raises",
        run = function()
            local ok, err = pcall(Voice_set_keywords, nil)
            if ok then return false, "expected raise; got return" end
            if type(err) ~= "string" then return false, "raise msg not string" end
            return true, err
        end,
    },
    {
        name = "arg=string raises",
        run = function()
            local ok, err = pcall(Voice_set_keywords, "not_a_table")
            if ok then return false, "expected raise; got return" end
            return true, tostring(err)
        end,
    },
    {
        name = "sensitivity=string raises",
        run = function()
            local ok = pcall(Voice_set_keywords, { "jump" }, "loud")
            if ok then return false, "expected raise" end
            return true, "raised"
        end,
    },
    {
        name = "not_array -> (nil,'keywords_not_array')",
        run = function()
            local ok, reason = Voice_set_keywords(build_not_array())
            if ok ~= nil then return false, fmt("expected nil, got %s", tostring(ok)) end
            if reason ~= "keywords_not_array" then
                return false, fmt("reason=%s (want keywords_not_array)", tostring(reason))
            end
            return true, "reason=keywords_not_array"
        end,
    },
    {
        name = "too_many -> (nil,'too_many_keywords')",
        run = function()
            local ok, reason = Voice_set_keywords(build_too_many_keywords())
            if ok ~= nil then return false, "expected nil" end
            if reason ~= "too_many_keywords" then
                return false, fmt("reason=%s (want too_many_keywords)", tostring(reason))
            end
            return true, "reason=too_many_keywords"
        end,
    },
    {
        name = "too_big -> (nil,'payload_too_big')",
        run = function()
            local ok, reason = Voice_set_keywords(build_payload_too_big())
            if ok ~= nil then return false, "expected nil" end
            if reason ~= "payload_too_big" then
                return false, fmt("reason=%s (want payload_too_big)", tostring(reason))
            end
            return true, "reason=payload_too_big"
        end,
    },
    {
        name = "Voice.stop() idempotent when idle",
        run = function()
            local r = Voice_stop()
            if r ~= true then return false, fmt("got %s, want true", tostring(r)) end
            return true, "ok"
        end,
    },
    {
        name = "Voice.is_available() returns boolean",
        run = function()
            local v = Voice_is_available()
            if type(v) ~= "boolean" then
                return false, "got type=" .. type(v) .. " want boolean"
            end
            return true, "is_available=" .. tostring(v)
        end,
    },
    {
        name = "Voice.mode() returns string",
        run = function()
            local m = Voice_mode and Voice_mode() or nil
            if type(m) ~= "string" then
                return false, "got type=" .. type(m) .. " want string"
            end
            return true, "mode=" .. m
        end,
    },
}

local function run_error_tests()
    errors.results = {}
    local pass, fail = 0, 0
    for _, t in ipairs(error_tests) do
        local ok_run, ok, msg = pcall(t.run)
        local entry
        if not ok_run then
            entry = { name = t.name, status = "FAIL",
                      detail = "test raised: " .. tostring(ok) }
            fail = fail + 1
        elseif ok then
            entry = { name = t.name, status = "PASS", detail = msg or "" }
            pass = pass + 1
        else
            entry = { name = t.name, status = "FAIL", detail = msg or "" }
            fail = fail + 1
        end
        errors.results[#errors.results + 1] = entry
    end
    errors.ran = true
    print(fmt("voice_probe ERRORS: %d/%d PASS", pass, pass + fail))
    for _, r in ipairs(errors.results) do
        print(fmt("  [%s] %s :: %s", r.status, r.name, r.detail))
    end
end

-- ── Mode definitions ──────────────────────────────────────────────────
local hud_dirty = true
local function dirty() hud_dirty = true end

-- Load vocabulary then open the session. set_keywords must precede start so the
-- server vocabulary is non-empty (an empty START while idle is rejected with
-- no_keywords by back).
local function listen_start()
    listen.last_err  = nil
    listen.available = true
    local ok, reason = Voice_set_keywords(KEYWORDS, SENSITIVITY)
    if ok == nil then
        listen.last_err = reason or "set_keywords_failed"
        print("voice_probe LISTEN set_keywords failed: " .. tostring(reason))
        return false
    end
    ok, reason = Voice_start()
    if ok == nil then
        listen.last_err = reason or "start_failed"
        print("voice_probe LISTEN start failed: " .. tostring(reason))
        return false
    end
    print("voice_probe LISTEN start ok")
    return true
end

local function listen_toggle()
    if listen.started then
        Voice_stop()
        listen.started = false
        print("voice_probe LISTEN: stop requested")
        return
    end
    if listen_start() then listen.started = true end
end

local function latency_reset_run()
    latency.dt_first = nil
    latency.last_err = nil
end

local function latency_record_first(dt)
    latency.dt_first = dt
    latency.n   = latency.n + 1
    latency.sum = latency.sum + dt
    if not latency.best  or dt < latency.best  then latency.best  = dt end
    if not latency.worst or dt > latency.worst then latency.worst = dt end
end

local function latency_toggle()
    if latency.started then
        Voice_stop()
        latency.started = false
        print("voice_probe LATENCY: stop requested")
        return
    end
    latency_reset_run()
    latency.t0 = clock_ms()
    local ok, reason = Voice_set_keywords(KEYWORDS, SENSITIVITY)
    if ok == nil then
        latency.last_err = reason or "set_keywords_failed"
        print("voice_probe LATENCY set_keywords failed: " .. tostring(reason))
        return
    end
    ok, reason = Voice_start()
    if ok == nil then
        latency.last_err = reason or "start_failed"
        print("voice_probe LATENCY start failed: " .. tostring(reason))
    else
        latency.started = true
        print("voice_probe LATENCY start ok (speak a keyword)")
    end
end

-- RESULT: report the currently-selected event, then exit. In an A2A game the
-- backend uplinks game_result{event}; offline it is ignored back-side. Because
-- ENTER ends the game, the event is chosen by re-entering this mode: each entry
-- via LEFT/RIGHT advances win -> lose -> quit (see on_input). ENTER fires it.
local function result_fire()
    local ev = RESULT_EVENTS[result.idx] or "win"
    local ok, reason = Engine_report({ event = ev })
    if ok == nil then
        result.last_err = reason or "report_failed"
        print("voice_probe RESULT report failed: " .. tostring(reason))
        dirty()
        return
    end
    print("voice_probe RESULT reported event=" .. ev .. " -> exit")
    Engine_exit(ev)   -- ends the game; back sends GAME_STOP -> conversation LeaveGame
end

local MODES = {
    { name = "LISTEN",  hint = "ENTER toggle; speak a command",         on_fire = listen_toggle },
    { name = "ERRORS",  hint = "ENTER run P1 guard tests (local)",      on_fire = run_error_tests },
    { name = "LATENCY", hint = "ENTER probe; speak for cmd RTT",        on_fire = latency_toggle },
    { name = "RESULT",  hint = "LEFT/RIGHT picks event; ENTER report+exit", on_fire = result_fire },
}
local cursor = 1

-- ── on_voice_event dispatch ───────────────────────────────────────────
local function push_command(keyword)
    listen.ring[#listen.ring + 1] = keyword or "?"
    if #listen.ring > MAX_CMD_RING then table.remove(listen.ring, 1) end
    listen.commands = listen.commands + 1
end

local function clear_started(mode_name)
    if mode_name == "LISTEN" then listen.started = false
    elseif mode_name == "LATENCY" then latency.started = false end
end

function on_voice_event(e)
    -- Defensive: parse-fail / depth-cap fallback delivers a raw JSON string.
    if type(e) ~= "table" then
        print("voice_probe: raw-string event fallback: " .. tostring(e))
        if cursor == 1 then listen.last_err = "raw_fallback" end
        if cursor == 3 then latency.last_err = "raw_fallback" end
        dirty()
        return
    end

    local t = e.type
    local mode_name = MODES[cursor].name

    -- Engine-synth error frames (back {type:"error",code,message}) — terminal.
    if t == "error" then
        if mode_name == "LISTEN" then listen.last_err = e.code or "?"
        elseif mode_name == "LATENCY" then latency.last_err = e.code or "?" end
        clear_started(mode_name)
        print(fmt("voice_probe %s ERROR code=%s msg=%s",
                  mode_name, tostring(e.code), tostring(e.message)))
        dirty()
        return
    end

    -- Server VOICE_COMMAND — two branches per BE contract:
    --   data.keyword           -> a recognised command
    --   data.status=="unavail" -> keyword spotting down; hide voice UI, keep
    --                             playing (backend never closes the session).
    if t == "VOICE_COMMAND" then
        local data = e.data
        if type(data) == "table" and data.keyword then
            push_command(data.keyword)
            if mode_name == "LATENCY" and latency.started and not latency.dt_first then
                latency_record_first(clock_ms() - latency.t0)
                latency.started = false   -- one-shot per ENTER
            end
            print(fmt("voice_probe CMD: %s", tostring(data.keyword)))
        elseif type(data) == "table" and data.status == "unavailable" then
            listen.available = false
            print("voice_probe: voice unavailable (game keeps playing)")
        else
            print("voice_probe: VOICE_COMMAND with no keyword/status")
        end
        dirty()
        return
    end

    -- Unknown type — log + show so we never silently drop a server message.
    print(fmt("voice_probe: unknown event type=%s", tostring(t)))
    dirty()
end

-- Advance the RESULT event selector when the cursor lands on the RESULT mode,
-- so LEFT/RIGHT both browse modes AND pick win/lose/quit (ENTER ends the game,
-- so there is no in-mode ENTER to cycle with).
local function on_cursor_moved()
    if MODES[cursor].name == "RESULT" then
        result.idx = (result.idx % #RESULT_EVENTS) + 1
    end
end

-- ── Input ─────────────────────────────────────────────────────────────
function on_input(action, phase, _hold_ms)
    if phase ~= Input.PRESS then return end
    if action == "next" then
        cursor = (cursor % #MODES) + 1
        on_cursor_moved()
        dirty()
    elseif action == "prev" then
        cursor = ((cursor - 2) % #MODES) + 1
        on_cursor_moved()
        dirty()
    elseif action == "fire" then
        MODES[cursor].on_fire()
        dirty()
    end
end

-- ── HUD ───────────────────────────────────────────────────────────────
local hud_buf = {}

local function render_listen(buf, n)
    n = n + 1; buf[n] = fmt("LISTEN running=%s cmds=%d",
                            tostring(listen.started), listen.commands)
    n = n + 1; buf[n] = "voice: " .. (listen.available and "available" or "UNAVAILABLE")
    if listen.last_err then
        n = n + 1; buf[n] = "ERR: " .. listen.last_err
    end
    n = n + 1; buf[n] = "kw: " .. concat(KEYWORDS, ", "):sub(1, 34)
    local count = #listen.ring
    local start = math.max(1, count - 3)
    for i = start, count do
        n = n + 1; buf[n] = "  > " .. (listen.ring[i] or "")
    end
    return n
end

local function render_errors(buf, n)
    if not errors.ran then
        n = n + 1; buf[n] = "(not run — press ENTER)"
        return n
    end
    local pass = 0
    for _, r in ipairs(errors.results) do
        if r.status == "PASS" then pass = pass + 1 end
    end
    n = n + 1; buf[n] = fmt("ERRORS: %d/%d PASS", pass, #errors.results)
    local start = math.max(1, #errors.results - 4)
    for i = start, #errors.results do
        local r = errors.results[i]
        n = n + 1; buf[n] = fmt(" %s %s", r.status, (r.name or ""):sub(1, 32))
    end
    return n
end

local function render_latency(buf, n)
    local function ms(v) return v and (tostring(v) .. "ms") or "--" end
    n = n + 1; buf[n] = fmt("LATENCY running=%s", tostring(latency.started))
    n = n + 1; buf[n] = fmt(" 1st cmd RTT: %s", ms(latency.dt_first))
    if latency.n > 0 then
        n = n + 1; buf[n] = fmt("cmd n=%d min=%d avg=%d max=%d",
                                latency.n, latency.best,
                                math.floor(latency.sum / latency.n + 0.5),
                                latency.worst)
    end
    if latency.last_err then
        n = n + 1; buf[n] = "ERR: " .. latency.last_err
    end
    return n
end

local function render_result(buf, n)
    n = n + 1; buf[n] = fmt("RESULT mode=%s",
                            tostring(Voice_mode and Voice_mode() or "?"))
    n = n + 1; buf[n] = fmt("event > %s", RESULT_EVENTS[result.idx] or "?")
    n = n + 1; buf[n] = "(A2A: uplinks game_result)"
    if result.last_err then
        n = n + 1; buf[n] = "ERR: " .. result.last_err
    end
    return n
end

-- Structured panel: a fixed-width rule frames the screen, the mode name + hint
-- read as a plain-language "what this mode does", and the mode body renders
-- below it.
local PANEL_W = 40
local RULE    = string.rep("-", PANEL_W)

local function render()
    local m = MODES[cursor]
    local n = 0
    n = n + 1; hud_buf[n] = fmt("VOICE PROBE           %d/%d", cursor, #MODES)
    n = n + 1; hud_buf[n] = RULE
    n = n + 1; hud_buf[n] = "MODE > " .. m.name
    n = n + 1; hud_buf[n] = "     " .. m.hint
    n = n + 1; hud_buf[n] = RULE
    if     cursor == 1 then n = render_listen(hud_buf, n)
    elseif cursor == 2 then n = render_errors(hud_buf, n)
    elseif cursor == 3 then n = render_latency(hud_buf, n)
    else                    n = render_result(hud_buf, n) end
    n = n + 1; hud_buf[n] = RULE
    n = n + 1; hud_buf[n] = "LEFT/RIGHT = mode   ENTER = fire"
    for i = n + 1, #hud_buf do hud_buf[i] = nil end
    HUD_set_label(concat(hud_buf, "\n", 1, n))
end

-- ── Engine hooks ──────────────────────────────────────────────────────
function game_start()
    local ev = (Engine and Engine.version and Engine.version()) or "?"
    print(fmt("voice_probe game_start engine=%s available=%s mode=%s",
              tostring(ev), tostring(Voice_is_available()),
              tostring(Voice_mode and Voice_mode() or "?")))
    dirty()
end

function on_tick(_dt)
    if hud_dirty then
        render()
        hud_dirty = false
    end
end

function game_end()
    Voice_stop()
    print(fmt("voice_probe game_end cmds=%d err_tests=%d lat_samples=%d",
              listen.commands, #errors.results, latency.n))
end
