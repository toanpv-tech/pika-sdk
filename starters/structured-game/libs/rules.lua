-- libs/rules.lua: game rules in plain Lua.
--
-- This file calls NO engine API (Sprite, Text, Shape, Anim, Speaker, Voice, Led,
-- Servo, Ranking, Engine, Input, Timer). Time arrives as the dt argument and
-- randomness comes from a seeded generator in the state, so the rules run and
-- can be tested on a PC under stock Lua 5.5.
--
-- Sample game "Star Catch": stars fall, the player runs left/right to catch
-- them (+1 point). Missing 3 stars or running out of time ends the round.

local Rules = {}

-- Constants ---------------------------------------------------------------
Rules.SCENE_TITLE = 1
Rules.SCENE_PLAY  = 2
Rules.SCENE_OVER  = 3

Rules.EV_START = 1      -- round started
Rules.EV_CATCH = 2      -- star caught
Rules.EV_MISS  = 3      -- star missed
Rules.EV_OVER  = 4      -- round over

Rules.FIELD_W    = 480
Rules.FIELD_H    = 320
Rules.PLAYER_W   = 40
Rules.PLAYER_H   = 16
Rules.PLAYER_Y   = 290
Rules.STAR_SIZE  = 16
Rules.MAX_STARS  = 5            -- main.lua creates this many star sprites
Rules.MAX_MISSES = 3
Rules.ROUND_MS   = 30000

local PLAYER_SPEED = 0.25       -- px per ms
local STAR_SPEED   = 0.10       -- px per ms, grows with the score
local SPAWN_MS     = 900

-- Deterministic generator (a fixed seed replays the same round in tests) ----
-- Park-Miller minimal standard, computed with Schrage's method so every
-- intermediate stays below 2^31: the robot's integers are 32-bit (LUA-INT32)
-- and a PC's are 64-bit, and both must produce the same sequence.
local RNG_MOD = 2147483647      -- 2^31 - 1, the largest 32-bit integer
local RNG_A   = 16807
local RNG_Q   = 127773          -- RNG_MOD // RNG_A
local RNG_R   = 2836            -- RNG_MOD %  RNG_A

local function rng_next(S)
  local hi, lo = S.rng // RNG_Q, S.rng % RNG_Q
  local t = RNG_A * lo - RNG_R * hi
  if t <= 0 then t = t + RNG_MOD end
  S.rng = t                       -- always 1 .. RNG_MOD - 1
  return t
end

local function rng_range(S, lo, hi)
  return lo + rng_next(S) % (hi - lo + 1)
end

-- Events --------------------------------------------------------------------
local function emit(S, ev)
  S.event_n = S.event_n + 1
  S.events[S.event_n] = ev
end

function Rules.clear_events(S)
  for i = 1, S.event_n do S.events[i] = nil end
  S.event_n = 0
end

-- State ---------------------------------------------------------------------
function Rules.new_state(seed)
  local S = {
    scene = Rules.SCENE_TITLE,
    rng = math.floor(seed or 1) % (RNG_MOD - 1) + 1,   -- 0 would stick at 0
    events = {}, event_n = 0,
    score = 0, best = 0, misses = 0,
    time_left = Rules.ROUND_MS,
    player_x = (Rules.FIELD_W - Rules.PLAYER_W) // 2,
    move_dir = 0,
    spawn_ms = 0,
    stars = {},
  }
  for i = 1, Rules.MAX_STARS do
    S.stars[i] = { alive = false, x = 0, y = 0 }
  end
  return S
end

function Rules.start_run(S)
  S.scene = Rules.SCENE_PLAY
  S.score, S.misses = 0, 0
  S.time_left = Rules.ROUND_MS
  S.player_x = (Rules.FIELD_W - Rules.PLAYER_W) // 2
  S.move_dir = 0
  S.spawn_ms = 0
  for i = 1, Rules.MAX_STARS do S.stars[i].alive = false end
  emit(S, Rules.EV_START)
end

-- dir: -1 left, 0 still, 1 right. main.lua sets it every frame from the buttons.
function Rules.set_move(S, dir)
  S.move_dir = dir
end

-- One rules step ------------------------------------------------------------
local function spawn_star(S)
  for i = 1, Rules.MAX_STARS do
    local st = S.stars[i]
    if not st.alive then
      st.alive = true
      st.x = rng_range(S, 0, Rules.FIELD_W - Rules.STAR_SIZE)
      st.y = -Rules.STAR_SIZE
      return
    end
  end
end

local function overlaps(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

local function end_run(S)
  S.scene = Rules.SCENE_OVER
  if S.score > S.best then S.best = S.score end
  emit(S, Rules.EV_OVER)
end

function Rules.step(S, dt)
  if S.scene ~= Rules.SCENE_PLAY then return end

  S.time_left = S.time_left - dt
  if S.time_left <= 0 then
    S.time_left = 0
    end_run(S)
    return
  end

  local px = S.player_x + S.move_dir * PLAYER_SPEED * dt
  if px < 0 then px = 0 end
  if px > Rules.FIELD_W - Rules.PLAYER_W then px = Rules.FIELD_W - Rules.PLAYER_W end
  S.player_x = px                 -- may be a float: main.lua floors it

  S.spawn_ms = S.spawn_ms - dt
  if S.spawn_ms <= 0 then
    S.spawn_ms = SPAWN_MS
    spawn_star(S)
  end

  local speed = STAR_SPEED + S.score * 0.004
  for i = 1, Rules.MAX_STARS do
    local st = S.stars[i]
    if st.alive then
      st.y = st.y + speed * dt
      if overlaps(st.x, st.y, Rules.STAR_SIZE, Rules.STAR_SIZE,
                  S.player_x, Rules.PLAYER_Y, Rules.PLAYER_W, Rules.PLAYER_H) then
        st.alive = false
        S.score = S.score + 1
        emit(S, Rules.EV_CATCH)
      elseif st.y > Rules.FIELD_H then
        st.alive = false
        S.misses = S.misses + 1
        emit(S, Rules.EV_MISS)
        if S.misses >= Rules.MAX_MISSES then
          end_run(S)
          return
        end
      end
    end
  end
end

return Rules
