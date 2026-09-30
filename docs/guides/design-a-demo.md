# Design a demo in the browser

> **For:** designers and developers · **Needs:** [Getting started](../start/getting-started.md) · **Result:** a browser demo and its `pika-spec.json` with the verdict `READY TO PORT` (stage S3)

A browser demo is a **draft of the Lua game**, not a web app. It runs on `kit/pika-frame.js`,
a robot frame with the engine's hooks, API names and limits, which flags every violation
while you play. A demo that stays inside the kit ports to Lua by transliteration. Settle
layout, timing and feel here, in seconds, instead of on a robot.

The rules the demo must follow (R1–R9) and every lint code are defined once, in
[skill/demo-kit.md](../../skill/demo-kit.md): the page the AI follows too. Read it once.

## The one rule: static inside, dynamic outside

- **Inside a sprite** anything goes: gradients, shadows, blur, SVG, web fonts, borders. It is
  baked into an image at its declared size.
- **At runtime** a game may only move, fade, show or hide, flip, restack, swap frames, change
  a `Text` string and play a sound by alias. Scale and rotation work only on small sprites
  ([transform limit](../reference/api.md#transform-limit)).

## Start from the template

`kit/template/index.html` is a complete demo; `examples/pick_word/` is its Lua port.

1. Copy `kit/template/` to a sibling folder inside `kit/` named after your game id
   (`snake_case`). Elsewhere, copy `kit/pika-constraints.js` and `kit/pika-frame.js` too and
   fix the two `<script>` paths.
2. Put the TTF you will ship in `fonts/` and audio files where their `path` points.
3. Open `index.html` directly in a browser (`file://` works).

A page has three parts, loaded in this order:

```html
<template id="pika-art">
  <!-- one element per sprite, at its exact robot size; any CSS inside -->
  <div data-pika-sprite="assets/card.png" style="width:120px;height:80px;
       border-radius:12px;background:linear-gradient(#fff,#cde)"></div>
  <!-- a multi-frame sprite: an opaque .rgb565 strip, frames as children -->
  <div data-pika-sprite="assets/hero.rgb565" style="width:64px;height:64px;background:#6fa36b">
    <div data-pika-frame="0">☆</div><div data-pika-frame="1" style="display:none">★</div>
  </div>
</template>
<script src="../pika-constraints.js"></script>
<script>
window.PIKA_MANIFEST = {                          // becomes manifest.json
  id: "my_game",
  name: "My Game",
  input: { actions: { confirm: ["button:enter"], left: ["button:left"], right: ["button:right"] } },
  sounds: { ok: { path: "assets/sounds/ok.wav", say: "Well done!", lang: "en-US" } },
  fonts: { "fonts/regular.ttf": "GameFont" }      // TTF path -> CSS family of its @font-face
};
function game_start(params) { /* ... */ }
function on_tick(dt_ms) { /* ... */ }
function on_input(action, phase, hold_ms) { /* ... */ }
</script>
<script src="../pika-frame.js"></script>
```

- Each `data-pika-sprite` element is one sprite with a **fixed pixel size equal to its size
  on the robot**. A multi-frame sprite is loaded with `Sprite.new(strip, w, h)` and switched
  with `set_frame`; the kit supports frames only on `.rgb565` strips.
- Declare `input.actions`: the kit and the engine have different default action names.
- `say` is the line to record; the kit speaks it with browser TTS until the file exists.
  `fonts`, `say`, `lang` and `id` are kit-only and are dropped when porting.

## Kit controls

| Robot | Keyboard / UI |
| --- | --- |
| LEFT / ENTER / RIGHT | `←`/`A`, `Enter`/`Space`, `→`/`D`, or the on-screen buttons |
| HOME | `H` or `Esc` |
| Kit only | `G` 8 px grid · `Z` 2× zoom · `R` restart (a fresh session, like a new VM) <!-- number-ok --> |

URL parameters set `game_start` params: `?a2a=1` sets `params.is_a2a`; `?lang=en` sets
`params.language` (default `vi`). The side panel shows the budget (Text slots, font faces,
sprites, sprite PSRAM, sound aliases), live lints, LED/servo/voice activity, and an
**Export pika-spec.json** button. Red lints block the hand-off; yellow lints need a decision.

## Pass the gate

Run the [S3 gate](../reference/pipeline.md#gates) with a step list that walks **every
branch**: right answer, wrong answer, timeout, HOME, restart. `playtest.js` writes
`pika-spec.json` and a `shot.png` of the final state; look at it. `check_spec.py` rechecks
what a browser cannot see (glyph coverage of the real TTF, file sizes, alias and path
lengths) and prints every sound whose file is missing as **To record**, with its `say` line.

## Hand off

Deliver the demo folder with `index.html` and every file it references, the final
`pika-spec.json`, one `shot.png` per main screen (`--out` per run), and the `check_spec.py`
output with its **To record** list for the voice talent. Next: [Port a demo](port-a-demo.md).
