# Frame budget: plan before code, measure on the robot

> **Load when** planning a port or a new game with many objects, before the first line of Lua;
> or when a robot log shows dropped frames, hitches or memory growth (mode D). Costs and the
> send-if-changed patterns: [performance.md](performance.md). What each log field means and the
> symptom tables: [telemetry.md](../docs/reference/telemetry.md) (this page does not repeat
> them). Robot acceptance: [release-checklist.md](../docs/guides/release-checklist.md#c-on-the-robot).

## Rules

| ID | Rule | Why | Check |
| --- | --- | --- | --- |
| **BUDGET-FIRST** | MUST fill the *planned* column of the worksheet for every scene before writing the scene | A design that does not fit has to be renegotiated before it is built, not after it stutters | The worksheet is in the hand-off and in the budget comment of `main.lua` |
| **BUDGET-WORST** | MUST plan the worst frame, not the average: peak object count + a scene change + a sound starting + an `Anim` frame | One heavy path that runs on a few frames shows up as `slow_pm` and `gap_us` spikes even when `p95` looks fine | Name the worst frame per scene in the worksheet |
| **BUDGET-HEADROOM** | MUST plan pools below the limits: live `Text` at 80% of (`text_slots` = 8) as in [demo-kit.md R5](demo-kit.md#rules); 🧪 the same margin for faces, `Shape` lines and the Lua heap | Content grows after the first build; a pack at the limit fails on the first longer word list. Time limits need the same margin: 🤖 one map build took 1.0–1.7 s depending on whether the robot was writing to the SD card at the same time (robot, 2026-09) | Planned column vs the limit column |
| **BUDGET-SCENE** | MUST plan each scene entry as its own row: what it loads and redraws, and that nothing timed runs in it (no sound start, no countdown, no input window) | A scene change can block for several frames: 🤖 a full-screen map repaint cost 130–160 ms of engine time per frame for about ten frames, and entering a detail screen cost one frame of 425–503 ms on every entry (robot, 2026-09; the cause of the detail cost was not established) | Start timers and sounds after the first frame of the new scene; `gap_us` spikes only at transitions |
| **BUDGET-MEASURED** | NEVER fill the *measured* column from smoke or Pika Studio; only from a robot log | PC timing proves nothing about the robot (PC-SPEED) | Every measured cell names its log line |
| **BUDGET-CUT** | MUST cut in this order when the robot misses: (1) fewer objects at once, every mechanism kept; (2) pooling and send-if-changed; (3) HUD and non-essential effects updated less often; (4) asset format and size; (5) only with approval: UX, animation or rules | Steps 1–4 keep the game the brief asked for; step 5 changes it (BRIEF-NOSILENT) | Each change in the hand-off names its step |
| **BUDGET-REMEASURE** | MUST re-run the robot session after every accepted change | Fixing one cost often exposes the next | One log per change |

## Worksheet

One table per scene, worst frame. Leave *measured* empty until a robot run.

| Line | Planned | Limit (key) | Measured | From |
| --- | --- | --- | --- | --- |
| Live `Text` | count | (`text_slots` = 8), plan 80% | peak count | code review |
| Font faces | list of (file, size) | (`font_slots` = 8) | — | `game.render: font cache full` absent |
| Live `Shape` lines | count | (`line_slots` = 8) | — | `Shape.line` in `game.warn` absent |
| Sprite PSRAM | Σ `w*h*2` or `w*h*3` per live sprite, images kept from other scenes included, + largest PNG file while it decodes, + both images during a swap that keeps the old one ([performance.md](performance.md#pools-by-file-and-the-psram-peak-across-scenes)) | free PSRAM (`facts.sprite_cap`) | smoke PSRAM figure (PC); `psram` in `game.start` / `game.stop` | [api.md#sprite](../docs/reference/api.md#sprite) |
| `Anim` | one, file size | `facts.anim_concurrent`, file limit in [constraints.md](constraints.md) | `animerr` absent | `game.warn` |
| Lua heap | tables and strings kept | (`lua_heap_bytes` = 524288); warning at (`lua_near_budget_pct` = 90) % | `arena_pk`; `arena` per round | `game.stop`, `game.running` |
| Engine calls per frame | mutators left after send-if-changed | — | `tick_us`, `p95` | `game.running`, `game.stop` |
| Loads during play | 0 (PERF-LOCK) | — | no `overrun` outside scene changes | `game.warn` |
| Scene entry redraw | screens fully redrawn, ticks the entry may block | — | the longest `gap_us` at the transition | `game.running`, phase timing |
| Loads at scene entry | files and sizes, ticks they are spread over | (`hook_watchdog_ms` = 1500) per hook | `load` in `game.start`; `tick_us` while loading | `game.start`, `game.running` |
| Frame rate | — | (`tick_hz_max` = 33) | `tick_hz`, `slow_pm` | `game.running`, `game.stop` |
| Sounds | one per event, spaced by the cooldown | (`sound_cooldown_ms` = 150), one channel (`facts.sound_channels`) | `Speaker.play` in `game.warn` absent | `game.warn` |
| Servo motion | gestures per minute per servo | (`servo_duty_limit_s` = 8) s per (`servo_duty_window_s` = 10) s | servo value of `drop`; `back_reject_*` in `Servo.stats()` | `game.stop`; Lua at round end |
| Failed calls | 0 | — | `api_fail`, `drop` | `game.stop` |

## Diagnose a robot log

1. Get the **full** serial log of the session, not an excerpt. Ignore the first `game.running`
   line ([KI-FIRST-RUNNING](../docs/reference/known-issues.md#ki-first-running)).
2. Read `game.stop` first: `end`, `err`, `slow_pm`, `p95`, `arena_pk`, `api_fail`, `drop`. A
   session with `game.error` and no `game.stop` never tore down: start from the error line.
3. Read `game.warn` keys and the `game.running` trend (`tick_us`, `gap_us`, `arena`, `heap`).
4. Match the pattern in [telemetry.md#diagnosis-heuristics](../docs/reference/telemetry.md#diagnosis-heuristics),
   then the code path in [pitfalls.md](pitfalls.md). Write the *measured* column.
5. Fix in BUDGET-CUT order, one change per run, and re-measure.

When the log does not say which part of a frame costs, time phases with `Timer.millis()` in a
diagnostic build and print the sums once, from `game_end` (a `print` in a frame is paid in that
frame, PERF-PRINT). Millisecond resolution is coarse for one frame and fine summed over many.

```lua
local prof = { rules = 0, draw = 0, frames = 0 }    -- diagnostic build only

local function profiled_frame()                     -- called from on_tick
  local t0 = Timer.millis()
  step_rules()
  local t1 = Timer.millis()
  render()
  prof.rules = prof.rules + (t1 - t0)
  prof.draw = prof.draw + (Timer.millis() - t1)
  prof.frames = prof.frames + 1
end

function game_end()
  print(table.concat({ "prof frames=", prof.frames, " rules_ms=", prof.rules, " draw_ms=", prof.draw }))
end
```

Lua-side sums miss the screen work, which runs outside the hooks. To see it, also keep per
scene (loading, each screen) the number of ticks, the sum of the intervals between two
`on_tick` calls and the worst interval, and print ticks per second and the worst gap per scene
from `game_end`: a scene with a slow tick rate and small Lua sums is paint-bound
([PERF-PIXELS](performance.md#rules)). 🤖 a map pack kept this per scene and compared builds
with it on the robot (2026-09).

To count calls that may be refused, read `Input.stats()`, `Speaker.stats()`, `Servo.stats()`
and `Led.stats()` once at round end ([api-contract.md](api-contract.md)).

## Symptoms to patterns

Start from the log, then apply the cheapest pattern first (BUDGET-CUT). One change per robot run.

| Symptom (where it shows) | First patterns | Proved by |
| --- | --- | --- |
| The pack never opens, or ends at once: `LUA_WATCHDOG` while loading ([P11](pitfalls.md#p11)) | PERF-COUNT, PERF-SPREAD: fewer factory calls in `game_start`, the rest from `on_tick` | `game.start` appears; `load` in `game.start` drops |
| One long frame at a scene change: a single big `gap_us` ([P23](pitfalls.md#p23)) | BUDGET-SCENE, PERF-LOCK: load before the cover screen, start nothing timed in the entry frame | the transition `gap_us`; no `overrun` outside transitions |
| Steady slow play: `tick_hz` below (`tick_hz_max` = 33), high `p95` or `slow_pm` | PERF-SEND, [allocation-free per-frame code](performance.md#allocation-free-per-frame-code), then BUDGET-CUT steps 1–3 | `tick_hz`, `p95`, `slow_pm` in `game.running` and `game.stop` |
| Lua memory grows round after round: `arena` per round, `alloc near_budget` | PERF-HEAP, REVIEW-RESTART: reuse tables, reset state in `game_start` | `arena` returns to the same level after each round; `arena_pk` |
| Free PSRAM falls from one launch to the next: `psram` in `game.start` | PERF-ONCE: create big sprites once, toggle visibility, keep handles | `psram` in `game.start` stable across launches |
| A factory returns nil at load and the pack is rejected (`pool_full`, `no_mem`) ([P14](pitfalls.md#p14)) | BUDGET-HEADROOM; a straight bar is a solid sprite, not a `Shape` line, when lines run out | the worksheet's planned column below the limit; no failed factory at load |
| The pack takes seconds to open: `load` in `game.start` large although `game_start` is short | PERF-FILES: fewer files (strips, no unused files) | `load` in `game.start` |
| A screen is slow while large layers fade, pulse or move, with a small `tick_us` | PERF-PIXELS (stepped fades, one secondary mover per frame), PERF-RESTACK (no re-stack or line edit per frame) | `tick_hz`, `slow_pm`, `gap_us`; the per-scene tick rate |
| The first screen appears half built, or its first animation jumps | `Engine.show(false)` in `game_start`, `Engine.show()` in the tick that completes the build (the engine shows anyway after (`show_hold_max_s` = 3) s); start animation clocks on the next tick. 🤖 symptom (robot, 2026-10), 🧪 fix | the first animation runs from its start on the robot |
| Calls refused: `api_fail`, `drop` in `game.stop` | the matching rule for the refused call (sound cooldown, servo duty, input ring) in [api-contract.md](api-contract.md) | `api_fail=0`, no `drop=` |

`tools/check_robot_log.py <log> --game <id>` scores the release gates of a log in one step;
compare its JSON before and after each change.

## Verdict

- **PASS:** every telemetry gate of [release-checklist.md](../docs/guides/release-checklist.md#telemetry-gates)
  holds on a robot, every approved deviation is listed, nothing blocks.
- **CONDITIONAL:** only defects that do not touch gameplay remain, each with an owner and a
  fix date.
- **FAIL:** not run on a robot, log missing, any `game.error` or `game.stalled`, a gate missed,
  or gameplay/UX changed without approval.

Hand over: the worksheet with both columns, the parity table and its approved deviations, the
full serial log, the last smoke output, and what was not run on a robot.
