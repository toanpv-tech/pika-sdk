# Recipe: several scenes (title → play → game over)

> **Load when** a game has more than one screen. Runnable mini pack: the manifest and
> `scripts/main.lua` below. Full structure: [../game-architecture.md](../game-architecture.md);
> larger skeleton: [../templates/structured-game/](../templates/structured-game/).

API: [`Text.new`](../../docs/reference/api.md#text), `t:set`, `t:show`, `spr:set_visible`, `Input.PRESS`.

## Rules

- **SCN-STATE** MUST switch scenes with one `scene` variable read inside the single top-level `on_tick` — hooks are bound once; `on_tick = other` is ignored ([api.md#hooks](../../docs/reference/api.md#hooks)).
- **SCN-HIDE** MUST hide, on entry, everything that is not the new scene's own — otherwise the previous screen stays on top.
- **SCN-ONCE** MUST do expensive work (fonts, fixed labels, string building, loads) once in `enter_scene`, not per frame.
- **SCN-REUSE** MUST reuse `Text` handles across scenes (`text_slots` = 8) and keep every handle referenced (HANDLE-GC).

## `manifest.json`

```json
{
  "version": "0.1.0",
  "name": {"vi": "Chuyển cảnh", "en": "Scenes"},
  "main": "scripts/main.lua",
  "peripherals": ["display", "button"],
  "input": {
    "actions": {
      "confirm": ["button:enter"],
      "left":    ["button:left"],
      "right":   ["button:right"]
    }
  }
}
```

## `scripts/main.lua`

```lua
local SCENE_TITLE, SCENE_PLAY, SCENE_OVER = 1, 2, 3
local PLAY_MS = 5000
local scene, last_scene = SCENE_TITLE, nil
local play_until = 0
local player, label                  -- reused by every scene; kept referenced

local function enter_scene(sc)       -- expensive work, once per change
  if sc == SCENE_TITLE then
    if player then player:set_visible(false) end
    if label then label:set("Press ENTER"); label:show(true) end
  elseif sc == SCENE_PLAY then
    if label then label:show(false) end
    if player then player:set_pos(228, 280); player:set_visible(true) end
    play_until = Timer.millis() + PLAY_MS
  else
    if player then player:set_visible(false) end
    if label then label:set("Game over\nPress ENTER"); label:show(true) end
  end
end

function game_start(params)
  player = Sprite.solid(24, 24, 0x07E0)         -- created hidden
  label = Text.new("", 150, 140)                -- Text last: drawn above sprites
end

function on_tick(dt_ms)
  if scene == SCENE_PLAY and Timer.millis() - play_until >= 0 then scene = SCENE_OVER end
  if scene ~= last_scene then last_scene = scene; enter_scene(scene) end
  -- per-frame updates for the current scene only
end

function on_input(action, phase, hold_ms)
  if phase ~= Input.PRESS or action ~= "confirm" then return end
  if scene ~= SCENE_PLAY then scene = SCENE_PLAY end
end
```

## Notes

- A scene that needs many new images builds them over several ticks and destroys the previous
  scene's large sprites first ([../performance.md](../performance.md#spread-loads-across-ticks)).
- HOME is not a scene change: `on_home()` truthy keeps the game (for a confirm prompt).

## Check

`python tools/smoke.py <pack> "enter,wait:6000,enter,wait:1000"` ends `0 error(s)`, exit 0.
