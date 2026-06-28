-- examples/sprite-demo — move a colored block, no SD asset needed (engine_level 1)
-- Sprite.solid builds an in-memory RGB565 rect, so this runs even before any
-- art is dropped on the card. set_pos wants integers, so positions are floored.

local box
local dir = 0            -- -1 left, +1 right, 0 idle
local x = 200.0          -- float accumulator; floored before set_pos
local y = 140
local speed = 0.12       -- pixels per millisecond
local BOX = 48

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

function game_start(level_json)
  box = Sprite.solid(BOX, BOX, 0xF800)   -- 0xF800 = red (RGB565)
  if box then box:set_pos(math.floor(x), y) end
  HUD.set_label("LEFT/RIGHT move, ENTER exit")
end

function on_input(action, phase, hold_ms)
  if action == "fire" and phase == Input.PRESS then
    Engine.exit()
    return
  end
  if phase == Input.PRESS then
    if action == "left" then dir = -1
    elseif action == "right" then dir = 1 end
  elseif phase == Input.RELEASE then
    dir = 0
  end
end

function on_tick(dt_ms)
  if dir ~= 0 and box then
    x = clamp(x + dir * speed * dt_ms, 0, 480 - BOX)
    box:set_pos(math.floor(x), y)
  end
end

function game_end()
  if box then box:destroy() end
end
