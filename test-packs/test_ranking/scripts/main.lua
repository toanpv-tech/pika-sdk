-- test_ranking: the Ranking API (Ranking.report, Ranking.get_result) on a robot.
--
-- Groups (suite order):
--   probe  : both calls exist; get_result() is nil when nothing is pending
--   guard  : bad arguments to Ranking.report return false and never raise
--            (status-call family: it validates little and drops a bad call)
--   result : one report{score = 0} -> true, then poll get_result() from
--            on_tick until the leaderboard arrives; the table's shape and
--            consume-once (the next call is nil) are checked
--   accept : a numeric-string score is accepted like a number
--
-- Needs the robot launched FROM THE MENU with network: only then does the
-- body board post the score and send the leaderboard back. In talk-flow
-- (params.is_a2a) the report goes to the conversation and no result follows,
-- so the result test is "skip". Offline, outside a server session or with a
-- slow server, nothing arrives before the deadline: also "skip", because Lua
-- cannot tell those cases apart. smoke.py does not model the server either.
--
-- Every accepted report is a real score on this pack's leaderboard: the suite
-- sends two (score 0), the guard rows send none.

local RANK_TIMEOUT_MS = 10000   -- knowledge/recipes/leaderboard.md RANK-DEADLINE uses 6 s (not measured)
local SCORE           = 0       -- keeps the real leaderboard clean of fake highs

local fmt = string.format
local clock_ms = Timer.millis
local Ranking_report, Ranking_get_result = Ranking.report, Ranking.get_result

local start = { is_a2a = false, stale = nil }
local stats = { reports = 0, last = "none" }

local function summarize(r)
    local top = type(r.top) == "table" and #r.top or -1
    local mine = type(r.my_rank) == "table" and ("#" .. tostring(r.my_rank.rank)) or "none"
    return fmt("top=%d my_rank=%s best=%s", top, mine, tostring(r.my_best_score))
end

-- Counts accepted reports for the HUD; every true is a score on the server.
local function report(t)
    local r = Ranking_report(t)
    if r == true then stats.reports = stats.reports + 1 end
    return r
end

-- ── Suite ────────────────────────────────────────────────────────────
local tk = require("libs/testkit")

local S = tk.suite({
    tag = "ranking", title = "RANKING TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    groups = {
        probe  = { label = "PROBE",   what = "calls exist, nothing pending" },
        guard  = { label = "GUARDS",  what = "bad report args -> false" },
        result = { label = "RESULT",  what = "report, then poll the leaderboard" },
        accept = { label = "ACCEPT",  what = "numeric-string score" },
    },
    status = function()
        return fmt("%s  sent=%d  last result: %s",
                   start.is_a2a and "talk-flow" or "menu", stats.reports, stats.last)
    end,
})

-- ── Group: probe ─────────────────────────────────────────────────────
S:sync("probe", "report / get_result are functions", function()
    local ok = type(Ranking_report) == "function" and type(Ranking_get_result) == "function"
    return ok, fmt("report=%s get_result=%s", type(Ranking_report), type(Ranking_get_result))
end)

-- The first call may hand back a result latched before this test (api.md:
-- a result after the last game ended comes back on the next first call), so
-- drain once; the second call must then be nil.
S:sync("probe", "get_result() with nothing pending -> nil", function()
    local first = Ranking_get_result()
    local second = Ranking_get_result()
    return second == nil, fmt("drained %s, then %s", type(first), tostring(second))
end)

-- ── Group: guard ─────────────────────────────────────────────────────
local function expect_false(what, ...)
    local ok, r = pcall(Ranking_report, ...)
    if not ok then return false, what .. " raised: " .. tostring(r) end
    return r == false, fmt("%s -> %s", what, tostring(r))
end

S:sync("guard", "report() no argument -> false", function()
    return expect_false("()")
end)

S:sync("guard", "report('x') not a table -> false", function()
    return expect_false("'x'", "x")
end)

S:sync("guard", "report{} no score -> false", function()
    return expect_false("{}", {})
end)

S:sync("guard", "report{score=true} -> false", function()
    return expect_false("score=true", { score = true })
end)

S:sync("guard", "report{score='abc'} -> false", function()
    return expect_false("score='abc'", { score = "abc" })
end)

S:sync("guard", "report{score={}} -> false", function()
    return expect_false("score={}", { score = {} })
end)

-- ── Group: result ────────────────────────────────────────────────────
local function check_shape(r)
    if type(r.top) ~= "table" then return false, "top is " .. type(r.top) end
    for i = 1, #r.top do
        local row = r.top[i]
        if type(row) ~= "table" or type(row.rank) ~= "number" or type(row.score) ~= "number" then
            return false, fmt("top[%d] lacks number rank/score", i)
        end
    end
    if r.my_rank ~= nil and type(r.my_rank) ~= "table" then
        return false, "my_rank is " .. type(r.my_rank)
    end
    if r.my_best_score ~= nil and type(r.my_best_score) ~= "number" then
        return false, "my_best_score is " .. type(r.my_best_score)
    end
    return true
end

-- One latch, not a queue: the table may answer an earlier accepted report
-- of this session (e.g. the accept row run by hand), not this one.
S:async("result", "report{score=0} -> true, result arrives",
    function()
        if start.is_a2a then return { skip = true } end
        Ranking_get_result()                          -- RANK-STALE: drop an old answer
        local sent = report({ score = SCORE })
        return { sent = sent, t0 = clock_ms() }
    end,
    function(st)
        if st.skip then
            return true, "skip", "talk-flow: the report goes to the conversation, no result"
        end
        if st.sent ~= true then
            return true, false, "report returned " .. tostring(st.sent)
        end
        local r = Ranking_get_result()
        if r == nil then
            local waited = clock_ms() - st.t0
            if waited < RANK_TIMEOUT_MS then return false end
            return true, "skip", fmt("no result in %d s: offline, not launched from the menu, or server slow",
                                     RANK_TIMEOUT_MS // 1000)
        end
        local waited = clock_ms() - st.t0
        if type(r) ~= "table" then
            return true, false, "get_result returned " .. type(r)
        end
        stats.last = summarize(r)
        local again = Ranking_get_result()
        if again ~= nil then
            return true, false, "consume-once broken: second call returned " .. type(again)
        end
        local ok, why = check_shape(r)
        if not ok then return true, false, why end
        return true, true, fmt("after %d ms: %s; second call nil", waited, stats.last)
    end,
    { prompt = "waiting for the leaderboard (LEFT aborts)", settle_ms = 1500 })

-- ── Group: accept ────────────────────────────────────────────────────
-- api.md: score may be a number or a numeric string (bind_ranking.c reads it
-- with lua_isnumber). This row posts a second real score.
S:sync("accept", "report{score='0'} numeric string -> true", function()
    local ok, r = pcall(report, { score = "0" })
    if not ok then return false, "raised: " .. tostring(r) end
    return r == true, "-> " .. tostring(r)
end)

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start(params)
    start.is_a2a = type(params) == "table" and params.is_a2a == true
    -- RANK-STALE: a slow answer from the previous game is returned here once.
    local stale = Ranking_get_result()
    start.stale = stale and summarize(stale) or nil
    print(fmt("ranking: game_start is_a2a=%s stale=%s",
              tostring(start.is_a2a), tostring(start.stale)))
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    S:tick()
end

function game_end()
    S:summary(fmt("reports_sent=%d last_result=%s", stats.reports, stats.last))
end
