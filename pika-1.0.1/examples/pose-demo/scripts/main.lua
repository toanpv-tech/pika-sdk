-- examples/pose-demo — cycle curated servo poses (engine_level 7, needs back board)
-- Pose aliases map to curated gestures in manifest.poses; servo aliases (for
-- single-servo moves) map to hardware names in manifest.servos.

local pose_names = { "hello", "wave", "cheer" }   -- keys declared in manifest.poses
local idx = 1

local function show()
  HUD.set_label(string.format("Pose: %s  (%d/%d) ENTER=play", pose_names[idx], idx, #pose_names))
end

function game_start(level_json)
  Servo.move("head", 0, 400, "in_out")   -- center the head with a single-servo move
  show()
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "next" then
    idx = (idx % #pose_names) + 1
    show()
  elseif action == "prev" then
    idx = ((idx - 2) % #pose_names) + 1
    show()
  elseif action == "fire" then
    Servo.pose(pose_names[idx])
  end
end

function on_tick(dt_ms) end

function game_end() end
