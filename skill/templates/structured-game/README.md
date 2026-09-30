# Template: structured-game ("Star Catch")

> **Load when** starting a multi-scene game. A runnable skeleton (title → play → game over)
> with the rules split from the wiring. Buttons: LEFT/RIGHT run, ENTER starts and replays, HOME
> exits. Architecture and rules: [../../game-architecture.md](../../game-architecture.md).

| File | Role |
| --- | --- |
| `scripts/main.lua` | wiring: send-if-changed helpers, object pool, ranking, render per scene, `react()`, hooks at the bottom (top level) |
| `libs/rules.lua` | rules in plain Lua: no engine calls, deterministic with a seed |
| `manifest.json` | actions `confirm` / `left` / `right`, four sound aliases |
| `assets/sounds/*.wav` | short silent placeholders: replace with recordings, keep the names |

What it demonstrates: fixed rules steps on `Timer.millis()` (`on_tick`), scenes switched by
`S.scene` inside one `on_tick`, every handle kept in `view`, `Text` created after the sprites,
one `react()` for all sounds, the ranking block ([../../recipes/leaderboard.md](../../recipes/leaderboard.md)).
It uses no voice; add it with [../../recipes/voice-keyword-trigger.md](../../recipes/voice-keyword-trigger.md)
(keywords from `on_tick`).

## Check (from the `pika-sdk` folder)

```bash
python tools/smoke.py skill/templates/structured-game "wait:1200,enter,wait:600,right,wait:600,left,wait:600,enter,wait:1500,restart,wait:600,home"
```

**Pass:** ends `0 error(s)`, exit 0.

Rules alone under stock Lua 5.5, from this folder:

```bash
lua -e "local R = require('libs/rules'); local S = R.new_state(1); R.start_run(S); for _ = 1, 100 do R.step(S, 33) end; print(S.scene, S.score, S.misses)"
```

**Make it your game:** keep the frame (fixed step, events, `react()`, render per scene, ranking
block); replace the rules in `libs/rules.lua` and the drawing in `main.lua`. Keep every
placeholder sound until its recording exists: a missing sound file rejects the whole pack.
