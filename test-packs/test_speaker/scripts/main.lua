-- test_speaker: stress + behaviour suite for the Speaker API.
--
-- Runner: libs/testkit (RUN SUITE + Reset rows, then the tests below).
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
--   * Finish events arrive via on_sound_end(alias, reason) at the start of
--     the next frame with the right reason: natural EOF -> COMPLETED,
--     Speaker.stop -> STOPPED, overlap -> PREEMPTED. A loop-flagged alias
--     restarts silently (no COMPLETED); each restart counts as a play for the
--     cooldown.
--   * Cooldown gate rejects a tight play() flood (cooldown_reject grows).
--
-- On a robot this suite is also the end-to-end audio check: if Speaker.play()
-- keeps returning false or no finish event ever fires, sound does not reach
-- the speaker at all. The DIAG test names that failure mode.
--
-- Async tests own their timing and snapshot Speaker.stats() at arm and at
-- validate; libs/testkit runs every test under pcall.

-- ── Localize hot upvalues ────────────────────────────────────────────
local Speaker_play       = Speaker.play
local Speaker_stop       = Speaker.stop
local Speaker_stop_all   = Speaker.stop_all
local Speaker_is_playing = Speaker.is_playing
local Speaker_is_busy    = Speaker.is_busy
local Speaker_set_volume = Speaker.set_volume
local Speaker_get_volume = Speaker.get_volume
local Speaker_stats      = Speaker.stats
local fmt    = string.format

local clock_ms = Timer.millis

-- ── Constants ────────────────────────────────────────────────────────
-- Manifest aliases (manifest.json -> audio.sounds).
-- Behavioural aliases, mapped to the real assets on the card, sized per test:
local A_SFX   = "sfx"        -- short WAV  (assets/audio/output.wav,      12 KB)
local A_CLIP  = "clip"       -- shortest   (assets/audio/en_home.mp3,     11 KB)
local A_LONG  = "long"       -- longest    (assets/audio/en_greeting.mp3, 92 KB)
local A_LOOP  = "loopclip"   -- loop=true  (assets/audio/en_home.mp3, short -> re-issues)

-- Stress playlist: the spread of real production clips on the card (all mp3,
-- 11-92 KB) used by the "sweep" group to exercise the robot's audio pipeline, SD
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

-- Mirror of sound_cooldown_ms in contract/constraints.json (150 ms).
local COOLDOWN_MS = 150

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


-- ── Finish-event capture ─────────────────────────────────────────────
-- The engine delivers sound finishes asynchronously via the global
-- on_sound_end(alias, reason). Async tests snapshot finish.seq at arm and
-- poll for an increment, then inspect the captured alias/reason.
local finish = { seq = 0, alias = nil, reason = nil, lost = 0 }

function on_sound_end(alias, reason)
    finish.seq    = finish.seq + 1
    finish.alias  = alias
    finish.reason = reason
    print(fmt("speaker on_sound_end: alias=%s reason=%s",
              tostring(alias), reason_name(reason)))
end

function on_sound_lost(count)
    finish.lost = finish.lost + count
    print(fmt("speaker on_sound_lost: count=%d (session total=%d)",
              count, finish.lost))
end

local tk = require("libs/testkit")

local S = tk.suite({
    tag = "speaker", title = "SPEAKER TEST",
    font = "fonts/nunito-regular.ttf", font_px = 14,
    settle_ms = SETTLE_MS,
    groups = {
        playall  = { label = "JUKEBOX",     what = "play every file to its end" },
        probe    = { label = "STATE PROBE", what = "read volume / busy / stats" },
        boundary = { label = "VALIDATION",  what = "reject bad input safely" },
        volume   = { label = "VOLUME",      what = "set / get round-trip" },
        play     = { label = "PLAYBACK",    what = "play / stop / preempt / loop" },
        sweep    = { label = "SWEEP",       what = "every clip resolves + decodes" },
        stress   = { label = "STRESS",      what = "cooldown gate / stop_all" },
        diag     = { label = "DIAGNOSTICS", what = "stats dump + hints" },
        session  = { label = "CLEANUP",     what = "stop all + exit session" },
    },
    status = function()
        local s = Speaker_stats()
        return fmt("bus  play=%d err=%d rej=%d drop=%d\nlast finish %s / %s",
            s.played_total, s.error_count, s.cooldown_reject, s.finish_dropped,
            tostring(finish.alias), reason_name(finish.reason))
    end,
    on_abort = function() Speaker_stop_all() end,
})

local function expect(cond, ok_msg, fail_msg)
    if cond then return true, ok_msg end
    return false, fail_msg
end

-- ── Group A0: Play-all jukebox (async / FSM) ─────────────────────────
-- Plays EVERY file on the card, one at a time, each to its natural end.
-- For each clip: play it, then wait for its on_sound_end COMPLETED before
-- starting the next (CLIP_MAX_MS is only a safety ceiling). This is the
-- "let me hear them all" mode and the end-to-end decode proof: a missing /
-- corrupt / unsupported file shows up as play()=false, an ERROR reason, or
-- a timeout, and is named in the result. LEFT aborts mid-playlist.
S:async("playall", "play EVERY file to EOF (audible jukebox)",
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
            print(fmt("speaker playall: [%d/%d] %s ...",
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
    end, { settle_ms = PLAY_SETTLE_MS })

-- ── Group A: Probe ───────────────────────────────────────────────────
S:sync("probe", "get_volume in 0..100", function()
    local v = Speaker_get_volume()
    return expect(type(v) == "number" and v >= 0 and v <= 100,
                  fmt("volume=%s", tostring(v)),
                  fmt("expected 0..100, got %s", tostring(v)))
end)

S:sync("probe", "is_busy returns boolean", function()
    local b = Speaker_is_busy()
    return expect(type(b) == "boolean",
                  fmt("is_busy=%s", tostring(b)),
                  "is_busy must return a boolean")
end)

S:sync("probe", "stats has expected fields", function()
    local s = Speaker_stats()
    local ok = type(s) == "table"
        and s.played_total    ~= nil and s.finish_dropped ~= nil
        and s.error_count     ~= nil and s.cooldown_reject ~= nil
    return expect(ok, "all counter fields present",
                  "stats() table missing expected fields")
end)

-- ── Group B: Boundary / validation ───────────────────────────────────
S:sync("boundary", "play unknown alias -> false", function()
    return expect(not Speaker_play("does_not_exist"),
                  "false as expected",
                  "unknown alias should return false")
end)

S:sync("boundary", "play non-string -> false", function()
    return expect(not Speaker_play(42),
                  "false as expected",
                  "numeric arg is not the contract")
end)

S:sync("boundary", "stop unknown alias -> false", function()
    return expect(not Speaker_stop("does_not_exist"),
                  "false as expected",
                  "stop of unknown alias should be false")
end)

S:sync("boundary", "stop when idle -> false", function()
    Speaker_stop_all()
    return expect(not Speaker_stop(A_CLIP),
                  "false as expected",
                  "stop of non-current alias should be false")
end)

S:sync("boundary", "is_playing unknown alias -> false", function()
    return expect(not Speaker_is_playing("nope"),
                  "false as expected",
                  "is_playing of unknown alias should be false")
end)

S:sync("boundary", "set_volume > 100 clamps to 100", function()
    Speaker_set_volume(150)
    local v = Speaker_get_volume()
    Speaker_set_volume(70)              -- restore audible baseline
    return expect(v == 100, fmt("clamped to %d", v),
                  fmt("expected 100, got %s", tostring(v)))
end)

S:sync("boundary", "set_volume < 0 clamps to 0", function()
    Speaker_set_volume(-25)
    local v = Speaker_get_volume()
    Speaker_set_volume(70)              -- restore audible baseline
    return expect(v == 0, fmt("clamped to %d", v),
                  fmt("expected 0, got %s", tostring(v)))
end)

S:sync("boundary", "set_volume non-number no-ops", function()
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
S:sync("volume", "set_volume(50) reflected by get_volume", function()
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
S:async("play", "clip -> COMPLETED (natural EOF)",
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
                "play('clip') false (asset missing? audio refused?)"
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
    end, { settle_ms = PLAY_SETTLE_MS })

-- Explicit stop of the current play -> STOPPED, and is_playing clears.
S:async("play", "stop(long) -> STOPPED",
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
    end, { settle_ms = PLAY_SETTLE_MS })

-- Overlapping play preempts the current one -> PREEMPTED for the old alias.
S:async("play", "play(clip) preempts long -> PREEMPTED",
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
            return true, false, "play('clip') false (cooldown? audio refused?)"
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
    end, { settle_ms = PLAY_SETTLE_MS })

-- A loop-flagged alias re-issues on natural EOF: it must NOT surface
-- COMPLETED to the game, and must still be playing after one clip length.
S:async("play", "loopclip re-issues (no COMPLETED, still playing)",
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
    end, { settle_ms = LONG_SETTLE_MS })

-- ── Group D2: Sweep the real playlist (async / FSM) ──────────────────
-- Walk every clip in PLAYLIST: play it, give the decoder a beat to open
-- the SD file + start, then assert is_playing(). A "File not found" or a
-- bad/unsupported asset surfaces as is_playing=false within this window.
-- This is the multi-file path/asset-resolution check (the exact failure
-- mode seen when assets/audio/ was missing on the card).
local SWEEP_OPEN_MS = 300
S:async("sweep", "every clip resolves + decodes",
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
    end, { settle_ms = PLAY_SETTLE_MS })

-- Distinct-file preempt storm: cycle PLAYLIST firing one play per tick for
-- 2 s. The 150 ms cooldown paces acceptance; each accepted play opens a
-- DIFFERENT clip that preempts the previous, churning decoder setup/teardown
-- across the whole set. Pass = pipeline survives + plays were accepted +
-- no decode/IO error (every distinct asset resolves).
S:async("sweep", "distinct-file preempt storm (2s)",
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
    end, { settle_ms = PLAY_SETTLE_MS })

-- ── Group E: Stress (async / FSM) ────────────────────────────────────
-- Cooldown flood: hammer play() 8x/tick for 2 s. The 150 ms engine-layer
-- cooldown must reject the bulk (cooldown_reject grows). Pass criteria:
--   * cooldown_reject delta > 0 (gate engages)
--   * no Lua error / crash; finish ring drop reported (informational)
S:async("stress", "cooldown throttle (rapid play, 2s)",
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
    end, { settle_ms = PLAY_SETTLE_MS })

-- stop_all must drive the pipeline to silence.
S:async("stress", "stop_all silences pipeline",
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
        -- let the audio pipeline wind down before sampling is_busy
        if clock_ms() - st.t_stop < 800 then return false end
        local busy = Speaker_is_busy()
        return true, (not busy),
            fmt("is_busy 800 ms after stop_all = %s", tostring(busy))
    end, { settle_ms = PLAY_SETTLE_MS })

-- ── Group F: Diagnostics ─────────────────────────────────────────────
-- Always-PASS. Value is the printed output; auto-DIAG names the failing
-- path so QA does not interpret raw counters.
S:sync("diag", "stats dump + DIAG hints", function()
    local s = Speaker_stats()
    print(fmt(
        "speaker stats: played=%d fin_drop=%d err=%d cooldown_rej=%d aband=%d/%d lost=%d",
        s.played_total, s.finish_dropped, s.error_count, s.cooldown_reject,
        s.speaker_abandoned_current, s.speaker_abandoned_peak, finish.lost))

    if s.played_total == 0 then
        print("speaker DIAG: played=0 -> Speaker.play never accepted "
              .. "(sound files missing, aliases not in manifest audio.sounds, "
              .. "or the robot refused every audio request)")
    end
    if s.error_count > 0 then
        print("speaker DIAG: error_count>0 -> decode/IO errors "
              .. "(missing/corrupt asset or unsupported format)")
    end
    if s.finish_dropped > 0 then
        print("speaker DIAG: finish_dropped>0 -> on_sound_end queue overflow "
              .. "(finishes produced faster than frames drain them; "
              .. "on_sound_lost reports it too)")
    end

    return true, fmt("played=%d err=%d cooldown_rej=%d drop=%d",
                     s.played_total, s.error_count,
                     s.cooldown_reject, s.finish_dropped)
end)

-- Final cleanup: silence + exit. The engine restores the user's volume
-- when the session ends.
S:sync("session", "Engine.exit (stop_all + restore)", function()
    Speaker_stop_all()
    Engine.exit("speaker_done")
    return true, "exit posted; session end restores the user's volume"
end, { manual = true })

-- ── Lua engine hooks ─────────────────────────────────────────────────
function game_start()
    print(fmt("speaker: sounds=%d", N_SOUNDS))
    Speaker_stop_all()
    Speaker_set_volume(70)   -- audible, known baseline for play tests
    S:start()
end

function on_input(action, phase, hold_ms)
    S:input(action, phase, hold_ms)
end

function on_tick(_dt)
    S:tick()
end

function game_end()
    Speaker_stop_all()
    local s = Speaker_stats()
    S:summary(fmt("stats played=%d err=%d cooldown_rej=%d drop=%d lost=%d",
        s.played_total, s.error_count, s.cooldown_reject,
        s.finish_dropped, finish.lost))
end
