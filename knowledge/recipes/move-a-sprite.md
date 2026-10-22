# Recipe: move a sprite with the buttons

> **Load when** a character must run left/right while a button is held. Runnable mini pack:
> the manifest and `scripts/main.lua` below.

API: [`Sprite.solid`/`Sprite.image`](../../docs/reference/api.md#sprite), `spr:set_pos`,
`spr:set_flip`, [`Input.is_down`](../../docs/reference/api.md#input), `Timer.millis`.

## Rules

- **MOVE-TIME** MUST scale motion by a `Timer.millis()` difference, not per frame or by `dt_ms` — frames are (`tick_period_ms` = 30) ms apart while (`dt_ms` = 33) ([KI-DT-NOMINAL](../../docs/reference/known-issues.md#ki-dt-nominal)).
- **MOVE-INT** MUST keep a float position and pass `math.floor(fx + 0.5)` to `set_pos` — fractional coordinates raise.
- **MOVE-FLIP** MUST call `set_flip` only when the direction changes — it rewrites every pixel.

## `manifest.json`

```json
{
  "version": "0.1.0",
  "name": {"vi": "Di chuyển sprite", "en": "Move a sprite"},
  "main": "scripts/main.lua",
  "peripherals": ["display", "button"],
  "input": {
    "actions": {
      "left":  ["button:left"],
      "right": ["button:right"]
    }
  }
}
```

## `scripts/main.lua`

```lua
local W = 24                     -- sprite side in px
local SPEED = 120                -- px per second
local player, fx, y = nil, 228.0, 200
local facing_left = false
local last_ms

function game_start()
  local err
  player, err = Sprite.solid(W, W, 0x07E0)          -- or Sprite.image("assets/hero.png")
  if not player then print("player failed: " .. tostring(err)); return end
  player:set_pos(math.floor(fx + 0.5), y)           -- place at once: sprites start hidden
end

function on_tick(dt_ms)                             -- dt_ms is nominal: unused
  local now = Timer.millis()
  local elapsed = now - (last_ms or now)
  last_ms = now
  if not player then return end
  if elapsed > 100 then elapsed = 100 end           -- do not jump after a stall

  local left, right = Input.is_down("left"), Input.is_down("right")
  local dir = (right and 1 or 0) - (left and 1 or 0)
  if dir ~= 0 then
    fx = fx + dir * SPEED * elapsed / 1000
    if fx < 0 then fx = 0 elseif fx > 480 - W then fx = 480 - W end
    player:set_pos(math.floor(fx + 0.5), y)
    if (dir < 0) ~= facing_left then
      facing_left = dir < 0
      player:set_flip(facing_left, false)
    end
  end
end

function on_input(action, phase, hold_ms) end
```

## Notes

- One-off actions (jump, shoot) belong in `on_input` with `phase == Input.PRESS`.
- Scale and rotation only for small sprites ([api.md#transform-limit](../../docs/reference/api.md#transform-limit)).
- A sprite that uses `set_frame` must not be flipped ([KI-FLIP-FRAME](../../docs/reference/known-issues.md#ki-flip-frame)): ship left- and right-facing frames.

## Check

`python tools/smoke.py <pack> "hold:right:800,hold:left:800"` ends `0 error(s)`, exit 0.
