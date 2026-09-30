# Mode C: port a kit demo to a Lua pack (stages S4–S6)

> **Load when** a kit demo has passed gate S3 (`Verdict: READY TO PORT`) and must become a pack.
> This page is the single source of the port procedure. Demo rules and the JS ↔ Lua table:
> [demo-kit.md](demo-kit.md). Reference pair: [`../kit/template/index.html`](../kit/template/index.html)
> → [`../examples/pick_word/`](../examples/pick_word/). Human version:
> [../docs/guides/port-a-demo.md](../docs/guides/port-a-demo.md).

A demo not built on the kit: rebuild it on the kit and pass S3, or write a parity table (one
row per mechanism: kept / adjusted / dropped, and the limit that forces it).

## Rules

- **PORT-PATHS** MUST keep the demo's relative paths (`assets/card.png`, `fonts/regular.ttf`) — every path string carries over unchanged. Check: each `data-pika-sprite` path exists in the pack.
- **PORT-HOOKS** MUST define `on_tick` and `on_input` at the top level; scene logic moves into a state switch — hooks are bound once ([api.md#hooks](../docs/reference/api.md#hooks)). Check: `grep -n "on_tick *=" scripts/*.lua` is empty.
- **PORT-INDEX** MUST shift stored indices to 1-based (`ROUNDS[0]` → `ROUNDS[1]`, `(i + 1) % n` → `i % n + 1`); the `set_frame` frame index stays 0-based. Check: grep `[0]` in the Lua.
- **PORT-VOICE** MUST send keywords from the first `on_tick`, never from the top level or `game_start` — dropped on the robot ([api.md#voice](../docs/reference/api.md#voice)). Check: smoke.py voice warning.
- **PORT-HANDLES** MUST keep every handle referenced (the JS garbage collector did not remove sprites; Lua's does, HANDLE-GC). Check: no factory result stored only in a local.
- **PORT-RETURNS** MUST check factories for `nil, msg` and mutators for `false`; raise only in `game_start`. Check: review.
- **PORT-SJSON** NEVER create or edit `s.json` — the Pika platform issues it at publish (PC-SJSON).

## Steps

1. **S4 · Pack folder.** `<game_id>/` (the demo's `PIKA_MANIFEST.id`) outside the demo folder:
   `manifest.json`, `icon.png`, `scripts/main.lua`, `assets/`, `fonts/`, optional `libs/`.

2. <a id="manifest"></a>**S4 · `manifest.json` from `PIKA_MANIFEST`** ([manifest.md](../docs/reference/manifest.md)):

   | `PIKA_MANIFEST` | `manifest.json` |
   |---|---|
   | `id` | the folder name (not a field) |
   | `name` | `name` |
   | `input.actions` | `input.actions`, unchanged |
   | `sounds.<alias>.path`, `.loop` | `audio.sounds.<alias>.path`, `.loop` |
   | `sounds.<alias>.say`, `.lang` | dropped (recording script only) |
   | `fonts` | dropped (Lua loads fonts by path) |

   Add `version`, `main` (`scripts/main.lua`) and `peripherals` (`"voice"` only if the game uses
   voice: with it, losing the voice connection ends the game).

3. **S4 · Transliterate the hooks** with [demo-kit.md#js--lua](demo-kit.md#js--lua):
   - `function f(a) { ... }` → `function f(a) ... end`; module-level `let`/`const` → `local`.
   - `const [a, b] = f()` → `local a, b = f()`; methods use `:`.
   - Strings: `+` → `..`; `.length` → `#s` (bytes) or `utf8.len(s)`; long chains → `table.concat` (PC-CCALLS).
   - Wrap computed coordinates in `math.floor` (the demo's `L-INT` marked them).
   - Integers stay below 2^31 (PC-INT).
   - Add what the kit lacks where the demo left a comment: `Ranking.report`,
     `Engine.report_result` (talk-flow only), `Shape.line`.

4. **S4 · Export sprites at their declared size.** `pika-spec.json` `sprites` lists `w`, `h`,
   `format` and frame count.
   - `png_alpha` (`Sprite.image`) → PNG with alpha, within the PNG file limit ([constraints.md](constraints.md)).
   - `rgb565` (`Sprite.new`) → raw RGB565 little-endian, `w*h*2` bytes, no header:
     `python tools/png2rgb565.py <out.rgb565> <in.png>... [--bg 0xRRGGBB]`.
   - Strips for `set_frame`: frames back to back in the sprite's own format. The kit only
     produces `.rgb565` strips (PC-STRIP); `w*h*3` strips for alpha PNG sprites are valid on the
     robot but nothing in the SDK makes them ([api.md#sprite](../docs/reference/api.md#sprite)).
   - Until a bake tool exists: capture each element at 1× zoom at its declared size (browser
     devtools "Capture node screenshot"); keep transparent pixels transparent.

5. **S4 · Audio.** Give the **To record** list from `check_spec.py` to the voice talent. Ship
   placeholder files under the final names meanwhile: a missing sound file rejects the pack.

6. **S5 · Smoke.** Replay the playtest step list:

   ```bash
   python tools/smoke.py <pack> "wait:800,right,enter,wait:1500,home,restart,enter"
   ```

   **Pass:** ends `0 error(s)`, exit 0. Read every warning (voice in `game_start`, long `..`
   chains, PSRAM figure). smoke.py does not prove PC-* rows ([PC vs robot](../docs/reference/known-issues.md#pc-vs-robot)).

7. **S6 · Pika Studio.** Run the pack in the simulator through every branch, two rounds,
   restart, HOME; compare screens with the demo's `shot.png` files.

8. **S8–S9 · Robot.** Publish through the Pika platform (it issues `s.json`), play every branch
   on a robot and read the telemetry ([telemetry.md](../docs/reference/telemetry.md)): clean stop,
   no `api_fail`, frames on time, `arena` back to the same level each round. Then tick
   [release-checklist.md](../docs/guides/release-checklist.md).

## Check

- [ ] Every demo hook ported; no JS-only calls left (`Math.*`, `Array.*`, `console.*`).
- [ ] `on_tick`/`on_input` at the top level; no hook reassigned.
- [ ] Indices 1-based except `set_frame` frames.
- [ ] Voice keywords sent from `on_tick`; every alias used is declared.
- [ ] Manifest: actions, `audio.sounds`, `peripherals`; every sound file present.
- [ ] Every sprite file at its declared size and format.
- [ ] S5 smoke `0 error(s)`; S6 every branch in Pika Studio.
- [ ] Published through the Pika platform and measured on a robot.
