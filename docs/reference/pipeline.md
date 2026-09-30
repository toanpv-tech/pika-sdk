# Pipeline: stages and gates

The one path every game takes, from idea to robot. Guides, prompts and checklists refer to
these stage IDs; this page is where each stage's input, output and gate are defined. A stage
is done only when its gate passes: a command's exact output, or a named human check.

Run every command from the SDK root.

| ID | Stage | Owner | Input | Output | Gate |
| --- | --- | --- | --- | --- | --- |
| S0 | Set up | everyone, once | this SDK, Pika Studio | working tools | `smoke.py examples/pick_word` passes (below) |
| S1 | Brief | game designer | an idea | a filled [brief](../templates/brief-template.md) | someone else can describe the game back from it |
| S2 | Challenge the brief | AI + designer | the brief | answers to [prompt A](../templates/prompts.md#a-start-a-game-from-a-brief); mode chosen | designer agrees; mode is *demo first* or *Lua directly* |
| S3 | Browser demo *(demo first only)* | designer + AI | the brief | kit demo, `pika-spec.json`, **To record** list | `playtest.js` then `check_spec.py` pass (below) |
| S4 | Lua pack | developer or AI | brief, or demo + spec | a pack folder outside any demo folder | the folder has `manifest.json` and `scripts/main.lua` |
| S5 | Smoke | developer or AI | the pack | smoke report | `smoke.py <pack>` passes (below) |
| S6 | Pika Studio | whole team | the pack | a playable build | every path played twice (win, lose, each wrong answer, restart) with nothing to report |
| S7 | Final assets | artist, audio | [asset guide](../guides/prepare-assets.md), **To record** list | final files under the placeholder names | smoke passes again; no placeholder left |
| S8 | Publish to a robot | pack owner | the pack | the pack on a robot, with `s.json` | the robot opens the game |
| S9 | Robot check | QA | the published pack | a ticked [release checklist](../guides/release-checklist.md) | every item ticked |

S3 is skipped in *Lua directly* mode. Choose *demo first* when the game has several screens,
custom art or recorded voice lines. After a fix in S6, S7 or S9, go back to S5.

## Gates

**S0 and S5/S7: smoke.** One-time setup: Python 3 and `pip install -r tools/requirements.txt`.

```bash
python tools/smoke.py <pack> "<steps>"
```

Pass: exit code 0 and a last line `0 error(s), N warning(s)`. For S0 use
`examples/pick_word` without steps; it must print `0 error(s), 0 warning(s)`. Steps walk every
branch (`left|right|enter|home`, `hold:<button>:<ms>`, `wait:<ms>`, `voice:<keyword>`,
`restart`); the full list is at the top of `tools/smoke.py`. A game with several UI languages
runs the gate once per language: add `--language vi` (default `en`, passed as
`params.language`). Every warning needs an explanation, even when it is kept.

**S3: demo gate.** One-time setup: Node.js, then `cd tools && npm install && npx playwright install chromium`.

```bash
node tools/playtest.js <demo>/index.html "<steps>" [--out <dir>]
python tools/check_spec.py <demo>/pika-spec.json
```

Pass: `playtest.js` exits 0 (no `JS-ERROR` line), and `check_spec.py` prints
`Verdict: READY TO PORT` and exits 0. `playtest.js` writes `pika-spec.json` and one `shot.png`
of the final state; run it once per screen with `--out` to keep several shots.

**S8: publish.** A pack runs on a robot only after it is published through the Pika
platform, which adds the `s.json` checksums the robot checks. Copying a folder to an SD card
is not enough, and `s.json` is never created or edited by hand. A step-by-step deployment
guide is being written; until then, ask the Pika team to publish your pack.

## What each stage cannot prove

| Stage | Proves | Not proven until |
| --- | --- | --- |
| S3 (kit) | contract use and layout in a browser | real Lua semantics (S5) |
| S5 (smoke) | Lua logic, contract use, pools, sandbox | drawing, sound and feel (S6) |
| S6 (Pika Studio) | the real engine compiled for a PC | speed, HOME, LED, servos, real voice, `s.json` (S9) |

The full list of PC-vs-robot differences is in
[Known issues](known-issues.md#pc-vs-robot).
