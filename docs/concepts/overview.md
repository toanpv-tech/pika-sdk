# Overview

What the PIKA robot is, how the Pika Engine runs a game, and why games are designed the way
this SDK asks. Facts and numbers live in the [API reference](../reference/api.md); this page
explains the model behind them.

## The robot

PIKA is a small desktop robot: a 480 × 320 colour screen, a speaker, a microphone, an RGB
LED, four servo joints (head, base, left arm, right arm), three game buttons (LEFT, ENTER,
RIGHT) and a HOME button. It has two boards: the **head** board runs the screen, sound and
the game engine; the **body** board runs buttons, servos, LED, network and voice, and talks
to the head over an internal link that games never see.

## The engine model

A game is a **pack** (a folder: `manifest.json`, Lua scripts, assets) that the Pika Engine
loads into a fresh, sandboxed Lua 5.5 VM on the head board.

- **The engine owns the loop.** A game defines global hook functions (`game_start`,
  `on_tick`, `on_input`, ...). Each frame the engine drains sound and button events into
  hooks, calls `on_tick`, sends queued servo and LED commands, and publishes all screen
  changes at once ([frame order](../reference/api.md#hooks)). There is no `while` loop, no
  sleep and no draw callback.
- **Graphics are retained.** A `Sprite`, `Text`, `Shape` or `Anim` is created once and then
  changed (moved, faded, shown, hidden); the engine redraws what changed.
- **Peripherals are asynchronous.** Servo, LED, voice and ranking calls are queued and return
  at once; only the speaker reports completion (`on_sound_end`). Gameplay never waits on them.
- **Every limit is hard.** Past a limit a call fails, a hook is aborted, or the pack is
  rejected ([limits](../reference/api.md#limits)). Nothing degrades gracefully by itself.

## Why "static inside, dynamic outside"

At runtime the engine can move, fade, show or hide, flip, restack and swap frames of images,
change text, and play recorded sounds. It cannot blend, blur, tint, draw gradients or
shadows, wrap text, or speak. So everything rich is **prepared ahead of time**: baked into
images at their final size and recorded as audio files. A browser demo built on the SDK's
kit enforces this while you play, which is why porting it to Lua becomes transliteration.

## Two ways a game is played

Both use the same pack and API.

| | Menu | Talk flow (A2A) |
| --- | --- | --- |
| Started by | the child, from the robot's game menu | the server, during a conversation |
| `params.is_a2a` | `false` | `true`, plus the server's start parameters |
| Ends | `Engine.exit()`, or HOME when `on_home` does not keep the game | the same; the conversation then resumes |
| Result | `Ranking.report` goes to the leaderboard | `Engine.report_result` goes to the conversation |

Voice keywords work in both flows for a pack that declares `"voice"`. From the menu the
robot opens its own voice connection for the game and ends the game if that connection fails
(for example without network); in talk flow the conversation's connection carries the
keywords ([Voice](../reference/api.md#voice)). Buttons must always be enough to play.

## How a game gets made

Ten stages, S0 to S9, each with a gate that proves it is done: set up, brief, challenge the
brief, optional browser demo, Lua pack, smoke check, Pika Studio, final assets, publish,
robot check. The table, owners and exact gates are in the [pipeline](../reference/pipeline.md).
