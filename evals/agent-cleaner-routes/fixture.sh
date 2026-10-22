#!/usr/bin/env bash
# Seeds games/meteor_dodge/ (a small pack with deliberate clean-code findings) in the run's workspace.
set -euo pipefail
mkdir -p games/meteor_dodge/scripts
cat > games/meteor_dodge/manifest.json <<'PIKA_EOF'
{
  "name": {"vi": "Né thiên thạch", "en": "Meteor Dodge"},
  "version": "0.1.0",
  "author": "Pika SDK eval",
  "main": "scripts/main.lua",
  "peripherals": ["display", "button"],
  "input": {
    "actions": {
      "enter": ["button:enter"],
      "left":  ["button:left"],
      "right": ["button:right"]
    }
  }
}
PIKA_EOF
cat > games/meteor_dodge/scripts/main.lua <<'PIKA_EOF'
-- Meteor Dodge: move with LEFT/RIGHT, avoid the falling meteors, ENTER restarts.

local player
local meteors = {}
local hud
local score = 0
local over = false
local last_ms = 0
local unused_counter = 0

local function spawn(i)
  local m = meteors[i]
  m.x = math.random(0, 456)
  m.y = -24 - i * 90
  m.spr:set_pos(m.x, m.y)
end

local function old_spawn_all()
  for i = 1, 4 do spawn(i) end
end

function game_start(params)
  hud = Text.new("Score: 0", 8, 8)
  player = Sprite.solid(24, 24, 0x07E0)
  if player then player:set_pos(228, 280) end
  for i = 1, 4 do
    local spr = Sprite.solid(24, 24, 0xF800)
    meteors[i] = { spr = spr, x = 0, y = 0 }
    if spr then spawn(i) end
  end
  last_ms = Timer.millis()
end

function on_tick(dt_ms)
  if over or not player then return end
  local now = Timer.millis()
  local steps = math.floor((now - last_ms) / 33)
  if steps > 3 then steps = 3 end
  last_ms = last_ms + steps * 33
  local x, y = player:get_pos()
  for s = 1, steps do
    if Input.is_down("left") then x = x - 4 end
    if Input.is_down("right") then x = x + 4 end
    if x < 0 then x = 0 elseif x > 456 then x = 456 end
    for i = 1, 4 do
      local m = meteors[i]
      if m.spr then
        m.y = m.y + 3
        if m.y > 320 then
          score = score + 1
          spawn(i)
        end
        if m.y + 24 > y and m.y < y + 24 and m.x + 24 > x and m.x < x + 24 then
          over = true
          debug_last_hit = i
        end
      end
    end
  end
  player:set_pos(x, y)
  for i = 1, 4 do
    local m = meteors[i]
    if m.spr then m.spr:set_pos(m.x, m.y) end
  end
  print("tick score=" .. score)
  if hud then hud:set("Score: " .. score) end
  if over and hud then hud:set("Game over - ENTER") end
  -- if score > 50 then
  --   speed_up()
  -- end
end

function on_input(action, phase, hold_ms)
  if action == "enter" and phase == 1 and over then
    over = false
    score = 0
    for i = 1, 4 do
      if meteors[i].spr then spawn(i) end
    end
    last_ms = Timer.millis()
  end
end

function on_home()
  return false
end

function game_end()
end
PIKA_EOF
