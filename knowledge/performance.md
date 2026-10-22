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
| **PERF-COUNT** | MUST budget factory calls per hook by **count**, not by file size: create many identical decorations lazily, a few per tick, or draw them from one sprite | Every `Sprite.new` and every first `Sprite.image` of a path opens, reads and decodes its file, however small; a later `Sprite.image` of a path a live sprite still uses shares its pixels (no read, no decode: [api.md#sprite](../docs/reference/api.md#sprite)), but each handle is still one more screen object created under the display lock. 🤖 a map screen that created 85 sprites in `game_start`, 56 of them small dots from one tiny PNG, ran past the hook watchdog and the pack never opened; computing the dot positions in `game_start` and creating 4 dots per tick fixed it (robot, 2026-09, on firmware without the shared image pixels) | Count factory calls in `game_start` and in any scene-entry function; no `LUA_WATCHDOG` |
| **PERF-RESTACK** | MUST stack a scene once, when it is built: every `set_z`, `to_front`, `to_back` and every Shape `set_points`/`set_style` that changes something goes in that one tick, never in `on_tick` of a running scene | A re-stack that changes an object's index repaints the **whole** screen, whatever the object's size; a Shape line that changes is re-rasterised as a new object and put back at its old index, so it repaints the whole screen too. Re-stacks in the same tick share one repaint (an area inside one already invalidated adds nothing), and an unchanged index costs nothing ✅. 🤖 connectors and nodes re-stacked one per tick cost one full repaint each, about 160 ms of engine time per frame; doing them all in the build tick paid it once (robot, 2026-09) | grep `set_z`, `to_front`, `to_back`, `set_points`, `set_style` in per-frame code; a long `gap_us` only at scene changes |
| **PERF-PIXELS** | MUST keep the area that changes each frame small: step fades of large sprites, move secondary objects less often, hide a layer once it has faded out | Every `set_opacity` call repaints the sprite's area through all the layers under it, even when the value did not change (the engine does not compare it ✅); a moved sprite repaints its old and new area. 🤖 a choice screen with a pulsing 162 × 125 ring and three bobbing 128 px eggs ran at about 13 fps with a small Lua tick (robot, 2026-10); the changes below halved the repainted pixels in a PC count, 🧪 not yet measured on a robot | Paint-bound when `tick_hz` falls and `gap_us` grows while `tick_us` stays small, at the moments large layers change: cut pixels, not Lua; grep `set_opacity` in per-frame code |
| **PERF-FILES** | MUST keep the number of files in a pack low: frame strips instead of one file per frame, no unused files | Every file of the pack is checked against `s.json` at each launch, before `game_start` ✅, so `load` in `game.start` grows with the file count. 🤖 each added file cost about 12 ms at every start; a pack of about 640 files took 12–13 s to open and the launch was abandoned, one of about 90 files took about 1 s (robot, 2026-10) | `load` in `game.start`; count the files before publishing |
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
short string is already skipped by the engine [fw: head_esp32/components/game_engine/src/render/lvgl_renderer.c:346-349];
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

## Create many small objects lazily

PERF-COUNT in code: keep only data in the hook that must stay short, and create handles when
they are first needed, with a per-tick cap. `PER_TICK` is a 🧪 starting value.

```lua
local DOTS = {}            -- { x, y, spr } filled in game_start: positions only
local PER_TICK = 4
local shown = 0            -- dots revealed so far, grows as the path is drawn

local function reveal_dots(due)        -- call from on_tick with the number that should show
  local made = 0
  while shown < due and made < PER_TICK do
    shown = shown + 1
    local d = DOTS[shown]
    local spr = Sprite.image("assets/dot.png")
    if spr then
      spr:set_pos(d.x, d.y)
      d.spr = spr                      -- keep the handle referenced (HANDLE-GC)
    end
    made = made + 1
  end
end
```

Two traps when creation is deferred (🤖 both broke a map screen before they were fixed, 2026-09):

- A skip press must not create everything at once: `on_input` shares the watchdog (PERF-SPREAD). Raise `due` and let the pump catch up.
- Call the pump from every scene a skip can reach, not only from the scene that started it, or the objects not yet created never appear.

A failed factory call is not retried every tick (each retry pays the SD read again): record the
failure and carry on with what exists, as `pump_loads` above does.

## Fewer changed pixels per frame

PERF-PIXELS in code. The screen redraws only what changed; each changed area is composed from
every visible layer under it, so a large fading or moving layer over a full-screen backdrop is the
usual cost of a slow screen with a small `tick_us`. Each item is 🧪, the gain is not measured.

```lua
local function steps(v, n)                 -- v in 0..1 -> n levels: n repaints, not one per frame
  if v <= 0 then return 0 elseif v >= 1 then return 1 end
  return math.floor(v * n) / n
end

local function fade(rec, a)                -- rec = { spr = handle }; a in 0..1
  local opa = math.floor(steps(a, 4) * 255 + 0.5)
  if opa ~= rec.opa then rec.opa = opa; rec.spr:set_opacity(opa) end
end
```

- **Step fades and pulses.** Three or four levels read as a fade; a pulse that changes every
  few frames looks the same as one that changes every frame.
- **One secondary mover per frame.** Keep the object the player looks at smooth; let idle
  objects bob slower, and move at most one of them per frame (a late one catches up next frame).
- **Pause the cosmetics during the main motion.** Hold a pulse while a hop or a slide runs.
- **Hide what is done.** `set_visible(false)` a full-screen layer once it has faded out, instead
  of leaving it at opacity 0 under everything else.
- **No black full-screen background.** The game screen is already black ✅: a black
  `Sprite.solid(480, 320, 0)` only adds PSRAM and one more layer to every repaint. <!-- number-ok -->

## Pools by file and the PSRAM peak across scenes

- **Key pools by file.** A handle stands in one place, so an icon shown N times needs N handles
  from a pool for that file; size each pool from the scene's data, grow it with the per-tick
  budget, and cap a pool whose file failed to load so it is not retried.
- **Hide between scenes, do not destroy.** While one handle of a path lives, more `Sprite.image`
  handles of it share its pixels; when the last one is destroyed the pixels are freed and the next
  load reads and decodes again ✅ ([api.md#sprite](../docs/reference/api.md#sprite)). Hide a
  scene's pool on exit and reuse it on the next entry.
- **Plan the peak, not the sum of one scene.** Peak PSRAM = every image still resident from
  other scenes + the scene's own images + the largest PNG file while it decodes. Two full-screen
  alpha backdrops at once cost `2 * w*h*3`: when one replaces the other behind a cover screen,
  destroy the old one first; keep both only when a swap must not show a blank frame, and write
  that peak in the budget comment.

## Heap

- Build a display string when its value changes, store it, compare.
- Reuse tables (clear entries) instead of a new table per frame.
- Keep content (levels, word lists) as compact tables in `libs/`.

## Allocation-free per-frame code

How to meet PERF-HEAP in `on_tick`, `on_input` and everything they call. Allocating is a Lua
fact (a table constructor, a closure, a concatenation each create an object); how much each
costs on the robot is 🧪, not measured.

- **Fixed arrays, explicit count.** Create pool entries at game or scene start; in play only
  reuse them. Remove by swapping with the last entry (order is not kept), never with
  `table.remove` from the middle:

  ```lua
  local live, live_n = {}, 0            -- array part only; the count lives outside the table

  local function release(i)
    live[i] = live[live_n]
    live[live_n] = nil
    live_n = live_n - 1
  end
  ```

- **No function literals in per-frame code.** Each one creates a closure; define helpers once
  at module level and pass state as arguments.
- **No `table.pack`, `{...}` or `string.format` per frame.** Build display strings when the
  shown value changes (PERF-SEND applies to strings too).
- **Numeric `for i = 1, n`** over arrays in hot loops; 🧪 `pairs`/`ipairs` and varargs are
  slower. Keep string keys out of hot arrays.
- **Hoist lookups.** 🧪 `local floor = math.floor` at module level, and a local for a table you
  index many times in one loop, are cheaper than repeated global and field lookups.
- **Stagger per-object housekeeping** by index, so it never lands on one frame:
  `if (frame + i) % 4 == 0 then slow_update(i) end`.
- **Lower-rate cosmetics.** 🧪 HUD numbers, timers and background effects refreshed a few
  times per second look the same to the player and cost fewer calls than every frame.
- **Cheap test before the engine test.** Reject most pairs with a number you already hold
  (lane, row, an x band) before calling `spr:intersects`, which crosses into the engine.
- **No recursion over game data** (flood fill, tree walks): an explicit stack in a preallocated
  array keeps memory and depth bounded.

## Fonts and text

- List the faces at the top of `main.lua` (`HUD 16, title 26 = 2 of 8`); call `set_font` on
  scene entry, not per frame ([api.md#fonts](../docs/reference/api.md#fonts)).
- No width query: reserve room for the longest string, or measure once per language in Pika
  Studio and write the figure in a comment.

## Check

1. `python tools/smoke.py <pack>` ends `0 error(s)`; read its PSRAM figure.
2. On a robot: `game.running` `tick_us` and `slow_n` growth steady, `game.stop` `slow_pm` low, `arena` flat across rounds, no
   `game.warn` `overrun` bursts at scene changes ([telemetry.md](../docs/reference/telemetry.md#diagnosis-heuristics)).
