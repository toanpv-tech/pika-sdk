-- Minimal Pika game: runs as is, use it as a starting point.
--
-- A game is a set of global hook functions that the engine calls. There is no
-- game loop of your own: on_tick is the frame (30 FPS). Only call names listed
-- in contract/api.json (see skill/api-contract.md).

-- Game state (module locals) -------------------------------------------------
local player          -- Sprite handle
local hud             -- Text handle
local score = 0
local SPEED = 3       -- px per frame
local SIZE = 24       -- player width/height in px

-- game_start(params): once, after the pack has loaded -------------------------
-- params is always a table (empty if the launcher sent nothing). The engine
-- adds params.is_a2a (bool) and params.language (ISO 639-1 code).
-- Keep this hook short: it shares the 1.5 s hook watchdog.
function game_start(params)
  hud = Text.new("Score: 0", 8, 8)            -- nil, "pool_full" past 8 labels
  player = Sprite.solid(SIZE, SIZE, 0x07E0)    -- green block (RGB565 colour)
  if player then player:set_pos(228, 180) end  -- sprites stay hidden until placed
end

-- on_tick(dt_ms): every frame ------------------------------------------------
-- dt_ms is the nominal frame time; use Timer.millis() to measure real time.
function on_tick(dt_ms)
  if not player then return end

  -- Poll the buttons for smooth movement.
  local x, y = player:get_pos()
  if Input.is_down("left")  then x = x - SPEED end
  if Input.is_down("right") then x = x + SPEED end
  if x < 0 then x = 0 elseif x > 480 - SIZE then x = 480 - SIZE end
  player:set_pos(x, y)                         -- integers only
end

-- on_input(action, phase, hold_ms): discrete button events -------------------
-- Use it for one-off actions (select, shoot), not continuous movement.
function on_input(action, phase, hold_ms)
  if action == "enter" and phase == Input.PRESS then
    score = score + 1
    if hud then hud:set("Score: " .. score) end
  end
end

-- on_home(): HOME button -----------------------------------------------------
-- Return true to keep the game running (e.g. to show a confirm prompt);
-- returning anything else ends the game.
function on_home()
  return false
end

-- game_end(): before teardown ------------------------------------------------
function game_end()
  -- Sprites and Text are freed by the engine; release things early here only
  -- if you need to (e.g. Speaker.stop_all()).
end
