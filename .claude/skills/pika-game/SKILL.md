---
name: pika-game
description: >
  Make a new game for the PIKA robot from an idea, or fix one under games/. Agrees a short
  plan with the user, then hands the build and the smoke loop to the pika-game-maker agent.
  Use for "/pika-game <idea>", "make a Pika game", "tạo game cho Pika", "fix my Pika game".
---

# /pika-game

The user's idea or request: $ARGUMENTS

You talk with the user; the `pika-game-maker` agent writes the pack. Keep the conversation
short: the goal is a first playable game in Pika Studio.

## 1. Load the rules

Read `skill/SKILL.md` §1 (golden rules) and §2 (route) before answering. Do not describe
engine features from memory; check `contract/api.json` and `skill/constraints.md`.

## 2. Understand the game

If the idea does not say what the child sees, which buttons do what, and how a round is won
or lost, ask at most 5 short questions, in the user's language. Offer sensible defaults so
the user can just accept them.

For a bug in an existing pack instead: ask for what they saw step by step, the full output of
`python tools/smoke.py games/<id> "<steps>"`, and robot log lines if it ran on a robot. Then
go to step 4.

## 3. Agree the plan

`skill/SKILL.md` asks for the seven questions of prompt A
(`docs/templates/prompts.md`) before a new game. Answer them in at most 12 lines, then wait
for the user's "ok":

- game id (folder name under `games/`) and a 1-2 sentence summary
- learning goal: the words or skill practised, what happens on a wrong answer
- controls on left / enter / right, and what HOME does
- screens, and win / lose
- budget: live sprites, Text labels, fonts, sounds (within `skill/constraints.md`)
- anything the engine cannot do, each with an alternative (golden rule G12)
- Lua directly with placeholder art, template sounds, buttons only (no demo, no voice yet);
  UI language vi, en, or both from `params.language`

## 4. Build

Start the `pika-game-maker` agent with the confirmed plan (or the bug report) written out in
full; it cannot see this conversation.

## 5. Hand back

Relay the agent's report: the last line of the smoke run, the key presses to try in Pika
Studio, and what is still placeholder. Then suggest the next step: play it in Pika Studio
(**Pika: Run**), report what looks wrong with `/pika-game fix ...`, and later final art
(`docs/guides/prepare-assets.md`) and publishing (`docs/guides/release-checklist.md`).
