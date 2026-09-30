-- Structured Pika game "Star Catch": skeleton for multi-scene games.
--
-- ARCHITECTURE (skill/game-architecture.md)
--   libs/rules.lua  game rules, plain Lua, no engine calls
--   this file       wiring: hooks, sprites, text, sound, ranking
--
-- BUDGET (skill/constraints.md)
--   Sprites  1 player + 5 stars (Sprite.solid, ~3 KB PSRAM)
--   Text     title + HUD + info line            = 3 of 8
--   Fonts    default font (ASCII strings)       = 0 of 4 faces
--   Anim     none
--
-- READ BOTTOM-UP: hooks are at the end of the file.
--   1 constants and strings   2 send-if-changed helpers   3 object pool
--   4 ranking                 5 render per scene          6 react to events
--   7 hooks

local Rules = require("libs/rules")

-- 1. Constants and strings ---------------------------------------------------
local LOGIC_DT  = 33      -- ms per rules step
local MAX_STEPS = 4       -- catch-up steps per frame at most
local DT_MAX    = 100     -- clamp a long stall
local RANK_TIMEOUT_MS = 6000

local COL_PLAYER = 0x07E0   -- RGB565 (Sprite.solid)
local COL_STAR   = 0xFFE0
local COL_TEXT   = 0xFFFFFF -- 0xRRGGBB (Text)
local COL_WARN   = 0xFF6060

-- UI strings in ASCII so the default font renders them. For accented or
-- non-Latin text ship a TTF (skill/recipes/localized-text.md).
local STR = {
  en = { title = "STAR CATCH", press = "Press ENTER to play", score = "Score",
         time = "Time", miss = "Miss", over = "GAME OVER", again = "Press ENTER to replay",
         rank = "Rank", loading = "Loading ranking..." },
  vi = { title = "HUNG SAO", press = "Nhan ENTER de choi", score = "Diem",
         time = "Gio", miss = "Truot", over = "HET GIO", again = "Nhan ENTER choi lai",
         rank = "Hang", loading = "Dang tai xep hang..." },
}
local T = STR.en

local S               -- game state (owned by Rules)
local view = {}       -- engine handles + last value sent to each

-- 2. Send-if-changed helpers (skill/performance.md section 1) -------------------
local function place(rec, x, y)
  if rec and rec.spr and (x ~= rec.x or y ~= rec.y) then
    rec.x, rec.y = x, y
    rec.spr:set_pos(x, y)
  end
end

local function show(rec, vis)
  if rec and rec.spr and vis ~= rec.vis then
    rec.vis = vis
    rec.spr:set_visible(vis)
  end
end

local function text_set(rec, str)
  if rec and rec.t and rec.s ~= str then
    rec.s = str
    rec.t:set(str)
  end
end

local function text_show(rec, vis)
  if rec and rec.t and rec.vis ~= vis then
    rec.vis = vis
    rec.t:show(vis)
  end
end

local function text_align(rec, where, dx, dy)
  if rec and rec.t and (rec.align ~= where or rec.dx ~= dx or rec.dy ~= dy) then
    rec.align, rec.dx, rec.dy = where, dx, dy
    rec.t:align(where, dx, dy)
  end
end

local function text_color(rec, col)
  if rec and rec.t and rec.col ~= col then
    rec.col = col
    rec.t:set_color(col)
  end
end

-- 3. Object pool ----------------------------------------------------------------
-- Creation order is draw order: sprites first, Text last so labels stay on top.
-- Sprites start hidden; they appear on their first set_pos or set_visible(true).
local function build_sprites()
  view.player = { spr = Sprite.solid(Rules.PLAYER_W, Rules.PLAYER_H, COL_PLAYER) }
  if not view.player.spr then print("main: player sprite failed") end
  view.stars = {}
  for i = 1, Rules.MAX_STARS do
    local spr, err = Sprite.solid(Rules.STAR_SIZE, Rules.STAR_SIZE, COL_STAR)
    if not spr then print("main: star sprite failed: " .. tostring(err)) end
    view.stars[i] = { spr = spr }
  end
end

local function build_texts()
  local function mk(x, y)
    local t, err = Text.new("", x, y)
    if not t then print("main: Text.new failed: " .. tostring(err)) end
    return { t = t }
  end
  view.title = mk(0, 0)
  view.hud   = mk(8, 8)
  view.info  = mk(0, 0)
end

local function destroy_all()
  local sprites = { view.player }
  for i = 1, #(view.stars or {}) do sprites[#sprites + 1] = view.stars[i] end
  for _, rec in ipairs(sprites) do
    if rec and rec.spr then rec.spr:destroy() end
  end
  for _, rec in ipairs({ view.title, view.hud, view.info }) do
    if rec and rec.t then rec.t:destroy() end
  end
  view = {}
end

-- 4. Ranking (skill/recipes/leaderboard.md) ------------------------------------------
local rank = { waiting = false, deadline = 0, result = nil }

local function finish_run()
  rank.result = nil
  rank.waiting = (Ranking.report({ score = S.score }) == true)
  rank.deadline = Timer.millis() + RANK_TIMEOUT_MS
end

local function poll_rank()
  if not rank.waiting then return end
  if Timer.millis() >= rank.deadline then rank.waiting = false; return end
  local r = Ranking.get_result()
  if type(r) == "table" then rank.result = r; rank.waiting = false end
end

local function discard_stale_rank()
  Ranking.get_result()              -- a late result of the previous round
  rank.waiting, rank.result = false, nil
end

-- 5. Render per scene -------------------------------------------------------------
local function hide_play()
  show(view.player, false)
  for i = 1, #view.stars do show(view.stars[i], false) end
end

local function render_title()
  hide_play()
  text_show(view.hud, false)
  text_set(view.title, T.title);  text_align(view.title, "center", 0, -30)
  text_color(view.title, COL_TEXT); text_show(view.title, true)
  text_set(view.info, T.press);   text_align(view.info, "center", 0, 20)
  text_color(view.info, COL_TEXT);  text_show(view.info, true)
end

local function render_play()
  text_show(view.title, false)
  text_show(view.info, false)

  place(view.player, math.floor(S.player_x), Rules.PLAYER_Y)
  show(view.player, true)
  for i = 1, Rules.MAX_STARS do
    local st, rec = S.stars[i], view.stars[i]
    if st.alive and st.y > -Rules.STAR_SIZE then
      place(rec, st.x, math.floor(st.y))
      show(rec, true)
    else
      show(rec, false)
    end
  end

  -- Build the HUD string only when a shown value changes (performance.md section 3).
  local secs = math.ceil(S.time_left / 1000)
  if view.hud_score ~= S.score or view.hud_secs ~= secs or view.hud_miss ~= S.misses then
    view.hud_score, view.hud_secs, view.hud_miss = S.score, secs, S.misses
    text_set(view.hud, T.score .. ": " .. S.score .. "   " .. T.time .. ": " .. secs ..
                       "s   " .. T.miss .. ": " .. S.misses .. "/" .. Rules.MAX_MISSES)
    text_color(view.hud, secs <= 5 and COL_WARN or COL_TEXT)
  end
  text_align(view.hud, "top_left", 8, 8)
  text_show(view.hud, true)
end

local function render_over()
  hide_play()
  text_show(view.hud, false)
  text_set(view.title, T.over .. "  " .. T.score .. ": " .. S.score)
  text_align(view.title, "center", 0, -30)
  text_show(view.title, true)

  local mine = rank.result and type(rank.result.my_rank) == "table" and rank.result.my_rank.rank
  local line
  if mine then
    line = T.rank .. " #" .. tostring(mine) .. "\n" .. T.again
  elseif rank.waiting then
    line = T.loading
  else
    line = T.again
  end
  text_set(view.info, line)
  text_align(view.info, "center", 0, 20)
  text_show(view.info, true)
end

local function render()
  if S.scene == Rules.SCENE_TITLE then render_title()
  elseif S.scene == Rules.SCENE_PLAY then render_play()
  else render_over() end
end

-- 6. React to events: the ONLY place that plays sounds / drives LED or servos -----
-- One channel, 150 ms cooldown: two sounds in the same step means the second is
-- refused. The miss that ends the round stays silent so "over" is heard.
local function react(ev)
  if ev == Rules.EV_START then Speaker.play("start")
  elseif ev == Rules.EV_CATCH then Speaker.play("coin")
  elseif ev == Rules.EV_MISS then
    if S.scene ~= Rules.SCENE_OVER then Speaker.play("miss") end
  elseif ev == Rules.EV_OVER then Speaker.play("over"); finish_run()
  end
end

local function drain_events()
  for i = 1, S.event_n do react(S.events[i]) end
  Rules.clear_events(S)
end

-- 7. Hooks ------------------------------------------------------------------------
function game_start(params)
  local lang = params.language or "en"
  T = STR[lang] or STR.en
  S = Rules.new_state(Timer.millis())
  view = { acc = 0 }
  build_sprites()
  build_texts()
  render()
  print("main: started lang=" .. lang)
end

function on_tick(dt_ms)
  if not S then return end

  -- Real elapsed time: dt_ms is the nominal 33 even when a frame runs late.
  local now = Timer.millis()
  local dt = now - (view.last_ms or now)
  view.last_ms = now
  if dt > DT_MAX then dt = DT_MAX end

  local dir = 0
  if Input.is_down("left") then dir = dir - 1 end
  if Input.is_down("right") then dir = dir + 1 end
  Rules.set_move(S, dir)

  view.acc = view.acc + dt
  local steps = 0
  while view.acc >= LOGIC_DT and steps < MAX_STEPS do
    Rules.step(S, LOGIC_DT)
    drain_events()
    view.acc = view.acc - LOGIC_DT
    steps = steps + 1
  end
  if steps >= MAX_STEPS then view.acc = 0 end

  if S.scene == Rules.SCENE_OVER then poll_rank() end
  render()
end

function on_input(action, phase, hold_ms)
  if not S or phase ~= Input.PRESS then return end
  if action == "confirm" and S.scene ~= Rules.SCENE_PLAY then
    discard_stale_rank()
    Rules.start_run(S)
    drain_events()
  end
end

-- Returning true would keep the game running (e.g. to show a confirm prompt);
-- anything else exits to the menu.
function on_home()
  return false
end

function game_end()
  Speaker.stop_all()
  destroy_all()
  S = nil
  print("main: game_end")
end
