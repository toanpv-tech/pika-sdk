# Recipe: play a sound on a collision

> **Load when** a collision or event must play a sound and update a score. Runnable mini pack:
> the manifest, two sound files under the declared paths (placeholders are fine), and
> `scripts/main.lua` below.

API: [`spr:intersects`](../../docs/reference/api.md#sprite), [`Speaker.play`](../../docs/reference/api.md#speaker)
(alias), `t:set`, hook `on_sound_end`.

## Rules

- **SND-ALIAS** MUST play by manifest alias, never by path; every declared file must exist or the whole pack is rejected.
- **SND-ONE** MUST expect one channel and a cooldown (`sound_cooldown_ms` = 150): a second play preempts or is refused. Chain sounds from `on_sound_end`.
- **SND-TIMEOUT** MUST NOT make game flow wait only on `on_sound_end` — events can be lost; add a `Timer.millis()` deadline.
- **SND-REASON** MUST compare `reason` with `Speaker.REASON_*`, never with numbers.

## `manifest.json`

```json
{
  "version": "0.1.0",
  "name": {"vi": "Âm thanh khi va chạm", "en": "Sound on hit"},
  "main": "scripts/main.lua",
  "peripherals": ["display", "button", "audio"],
  "input": {
    "actions": {
      "left":  ["button:left"],
      "right": ["button:right"]
    }
  },
  "audio": {
    "sounds": {
      "hit": { "path": "assets/sounds/hit.wav" },
      "win": { "path": "assets/sounds/win.wav" }
    }
  }
}
```

## `scripts/main.lua`

```lua
local WAIT_MS = 3000             -- never wait on on_sound_end alone
local player, coin, hud
local score = 0
local phase, deadline = "play", 0  -- "play" -> "hit" -> "win"

local function next_phase()      -- from on_sound_end or the timeout
  local now = Timer.millis()
  if phase == "hit" then
    if Speaker.play("win") then phase, deadline = "win", now + WAIT_MS
    else deadline = now + 200 end               -- refused (cooldown): retry from on_tick
  elseif phase == "win" then
    phase = "done"
    Engine.exit("won")
  end
end

function game_start()
  player = Sprite.solid(20, 20, 0x001F)         -- blue (RGB565)
  coin   = Sprite.solid(16, 16, 0xFFE0)         -- yellow
  if player then player:set_pos(50, 150) end
  if coin   then coin:set_pos(300, 152) end
  hud = Text.new("Score: 0", 8, 8)              -- Text last: drawn on top
end

function on_tick(dt_ms)
  if phase ~= "play" then
    if Timer.millis() - deadline >= 0 then next_phase() end
    return
  end
  if not player then return end
  local x, y = player:get_pos()
  if Input.is_down("left")  then player:set_pos(x - 3, y) end
  if Input.is_down("right") then player:set_pos(x + 3, y) end

  if coin and player:intersects(coin) then      -- bounding-box test
    Speaker.play("hit")                         -- false inside the cooldown: acceptable
    score = score + 1
    if hud then hud:set("Score: " .. score) end
    coin:destroy()
    coin = nil
    phase, deadline = "hit", Timer.millis() + WAIT_MS
  end
end

function on_input(action, phase_, hold_ms) end

function on_sound_end(alias, reason)
  if alias == phase then next_phase() end        -- "hit" or "win" finished, stopped or preempted
end
```

## Check

`python tools/smoke.py <pack> "hold:right:3000,wait:3500"` ends `0 error(s)`, exit 0.
Hear it in Pika Studio; only a robot proves timing.
