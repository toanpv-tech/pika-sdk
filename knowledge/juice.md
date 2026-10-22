# Juice and engagement, costed

> **Load when** asked to make a game more fun, more rewarding or more "alive", or when a port
> hands over its engagement backlog. Every idea arrives with its cost against the frame budget
> ([frame-budget.md](frame-budget.md#worksheet)); an idea without a cost is a wish. Calls and
> their failure rules: [api-contract.md](api-contract.md).

## Rules

- **JUICE-COST** MUST present ideas as the ranked table below, highest impact per cost first, each with what it adds to the worksheet (sprites and their PSRAM, `Text` labels, calls per frame, heap, robot commands). Check: no row without a cost.
- **JUICE-APPROVE** NEVER fold an idea into a game without approval; an idea that breaks the planned budget is marked `needs approval` and names what it displaces ("6 particle sprites, `w*h*2` each, displaces the second background"). Check: the backlog is separate from the port.
- **JUICE-PER-EVENT** MUST send servo, LED and sound commands once per game event, behind a state change, never every frame. Check: no `Servo.*`, `Led.*` or `Speaker.play` in per-frame code outside a change test.
- **JUICE-REMEASURE** MUST send an accepted idea back through the robot run (BUDGET-REMEASURE). Check: a log after the change.

## Ranked backlog

| # | Idea | Why it lands | Cost | Risk | Verdict |
| --- | --- | --- | --- | --- | --- |
| 1 | e.g. cheer gesture on a combo | the robot itself celebrates | 1 `Servo.pose` per combo; all servos busy (`servo_pose_busy_ms` = 1500) | duty limit if combos chain | ok |

## The robot body: cheap on the screen, limited by the hardware

Servo and LED commands are queued and sent after `on_tick`; they add no drawing. What limits
them is the robot, not the frame:

- **Servo.** `Servo.pose(alias)` takes an alias from `poses` in `manifest.json`, mapped to a
  built-in gesture ([manifest.md](../docs/reference/manifest.md)); a gesture name that is not an
  alias returns `false`. A pose marks all four servos busy for (`servo_pose_busy_ms` = 1500) ms.
  Each servo may move at most (`servo_duty_limit_s` = 8) s in any (`servo_duty_window_s` = 10) s;
  past that its commands are refused for (`servo_duty_cooldown_s` = 5) s ([constraints.md](constraints.md)).
  Budget gestures per minute, and keep continuous motion out of the design.
- **LED.** A second display for state: a steady colour per game state (`Led.set`, `Led.preset`),
  `Led.pulse` for a reward. `Led.blink` periods outside (`led_blink_min_ms` = 333)..(`led_blink_max_ms` = 5000)
  and `Led.pulse` durations outside (`led_pulse_min_ms` = 100)..(`led_pulse_max_ms` = 5000) are
  **rejected**, not clamped (photosensitivity limit): check the return. The light returns to its
  previous state when the game ends.
- **Sound.** One channel: a new play waits behind the current sound unless the game stops it
  first ([KI-SOUND-QUEUE](../docs/reference/known-issues.md#ki-sound-queue)), and plays closer
  than (`sound_cooldown_ms` = 150) ms are refused. One sound per event, not per particle;
  coalesce bursts.
- **Voice.** Shouting a keyword at the robot is a mechanic a screen game cannot copy, but listing
  `"voice"` in `peripherals` makes the voice connection a hard requirement: when it fails the
  game ends ([api-contract.md](api-contract.md#voice)). Keep buttons sufficient for every
  action (G10).

| Moment | Embodiment | Cost |
| --- | --- | --- |
| score, combo | a cheer pose alias, or `Led.pulse` in the score colour | 1 command; duty |
| danger, low lives | `Led.blink` in red within the allowed period | 1 command |
| boss enters | a pose alias + the one `Anim` (`facts.anim_concurrent`) | 1 command + the `Anim` file in PSRAM |
| right answer | a pose alias + one sound | 1 command + 1 play |
| game over | a pose alias, LED back to a calm colour | 1 command |
| waiting for input | an idle pose alias, at most every several seconds 🧪 | 1 command; duty |

## Screen juice, cheapest first 🧪

1. **Instant acknowledgement.** Change something on the frame the button arrives, even when the
   outcome resolves later.
2. **Anticipation and follow-through.** Two or three squash/stretch frames from a pre-rendered
   strip with `set_frame` on change, or preloaded sprites toggled with `set_visible`; no new
   sprite per effect.
3. **Tween, do not teleport.** `libs/animator` + `libs/math/easing` ([libs-catalog.md](libs-catalog.md));
   floor the value before `set_pos`.
4. **Hit flash.** `set_opacity` on the sprite that was hit, or a white frame, for a few frames.
5. **Small particle pool.** A handful of preloaded sprites recycled with `set_visible`; count
   their PSRAM in the worksheet.
6. **Score pop.** `Text` has no opacity and no `set_z`: move one existing label and change its
   colour with `t:move`/`t:set_color`, or use a sprite if it must fade.
7. **Audio ramp.** Distinct sounds per event, pitched upward along a combo, inside the one-channel
   and cooldown rules.
8. **Shake, small and short.** A decaying offset added to positions you already send. Shaking a
   small object costs little; shaking the background or the whole scene changes a large screen
   area every frame, which the panel cannot redraw in time ([performance.md](performance.md#known-expensive-unordered-not-measured-against-each-other),
   low `draw_pm` in [telemetry.md](../docs/reference/telemetry.md#frames)): keep it to a few frames.

Budget cliffs, not gradual costs: per-frame allocation, unbounded particles, a second `Anim`,
loads during play (PERF-LOCK), scale or rotate on sprites over (`transform_max_px` = 96) px.

## Pacing and progression 🧪

- **Fast first success:** something good happens within seconds of the start.
- **Short sessions**, always resolvable; talk-flow games keep a conversation waiting.
- **A visible near-term goal:** a progress bar (`Sprite.solid` resized or repositioned) beats a raw score.
- **Combo with a visible timer:** one label and one bar.
- **Personal best:** `Ranking.report` at the end, `Ranking.get_result` when it arrives, with a
  timeout ([recipes/leaderboard.md](recipes/leaderboard.md)). Nothing persists otherwise.
- **Rounds with a breath:** round → short celebration (an embodiment moment) → slightly harder round.
- **Difficulty as a curve capped by the budget:** the density ceiling of the worksheet is the
  maximum difficulty; say so in the design.
- **Mercy:** brief invulnerability after a hit, never an unavoidable spawn.
- **End on an upswing:** show what was achieved, one button to play again.

## Learning and talk-flow games

- The score is explainable ("8 of 10 words"), not an arbitrary total.
- The curriculum lives in data files (`libs/<data>.lua`), so content changes without a port.
- Layout is checked at the longest item of the curriculum (BRIEF-LAYOUT); text that must be read
  stays on screen long enough.
- In talk-flow (`params.is_a2a`), `Engine.report_result` hands the outcome back to the
  conversation, which then talks about it ([api-contract.md](api-contract.md#engine)).
