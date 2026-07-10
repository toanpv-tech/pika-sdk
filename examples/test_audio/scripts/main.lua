-- audio: stress + behaviour suite for the engine_level >=6 Speaker surface.
--
-- Layout (same runner as led_test / servo_test):
--   row 1   = "RUN SUITE" meta entry (ENTER walks every test)
--   row 2   = "Reset results"
--   row 3+  = individual tests grouped by category
--
-- Test groups (suite order):
--   playall   : jukebox — play EVERY file to its natural end, one at a time
--               (the "hear them all" mode + end-to-end decode proof)
--   probe     : get_volume range, is_busy/stats shape
--   boundary  : input validation (unknown alias, non-string, idle stop,
--               volume clamp, non-number no-op)
--   volume    : session volume set/get round-trip
--   play      : real playback — natural COMPLETED, explicit STOPPED,
--               PREEMPTED on overlap, loop re-issue (async, finish-driven)
--   sweep     : the whole real-asset playlist — every clip resolves +
--               decodes (path/asset check), then a distinct-file preempt storm
--   stress    : cooldown throttle flood, stop_all silence
--   diag      : stats dump with auto-DIAG hints
--
-- Controls:
--   LEFT/RIGHT : navigate, or abort an in-flight suite/async test
--   ENTER      : fire highlighted row
--
-- Pass criteria (head-side contract):
--   * Lua API returns the documented bool (true on accept, false on reject).
--   * Finish events arrive via on_sound_end(alias, reason) with the right
--     reason: natural EOF -> COMPLETED, Speaker.stop -> STOPPED, overlap ->
--     PREEMPTED. A loop-flagged alias re-issues silently (no COMPLETED).
--   * Cooldown gate rejects a tight play() flood (cooldown_reject grows).
--
-- This suite doubles as the on-target check for the sound bridge: if
-- Speaker.play() returns false / no finish event ever fires, the main-side
-- AudioManager bridge (pika_sound_bridge.cpp) is not wired and the engine
-- is running audio-less. The DIAG test names that failure mode explicitly.
--
-- Risk-aware design: every test wrapped in pcall, async tests own their
-- timing and snapshot Speaker.stats() at arm + validate. The cooldown hot
-- loop reuses no per-tick allocation.

-- ── Localize hot upvalues ────────────────────────────────────────────
local Speaker_play       = Speaker.play
local Speaker_stop       = Speaker.stop
local Speaker_stop_all   = Speaker.stop_all
local Speaker_is_playing = Speaker.is_playing
local Speaker_is_busy    = Speaker.is_busy
local Speaker_set_volume = Speaker.set_volume
local Speaker_get_volume = Speaker.get_volume
local Speaker_stats      = Speaker.stats
-- One Text label, created lazily (Text.new needs the game screen).
local hud_lbl
local function HUD_set_label(s)
  if not Text then return end
  if hud_lbl then hud_lbl:set(s) else hud_lbl = Text.new(s, 4, 4) end
end
local pcall, ipairs, pairs = pcall, ipairs, pairs
local fmt    = string.format
local concat = table.concat

local clock_ms = (Engine and Engine.now_ms) or (Timer and Timer.millis)
                 or function() return 0 end

-- ── Constants ────────────────────────────────────────────────────────
-- Manifest aliases (SD/games/audio/manifest.json -> audio.sounds).
-- Behavioural aliases, mapped to the real assets on the card, sized per test:
local A_SFX   = "sfx"        -- short WAV  (assets/audio/output.wav,      12 KB)
local A_CLIP  = "clip"       -- shortest   (assets/audio/en_home.mp3,     11 KB)
local A_LONG  = "long"       -- longest    (assets/audio/en_greeting.mp3, 92 KB)
local A_LOOP  = "loopclip"   -- loop=true  (assets/audio/en_home.mp3, short -> re-issues)

-- Stress playlist: the spread of real production clips on the card (all mp3,
-- 11-92 KB) used by the "sweep" group to exercise the AudioManager bridge, SD
-- path resolution and decoder setup/teardown across the WHOLE asset set rather
-- than a single file. Each name is a manifest alias -> a distinct real file.
-- (output.wav is intentionally excluded here: it is too short to still be
-- playing inside the open-window check; it is covered by the cooldown flood.)
local PLAYLIST = {
    "home", "greeting", "glitch", "glitch2",
    "let_learn", "lost_wifi", "sleep", "error",
}
local N_SOUNDS = 4 + #PLAYLIST   -- declared aliases (for game_start log)

-- Full real-asset list: one alias per DISTINCT file on the card (incl. the
-- short WAV). The "play all" jukebox walks this and waits for each clip's
-- natural COMPLETED before moving on, so every sound is heard end-to-end.
local FULL_PLAYLIST = {
    "sfx", "home", "greeting", "glitch", "glitch2",
    "let_learn", "lost_wifi", "sleep", "error",
}
local CLIP_MAX_MS = 30000   -- per-clip ceiling if no COMPLETED ever arrives

-- Mirror of PIKA_SOUND_PLAY_COOLDOWN_US (sound_tuning.h, default 80 ms).
local COOLDOWN_MS = 80

-- Reason code names for readable logs/HUD.
local REASON_NAME = {
    [Speaker.REASON_COMPLETED] = "COMPLETED",
    [Speaker.REASON_STOPPED]   = "STOPPED",
    [Speaker.REASON_PREEMPTED] = "PREEMPTED",
    [Speaker.REASON_ERROR]     = "ERROR",
}
local function reason_name(r)
    return REASON_NAME[r] or ("?" .. tostring(r))
end

-- Suite settle windows.
local SETTLE_MS      = 1200    -- default gap between suite tests
local PLAY_SETTLE_MS = 2500    -- after a clip play: let hardware quiesce
local LONG_SETTLE_MS = 3500    -- loop / long-clip tests
local RENDER_MIN_MS  = 100

-- Result codes
local R_PASS, R_FAIL, R_SKIP = "PASS", "FAIL", "SKIP"

-- ── Finish-event capture ─────────────────────────────────────────────
-- The engine delivers sound finishes asynchronously via the global
-- on_sound_end(alias, reason). Async tests snapshot finish.seq at arm and
-- poll for an increment, then inspect the captured alias/reason.
local finish = { seq = 0, alias = nil, reason = nil, lost = 0 }

function on_sound_end(alias, reason)
    finish.seq    = finish.seq + 1
    finish.alias  = alias
    finish.reason = reason
    print(fmt("audio on_sound_end: alias=%s reason=%s",
              tostring(alias), reason_name(reason)))
end

function on_sound_lost(count)
    finish.lost = finish.lost + count
    print(fmt("audio on_sound_lost: count=%d (session total=%d)",
              count, finish.lost))
end

-- ── Test registry (same shape as led_test / servo_test) ──────────────
local TESTS = {}

local function reg_meta(group, name, action)
    TESTS[#TESTS + 1] = { group = group, name = name, kind = "meta", action = action }
end
local function reg_sync(group, name, fn)
    TESTS[#TESTS + 1] = { group = group, name = name, sync = fn }
end
local function reg_async(group, name, arm, step)
    TESTS[#TESTS + 1] = { group = group, name = name,
                          async = { arm = arm, step = step } }
end

local function expect(cond, ok_msg, fail_msg)
    if cond then return true, ok_msg end
    return false, fail_msg
end

-- ── Meta rows ────────────────────────────────────────────────────────
reg_meta("runner", "RUN SUITE (all tests)", "suite")
reg_meta("runner", "Reset results",         "reset")

-- ── Group A0: Play-all jukebox (async / FSM) ─────────────────────────
-- Plays EVERY file on the card, one at a time, each to its natural end.
-- For each clip: play it, then wait for its on_sound_end COMPLETED before
-- starting the next (CLIP_MAX_MS is only a safety ceiling). This is the
-- "let me hear them all" mode and the end-to-end decode proof: a missing /
-- corrupt / unsupported file shows up as play()=false, an ERROR reason, or
-- a timeout, and is named in the result. LEFT aborts mid-playlist.
reg_async("playall", "play EVERY file to EOF (audible jukebox)",
    function()
        Speaker_stop_all()
        return { i = 0, done_n = 0, fail = nil, phase = "next",
                 alias = nil, base = 0, t_end = 0,
                 err0 = Speaker_stats().error_count }
    end,
    function(st, _dt)
        if st.phase == "next" then
            st.i = st.i + 1
            if st.i > #FULL_PLAYLIST then
                local err  = Speaker_stats().error_count - st.err0
                local pass = (st.done_n == #FULL_PLAYLIST and err == 0)
                return true, pass,
                    fmt("played %d/%d to EOF err=%d%s",
                        st.done_n, #FULL_PLAYLIST, err,
                        st.fail and (" first_fail=" .. st.fail) or "")
            end
            st.alias = FULL_PLAYLIST[st.i]
            st.base  = finish.seq
            if not Speaker_play(st.alias) then
                st.fail  = st.fail or (st.alias .. ":play=false")
                st.phase = "next"                 -- skip, keep going
                return false
            end
            st.t_end = clock_ms() + CLIP_MAX_MS
            st.phase = "await"
            print(fmt("audio playall: [%d/%d] %s ...",
                      st.i, #FULL_PLAYLIST, st.alias))
            return false
        end
        -- phase "await": let THIS clip run to its natural finish
        if finish.seq > st.base then
            if finish.alias == st.alias
               and finish.reason == Speaker.REASON_COMPLETED then
                st.done_n = st.done_n + 1
            else
                st.fail = st.fail
                    or (st.alias .. ":" .. reason_name(finish.reason))
            end
            st.phase = "next"
            return false
        end
        if clock_ms() >= st.t_end then
            st.fail = st.fail or (st.alias .. ":timeout")
            Speaker_stop(st.alias)
            st.phase = "next"
            return false
        end
        return false
    end)
TESTS[#TESTS].settle_ms = PLAY_SETTLE_MS

-- ── Group A: Probe ───────────────────────────────────────────────────
reg_sync("probe", "get_volume in 0..100", function()
    local v = Speaker_get_volume()
    return expect(type(v) == "number" and v >= 0 and v <= 100,
                  fmt("volume=%s", tostring(v)),
                  fmt("expected 0..100, got %s", tostring(v)))
end)

reg_sync("probe", "is_busy returns boolean", function()
    local b = Speaker_is_busy()
    return expect(type(b) == "boolean",
                  fmt("is_busy=%s", tostring(b)),
                  "is_busy must return a boolean")
end)

reg_sync("probe", "stats has expected fields", function()
    local s = Speaker_stats()
    local ok = type(s) == "table"
        and s.played_total    ~= nil and s.finish_dropped ~= nil
        and s.error_count     ~= nil and s.cooldown_reject ~= nil
    return expect(ok, "all counter fields present",
                  "stats() table missing expected fields")
end)

-- ── Group B: Boundary / validation ───────────────────────────────────
reg_sync("boundary", "play unknown alias -> false", function()
    return expect(not Speaker_play("does_not_exist"),
                  "false as expected",
                  "unknown alias should return false")
end)

reg_sync("boundary", "play non-string -> false", function()
    return expect(not Speaker_play(42),
                  "false as expected",
                  "numeric arg is not the contract")
end)

reg_sync("boundary", "stop unknown alias -> false", function()
    return expect(not Speaker_stop("does_not_exist"),
                  "false as expected",
                  "stop of unknown alias should be false")
end)

reg_sync("boundary", "stop when idle -> false", function()
    Speaker_stop_all()
    return expect(not Speaker_stop(A_CLIP),
                  "false as expected",
                  "stop of non-current alias should be false")
end)

reg_sync("boundary", "is_playing unknown alias -> false", function()
    return expect(not Speaker_is_playing("nope"),
                  "false as expected",
                  "is_playing of unknown alias should be false")
end)

reg_sync("boundary", "set_volume > 100 clamps to 100", function()
    Speaker_set_volume(150)
    local v = Speaker_get_volume()
    Speaker_set_volume(70)              -- restore audible baseline
    return expect(v == 100, fmt("clamped to %d", v),
                  fmt("expected 100, got %s", tostring(v)))
end)

reg_sync("boundary", "set_volume < 0 clamps to 0", function()
    Speaker_set_volume(-25)
    local v = Speaker_get_volume()
    Speaker_set_volume(70)              -- restore audible baseline
    return expect(v == 0, fmt("clamped to %d", v),
                  fmt("expected 0, got %s", tostring(v)))
end)

reg_sync("boundary", "set_volume non-number no-ops", function()
    Speaker_set_volume(60)
    local before = Speaker_get_volume()
    Speaker_set_volume("loud")         -- silent no-op
    local after = Speaker_get_volume()
    Speaker_set_volume(70)             -- restore
    return expect(after == before,
                  fmt("unchanged at %d", after),
                  fmt("non-number changed volume %d -> %d", before, after))
end)

-- ── Group C: Volume round-trip ───────────────────────────────────────
reg_sync("volume", "set_volume(50) reflected by get_volume", function()
    Speaker_set_volume(50)
    local v = Speaker_get_volume()
    Speaker_set_volume(70)             -- restore audible baseline
    return expect(v == 50,
                  fmt("get_volume=%d after set(50)", v),
                  fmt("expected 50, got %s", tostring(v)))
end)

-- ── Group D: Playback (async, finish-driven) ─────────────────────────
-- A short clip must play to natural EOF and surface COMPLETED. Also
-- checks is_playing() is true immediately after play (synchronous state).
reg_async("play", "clip -> COMPLETED (natural EOF)",
    function()
        Speaker_stop_all()
        local base    = finish.seq
        local ok      = Speaker_play(A_CLIP)
        local playing = Speaker_is_playing(A_CLIP)
        return { base = base, ok = ok, playing = playing,
                 t_end = clock_ms() + 6000 }
    end,
    function(st, _dt)
        if not st.ok then
            return true, false,
                "play('clip') false (bridge unwired? asset missing?)"
        end
        if finish.seq > st.base then
            local pass = (finish.alias == A_CLIP
                          and finish.reason == Speaker.REASON_COMPLETED)
            return true, pass,
                fmt("is_playing@arm=%s finish=%s/%s (want clip/COMPLETED)",
                    tostring(st.playing), tostring(finish.alias),
                    reason_name(finish.reason))
        end
        if clock_ms() >= st.t_end then
            return true, false, "no on_sound_end within 6 s"
        end
        return false
    end)
TESTS[#TESTS].settle_ms = PLAY_SETTLE_MS

-- Explicit stop of the current play -> STOPPED, and is_playing clears.
reg_async("play", "stop(long) -> STOPPED",
    function()
        Speaker_stop_all()
        local ok = Speaker_play(A_LONG)
        return { ok = ok, phase = "play", t0 = clock_ms(), base = finish.seq }
    end,
    function(st, _dt)
        if not st.ok then return true, false, "play('long') false" end
        if st.phase == "play" then
            if clock_ms() - st.t0 < 400 then return false end
            if not Speaker_is_playing(A_LONG) then
                return true, false, "long not playing 400 ms after play"
            end
            st.base   = finish.seq
            Speaker_stop(A_LONG)
            st.phase  = "await"
            st.t_stop = clock_ms()
            return false
        end
        if finish.seq > st.base then
            local pass = (finish.alias == A_LONG
                          and finish.reason == Speaker.REASON_STOPPED
                          and not Speaker_is_playing(A_LONG))
            return true, pass,
                fmt("finish=%s/%s is_playing=%s",
                    tostring(finish.alias), reason_name(finish.reason),
                    tostring(Speaker_is_playing(A_LONG)))
        end
        if clock_ms() - st.t_stop >= 2000 then
            return true, false, "no STOPPED within 2 s of stop()"
        end
        return false
    end)
TESTS[#TESTS].settle_ms = PLAY_SETTLE_MS

-- Overlapping play preempts the current one -> PREEMPTED for the old alias.
reg_async("play", "play(clip) preempts long -> PREEMPTED",
    function()
        Speaker_stop_all()
        local ok1 = Speaker_play(A_LONG)
        return { ok1 = ok1, phase = "settle", t0 = clock_ms() }
    end,
    function(st, _dt)
        if not st.ok1 then return true, false, "play('long') false" end
        if st.phase == "settle" then
            -- wait past the cooldown window before the second dispatch
            if clock_ms() - st.t0 < (COOLDOWN_MS + 120) then return false end
            if not Speaker_is_playing(A_LONG) then
                return true, false, "long not playing before preempt"
            end
            st.base      = finish.seq
            st.ok2       = Speaker_play(A_CLIP)
            st.phase     = "await"
            st.t_preempt = clock_ms()
            return false
        end
        if not st.ok2 then
            return true, false, "play('clip') false (cooldown? bridge?)"
        end
        if finish.seq > st.base then
            local pass = (finish.alias == A_LONG
                          and finish.reason == Speaker.REASON_PREEMPTED)
            return true, pass,
                fmt("finish=%s/%s (want long/PREEMPTED) clip_playing=%s",
                    tostring(finish.alias), reason_name(finish.reason),
                    tostring(Speaker_is_playing(A_CLIP)))
        end
        if clock_ms() - st.t_preempt >= 2000 then
            return true, false, "no PREEMPTED within 2 s"
        end
        return false
    end)
TESTS[#TESTS].settle_ms = PLAY_SETTLE_MS

-- A loop-flagged alias re-issues on natural EOF: it must NOT surface
-- COMPLETED to the game, and must still be playing after one clip length.
reg_async("play", "loopclip re-issues (no COMPLETED, still playing)",
    function()
        Speaker_stop_all()
        local ok = Speaker_play(A_LOOP)
        return { ok = ok, base = finish.seq, t_end = clock_ms() + 3000 }
    end,
    function(st, _dt)
        if not st.ok then return true, false, "play('loopclip') false" end
        if finish.seq > st.base
           and finish.alias == A_LOOP
           and finish.reason == Speaker.REASON_COMPLETED then
            return true, false,
                "loop surfaced COMPLETED (should re-issue silently)"
        end
        if clock_ms() < st.t_end then return false end
        local still = Speaker_is_playing(A_LOOP)
        Speaker_stop(A_LOOP)
        return true, still,
            fmt("after 3 s is_playing=%s (%s)", tostring(still),
                still and "re-issued OK" or "stopped early - FAIL")
    end)
TESTS[#TESTS].settle_ms = LONG_SETTLE_MS

-- ── Group D2: Sweep the real playlist (async / FSM) ──────────────────
-- Walk every clip in PLAYLIST: play it, give the decoder a beat to open
-- the SD file + start, then assert is_playing(). A "File not found" or a
-- bad/unsupported asset surfaces as is_playing=false within this window.
-- This is the multi-file path/asset-resolution check (the exact failure
-- mode seen when assets/audio/ was missing on the card).
local SWEEP_OPEN_MS = 300
reg_async("sweep", "every clip resolves + decodes",
    function()
        Speaker_stop_all()
        return { i = 0, opened = 0, bad = nil, phase = "next", t = 0,
                 alias = nil, ok = false,
                 err0 = Speaker_stats().error_count }
    end,
    function(st, _dt)
        if st.phase == "next" then
            st.i = st.i + 1
            if st.i > #PLAYLIST then
                Speaker_stop_all()
                local err  = Speaker_stats().error_count - st.err0
                local pass = (st.opened == #PLAYLIST)
                return true, pass,
                    fmt("opened %d/%d err_delta=%d%s",
                        st.opened, #PLAYLIST, err,
                        st.bad and (" first_bad=" .. st.bad) or "")
            end
            st.alias = PLAYLIST[st.i]
            st.ok    = Speaker_play(st.alias)
            st.t     = clock_ms()
            st.phase = "check"
            return false
        end
        -- phase "check": let the decoder open + start (or error) first
        if clock_ms() - st.t < SWEEP_OPEN_MS then return false end
        if st.ok and Speaker_is_playing(st.alias) then
            st.opened = st.opened + 1
        else
            st.bad = st.bad or st.alias
        end
        Speaker_stop(st.alias)
        st.phase = "next"
        return false
    end)
TESTS[#TESTS].settle_ms = PLAY_SETTLE_MS

-- Distinct-file preempt storm: cycle PLAYLIST firing one play per tick for
-- 2 s. The 80 ms cooldown paces acceptance; each accepted play opens a
-- DIFFERENT clip that preempts the previous, churning decoder setup/teardown
-- across the whole set. Pass = pipeline survives + plays were accepted +
-- no decode/IO error (every distinct asset resolves).
reg_async("sweep", "distinct-file preempt storm (2s)",
    function()
        Speaker_stop_all()
        local s = Speaker_stats()
        return { played0 = s.played_total, err0 = s.error_count,
                 i = 0, t_end = clock_ms() + 2000 }
    end,
    function(st, _dt)
        if clock_ms() < st.t_end then
            st.i = (st.i % #PLAYLIST) + 1
            Speaker_play(PLAYLIST[st.i])   -- cooldown paces; distinct each time
            return false
        end
        Speaker_stop_all()
        local s      = Speaker_stats()
        local played = s.played_total - st.played0
        local err    = s.error_count  - st.err0
        return true, (played >= 6 and err == 0),
            fmt("accepted=%d err_delta=%d (distinct-file preempts)",
                played, err)
    end)
TESTS[#TESTS].settle_ms = PLAY_SETTLE_MS

-- ── Group E: Stress (async / FSM) ────────────────────────────────────
-- Cooldown flood: hammer play() 8x/tick for 2 s. The 80 ms engine-layer
-- cooldown must reject the bulk (cooldown_reject grows). Pass criteria:
--   * cooldown_reject delta > 0 (gate engages)
--   * no Lua error / crash; finish ring drop reported (informational)
reg_async("stress", "cooldown throttle (rapid play, 2s)",
    function()
        Speaker_stop_all()
        local s = Speaker_stats()
        return { rej0 = s.cooldown_reject, drop0 = s.finish_dropped,
                 err0 = s.error_count, t_end = clock_ms() + 2000, tries = 0 }
    end,
    function(st, _dt)
        if clock_ms() < st.t_end then
            for _ = 1, 8 do
                Speaker_play(A_SFX)
                st.tries = st.tries + 1
            end
            return false
        end
        Speaker_stop_all()
        local s    = Speaker_stats()
        local rej  = s.cooldown_reject - st.rej0
        local drop = s.finish_dropped  - st.drop0
        local err  = s.error_count     - st.err0
        return true, (rej > 0),
            fmt("tries=%d rejected=%d drop=%d err=%d (gate %s)",
                st.tries, rej, drop, err,
                rej > 0 and "active" or "NOT engaging")
    end)
TESTS[#TESTS].settle_ms = PLAY_SETTLE_MS

-- stop_all must drive the pipeline to silence.
reg_async("stress", "stop_all silences pipeline",
    function()
        Speaker_stop_all()
        local ok = Speaker_play(A_LONG)
        return { ok = ok, phase = "play", t0 = clock_ms() }
    end,
    function(st, _dt)
        if not st.ok then return true, false, "play('long') false" end
        if st.phase == "play" then
            if clock_ms() - st.t0 < 400 then return false end
            Speaker_stop_all()
            st.phase  = "settle"
            st.t_stop = clock_ms()
            return false
        end
        -- allow the GMF pipeline to wind down before sampling is_busy
        if clock_ms() - st.t_stop < 800 then return false end
        local busy = Speaker_is_busy()
        return true, (not busy),
            fmt("is_busy 800 ms after stop_all = %s", tostring(busy))
    end)
TESTS[#TESTS].settle_ms = PLAY_SETTLE_MS

-- ── Group F: Diagnostics ─────────────────────────────────────────────
-- Always-PASS. Value is the printed output; auto-DIAG names the failing
-- path so QA does not interpret raw counters.
reg_sync("diag", "stats dump + DIAG hints", function()
    local s = Speaker_stats()
    print(fmt(
        "audio stats: played=%d fin_drop=%d err=%d cooldown_rej=%d aband=%d/%d lost=%d",
        s.played_total, s.finish_dropped, s.error_count, s.cooldown_reject,
        s.speaker_abandoned_current, s.speaker_abandoned_peak, finish.lost))

    if s.played_total == 0 then
        print("audio DIAG: played=0 -> Speaker.play never accepted "
              .. "(engine_level<6? Speaker==nil? bridge unwired -> "
              .. "request_play returns 0?)")
    end
    if s.error_count > 0 then
        print("audio DIAG: error_count>0 -> decode/IO errors "
              .. "(missing/corrupt asset or unsupported format)")
    end
    if s.finish_dropped > 0 then
        print("audio DIAG: finish_dropped>0 -> finish ring overflow "
              .. "(events produced faster than engine_task drains)")
    end

    return true, fmt("played=%d err=%d cooldown_rej=%d drop=%d",
                     s.played_total, s.error_count,
                     s.cooldown_reject, s.finish_dropped)
end)

-- Final cleanup: silence + exit. Exit drives back's GameDispatchRaw
-- teardown; session end restores the T1 volume snapshot.
reg_sync("session", "Engine.exit (stop_all + restore)", function()
    Speaker_stop_all()
    Engine.exit("audio_done")
    return true, "exit posted; session-end restores T1 volume"
end)

-- ── Runner state (mirrors led_test / servo_test layout) ──────────────
local N_TESTS      = #TESTS
local cursor       = 1
local mode         = "single"
local in_suite     = false
local active       = nil
local async_st     = nil
local settle_until = 0

local results = {}
local total_pass, total_fail, total_skip = 0, 0, 0

local hud_dirty    = true
local hud_last_ms  = 0
local hud_buf      = {}
local hud_last_str = ""

local function dirty() hud_dirty = true end

local function record(idx, status, msg)
    if results[idx] then
        if results[idx].status == R_PASS then total_pass = total_pass - 1
        elseif results[idx].status == R_FAIL then total_fail = total_fail - 1
        elseif results[idx].status == R_SKIP then total_skip = total_skip - 1
        end
    end
    results[idx] = { status = status, msg = msg, t_ms = clock_ms() }
    if status == R_PASS then total_pass = total_pass + 1
    elseif status == R_FAIL then total_fail = total_fail + 1
    elseif status == R_SKIP then total_skip = total_skip + 1
    end
end

local meta_dispatch  -- forward decl

local function log_begin(idx, t)
    print(fmt("audio [%02d/%02d] BEGIN  %-9s :: %s",
              idx, N_TESTS, t.group, t.name))
end
local function log_end(idx, t, status, msg)
    if msg == nil or msg == "" then msg = "(no detail)" end
    print(fmt("audio [%02d/%02d] %-4s   %-9s :: %s :: %s",
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
        if not ok then
            pass, msg = false, "lua error: " .. tostring(a)
        else
            pass, msg = a, b or ""
        end
        local status = pass and R_PASS or R_FAIL
        record(idx, status, msg)
        log_end(idx, t, status, msg)
        dirty()
        return "sync_done"
    end

    -- async: arm under pcall so a constructor crash cannot kill the runner.
    local ok, st = pcall(t.async.arm)
    if not ok then
        local msg = "arm error: " .. tostring(st)
        record(idx, R_FAIL, msg)
        log_end(idx, t, R_FAIL, msg)
        dirty()
        return "sync_done"
    end
    active   = idx
    async_st = st
    mode     = "running_async"
    dirty()
    return "async_armed"
end

local function step_async()
    if not active then return end
    local t = TESTS[active]
    local done, ok, msg = t.async.step(async_st, 0)
    if done then
        local status = ok and R_PASS or R_FAIL
        record(active, status, msg or "")
        log_end(active, t, status, msg or "")
        active, async_st = nil, nil
        mode = "single"
        dirty()
    end
end

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
        print("audio ============================================")
        print(fmt("audio SUITE END :: PASS=%d  FAIL=%d  SKIP=%d  (of %d total)",
                  total_pass, total_fail, total_skip,
                  N_TESTS - (FIRST_TEST_IDX - 1)))
        print("audio ============================================")
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
    Speaker_stop_all()
    print("audio ============================================")
    print(fmt("audio SUITE BEGIN :: %d tests queued",
              N_TESTS - (FIRST_TEST_IDX - 1)))
    print("audio ============================================")
    suite_step()
end

local function reset_results()
    total_pass, total_fail, total_skip = 0, 0, 0
    for k in pairs(results) do results[k] = nil end
    print("audio: results reset")
    dirty()
end

meta_dispatch = function(action)
    if     action == "suite" then suite_start()
    elseif action == "reset" then reset_results()
    end
end

-- ── HUD ──────────────────────────────────────────────────────────────
-- The LCD label uses the default (proportional) font with no width set, so we
-- structure the panel ourselves: a fixed-width rule defines the block, every
-- line left-aligns to it, and indentation gives the hierarchy. Each row also
-- carries a plain-language group label + "what it tests" line so a non-engineer
-- reading the screen knows which feature is under test, not just its code name.
local ssub    = string.sub
local PANEL_W = 40
local RULE    = string.rep("-", PANEL_W)

-- group code -> { readable title, one-line purpose }
local GROUP_INFO = {
    runner   = { label = "SUITE CONTROL", what = "run all tests / reset results" },
    playall  = { label = "JUKEBOX",       what = "play every file to its end" },
    probe    = { label = "STATE PROBE",   what = "read volume / busy / stats" },
    boundary = { label = "VALIDATION",    what = "reject bad input safely" },
    volume   = { label = "VOLUME",        what = "set / get round-trip" },
    play     = { label = "PLAYBACK",      what = "play / stop / preempt / loop" },
    sweep    = { label = "SWEEP",         what = "every clip resolves + decodes" },
    stress   = { label = "STRESS",        what = "cooldown gate / stop_all" },
    diag     = { label = "DIAGNOSTICS",   what = "stats dump + hints" },
    session  = { label = "CLEANUP",       what = "stop all + exit session" },
}
local GROUP_FALLBACK = { label = "TEST", what = "" }
local function group_info(g) return GROUP_INFO[g] or GROUP_FALLBACK end

-- Keep a line inside the panel so a long message never overflows the screen.
local function clip_w(s)
    if #s > PANEL_W then return ssub(s, 1, PANEL_W - 1) .. "~" end
    return s
end

local function format_hud()
    local n  = 0
    local t  = TESTS[cursor]
    local gi = group_info(t.group)

    -- Header: position, then run mode + pass/fail/skip tally.
    n = n + 1; hud_buf[n] = fmt("AUDIO TEST            %02d/%02d", cursor, N_TESTS)
    n = n + 1; hud_buf[n] = fmt("mode %-7s  PASS %d  FAIL %d  SKIP %d",
        mode, total_pass, total_fail, total_skip)
    n = n + 1; hud_buf[n] = RULE

    -- Current row: feature group, what it exercises, the specific case.
    n = n + 1; hud_buf[n] = clip_w("NOW  > " .. gi.label)
    if gi.what ~= "" then
        n = n + 1; hud_buf[n] = clip_w("     " .. gi.what)
    end
    n = n + 1; hud_buf[n] = clip_w("     case: " .. t.name)
    n = n + 1; hud_buf[n] = RULE

    -- Result of the highlighted row.
    local r = results[cursor]
    if r then
        n = n + 1; hud_buf[n] = fmt("RESULT  %s", r.status)
        if r.msg and r.msg ~= "" then
            n = n + 1; hud_buf[n] = clip_w("        " .. r.msg)
        end
    else
        n = n + 1; hud_buf[n] = "RESULT  (not run)"
    end
    n = n + 1; hud_buf[n] = RULE

    -- Navigation context (readable group label, not the code name).
    if cursor > 1 then
        local p = TESTS[cursor - 1]
        n = n + 1; hud_buf[n] =
            clip_w("prev <  " .. group_info(p.group).label .. " / " .. p.name)
    end
    if cursor < N_TESTS then
        local nx = TESTS[cursor + 1]
        n = n + 1; hud_buf[n] =
            clip_w("next >  " .. group_info(nx.group).label .. " / " .. nx.name)
    end

    -- Engine-side health line + last finish event.
    local s = Speaker_stats()
    n = n + 1; hud_buf[n] = clip_w(fmt("bus  play=%d err=%d rej=%d drop=%d",
        s.played_total, s.error_count, s.cooldown_reject, s.finish_dropped))
    n = n + 1; hud_buf[n] = clip_w(fmt("last finish %s / %s",
        tostring(finish.alias), reason_name(finish.reason)))

    -- Footer: controls / suite state.
    n = n + 1; hud_buf[n] = in_suite
        and "SUITE running   LEFT = abort"
        or  "ENTER=fire   LEFT/RIGHT=nav   row1=suite"

    for i = n + 1, #hud_buf do hud_buf[i] = nil end
    return concat(hud_buf, "\n", 1, n)
end

local function render_if_dirty()
    if not hud_dirty then return end
    local now = clock_ms()
    if (now - hud_last_ms) < RENDER_MIN_MS then return end
    local s = format_hud()
    if s ~= hud_last_str then
        HUD_set_label(s)
        hud_last_str = s
    end
    hud_last_ms = now
    hud_dirty = false
end

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    local ev = (Engine and Engine.version and Engine.version()) or "?"
    print(fmt("audio: game_start engine=%s tests=%d sounds=%d",
              tostring(ev), N_TESTS, N_SOUNDS))
    Speaker_stop_all()
    Speaker_set_volume(70)   -- audible, known baseline for play tests
    dirty()
end

function on_input(action, phase)
    if phase ~= Input.PRESS then return end

    if action == "prev" then
        if mode ~= "single" then
            if active then
                local t = TESTS[active]
                record(active, R_SKIP, "aborted by user")
                log_end(active, t, R_SKIP, "aborted by user")
                active, async_st = nil, nil
                Speaker_stop_all()
            end
            in_suite = false
            mode = "single"
            print("audio: aborted to SINGLE")
            dirty()
            return
        end
        cursor = (cursor > 1) and (cursor - 1) or N_TESTS
        dirty()
        return
    end

    if action == "next" then
        if mode == "running_async" then return end
        cursor = (cursor < N_TESTS) and (cursor + 1) or 1
        dirty()
        return
    end

    if action == "fire" then
        if mode == "running_async" or mode == "between" then return end
        fire(cursor)
        return
    end
end

function on_tick(_dt)
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

    elseif mode == "running_async" then
        step_async()
        if not active and in_suite then
            local finished_settle = TESTS[cursor].settle_ms
            cursor = cursor + 1
            suite_step(finished_settle)
        end
    end

    render_if_dirty()
end

function game_end()
    Speaker_stop_all()
    print("audio ============================================")
    print(fmt("audio SUMMARY :: PASS=%d  FAIL=%d  SKIP=%d  total=%d",
              total_pass, total_fail, total_skip, N_TESTS))
    print("audio ============================================")
    for i, t in ipairs(TESTS) do
        if t.kind ~= "meta" then
            local r = results[i]
            if r then
                print(fmt("audio [%02d/%02d] %-4s   %-9s :: %s :: %s",
                          i, N_TESTS, r.status, t.group, t.name, r.msg))
            else
                print(fmt("audio [%02d/%02d] ----   %-9s :: %s :: not run",
                          i, N_TESTS, t.group, t.name))
            end
        end
    end
    print("audio ============================================")
    local s = Speaker_stats()
    print(fmt("audio FINAL stats played=%d err=%d cooldown_rej=%d drop=%d lost=%d",
        s.played_total, s.error_count, s.cooldown_reject,
        s.finish_dropped, finish.lost))
end
