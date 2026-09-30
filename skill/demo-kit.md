# Mode A: design a browser demo with the kit (stage S3)

> **Load when** the user wants a playable mock-up in the browser, or a demo must be checked
> before porting. This page is the single source of the demo rules (R1–R9), the JS ↔ Lua table
> and the lint codes. Next step: [porting.md](porting.md). Human version:
> [../docs/guides/design-a-demo.md](../docs/guides/design-a-demo.md).

A demo is **a draft of the Lua game**, not a web app. It runs on
[`../kit/pika-frame.js`](../kit/pika-frame.js): a 480×320 screen, the three buttons plus HOME, the
engine's hook and API names, the limits from [`../kit/pika-constraints.js`](../kit/pika-constraints.js)
(generated from the firmware), live lint, an **Export pika-spec.json** button and a
`window.__pika` test hook. At boot the kit checks its API against
[`../contract/api.json`](../contract/api.json).

**Root rule: static inside, dynamic outside.** Inside a sprite any CSS is allowed (gradients,
shadows, SVG, web fonts); it is baked into an image at its declared size. At runtime the demo
only moves, fades, shows/hides, flips, reorders and swaps frames of sprites; scales or rotates
small sprites; changes `Text` strings; plays sounds by alias.

## Rules

- **R1 Loop** NEVER use `setTimeout`, `setInterval`, `requestAnimationFrame`, `async`/`await` or `Promise` in game code — the engine owns the loop. Define `on_tick`/`on_input` once at the top level and switch with a `state` variable (HOOK-REBIND); time with `Timer.millis()` deadlines, never by summing `dt_ms` ([KI-DT-NOMINAL](../docs/reference/known-issues.md#ki-dt-nominal)). Check: `L-ASYNC`, `L-HOOK-REBIND`.
- **R2 Art** MUST give every sprite element a fixed width and height equal to its size on the robot, and place every sprite (new sprites stay hidden until `set_pos`/`set_visible`). No `@keyframes`/`transition` inside a sprite. Several looks = `data-pika-frame` children switched with `set_frame` on an **opaque `.rgb565` strip loaded with `Sprite.new`** (a kit simplification, PC-STRIP), or separate sprites toggled with `set_visible`. Never flip a sprite that uses `set_frame` ([KI-FLIP-FRAME](../docs/reference/known-issues.md#ki-flip-frame)). Check: `L-SIZE`, `L-HIDDEN`, `L-BAKE`, `L-FRAME-FMT`, `L-FLIP-FRAME`.
- **R3 Motion** MUST tween position and opacity against `Timer.millis()`; physics are scripted paths plus bounding-box tests; coordinates are integers. Scale/rotate only small sprites ([api.md#transform-limit](../docs/reference/api.md#transform-limit)), for short effects. Check: `L-INT`, `L-XFORM`.
- **R4 Layers** MUST create backgrounds first and `Text` last — draw order is creation order and `Text` has no `set_z`. Check: look at `shot.png`.
- **R5 Text** MUST keep live `Text` at 80% of (`text_slots` = 8) (check_spec.py headroom), created once and changed with `set`; every `Text` calls `set_font` with the shipped TTF; at most (`font_slots` = 4) faces. No wrap: break lines in the data and test the **longest** string. Symbols and emoji as sprites. Check: `L-TEXT`, `L-TEXT-OVF`, `L-TEXT-OVL`, `L-FONT`, `L-GLYPH`.
- **R6 Sound** MUST declare every sound in `PIKA_MANIFEST.sounds`; never call `speechSynthesis` or `AudioContext`. One channel; plays within (`sound_cooldown_ms` = 150) are refused; too many aliases reject the whole pack. Every wait on `on_sound_end` has a timeout. Check: `L-SOUND`, `L-COOLDOWN`, `L-VOICE` (no recording yet).
- **R7 Input** MUST use only left, enter, right (named in `input.actions`) plus HOME; no mouse, touch or drag. `on_home()` truthy keeps the game. Voice is English keywords, sent from `on_tick` (never `game_start`), and buttons must always finish the game. Check: `L-INPUT`, `L-VOICE-EARLY`.
- **R8 Memory and load** MUST destroy the previous scene's sprites before building the next, and build a scene with many new images over several ticks — every hook shares the watchdog. Check: `L-WDOG`, `L-PSRAM`, side panel "PSRAM sprite KB".
- **R9 Isolation** NEVER touch the DOM, `document`, `window.*`, `localStorage` or `fetch` from game code; nothing persists between runs. Check: `L-API`, `L-ERROR`.

## Set up

1. Copy [`../kit/template/`](../kit/template/) to a new `snake_case` folder **outside any game
   pack** (Pika Studio's export copies the whole pack folder).
2. **Path rule:** the template loads `../pika-constraints.js` and `../pika-frame.js`. Keep the
   demo folder a sibling of `kit/template/` (inside `kit/`), or copy both `.js` files into the demo
   folder and change the two `<script src>` lines.
3. Put the TTF the game ships in `fonts/` and declare it in `PIKA_MANIFEST.fonts` as
   `{ "<path>": "<css font-family>" }`.

Page order stays: `<template id="pika-art">` → `pika-constraints.js` → `PIKA_MANIFEST` and hooks →
`pika-frame.js`.

## Build order

1. **Content as data**: `ROUNDS`, `LINES`, `LEVELS` tables first.
2. **Art** in `<template id="pika-art">`: one element per image with
   `data-pika-sprite="assets/<name>.png"` (`.rgb565` for opaque art and strips), fixed size.
3. **`PIKA_MANIFEST`**: `id`, `name`, `input.actions`, `fonts`, `sounds` (`path` of the shipped
   file, plus `say` = the spoken line and `lang`; the kit speaks with browser TTS until the file exists).
4. **Hooks**: `game_start`, `on_tick`, `on_input`, `on_sound_end`, `on_voice_event`, `on_home`, `game_end`.

## JS ↔ Lua

| Demo (JS) | Lua |
| --- | --- |
| `const [spr, err] = Sprite.image("assets/a.png")` | `local spr, err = Sprite.image("assets/a.png")` |
| `spr.set_pos(x, y)` · `const [x, y] = spr.get_pos()` | `spr:set_pos(x, y)` · `local x, y = spr:get_pos()` |
| `const [t, err] = Text.new(s, x, y)` · `t.set_font(p, n)` | `local t, err = Text.new(s, x, y)` · `t:set_font(p, n)` |
| `Speaker.play("ok")` · `Input.PRESS` · `Timer.millis()` | unchanged |
| `const ROUNDS = [{ ... }]`, `ROUNDS[0]` | `local ROUNDS = { { ... } }`, `ROUNDS[1]` (**1-based**; `set_frame` index stays 0-based) |
| `PIKA_MANIFEST` | `manifest.json` (see [porting.md](porting.md#manifest)) |
| `===` `!==` `&&` `\|\|` `!` | `==` `~=` `and` `or` `not` |
| `Math.round(v)` · `a + b` on strings | `math.floor(v + 0.5)` · `a .. b` (or `table.concat` for long chains, PC-CCALLS) |

Every factory returns an array in JS (`[obj]` or `[null, msg]`), mapping 1:1 to Lua's multi-return.

**Not in the kit:** `Shape`, `Ranking`, `Engine.report_result`, `Servo.list`, the `stats()`
calls. Leave them to the Lua port and mark the spot with a comment. `Speaker.set_url` only
validates its arguments; the kit plays no remote sound.

Buttons behave as on the robot: holding one sends `Input.REPEAT` (`button_repeat_delay_ms` = 400)
after the press, then about every (`button_repeat_rate_ms` = 80) (frame-granular in the
browser); `hold_ms` keeps the release value; an event reaches `on_input` once for every action
bound to that button, in manifest order. `Voice.is_available()` and `Led.is_available()` are
`false` during the top level and `game_start`, as on the robot.

## Lint codes

**Blocking** (the robot would refuse or break; `check_spec.py` fails): exactly the `BLOCKING` set
in `kit/pika-frame.js` = `BLOCKING_LINTS` in `tools/check_spec.py`:
`L-FRAME-FMT` `L-TEXT` `L-TEXT-OVF` `L-TEXT-OVL` `L-XFORM` `L-SIZE` `L-WDOG` `L-ERROR` `L-ASYNC`
`L-INT` `L-LED` `L-INPUT` `L-SOUND` `L-API` `L-VOICE-EARLY` (voice call in `game_start`)
`L-HOOK-REBIND` (hook reassigned after load).

**Warning** (decide and note in the hand-off): `L-HIDDEN` `L-BAKE` `L-GLYPH` `L-FONT` `L-COOLDOWN`
`L-FRAME` `L-FLIP-FRAME` (flip combined with `set_frame`) `L-PSRAM` `L-VOICE` `L-ART`.

Browser keys: arrows or A/D, Enter/Space, H or Esc = HOME, G = pixel grid, Z = 2× zoom,
R = restart. `?a2a=1` and `?lang=en` set `params.is_a2a` and `params.language`.

## Assets for the demo

Opaque art and frame strips are `.rgb565` files. Make them with:

```bash
python tools/png2rgb565.py <out.rgb565> <in.png>... [--bg 0xRRGGBB]
```

Several inputs of the same size are written back to back as one frame strip. `.rgb565` has no
alpha: pixels with alpha below 255 are blended over `--bg`, required when an input has
transparency ([`../tools/png2rgb565.py`](../tools/png2rgb565.py) header).

## Gate S3 (required before hand-off)

One-time setup in `tools/`: `npm install && npx playwright install chromium`; `pip install fonttools`
for the glyph check.

```bash
# from the pika-sdk folder; one run per screen you want to look at
node tools/playtest.js <demo>/index.html "wait:800,right,enter,wait:1500,home,restart,enter" --out <demo>/shots/title
python tools/check_spec.py <demo>/pika-spec.json
```

- `playtest.js`: steps `left` `right` `enter` `home`, `wait:<ms>`, `voice:<keyword>`, `restart`.
  It writes `pika-spec.json` and **one** `shot.png` (the last screen) per run into the demo folder
  or `--out <dir>`, prints lints and JS errors, and exits 1 on any JS error. **Pass:** exit 0 and
  no `JS-ERROR` line.
- The step list must walk every branch: right answer, wrong answer, timeout, HOME, restart, two
  rounds. Open each `shot.png`.
- `check_spec.py` re-checks the spec against the shipped files and `contract/constraints.json`
  (glyphs, font size, sprite size, alias count and length) and prints the **To record** list.
  **Pass:** prints `Verdict: READY TO PORT`, exit 0. Otherwise fix every blocker and rerun both.
  Point `check_spec.py` at the `pika-spec.json` of a run that covered every branch.

Hand-off = demo folder + `pika-spec.json` + To-record list.

## Do not

- Invent APIs or limits, or go outside the kit "for looks, port later".
- Hand over a demo that has not passed gate S3.
- Use web fonts for runtime `Text` (only inside baked sprites).
- Inline large base64 blobs; keep assets as files next to the demo.
