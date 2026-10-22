# Port from a brief (art + design doc + any HTML demo)

> **Load when** the input is a game brief: an art folder, a design document and a playable demo
> that was **not** built on the kit (any HTML, CSS, canvas or framework). It runs before the
> mechanical port: [porting.md](porting.md) takes over at S4 once the parity table, the layout
> and the frame budget ([frame-budget.md](frame-budget.md)) are approved. A kit demo with a
> `pika-spec.json` skips this page. People: [port-a-demo.md](../docs/guides/port-a-demo.md#porting-a-demo-that-was-not-built-on-the-kit).

Order: **Intake → Fit → Budget → Build → Validate.** The budget comes before the code: on this
engine a design that was never affordable cannot be optimised into one.

## Rules

- **BRIEF-INVENTORY** MUST list every input before planning: each asset (path, pixel size, file size, format, has alpha), the design doc, the demo entry file. Name what is missing; never invent an asset, a rule or a line of dialogue. Check: the inventory table is in the hand-off.
- **BRIEF-LOGIC** MUST read the demo's code, not its looks: the update loop and its real timestep, spawn, collision, scoring, lives, timers, every scene and transition, and what is *content* (levels, word lists) versus *code*. Check: every rule in the parity table cites the demo function or design-doc section it came from.
- **BRIEF-PARITY** MUST write the parity table before any Lua (format below), one row per mechanism, with the limit that forces each change. Check: no `adapt`/`drop` row without a reason.
- **BRIEF-SCALE** MUST compute one scale factor from the demo canvas to the screen (`facts.screen`) and apply it to every size, speed, hitbox and spacing; speeds are rescaled for time too (a demo that moves a constant per browser animation frame must be converted to pixels per millisecond, then stepped at (`target_fps` = 30) on `Timer.millis()`). Check: the factor is written in the budget comment of `main.lua`.
- **BRIEF-LAYOUT** MUST give every scene a layout table with real integer coordinates (format below), and check text at the **longest** string of the whole content set (longest word, hint, score, every UI language), not the sample string. Check: the longest string is named per label; it fits in Pika Studio.
- **BRIEF-CONTROLS** MUST map every demo input to the three game buttons plus HOME (table below) and say which mapping was chosen for any extra verb. Check: no mouse, touch, drag or keyboard row left.
- **BRIEF-STOP** MUST stop after Intake, Fit and Budget and get approval of the parity table, the layout and the budget before writing the pack, unless they were approved already. Check: the approval is quoted in the hand-off.
- **BRIEF-NOSILENT** NEVER change a rule, a screen, the UX or the art direction to fit the engine or the budget without listing it as a deviation and getting approval. Check: every difference from the demo is a parity row.
- **BRIEF-NOAPI** MUST stop and report when the game needs a call the engine lacks: the proposed call shape (name, arguments, return, failure), why the game needs it, and the per-frame cost of doing without — for the Pika team. NEVER fake it with per-frame Lua work (G12). Check: [api-contract.md](api-contract.md#does-not-exist-commonly-invented) lists the usual substitutes; anything else is a report.

## Parity table

| Mechanism | Demo behaviour (source) | Pack plan | Cost concern | Status |
| --- | --- | --- | --- | --- |
| e.g. bubble shot | straight line, wall bounce (`shoot()`) | same, integer steps on `Timer.millis()` | one sprite moving per frame | port |
| e.g. 3 GIFs on the title screen | three looping animations | one `Anim`, two still sprites | one `Anim` plays at a time (`facts.anim_concurrent`) | adapt |

Cover at least: scenes (boot, play, round change, boss, game over), rules, HUD, input, audio,
LED, servo, voice, ranking. Status is `port`, `adapt` (with the limit) or `drop` (with the
limit and the approval).

Demo patterns with no engine equivalent, and their port, beyond the tables in
[demo-kit.md](demo-kit.md#js--lua) and [port-a-demo.md](../docs/guides/port-a-demo.md#porting-a-demo-that-was-not-built-on-the-kit):

| Demo | Why it cannot carry over | Port as |
| --- | --- | --- |
| `async`/`await`, generators, promises | no `coroutine` in the sandbox ([api.md#sandbox](../docs/reference/api.md#sandbox)) | a state variable plus a step function in `on_tick` |
| canvas pixel drawing (`fillRect`, `drawImage` every frame) | no pixel API; objects are retained | pooled sprites, `Sprite.solid` blocks, `Shape.line` |
| unbounded particles | every sprite costs PSRAM (`facts.sprite_cap`) | a fixed pool sized in the budget, or drop the effect (approval) |
| free speech input | keyword spotting only, English | a keyword list ([recipes/voice-keyword-trigger.md](recipes/voice-keyword-trigger.md)) |
| web fonts at any size | (`font_slots` = 8) faces, TTF from the pack | one subset TTF per script, two or three sizes |
| `localStorage`, saves | nothing persists (`facts.persistence`) | `Ranking.report` for scores; otherwise drop (approval) |

## Layout table (one per scene)

| Element | x, y | w, h | Layer (creation order) | Type | Visible when |
| --- | --- | --- | --- | --- | --- |
| background | 0, 0 | 480, 320 | 1 | `Sprite.new` | always |
| score | 8, 6 | — | last | `Text` | play, over |

Origin top-left; `Text.new(str, x, y)` places the top-left corner and `t:align` centres without
arithmetic. Keep the HUD out of the play field. Nothing important at the screen edge until it
has been checked on a robot ([release-checklist.md](../docs/guides/release-checklist.md#screen)).

## Control mapping

| Demo input | Shape | Engine |
| --- | --- | --- |
| held movement | continuous | `Input.is_down(action)` in `on_tick` |
| click, key press | discrete | `on_input` with `Input.PRESS` |
| charge meter | hold | time since `Input.PRESS`, measured with `Timer.millis()` (`Input.hold_ms` stays 0 until the first repeat, (`button_repeat_delay_ms` = 400) ms after the press) |
| long press, auto-repeat | hold | `Input.REPEAT` events, `Input.hold_ms(action)` |
| a fourth verb | — | long press on enter, left+right together, or a mode toggle: say which |
| back, menu, close | — | HOME calls `on_home()`; HOME held always exits ([api.md#hooks](../docs/reference/api.md#hooks)) |

Handle `on_input_lost(count)`: resynchronise held state, never assume a matching release arrived.

## Hand-off for approval

1. Input inventory and the list of what is missing or ambiguous (questions, not guesses).
2. Parity table.
3. Layout table per scene, with the longest string per label.
4. Control mapping.
5. Frame budget, planned column filled ([frame-budget.md](frame-budget.md#worksheet)).

After approval: [porting.md](porting.md) from step 1 (pack folder), with the demo's own
mechanisms in place of `pika-spec.json`; then [review-checklist.md](review-checklist.md).
