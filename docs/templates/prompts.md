# Prompts (copy and paste)

Paste one of these into your AI assistant and fill in the `[...]` parts. Each prompt makes
the AI read `skill/` before writing anything; without that, assistants invent functions the
robot does not have. Stage IDs (S0–S9) are defined in the [pipeline](../reference/pipeline.md).

Working in a folder that is not the SDK? Give the AI the SDK location (a local path or the
git URL) so it can read `skill/` and `contract/`.

| Prompt | Stage |
| --- | --- |
| [A. Start a game from a brief](#a-start-a-game-from-a-brief) | S2, then S3 or S4 |
| [B. Report a bug](#b-report-a-bug) | S5–S7 |
| [C. Port a kit demo](#c-port-a-kit-demo) | S4 |
| [D. Review a robot run](#d-review-a-robot-run) | S9 |
| [E. Quick first game](#e-quick-first-game) | S4–S6, no brief or demo |

## A. Start a game from a brief

```text
You will help me build an educational game for the PIKA robot (Pika Engine: Lua 5.5,
480x320 screen, three buttons left/enter/right plus HOME, one sound channel,
English keyword voice).

STEP 1 - Load the contract (mandatory, before writing any code):
Read the skill/ folder of the Pika SDK at: [SDK path or git URL]
Start with skill/SKILL.md and follow its routing. contract/api.json is the complete
API list: a name that is not in it does not exist. Limits come from
contract/constraints.json. Where a doc marks something as an open question, use the
safe way it describes.

STEP 2 - Read my brief: [path to the brief, or paste it at the end]

STEP 3 - Before coding, reply with:
1. A 3-5 sentence summary of the game.
2. The learning goals as you understand them: word set, what the child must say,
   UI language vs learning language, what happens on silence or a wrong answer.
3. Controls mapped to left / enter / right; how the game continues with buttons
   only when voice is unavailable.
4. Win and lose conditions.
5. A budget: live sprites and their PSRAM, Text labels, font faces, sound aliases.
6. What in the brief the engine cannot do, each with an alternative.
7. Whether you propose a browser demo first (skill/demo-kit.md) or Lua directly.
Do not write code until I answer.

STEP 4 - After I confirm:
- Demo: start from kit/template/ in a sibling folder inside kit/, outside any game
  pack; run the S3 gate (docs/reference/pipeline.md) and paste both outputs until the
  verdict is READY TO PORT.
- Lua: start from skill/templates/ or the closest example; reuse libraries/ modules
  instead of rewriting them. Run the S5 gate with steps that reach every branch and
  paste the FULL output. Fix until it ends with 0 error(s); explain every warning.
- Finish with the key presses that test every branch in Pika Studio.

--- Brief (if you cannot point to a file) ---
[brief]
```

Short version, for a session where the AI has already read `skill/`:

```text
Re-read skill/SKILL.md if you have not in this session. Only use names from
contract/api.json. Brief: [path]. Before coding: summary, learning goals, controls
on left/enter/right, win/lose, budget, what exceeds the limits, demo-first or
Lua-direct. Wait for my answer.
```

## B. Report a bug

```text
In [Pika Studio / on the robot] I see: [what you saw, step by step; no guessed cause].
Expected: [what should have happened].
smoke output:
[paste the full output of `python tools/smoke.py <pack> "<steps>"`]
Robot log (if on the robot): [game.start / game.warn / game.error / game.stop lines]

Check skill/pitfalls.md and docs/reference/known-issues.md first. Explain the cause
from the code before changing anything. Fix it, run tools/smoke.py again and paste
the full output. If this failure is in neither file, say so and draft a pitfalls entry.
```

## C. Port a kit demo

```text
Read skill/SKILL.md and skill/porting.md in the Pika SDK at [SDK path].
Port the demo in [demo folder] (with its pika-spec.json, verdict READY TO PORT)
to a Lua pack in [pack folder], outside the demo folder.
Follow porting.md step by step. Keep the demo's asset paths. Then run the S5 gate
with the playtest's steps and paste the full output, and list the files still to be
exported or recorded (sprites, frame strips, voice lines).
```

## D. Review a robot run

```text
Read skill/SKILL.md, docs/reference/telemetry.md and docs/reference/known-issues.md
in the Pika SDK at [SDK path]. This is the serial log of [game] on a robot:
[paste every game.* line of the session, from game.start to game.stop]
What I did: [e.g. three rounds, one wrong answer each, then HOME].
What I saw: [e.g. it stutters when the cards appear].

Go through the release checklist's telemetry gates (docs/guides/release-checklist.md)
one by one: quote the field and value for each, and say pass or fail. For each fail,
name the likely cause with its heuristic from telemetry.md, point at the code, and
propose the smallest change. Do not claim a fix works until a new robot run shows it.
```

## E. Quick first game

For a first playable game right after cloning the SDK: Lua directly from a template,
placeholder art, buttons only, one confirmation before code. Open the SDK folder in the
editor where the AI runs, so the relative paths below resolve. Once it plays, continue with
prompt A's checks (budget, voice fallback) before final art.

```text
Build a first playable game for the PIKA robot, as fast as possible.

Rules:
- Read skill/SKILL.md first and follow its routing. Only use names from
  contract/api.json; a name that is not there does not exist on the robot.
- Lua directly, no browser demo. Start from skill/templates/structured-game: copy
  everything except README.md to games/[game_id]/ (do not edit the template). Reuse
  libraries/ modules instead of writing your own.
- Placeholder art only: Sprite.solid blocks and Text labels. No image files yet.
  Sounds: reuse the template's wav files; every sound in the manifest must exist.
- Buttons only (left / enter / right). No voice in this first version.
- Manifest "name" is {"vi": "...", "en": "..."}. Do not create s.json.

The game: [2-4 sentences: what the child sees, what they press, how they win or lose.
Example: "Three coloured blocks; one word at the top names a colour. Left/right move
a cursor, enter picks. 5 rounds, 1 point per correct pick, then a score screen."]
UI language: [vi / en / both, chosen from params.language]

Before coding, reply in at most 10 lines: controls, win/lose, screens, and anything
the engine cannot do. Then wait for "ok".

After I say ok: write the pack, run
  python tools/smoke.py games/[game_id] "<steps that reach every branch>"
(again with --language vi if the game shows Vietnamese), paste the FULL output and
fix until it ends with 0 error(s). Finish with the key
presses I should try in Pika Studio.
```

Then play it in Pika Studio and report problems with [prompt B](#b-report-a-bug).
`games/` is ignored by the SDK's git, so your packs never mix with SDK changes.

## After the first version

Run it in Pika Studio, describe what looks wrong with prompt B, and repeat. When it plays
well, continue with S7 (final assets) and S8 (publish).
