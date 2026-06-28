-- examples/led-blink — toggle the LED and cycle colors (engine_level 7, needs back board)
-- Led.set takes three args (r, g, b) in 0..255 — NOT a packed 0xRRGGBB integer.

local fsm = require("@sdk/libs/fsm")

local colors = {
  { 255, 0, 0 },     -- red
  { 0, 255, 0 },     -- green
  { 0, 0, 255 },     -- blue
  { 255, 255, 0 },   -- yellow
}
local idx = 1

local function apply()
  local c = colors[idx]
  Led.set(c[1], c[2], c[3])
end

local m = fsm.new("off")
  :add("off", "toggle", "on")
  :add("on", "toggle", "off")
  :on("on", apply)
  :on("off", function() Led.off() end)

local function show()
  HUD.set_label(string.format("LED %s  color %d/%d", m:get(), idx, #colors))
end

function game_start(level_json)
  Led.off()
  show()
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS then return end
  if action == "toggle" then
    m:fire("toggle")
  elseif action == "next" then
    idx = (idx % #colors) + 1
    if m:get() == "on" then apply() end
  elseif action == "prev" then
    idx = ((idx - 2) % #colors) + 1
    if m:get() == "on" then apply() end
  end
  show()
end

function on_tick(dt_ms) end

function game_end()
  Led.off()
end
