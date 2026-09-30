# Recipe: pre-game settings screen

> **Load when** a game needs a first screen with Start plus a few options (difficulty, volume).
> Uses the shipped `libs/settings` module ([../libs-catalog.md](../libs-catalog.md)). Runnable
> mini pack: the manifest, `libs/settings.lua` copied from [`../../libraries/settings.lua`](../../libraries/settings.lua),
> the label images, and `scripts/main.lua` below.

## Rules

- **SET-ART** MUST ship the label images — the menu draws its chrome with `Sprite.solid` but every caption is an image under `spec.kit`; a missing image is logged (`settings: asset MISSING/invalid -> <path>`) and left blank. The text fallback runs only when `Sprite.solid` itself fails (`libraries/settings.lua:226`), so **without art the rows show no labels**.
- **SET-ACTIONS** MUST pass `spec.actions` when the manifest names differ from the defaults `left` / `right` / `fire`.
- **SET-DESTROY** MUST call `menu:destroy()` when leaving the menu and in `game_end` — frees its sprites.
- **SET-RENDER** MUST call `menu:render()` after each handled input (the first call builds the menu).

## Art the module loads

| File (under `spec.kit`, default `images/settings`) | Shows |
| --- | --- |
| `chrome/btn_start.png` | Start button caption |
| `lbl_<key>.png` | one label per row |
| `<key>/<i>.png` | one image per option of a `choice` row (`i` is 1-based) |

Per-row overrides: `label_img`, `option_imgs`. `range` rows draw their bars with solids.

## `manifest.json`

```json
{
  "version": "0.1.0",
  "name": {"vi": "Menu cài đặt", "en": "Settings menu"},
  "main": "scripts/main.lua",
  "peripherals": ["display", "button", "audio"],
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
local settings = require("libs/settings")
local menu            -- nil once the game has started
local cfg             -- chosen values
local player

local function start_game(chosen)                 -- called from menu:input
  cfg = chosen                                    -- { difficulty = 1..3, volume = 0..100 }
  Speaker.set_volume(cfg.volume)
  menu:destroy()
  menu = nil
  player = Sprite.solid(24, 24, 0x07E0)
  if player then player:set_pos(228, 180) end
end

function game_start()
  menu = settings.new({
    actions = { left = "left", right = "right", enter = "confirm" },
    on_start = start_game,                        -- required: new() raises without it
    rows = {
      { kind = "choice", key = "difficulty", label = "Difficulty",
        options = { "Easy", "Normal", "Hard" }, default = 2 },   -- cfg.difficulty = index
      { kind = "range", key = "volume", label = "Volume",
        min = 0, max = 100, step = 10, default = 60 },           -- cfg.volume = number
    },
  })
  menu:render()
end

function on_input(action, phase, hold_ms)
  if menu then
    if menu:input(action, phase) and menu then menu:render() end
    return
  end
  -- game input, reading cfg.difficulty
end

function on_tick(dt_ms)
  if menu then return end
  -- game logic
end

function game_end()
  if menu then menu:destroy() end
end
```

## Notes

- Controls: left/right move the cursor (Start first, wrapping); enter on a row opens it for
  editing, left/right change it, enter confirms. HOME is not handled by the menu: define `on_home`.
- `choice` rows give the 1-based index, `range` rows the number (optional `unit`, `on_change`).
- No "Continue" row: nothing persists between sessions.
- Full reference: the header comment of [`../../libraries/settings.lua`](../../libraries/settings.lua).

## Check

`python tools/smoke.py <pack> "right,enter,right,enter,left,enter,wait:500"` ends `0 error(s)`,
exit 0; then look at the menu in Pika Studio (labels visible only with the art).
