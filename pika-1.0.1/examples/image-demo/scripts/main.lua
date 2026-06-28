-- examples/image-demo — load a PNG sprite via Sprite.image (engine_level 1)
--
-- ASSET REQUIRED (currently 0-byte placeholder — drop a real file to run):
--   <sdk>/images/ui/icons/heart.png   (any PNG)
-- Until a real PNG exists, Sprite.image returns (nil, msg) and the game shows
-- the error instead of crashing.

local spr
local x = 216
local maxx = 480 - 48   -- refined from sprite width once loaded

function game_start(level_json)
  local s, err = Sprite.image("@sdk/images/ui/icons/heart.png")
  if not s then
    HUD.set_label("img fail: " .. tostring(err) .. " (drop real PNG)")
    return
  end
  spr = s
  local w = spr:get_size()          -- get_size returns w, h
  maxx = 480 - (w or 48)
  spr:set_pos(x, 136)
  HUD.set_label("LEFT/RIGHT move, ENTER bring to front")
end

local function clampx(v)
  if v < 0 then return 0 elseif v > maxx then return maxx else return v end
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS or not spr then return end
  if action == "left" then x = clampx(x - 16); spr:set_pos(x, 136)
  elseif action == "right" then x = clampx(x + 16); spr:set_pos(x, 136)
  elseif action == "fire" then spr:to_front() end
end

function on_tick(dt_ms) end

function game_end() if spr then spr:destroy() end end
