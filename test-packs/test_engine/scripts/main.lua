-- test_engine: the Engine API and the session hooks around it.
--
-- Covers game_start(params), Engine.show, Engine.report_result, on_home,
-- Engine.exit and game_end.
--
-- Groups:
--   start   : what game_start received and what Engine.show returned there
--   report  : Engine.report_result argument checks (talk-flow uses the value;
--             from the menu nothing reads it, the call still validates)
--   home    : press HOME; on_home returns true so the game keeps running
--   exit    : MANUAL rows (RUN SUITE skips them): each one ends the game.
--             The UART log then shows "engine game_end ran" from game_end.
--
-- Engine.show(false) is called in game_start, which keeps the robot's
-- loading animation up; the first on_tick calls Engine.show() to put the
-- game screen up. Older firmware has no Engine.show: those tests SKIP.

local REPORT_EVENT_MAX = 256     -- report_event_max_len in contract/constraints.json
local HOME_WAIT_MS     = 20000

local fmt, rep = string.format, string.rep
local clock_ms = Timer.millis

local start = { params = nil, is_a2a = false, language = nil,
                show_false = nil, show_first_tick = nil, ticks = 0 }
local home = { armed = false, count = 0 }

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "engine", title = "ENGINE TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    groups = {
        start  = { label = "START",  what = "game_start params, Engine.show" },
        report = { label = "REPORT", what = "Engine.report_result checks" },
        home   = { label = "HOME",   what = "on_home keeps the game" },
        exit   = { label = "EXIT",   what = "ends the game (manual rows)" },
    },
    status = function()
        return fmt("%s  lang=%s  home presses=%d",
                   start.is_a2a and "talk-flow" or "menu",
                   tostring(start.language), home.count)
    end,
})

-- ── Group: start ─────────────────────────────────────────────────────
S:sync("start", "params is a table", function()
    return type(start.params) == "table", "type=" .. type(start.params)
end)

S:sync("start", "params.is_a2a is boolean or nil", function()
    local v = type(start.params) == "table" and start.params.is_a2a
    return v == nil or v == false or v == true, "is_a2a=" .. tostring(v)
end)

S:sync("start", "params.language is a string", function()
    return type(start.language) == "string", "language=" .. tostring(start.language)
end)

S:sync("start", "Engine.show(false) in game_start -> true", function()
    if not Engine.show then return "skip", "no Engine.show on this firmware" end
    return start.show_false == true, "returned " .. tostring(start.show_false)
end)

S:sync("start", "Engine.show() on first tick -> true", function()
    if not Engine.show then return "skip", "no Engine.show on this firmware" end
    return start.show_first_tick == true, "returned " .. tostring(start.show_first_tick)
end)

S:sync("start", "Engine.show() when already up -> false", function()
    if not Engine.show then return "skip", "no Engine.show on this firmware" end
    local r = Engine.show()
    return r == false, "returned " .. tostring(r)
end)

-- ── Group: report ────────────────────────────────────────────────────
local function expect_bad_event(arg, what)
    local r, reason = Engine.report_result(arg)
    return r == nil and reason == "bad_event",
           fmt("%s -> %s, %s", what, tostring(r), tostring(reason))
end

S:sync("report", "report_result(string) raises", function()
    local ok = pcall(Engine.report_result, "win")
    return not ok, ok and "returned instead of raising" or "raised"
end)

S:sync("report", "missing event -> nil, bad_event", function()
    return expect_bad_event({}, "{}")
end)

S:sync("report", "empty event -> nil, bad_event", function()
    return expect_bad_event({ event = "" }, "event=''")
end)

S:sync("report", "event over 256 bytes -> nil, bad_event", function()
    return expect_bad_event({ event = rep("x", REPORT_EVENT_MAX + 1) },
                            fmt("%d bytes", REPORT_EVENT_MAX + 1))
end)

S:sync("report", "event 'win' -> true", function()
    local r, reason = Engine.report_result({ event = "win" })
    return r == true, fmt("-> %s%s (%s)", tostring(r),
                          reason and (", " .. reason) or "",
                          start.is_a2a and "talk-flow: sent" or "menu: nobody reads it")
end)

-- ── Group: home ──────────────────────────────────────────────────────
S:async("home", "HOME press -> on_home, game keeps running",
    function()
        if start.is_a2a then return { skip = true } end
        home.armed = true
        return { base = home.count, t0 = clock_ms() }
    end,
    function(st)
        if st.skip then return true, "skip", "talk-flow: HOME ends the game without on_home" end
        if home.count > st.base then
            home.armed = false
            return true, true, "on_home called, returned true, still running"
        end
        if clock_ms() - st.t0 >= HOME_WAIT_MS then
            home.armed = false
            return true, false, fmt("no on_home within %d s", HOME_WAIT_MS // 1000)
        end
        return false
    end,
    { prompt = "Short-press HOME once" })

-- ── Group: exit (manual: each row ends the game) ─────────────────────
S:sync("exit", "Engine.exit(table) raises", function()
    local ok = pcall(Engine.exit, {})
    -- if it did not raise, an exit is now scheduled: the log shows game_end
    return not ok, ok and "returned instead of raising (the game will end)" or "raised"
end, { manual = true })

for _, event in ipairs({ "win", "lose", "quit" }) do
    S:sync("exit", "report_result '" .. event .. "' + Engine.exit", function()
        local r, reason = Engine.report_result({ event = event })
        if r ~= true then return false, "report_result -> " .. tostring(reason) end
        Engine.exit("engine_" .. event)
        return true, "exit posted; expect 'engine game_end ran' in the log"
    end, { manual = true })
end

S:sync("exit", "Engine.exit() default reason", function()
    Engine.exit()
    return true, "exit posted with reason 'lua'"
end, { manual = true })

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start(params)
    start.params   = params
    start.is_a2a   = type(params) == "table" and params.is_a2a == true
    start.language = type(params) == "table" and params.language or nil
    if Engine.show then start.show_false = Engine.show(false) end
    print(fmt("engine: game_start is_a2a=%s language=%s show(false)=%s",
              tostring(start.is_a2a), tostring(start.language), tostring(start.show_false)))
    S:start()
end

function on_home()
    if not home.armed then return nil end   -- outside the test HOME ends the game
    home.count = home.count + 1
    print(fmt("engine: on_home #%d -> keep running", home.count))
    return true
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    if start.ticks == 0 and Engine.show then start.show_first_tick = Engine.show() end
    start.ticks = start.ticks + 1
    S:tick()
end

function game_end()
    print("engine game_end ran")
    S:summary()
end
