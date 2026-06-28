-- examples/anim-demo — play a GIF/MJPEG via Anim (engine_level 1)
--
-- ASSET REQUIRED (currently 0-byte placeholder — drop a real file to run):
--   <sdk>/images/characters/pika/idle.gif   (GIF or MJPEG)
-- Until a real animation exists, Anim.new returns (nil, msg) and the game shows
-- the error instead of crashing.

local anim
local paused = false

function game_start(level_json)
  local a, err = Anim.new("@sdk/images/characters/pika/idle.gif")
  if not a then
    HUD.set_label("anim fail: " .. tostring(err) .. " (drop real GIF)")
    return
  end
  anim = a
  anim:set_pos(160, 80)
  anim:play({ loop = true })
  HUD.set_label("ENTER pause/resume, LEFT stop, RIGHT play")
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS or not anim then return end
  if action == "fire" then
    if paused then anim:resume() else anim:pause() end
    paused = not paused
  elseif action == "prev" then
    anim:stop(); paused = false
  elseif action == "next" then
    anim:play({ loop = true }); paused = false
  end
end

function on_tick(dt_ms) end

function game_end() if anim then anim:destroy() end end
