# Game architecture

> **Load when** a game has several scenes or grows past ~300 lines. The structure shipped
> multi-scene games use. Runnable skeleton: [templates/structured-game/](templates/structured-game/)
> (line references below point into its `scripts/main.lua`). One-screen games can stay in one
> file ([templates/minimal-game/](templates/minimal-game/)).

## Rules

- **ARCH-SPLIT** MUST keep rules in `libs/rules.lua` as plain Lua with no engine call — rules then run and unit-test under stock Lua 5.5 on a PC. Check: `grep -nE "(Sprite|Text|Shape|Anim|Speaker|Voice|Led|Servo|Ranking|Engine|Input|Timer)[.:]" libs/rules.lua` is empty.
- **ARCH-HOOKS** MUST define one `on_tick` and one `on_input` at the top level and switch scenes with a state variable inside them — hooks are bound once; reassigning is ignored ([pitfalls.md P8](pitfalls.md#p8)). Check: no `on_tick =` anywhere.
- **ARCH-TIME** MUST run rules in fixed steps measured with `Timer.millis()`, never by adding `dt_ms` — `dt_ms` is nominal ([KI-DT-NOMINAL](../docs/reference/known-issues.md#ki-dt-nominal)). Check: `dt_ms` is not summed anywhere.
- **ARCH-HANDLES** MUST keep every handle in the `view` table for its whole life — an unreferenced handle is freed by the garbage collector mid-game ([pitfalls.md P9](pitfalls.md#p9)). Check: every factory result is stored in `view`.
- **ARCH-LAYERS** MUST create `Text` last — creation order is draw order and `Text` has no `set_z` ([api.md#text](../docs/reference/api.md#text)). Check: all `Text.new` calls run after the sprite builders.
- **ARCH-VOICE** MUST send voice keywords from `on_tick` (first tick, or after a scene change) — keywords sent in `game_start` are dropped ([api.md#voice](../docs/reference/api.md#voice)). Check: no `Voice.` in `game_start`.
- **ARCH-EVENTS** MUST let rules emit event codes and play sounds, LED and servos in one `react()` — changing feedback then never touches the rules. Check: `Speaker.play` appears only inside `react()`.

## Files and tables

```text
scripts/main.lua     wiring: hooks, Sprite/Text/Speaker/Led/Voice/Ranking calls
libs/rules.lua       game rules: plain Lua, no engine API
libs/<data>.lua      levels, word lists, translations (plain tables)
```

| Table | Owner | Holds |
| --- | --- | --- |
| `S` (state) | `rules.lua` creates and mutates it | scene, score, lives, positions, time left, pending events |
| `view` | `main.lua` | engine handles and the last value sent to each one |

`main.lua` reads `S` to draw and changes it only through rule functions (`Rules.start_run(S)`,
`Rules.step(S, dt)`, `Rules.set_move(S, dir)`). Time enters the rules as a `dt` argument;
randomness from a seeded generator inside `S`.

## Events

Rules append event codes; `main.lua` drains them in one place (template `react`/`drain_events`,
lines 217-232):

```lua
-- libs/rules.lua
local function emit(S, ev)
  S.event_n = S.event_n + 1
  S.events[S.event_n] = ev
end
```

## Fixed step on real time

Template `on_tick`, lines 246-272:

```lua
local LOGIC_DT, MAX_STEPS, DT_MAX = 33, 4, 100   -- ms per step, catch-up cap, stall clamp

function on_tick(dt_ms)                          -- dt_ms unused: it is nominal
  local now = Timer.millis()
  local dt = now - (view.last_ms or now)
  view.last_ms = now
  if dt > DT_MAX then dt = DT_MAX end            -- a long stall is not replayed
  view.acc = view.acc + dt
  local steps = 0
  while view.acc >= LOGIC_DT and steps < MAX_STEPS do
    Rules.step(S, LOGIC_DT)
    drain_events()
    view.acc = view.acc - LOGIC_DT
    steps = steps + 1
  end
  if steps >= MAX_STEPS then view.acc = 0 end    -- drop the debt instead of spiralling
  render()
end
```

The `while` is bounded by `MAX_STEPS`, so it is not a waiting loop. Once-per-frame work (a
voice keyword swap after a scene change) is flagged inside the loop and done after it.

## Scenes inside one `on_tick`

`S.scene` holds one constant (`SCENE_TITLE → SCENE_PLAY → SCENE_OVER`); rules decide the
transitions. `render()` detects a change and does the expensive work once, on entry:

```lua
local function render()
  if S.scene ~= view.last_scene then
    view.last_scene = S.scene
    enter_scene(S.scene)          -- fonts, fixed labels, show/hide groups, voice flag
  end
  if S.scene == Rules.SCENE_PLAY then render_play() end
end
```

Each scene hides what is not its own. Details: [recipes/scenes.md](recipes/scenes.md).

## Object pools and budget

- Create a scene's objects when the game or scene starts; while playing only `set_pos`,
  `set_visible`, `set`, `set_frame`. Spread large sets over ticks
  ([performance.md](performance.md#spread-loads-across-ticks)).
- One object can serve several scenes (a play-screen label becomes a result line): that keeps a
  game inside (`text_slots` = 8) labels.
- Budget comment at the top of `main.lua`: sprites and PSRAM, `Text` count, font faces
  (`font_slots` = 4), `Shape` lines, `Anim` (template lines 7-11).
- Destroy a scene's large sprites before building the next; the engine frees the rest at the end.

## Draw order

Create in this order: background and tiles → items → characters → hidden full-screen overlays →
HUD icons → **`Text` last**. `set_z(i)` is a child index in one list shared with `Text`; reorder
only after everything exists. A sprite re-created later lands on top: `to_front()` what must
stay above it.

## One block per peripheral

| Block | Functions | Recipe |
| --- | --- | --- |
| Voice | `voice_tick()` (sends once, from `on_tick`), `voice_swap(list)` | [recipes/voice-keyword-trigger.md](recipes/voice-keyword-trigger.md) |
| Ranking | `finish_run()`, `poll_rank()`, `discard_stale_rank()` | [recipes/leaderboard.md](recipes/leaderboard.md) |
| LED | `led_base()`, `led_flash()` | [api.md#led](../docs/reference/api.md#led) |
| Sound | `react(ev)` only | [recipes/play-sound-on-hit.md](recipes/play-sound-on-hit.md) |

## File order of `main.lua`

Helpers before use, hooks at the bottom (top level). Open the file with a comment listing the
blocks (constants, send-if-changed helpers, pools, render per scene, react, peripherals, hooks)
and the budget.

## Check

```bash
python tools/smoke.py <pack> "wait:1200,enter,wait:600,right,wait:600,enter,wait:1500,restart,wait:600,home"
```

Ends `0 error(s)`, exit 0; then walk every scene in Pika Studio.
