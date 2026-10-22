---
name: pika-game
description: >
  Make a new game for the PIKA robot from an idea, or fix one under games/. Agrees a short
  plan with the user, then runs the loop: pika-game-maker or pika-game-porter builds,
  pika-game-cleaner cleans, pika-game-tester tests, pika-game-optimizer fixes speed and memory
  from a robot log. Use for "/pika-game <idea>", "make a Pika game", "tạo game cho Pika", "fix my Pika game".
---

# /pika-game

The user's idea or request: $ARGUMENTS

You talk with the user and run the loop; the agents write, review and test the pack. Keep
the conversation short: the goal is a first playable game in Pika Studio.

The SDK is the installed plugin at `${CLAUDE_PLUGIN_ROOT}`; every `knowledge/`, `contract/`,
`docs/` and `tools/` path below is under it. Packs go in `games/<id>/` in the current working
directory.

## 1. Load the rules

Read `knowledge/SKILL.md` §1 (golden rules) and §2 (route) before answering. Do not describe
engine features from memory; check `contract/api.json` and `knowledge/constraints.md`.

## 2. Understand the game

If the idea does not say what the child sees, which buttons do what, and how a round is won
or lost, ask at most 5 short questions, in the user's language. Offer sensible defaults so
the user can just accept them.

For a bug in an existing pack instead: ask for what they saw step by step, the full output of
`python "${CLAUDE_PLUGIN_ROOT}/tools/smoke.py" games/<id> "<steps>"`, and robot log lines if it ran on a robot. Then
go to step 4.

## 3. Agree the plan

`knowledge/SKILL.md` asks for the seven questions of prompt A
(`docs/templates/prompts.md`) before a new game. Answer them in at most 12 lines, then wait
for the user's "ok":

- game id (folder name under `games/`) and a 1-2 sentence summary
- learning goal: the words or skill practised, what happens on a wrong answer
- controls on left / enter / right, and what HOME does
- screens, and win / lose
- budget: live sprites, Text labels, fonts, sounds (within `knowledge/constraints.md`)
- anything the engine cannot do, each with an alternative (golden rule G12)
- Lua directly with placeholder art, template sounds, buttons only (no demo, no voice yet);
  UI language vi, en, or both from `params.language`

## 4. Build

Start the agent that fits, with the confirmed plan (or the bug report) written out in full; it
cannot see this conversation:

- `pika-game-maker`: Lua directly from the plan, or a bug in a pack.
- `pika-game-porter`: the user brings a brief with art, a design doc or a demo `.html`, or
  wants costed engagement ideas. It stops after intake, fit and budget; show those to the user
  and wait for "ok" before it builds.
- `pika-game-optimizer`: the game is slow, stutters, opens slowly or grows in memory, or a
  robot log shows it. Ask for the serial log first; without one it can only say what to
  record. Its proposals that change what the player sees need the user's "ok".

## 5. Review and test

1. `pika-game-cleaner` in mode `light` on the files the builder changed.
2. `pika-game-tester` on the pack, with the plan's branches and UI languages.
3. On FAIL, send the tester's findings (and the cleaner's deferred items) back to the builder,
   then review and test again. Stop after three rounds and ask the user, with the open
   findings.
4. When the tester scored a log and a performance gate is WARN or FAIL (frames keep time, no
   leak between rounds, a stall or a watchdog error), send the pack and the log to
   `pika-game-optimizer`, then `pika-game-cleaner` in mode `light`, then the tester again.
5. On PASS, `pika-game-cleaner` in mode `full`, then `pika-game-tester` again as a regression
   run.

Decide from each agent's JSON block, not from its prose.

## 6. Hand back

Relay the tester's verdict and branch table, the cleaner's deferred items, the key presses to
try in Pika Studio, and what is still placeholder. Then suggest the next step: play it in Pika
Studio (**Pika: Run**), report what looks wrong with `/pika-game fix ...`, run `/pika-test` with
a robot log once it ran on a robot, and later final art (`docs/guides/prepare-assets.md`) and
publishing (`docs/guides/release-checklist.md`).
