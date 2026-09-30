# Port a demo to a Lua pack

> **For:** developers, or anyone directing an AI assistant · **Needs:** a demo that passed [Design a demo](design-a-demo.md) · **Result:** a Lua pack that passes smoke and runs in Pika Studio (stages S4–S6)

Porting a kit demo is mechanical: the same hooks, the same API names, the same asset paths.
The step-by-step procedure (manifest mapping, the JS ↔ Lua rules, 1-based data, sprite
export, recording list) is defined once in [skill/porting.md](../../skill/porting.md); an AI
assistant follows it with [prompt C](../templates/prompts.md#c-port-a-kit-demo). This guide
covers what a person decides and checks, and how to port a demo that was **not** built on
the kit.

The worked pair is `kit/template/index.html` → `examples/pick_word/`; keep both open.

## What you check

| Stage | Check | Pass |
| --- | --- | --- |
| S4 | The pack folder sits outside the demo folder and keeps the demo's relative paths (`assets/...`, `fonts/...`). | paths in the code carry over unchanged |
| S4 | Every sprite in `pika-spec.json` exists as a file at its declared size; opaque images and frame strips are `.rgb565` (`python tools/png2rgb565.py`, see the [asset guide](prepare-assets.md)). | no missing or resized file |
| S4 | Every sound alias has a file, a placeholder until the recording arrives. | a missing file rejects the whole pack |
| S5 | Smoke with the playtest's step list. | [S5 gate](../reference/pipeline.md#gates) |
| S6 | The same key script in Pika Studio: every branch, two rounds, a restart; screens compared with the demo's `shot.png`. | nothing to report |

Speed, HOME, LED, servos and voice are proven only on a robot (S9).

## Porting a demo that was not built on the kit

An arbitrary HTML, CSS or canvas demo needs one decision per mechanism first. Write a
**parity table** before any code:

| Demo mechanism | Decision | Reason (which limit) |
| --- | --- | --- |
| e.g. physics ball | adjusted: scripted tween to fixed targets | no physics engine |
| e.g. word wrap in a speech bubble | adjusted: lines broken in the data | no wrap, no width query |
| e.g. three GIFs at once | adjusted: one `Anim`, the others as still sprites | one animation plays at a time |

Usually the fastest route is to rebuild the demo on the kit, keeping its art inside
`pika-art`, pass the S3 gate, then port as above.

Common substitutions:

| Demo | On the engine |
| --- | --- |
| `translate` | `set_pos`, integers only |
| `opacity` | `set_opacity(0..255)` |
| `z-index` | creation order, `set_z`, `to_front`, `to_back` |
| `rotate` / `scale` | only on small sprites ([transform limit](../reference/api.md#transform-limit)); larger: pre-render each angle or size |
| `scaleX(-1)` | `set_flip`, which rewrites pixels: on state changes only |
| `skew`, `matrix`, 3D | pre-render |
| gradients, `box-shadow`, `filter`, `border-radius` | bake into the image; fade with `set_opacity` |
| `mix-blend-mode: screen` over black | bake the luminance into the PNG's alpha channel (keeps glows) |
| other blend modes, tint, recolour | pre-composite, one file per colour |
| "grow the selected item" | move it to the centre and dim the others |
| rotating wobble or shake | a vertical bob or horizontal shake with `set_pos` |
| looping sprite-sheet animation | `Anim` (GIF/MJPEG), or pre-loaded sprites toggled with `set_visible`; not `set_frame` every frame (it reads the SD card) |
| `speechSynthesis` | recorded files |
| `setTimeout` chains | `Timer.millis()` deadlines checked in `on_tick` |
| mouse, touch, drag | a cursor moved with left/right, chosen with confirm |

## See also

- [Write a game pack](write-a-game-pack.md): the pack structure and runtime model
- [Release checklist](release-checklist.md): what only a robot shows
