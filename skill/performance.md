# Performance and memory

> **Load when** a game has many sprites, large art, frame drops, hitches or memory errors.
> Numbers and costs live in [api-contract.md](api-contract.md) and [constraints.md](constraints.md);
> this page says how to stay inside them. The PC tools cannot measure robot cost (PC-SPEED):
> only robot telemetry proves performance ([telemetry.md](../docs/reference/telemetry.md)).

## Rules

| ID | Rule | Why | Check |
| --- | --- | --- | --- |
| **PERF-LOCK** | NEVER load or decode during active play; do it at a scene change, behind a cover screen. `set_frame` on change is the exception: few calls per frame | The display lock is held for the whole tick: `Sprite.image`, `Sprite.new`, `set_frame`, `set_font`, `Anim.new` stop screen refresh while they run ([api.md#hooks](../docs/reference/api.md#hooks)) | grep these calls inside per-frame code paths |
| **PERF-SEND** | MUST send a mutator only when its value changes | Every call crosses into the renderer; `set_flip` rewrites every pixel, `set_frame` reads the SD card each call ([api.md#sprite](../docs/reference/api.md#sprite)) | Each `set_*` in `on_tick` sits behind a compare |
| **PERF-ONCE** | MUST create large sprites once and toggle them with `set_visible` | A PNG decode holds the whole file plus the decoded pixels in PSRAM at its peak ([api.md#sprite](../docs/reference/api.md#sprite)); 🧪 create/destroy cycles of full-screen sprites may fragment PSRAM (not measured) | No factory call inside per-frame code |
| **PERF-SPREAD** | MUST spread loads across ticks | Every hook shares the watchdog (`hook_watchdog_ms` = 1500) | Robot `game.start` `load=`/`init=`; no `LUA_WATCHDOG` |
| **PERF-OPAQUE** | MUST export opaque art as RGB PNG or `.rgb565` | A PNG that can carry alpha costs `w*h*3`, one without alpha `w*h*2`, decided from the header ([api.md#sprite](../docs/reference/api.md#sprite)) | smoke.py PSRAM figure (PC-PNG-COST) |
| **PERF-HEAP** | MUST NOT build strings or tables every frame | Garbage counts toward the Lua heap; near the limit the game can end OOM ([KI-OOM-EDGE](../docs/reference/known-issues.md#ki-oom-edge)) | `arena` stable across `game.running` lines |
| **PERF-PRINT** | NEVER `print` in `on_tick` in a build you measure | Serial output blocks the frame and is paid in that frame's `tick_us` ([telemetry.md](../docs/reference/telemetry.md#how-a-frame-is-measured)) | grep `print(` in per-frame code |

## Known expensive (unordered, not measured against each other)

Image factories (SD read, and decode for PNG) · `set_frame` (SD read every call) · `set_flip`
(O(w·h)) · `set_scale`/`set_rotation` (extra draw time) · `set_font` on a face not cached ·
`Anim.new` (whole file in PSRAM) · large screen areas changing every frame (the panel cannot
redraw the full screen every frame: [telemetry.md](../docs/reference/telemetry.md#frames)).
Lua logic is rarely the cost 🧪.

## Send only on change

```lua
local function place(rec, x, y)            -- rec = { spr = handle }
  if rec.spr and (x ~= rec.x or y ~= rec.y) then
    rec.x, rec.y = x, y
    rec.spr:set_pos(x, y)
  end
end

local function show(rec, vis)
  if rec.spr and vis ~= rec.vis then
    rec.vis = vis
    rec.spr:set_visible(vis)
  end
end
```

Same pattern for `set_frame`, `set_flip`, `set_font`, `set_color` and `align`. When an object is
re-created, clear its cache (`rec.x, rec.y, rec.vis = nil, nil, nil`). `t:set` of an identical
short string is already skipped by the engine [fw: head_esp32/components/game_engine/src/render/lvgl_renderer.c:319-322];
what costs is building the string: build it when the shown value changes.

## Pick the factory

| Factory | Use for | Cost source |
| --- | --- | --- |
| `Sprite.image("x.png")` | art with transparency; opaque art saved as RGB PNG | [api.md#sprite](../docs/reference/api.md#sprite) |
| `Sprite.new("x.rgb565", w, h)` | opaque backgrounds, tiles, frame strips | same |
| `Sprite.solid(w, h, rgb565)` | panels, bars, hitboxes | same |

A PNG sprite changes its image only by `set_frame` from a strip in its own format, or by
destroy + create (do that on a real state change only). Scale and rotate small sprites for
short effects ([api.md#transform-limit](../docs/reference/api.md#transform-limit)).

## Spread loads across ticks

Load what the first screen needs in `game_start`; pump the rest from `on_tick`, ideally behind a
cover screen. `PER_TICK` is a 🧪 starting value: tune it from robot `game.running` `tick_us` during loading.

```lua
local PENDING = { "assets/a.png", "assets/b.png", "assets/c.png" }
local PER_TICK = 2
local loaded, next_i = {}, 1           -- keep every handle referenced (HANDLE-GC)

local function pump_loads()            -- call from on_tick; true when done
  local last = math.min(next_i + PER_TICK - 1, #PENDING)
  for k = next_i, last do
    local spr, err = Sprite.image(PENDING[k])
    if not spr then print("load failed: " .. tostring(err)) end
    loaded[k] = spr or false           -- stays hidden until set_pos
  end
  next_i = last + 1
  return next_i > #PENDING
end
```

## Heap

- Build a display string when its value changes, store it, compare.
- Reuse tables (clear entries) instead of a new table per frame.
- Keep content (levels, word lists) as compact tables in `libs/`.

## Fonts and text

- List the faces at the top of `main.lua` (`HUD 16, title 26 = 2 of 4`); call `set_font` on
  scene entry, not per frame ([api.md#fonts](../docs/reference/api.md#fonts)).
- No width query: reserve room for the longest string, or measure once per language in Pika
  Studio and write the figure in a comment.

## Check

1. `python tools/smoke.py <pack>` ends `0 error(s)`; read its PSRAM figure.
2. On a robot: `game.running` `tick_us` and `slow_n` growth steady, `game.stop` `slow_pm` low, `arena` flat across rounds, no
   `game.warn` `overrun` bursts at scene changes ([telemetry.md](../docs/reference/telemetry.md#diagnosis-heuristics)).
